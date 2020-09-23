/*
 * Copyright 2014 MongoDB, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <CLibMongoC_bson.h>

#include "CLibMongoC_mongoc-config.h"
#include "CLibMongoC_mongoc-error.h"
#include "mongoc-trace-private.h"
#include "mongoc-topology-scanner-private.h"
#include "mongoc-stream-private.h"
#include "CLibMongoC_mongoc-stream-socket.h"

#include "CLibMongoC_mongoc-handshake.h"
#include "mongoc-handshake-private.h"

#ifdef MONGOC_ENABLE_SSL
#include "CLibMongoC_mongoc-stream-tls.h"
#endif

#include "mongoc-counters-private.h"
#include "utlist.h"
#include "mongoc-topology-private.h"
#include "mongoc-host-list-private.h"
#include "mongoc-uri-private.h"
#include "mongoc-cluster-private.h"
#include "mongoc-client-private.h"
#include "mongoc-util-private.h"

#undef MONGOC_LOG_DOMAIN
#define MONGOC_LOG_DOMAIN "topology_scanner"

#define DNS_CACHE_TIMEOUT_MS 10 * 60 * 1000
#define HAPPY_EYEBALLS_DELAY_MS 250

/* forward declarations */
static void
_async_connected (mongoc_async_cmd_t *acmd);

static void
_async_success (mongoc_async_cmd_t *acmd,
                const bson_t *ismaster_response,
                int64_t duration_usec);

static void
_async_error_or_timeout (mongoc_async_cmd_t *acmd,
                         int64_t duration_usec,
                         const char *default_err_msg);

static void
_async_handler (mongoc_async_cmd_t *acmd,
                mongoc_async_cmd_result_t async_status,
                const bson_t *ismaster_response,
                int64_t duration_usec);

static void
_mongoc_topology_scanner_monitor_heartbeat_started (
   const mongoc_topology_scanner_t *ts, const mongoc_host_list_t *host);

static void
_mongoc_topology_scanner_monitor_heartbeat_succeeded (
   const mongoc_topology_scanner_t *ts,
   const mongoc_host_list_t *host,
   const bson_t *reply,
   int64_t duration_usec);

static void
_mongoc_topology_scanner_monitor_heartbeat_failed (
   const mongoc_topology_scanner_t *ts,
   const mongoc_host_list_t *host,
   const bson_error_t *error,
   int64_t duration_usec);


/* reset "retired" nodes that failed or were removed in the previous scan */
static void
_delete_retired_nodes (mongoc_topology_scanner_t *ts);

/* cancel any pending async commands for a specific node excluding acmd.
 * If acmd is NULL, cancel all async commands on the node. */
static void
_cancel_commands_excluding (mongoc_topology_scanner_node_t *node,
                            mongoc_async_cmd_t *acmd);

/* return the number of pending async commands for a node. */
static int
_count_acmds (mongoc_topology_scanner_node_t *node);

/* if acmd fails, schedule the sibling commands sooner. */
static void
_jumpstart_other_acmds (mongoc_topology_scanner_node_t *node,
                        mongoc_async_cmd_t *acmd);

static void
_add_ismaster (bson_t *cmd)
{
   BSON_APPEND_INT32 (cmd, "isMaster", 1);
}

const char *
_mongoc_topology_scanner_get_speculative_auth_mechanism (
   const mongoc_uri_t *uri)
{
   const char *mechanism = mongoc_uri_get_auth_mechanism (uri);
   bool requires_auth = mechanism || mongoc_uri_get_username (uri);

   if (!requires_auth) {
      return NULL;
   }

   if (!mechanism) {
      return "SCRAM-SHA-256";
   }

   return mechanism;
}

void
_mongoc_topology_scanner_add_speculative_authentication (
   bson_t *cmd,
   const mongoc_uri_t *uri,
   const mongoc_ssl_opt_t *ssl_opts,
   mongoc_scram_cache_t *scram_cache,
   mongoc_scram_t *scram /* OUT */)
{
   bson_t auth_cmd;
   bson_error_t error;
   bool has_auth = false;
   const char *mechanism =
      _mongoc_topology_scanner_get_speculative_auth_mechanism (uri);

   if (!mechanism) {
      return;
   }

   if (strcasecmp (mechanism, "MONGODB-X509") == 0) {
      /* Ignore errors while building authentication document: we proceed with
       * the handshake as usual and let the subsequent authenticate command
       * fail. */
      if (_mongoc_cluster_get_auth_cmd_x509 (
             uri, ssl_opts, &auth_cmd, &error)) {
         has_auth = true;
         BSON_APPEND_UTF8 (&auth_cmd, "db", "$external");
      }
   }

#ifdef MONGOC_ENABLE_CRYPTO
   if (strcasecmp (mechanism, "SCRAM-SHA-1") == 0 ||
       strcasecmp (mechanism, "SCRAM-SHA-256") == 0) {
      mongoc_crypto_hash_algorithm_t algo =
         strcasecmp (mechanism, "SCRAM-SHA-1") == 0
            ? MONGOC_CRYPTO_ALGORITHM_SHA_1
            : MONGOC_CRYPTO_ALGORITHM_SHA_256;

      _mongoc_uri_init_scram (uri, scram, algo);

      if (scram_cache) {
         _mongoc_scram_set_cache (scram, scram_cache);
      }

      if (_mongoc_cluster_get_auth_cmd_scram (algo, scram, &auth_cmd, &error)) {
         const char *auth_source;

         if (!(auth_source = mongoc_uri_get_auth_source (uri)) ||
             (*auth_source == '\0')) {
            auth_source = "admin";
         }

         has_auth = true;
         BSON_APPEND_UTF8 (&auth_cmd, "db", auth_source);
      }
   }
#endif

   if (has_auth) {
      BSON_APPEND_DOCUMENT (cmd, "speculativeAuthenticate", &auth_cmd);
      bson_destroy (&auth_cmd);
   }
}

void
_mongoc_topology_scanner_parse_speculative_authentication (
   const bson_t *ismaster, bson_t *speculative_authenticate)
{
   bson_iter_t iter;
   uint32_t data_len;
   const uint8_t *data;
   bson_t auth_response;

   BSON_ASSERT (ismaster);
   BSON_ASSERT (speculative_authenticate);

   if (!bson_iter_init_find (&iter, ismaster, "speculativeAuthenticate")) {
      return;
   }

   bson_iter_document (&iter, &data_len, &data);
   BSON_ASSERT (bson_init_static (&auth_response, data, data_len));

   bson_destroy (speculative_authenticate);
   bson_copy_to (&auth_response, speculative_authenticate);
}

static bool
_build_ismaster_with_handshake (mongoc_topology_scanner_t *ts)
{
   bson_t *doc = &ts->ismaster_cmd_with_handshake;
   bson_t subdoc;
   bson_iter_t iter;
   const char *key;
   int keylen;
   bool res;
   const bson_t *compressors;
   int count = 0;
   char buf[16];

   _add_ismaster (doc);

   BSON_APPEND_DOCUMENT_BEGIN (doc, HANDSHAKE_FIELD, &subdoc);
   res = _mongoc_handshake_build_doc_with_application (&subdoc, ts->appname);
   bson_append_document_end (doc, &subdoc);

   BSON_APPEND_ARRAY_BEGIN (doc, "compression", &subdoc);
   if (ts->uri) {
      compressors = mongoc_uri_get_compressors (ts->uri);

      if (bson_iter_init (&iter, compressors)) {
         while (bson_iter_next (&iter)) {
            keylen = bson_uint32_to_string (count++, &key, buf, sizeof buf);
            bson_append_utf8 (
               &subdoc, key, (int) keylen, bson_iter_key (&iter), -1);
         }
      }
   }
   bson_append_array_end (doc, &subdoc);

   /* Return whether the handshake doc fit the size limit */
   return res;
}

/* Caller must lock topology->mutex to protect ismaster_cmd_with_handshake. This
 * is called at the start of the scan in _mongoc_topology_run_background, when a
 * node is added in _mongoc_topology_reconcile_add_nodes, or when running an
 * ismaster directly on a node in _mongoc_stream_run_ismaster. */
const bson_t *
_mongoc_topology_scanner_get_ismaster (mongoc_topology_scanner_t *ts)
{
   /* If this is the first time using the node or if it's the first time
    * using it after a failure, build handshake doc */
   if (bson_empty (&ts->ismaster_cmd_with_handshake)) {
      ts->handshake_ok_to_send = _build_ismaster_with_handshake (ts);
      if (!ts->handshake_ok_to_send) {
         MONGOC_WARNING ("Handshake doc too big, not including in isMaster");
      }
   }

   /* If the doc turned out to be too big */
   if (!ts->handshake_ok_to_send) {
      return &ts->ismaster_cmd;
   }

   return &ts->ismaster_cmd_with_handshake;
}

static void
_begin_ismaster_cmd (mongoc_topology_scanner_node_t *node,
                     mongoc_stream_t *stream,
                     bool is_setup_done,
                     struct addrinfo *dns_result,
                     int64_t initiate_delay_ms)
{
   mongoc_topology_scanner_t *ts = node->ts;
   bson_t cmd;

   if (node->last_used != -1 && node->last_failed == -1) {
      /* The node's been used before and not failed recently */
      bson_copy_to (&ts->ismaster_cmd, &cmd);
   } else {
      bson_copy_to (_mongoc_topology_scanner_get_ismaster (ts), &cmd);
   }

   if (node->ts->negotiate_sasl_supported_mechs &&
       !node->negotiated_sasl_supported_mechs) {
      _mongoc_handshake_append_sasl_supported_mechs (ts->uri, &cmd);
   }

   if (node->ts->speculative_authentication && !node->has_auth &&
       bson_empty (&node->speculative_auth_response) && node->scram.step == 0) {
      mongoc_ssl_opt_t *ssl_opts = NULL;

#ifdef MONGOC_ENABLE_SSL
      ssl_opts = ts->ssl_opts;
#endif

      _mongoc_topology_scanner_add_speculative_authentication (
         &cmd, ts->uri, ssl_opts, NULL, &node->scram);
   }

   if (!bson_empty (&ts->cluster_time)) {
      bson_append_document (&cmd, "$clusterTime", 12, &ts->cluster_time);
   }

   /* if the node should connect with a TCP socket, stream will be null, and
    * dns_result will be set. The async loop is responsible for calling the
    * _tcp_initiator to construct TCP sockets. */
   mongoc_async_cmd_new (ts->async,
                         stream,
                         is_setup_done,
                         dns_result,
                         _mongoc_topology_scanner_tcp_initiate,
                         initiate_delay_ms,
                         ts->setup,
                         node->host.host,
                         "admin",
                         &cmd,
                         &_async_handler,
                         node,
                         ts->connect_timeout_msec);

   bson_destroy (&cmd);
}


mongoc_topology_scanner_t *
mongoc_topology_scanner_new (
   const mongoc_uri_t *uri,
   mongoc_topology_scanner_setup_err_cb_t setup_err_cb,
   mongoc_topology_scanner_cb_t cb,
   void *data,
   int64_t connect_timeout_msec)
{
   mongoc_topology_scanner_t *ts =
      (mongoc_topology_scanner_t *) bson_malloc0 (sizeof (*ts));

   ts->async = mongoc_async_new ();

   bson_init (&ts->ismaster_cmd);
   _add_ismaster (&ts->ismaster_cmd);
   bson_init (&ts->ismaster_cmd_with_handshake);
   bson_init (&ts->cluster_time);

   ts->setup_err_cb = setup_err_cb;
   ts->cb = cb;
   ts->cb_data = data;
   ts->uri = uri;
   ts->appname = NULL;
   ts->handshake_ok_to_send = false;
   ts->connect_timeout_msec = connect_timeout_msec;
   /* may be overridden for testing. */
   ts->dns_cache_timeout_ms = DNS_CACHE_TIMEOUT_MS;

   return ts;
}

#ifdef MONGOC_ENABLE_SSL
void
mongoc_topology_scanner_set_ssl_opts (mongoc_topology_scanner_t *ts,
                                      mongoc_ssl_opt_t *opts)
{
   ts->ssl_opts = opts;
   ts->setup = mongoc_async_cmd_tls_setup;
}
#endif

void
mongoc_topology_scanner_set_stream_initiator (mongoc_topology_scanner_t *ts,
                                              mongoc_stream_initiator_t si,
                                              void *ctx)
{
   ts->initiator = si;
   ts->initiator_context = ctx;
   ts->setup = NULL;
}

void
mongoc_topology_scanner_destroy (mongoc_topology_scanner_t *ts)
{
   mongoc_topology_scanner_node_t *ele, *tmp;

   DL_FOREACH_SAFE (ts->nodes, ele, tmp)
   {
      mongoc_topology_scanner_node_destroy (ele, false);
   }

   mongoc_async_destroy (ts->async);
   bson_destroy (&ts->ismaster_cmd);
   bson_destroy (&ts->ismaster_cmd_with_handshake);
   bson_destroy (&ts->cluster_time);

   /* This field can be set by a mongoc_client */
   bson_free ((char *) ts->appname);

   bson_free (ts);
}

/* whether the scanner was successfully initialized - false if a mongodb+srv
 * URI failed to resolve to any hosts */
bool
mongoc_topology_scanner_valid (mongoc_topology_scanner_t *ts)
{
   return ts->nodes != NULL;
}

void
mongoc_topology_scanner_add (mongoc_topology_scanner_t *ts,
                             const mongoc_host_list_t *host,
                             uint32_t id)
{
   mongoc_topology_scanner_node_t *node;

   node = (mongoc_topology_scanner_node_t *) bson_malloc0 (sizeof (*node));

   memcpy (&node->host, host, sizeof (*host));

   node->id = id;
   node->ts = ts;
   node->last_failed = -1;
   node->last_used = -1;
   bson_init (&node->speculative_auth_response);

   DL_APPEND (ts->nodes, node);
}

void
mongoc_topology_scanner_scan (mongoc_topology_scanner_t *ts, uint32_t id)
{
   mongoc_topology_scanner_node_t *node;

   node = mongoc_topology_scanner_get_node (ts, id);

   /* begin non-blocking connection, don't wait for success */
   if (node) {
      mongoc_topology_scanner_node_setup (node, &node->last_error);
   }

   /* if setup fails the node stays in the scanner. destroyed after the scan. */
}

void
mongoc_topology_scanner_disconnect (mongoc_topology_scanner_t *scanner)
{
   mongoc_topology_scanner_node_t *node;

   BSON_ASSERT (scanner);
   node = scanner->nodes;

   while (node) {
      mongoc_topology_scanner_node_disconnect (node, false);
      node = node->next;
   }
}

void
mongoc_topology_scanner_node_retire (mongoc_topology_scanner_node_t *node)
{
   /* cancel any pending commands. */
   _cancel_commands_excluding (node, NULL);

   node->retired = true;
}

void
mongoc_topology_scanner_node_disconnect (mongoc_topology_scanner_node_t *node,
                                         bool failed)
{
   /* the node may or may not have succeeded in finding a working stream. */
   if (node->stream) {
      if (failed) {
         mongoc_stream_failed (node->stream);
      } else {
         mongoc_stream_destroy (node->stream);
      }

      node->stream = NULL;
      memset (
         &node->sasl_supported_mechs, 0, sizeof (node->sasl_supported_mechs));
      node->negotiated_sasl_supported_mechs = false;
      bson_reinit (&node->speculative_auth_response);
   }
}

void
mongoc_topology_scanner_node_destroy (mongoc_topology_scanner_node_t *node,
                                      bool failed)
{
   DL_DELETE (node->ts->nodes, node);
   mongoc_topology_scanner_node_disconnect (node, failed);
   if (node->dns_results) {
      freeaddrinfo (node->dns_results);
   }

   bson_destroy (&node->speculative_auth_response);

#ifdef MONGOC_ENABLE_CRYPTO
   _mongoc_scram_destroy (&node->scram);
#endif

   bson_free (node);
}

/*
 *--------------------------------------------------------------------------
 *
 * mongoc_topology_scanner_get_node --
 *
 *      Return the scanner node with the given id.
 *
 *--------------------------------------------------------------------------
 */
mongoc_topology_scanner_node_t *
mongoc_topology_scanner_get_node (mongoc_topology_scanner_t *ts, uint32_t id)
{
   mongoc_topology_scanner_node_t *ele, *tmp;

   DL_FOREACH_SAFE (ts->nodes, ele, tmp)
   {
      if (ele->id == id) {
         return ele;
      }

      if (ele->id > id) {
         break;
      }
   }

   return NULL;
}

/*
 *--------------------------------------------------------------------------
 *
 * mongoc_topology_scanner_has_node_for_host --
 *
 *      Whether the scanner has a node for the given host and port.
 *
 *--------------------------------------------------------------------------
 */
bool
mongoc_topology_scanner_has_node_for_host (mongoc_topology_scanner_t *ts,
                                           mongoc_host_list_t *host)
{
   mongoc_topology_scanner_node_t *ele, *tmp;

   DL_FOREACH_SAFE (ts->nodes, ele, tmp)
   {
      if (_mongoc_host_list_compare_one (&ele->host, host)) {
         return true;
      }
   }

   return false;
}

static void
_async_connected (mongoc_async_cmd_t *acmd)
{
   mongoc_topology_scanner_node_t *node =
      (mongoc_topology_scanner_node_t *) acmd->data;
   /* this cmd connected successfully, cancel other cmds on this node. */
   _cancel_commands_excluding (node, acmd);
   node->successful_dns_result = acmd->dns_result;
}

static void
_async_success (mongoc_async_cmd_t *acmd,
                const bson_t *ismaster_response,
                int64_t duration_usec)
{
   void *data = acmd->data;
   mongoc_topology_scanner_node_t *node =
      (mongoc_topology_scanner_node_t *) data;
   mongoc_stream_t *stream = acmd->stream;
   mongoc_topology_scanner_t *ts = node->ts;

   if (node->retired) {
      if (stream) {
         mongoc_stream_failed (stream);
      }
      return;
   }

   node->last_used = bson_get_monotonic_time ();
   node->last_failed = -1;

   _mongoc_topology_scanner_monitor_heartbeat_succeeded (
      ts, &node->host, ismaster_response, duration_usec);

   /* set our successful stream. */
   BSON_ASSERT (!node->stream);
   node->stream = stream;

   if (ts->negotiate_sasl_supported_mechs &&
       !node->negotiated_sasl_supported_mechs) {
      _mongoc_handshake_parse_sasl_supported_mechs (
         ismaster_response, &node->sasl_supported_mechs);
   }

   if (ts->speculative_authentication) {
      _mongoc_topology_scanner_parse_speculative_authentication (
         ismaster_response, &node->speculative_auth_response);
   }

   /* mongoc_topology_scanner_cb_t takes rtt_msec, not usec */
   ts->cb (node->id,
           ismaster_response,
           duration_usec / 1000,
           ts->cb_data,
           &acmd->error);
}

static void
_async_error_or_timeout (mongoc_async_cmd_t *acmd,
                         int64_t duration_usec,
                         const char *default_err_msg)
{
   void *data = acmd->data;
   mongoc_topology_scanner_node_t *node =
      (mongoc_topology_scanner_node_t *) data;
   mongoc_stream_t *stream = acmd->stream;
   mongoc_topology_scanner_t *ts = node->ts;
   bson_error_t *error = &acmd->error;
   int64_t now = bson_get_monotonic_time ();
   const char *message;

   /* the stream may have failed on initiation. */
   if (stream) {
      mongoc_stream_failed (stream);
   }

   if (node->retired) {
      return;
   }

   node->last_used = now;

   if (!node->stream && _count_acmds (node) == 1) {
      /* there are no remaining streams, connecting has failed. */
      node->last_failed = now;
      if (error->code) {
         message = error->message;
      } else {
         message = default_err_msg;
      }

      /* invalidate any cached DNS results. */
      if (node->dns_results) {
         freeaddrinfo (node->dns_results);
         node->dns_results = NULL;
         node->successful_dns_result = NULL;
      }

      bson_set_error (&node->last_error,
                      MONGOC_ERROR_CLIENT,
                      MONGOC_ERROR_STREAM_CONNECT,
                      "%s calling ismaster on \'%s\'",
                      message,
                      node->host.host_and_port);

      _mongoc_topology_scanner_monitor_heartbeat_failed (
         ts, &node->host, &node->last_error, duration_usec);

      /* call the topology scanner callback. cannot connect to this node.
       * callback takes rtt_msec, not usec. */
      ts->cb (node->id, NULL, duration_usec / 1000, ts->cb_data, error);
   } else {
      /* there are still more commands left for this node or it succeeded
       * with another stream. skip the topology scanner callback. */
      _jumpstart_other_acmds (node, acmd);
   }
}

/*
 *-----------------------------------------------------------------------
 *
 * This is the callback passed to async_cmd when we're running
 * ismasters from within the topology monitor.
 *
 *-----------------------------------------------------------------------
 */

static void
_async_handler (mongoc_async_cmd_t *acmd,
                mongoc_async_cmd_result_t async_status,
                const bson_t *ismaster_response,
                int64_t duration_usec)
{
   BSON_ASSERT (acmd->data);

   switch (async_status) {
   case MONGOC_ASYNC_CMD_CONNECTED:
      _async_connected (acmd);
      return;
   case MONGOC_ASYNC_CMD_SUCCESS:
      _async_success (acmd, ismaster_response, duration_usec);
      return;
   case MONGOC_ASYNC_CMD_TIMEOUT:
      _async_error_or_timeout (acmd, duration_usec, "connection timeout");
      return;
   case MONGOC_ASYNC_CMD_ERROR:
      _async_error_or_timeout (acmd, duration_usec, "connection error");
      return;
   case MONGOC_ASYNC_CMD_IN_PROGRESS:
   default:
      fprintf (stderr, "unexpected async status: %d\n", async_status);
      BSON_ASSERT (false);
      return;
   }
}

mongoc_stream_t *
_mongoc_topology_scanner_node_setup_stream_for_tls (
   mongoc_topology_scanner_node_t *node, mongoc_stream_t *stream)
{
#ifdef MONGOC_ENABLE_SSL
   mongoc_stream_t *tls_stream;
#endif
   if (!stream) {
      return NULL;
   }
#ifdef MONGOC_ENABLE_SSL
   if (node->ts->ssl_opts) {
      tls_stream = mongoc_stream_tls_new_with_hostname (
         stream, node->host.host, node->ts->ssl_opts, 1);
      if (!tls_stream) {
         mongoc_stream_destroy (stream);
         return NULL;
      } else {
         return tls_stream;
      }
   }
#endif
   return stream;
}

/* attempt to create a new socket stream using this dns result. */
mongoc_stream_t *
_mongoc_topology_scanner_tcp_initiate (mongoc_async_cmd_t *acmd)
{
   mongoc_topology_scanner_node_t *node =
      (mongoc_topology_scanner_node_t *) acmd->data;
   struct addrinfo *res = acmd->dns_result;
   mongoc_socket_t *sock = NULL;

   BSON_ASSERT (acmd->dns_result);
   /* create a new non-blocking socket. */
   if (!(sock = mongoc_socket_new (
            res->ai_family, res->ai_socktype, res->ai_protocol))) {
      return NULL;
   }

   (void) mongoc_socket_connect (
      sock, res->ai_addr, (mongoc_socklen_t) res->ai_addrlen, 0);

   return _mongoc_topology_scanner_node_setup_stream_for_tls (
      node, mongoc_stream_socket_new (sock));
}
/*
 *--------------------------------------------------------------------------
 *
 * mongoc_topology_scanner_node_setup_tcp --
 *
 *      Create an async command for each DNS record found for this node.
 *
 * Returns:
 *      A bool. On failure error is set.
 *
 *--------------------------------------------------------------------------
 */

bool
mongoc_topology_scanner_node_setup_tcp (mongoc_topology_scanner_node_t *node,
                                        bson_error_t *error)
{
   struct addrinfo hints;
   struct addrinfo *iter;
   char portstr[8];
   mongoc_host_list_t *host;
   int s;
   int64_t delay = 0;
   int64_t now = bson_get_monotonic_time ();

   ENTRY;

   host = &node->host;

   /* if cached dns results are expired, flush. */
   if (node->dns_results &&
       (now - node->last_dns_cache) > node->ts->dns_cache_timeout_ms * 1000) {
      freeaddrinfo (node->dns_results);
      node->dns_results = NULL;
      node->successful_dns_result = NULL;
   }

   if (!node->dns_results) {
      bson_snprintf (portstr, sizeof portstr, "%hu", host->port);

      memset (&hints, 0, sizeof hints);
      hints.ai_family = host->family;
      hints.ai_socktype = SOCK_STREAM;
      hints.ai_flags = 0;
      hints.ai_protocol = 0;

      s = getaddrinfo (host->host, portstr, &hints, &node->dns_results);

      if (s != 0) {
         mongoc_counter_dns_failure_inc ();
         bson_set_error (error,
                         MONGOC_ERROR_STREAM,
                         MONGOC_ERROR_STREAM_NAME_RESOLUTION,
                         "Failed to resolve '%s'",
                         host->host);
         RETURN (false);
      }

      mongoc_counter_dns_success_inc ();
      node->last_dns_cache = now;
   }

   if (node->successful_dns_result) {
      _begin_ismaster_cmd (node, NULL, false, node->successful_dns_result, 0);
   } else {
      LL_FOREACH2 (node->dns_results, iter, ai_next)
      {
         _begin_ismaster_cmd (node, NULL, false, iter, delay);
         /* each subsequent DNS result will have an additional 250ms delay. */
         delay += HAPPY_EYEBALLS_DELAY_MS;
      }
   }

   RETURN (true);
}

bool
mongoc_topology_scanner_node_connect_unix (mongoc_topology_scanner_node_t *node,
                                           bson_error_t *error)
{
#ifdef _WIN32
   ENTRY;
   bson_set_error (error,
                   MONGOC_ERROR_STREAM,
                   MONGOC_ERROR_STREAM_CONNECT,
                   "UNIX domain sockets not supported on win32.");
   RETURN (false);
#else
   struct sockaddr_un saddr;
   mongoc_socket_t *sock;
   mongoc_stream_t *stream;
   mongoc_host_list_t *host;

   ENTRY;

   host = &node->host;

   memset (&saddr, 0, sizeof saddr);
   saddr.sun_family = AF_UNIX;
   bson_snprintf (saddr.sun_path, sizeof saddr.sun_path - 1, "%s", host->host);

   sock = mongoc_socket_new (AF_UNIX, SOCK_STREAM, 0);

   if (sock == NULL) {
      bson_set_error (error,
                      MONGOC_ERROR_STREAM,
                      MONGOC_ERROR_STREAM_SOCKET,
                      "Failed to create socket.");
      RETURN (false);
   }

   if (-1 == mongoc_socket_connect (
                sock, (struct sockaddr *) &saddr, sizeof saddr, -1)) {
      char buf[128];
      char *errstr;

      errstr = bson_strerror_r (mongoc_socket_errno (sock), buf, sizeof (buf));

      bson_set_error (error,
                      MONGOC_ERROR_STREAM,
                      MONGOC_ERROR_STREAM_CONNECT,
                      "Failed to connect to UNIX domain socket: %s",
                      errstr);
      mongoc_socket_destroy (sock);
      RETURN (false);
   }

   stream = _mongoc_topology_scanner_node_setup_stream_for_tls (
      node, mongoc_stream_socket_new (sock));
   if (stream) {
      _begin_ismaster_cmd (node,
                           stream,
                           false /* is_setup_done */,
                           NULL /* dns result */,
                           0 /* delay */);
      RETURN (true);
   }
   bson_set_error (error,
                   MONGOC_ERROR_STREAM,
                   MONGOC_ERROR_STREAM_CONNECT,
                   "Failed to create TLS stream");
   RETURN (false);
#endif
}


/*
 *--------------------------------------------------------------------------
 *
 * mongoc_topology_scanner_node_setup --
 *
 *      Create a stream and begin a non-blocking connect.
 *
 * Returns:
 *      true on success, or false and error is set.
 *
 *--------------------------------------------------------------------------
 */

void
mongoc_topology_scanner_node_setup (mongoc_topology_scanner_node_t *node,
                                    bson_error_t *error)
{
   bool success = false;
   mongoc_stream_t *stream;
   int64_t start;

   _mongoc_topology_scanner_monitor_heartbeat_started (node->ts, &node->host);
   start = bson_get_monotonic_time ();

   /* if there is already a working stream, push it back to be re-scanned. */
   if (node->stream) {
      _begin_ismaster_cmd (
         node, node->stream, true /* is_setup_done */, NULL, 0);
      node->stream = NULL;
      return;
   }

   BSON_ASSERT (!node->retired);

   if (node->ts->initiator) {
      stream = node->ts->initiator (
         node->ts->uri, &node->host, node->ts->initiator_context, error);
      if (stream) {
         success = true;
         _begin_ismaster_cmd (node, stream, false, NULL, 0);
      }
   } else {
      if (node->host.family == AF_UNIX) {
         success = mongoc_topology_scanner_node_connect_unix (node, error);
      } else {
         success = mongoc_topology_scanner_node_setup_tcp (node, error);
      }
   }

   if (!success) {
      _mongoc_topology_scanner_monitor_heartbeat_failed (
         node->ts,
         &node->host,
         error,
         (bson_get_monotonic_time () - start) / 1000);

      node->ts->setup_err_cb (node->id, node->ts->cb_data, error);
      return;
   }

   node->has_auth = false;
}

/*
 *--------------------------------------------------------------------------
 *
 * mongoc_topology_scanner_node_in_cooldown --
 *
 *      Return true if @node has experienced a network error attempting
 *      to call "ismaster" less than 5 seconds before @when, a timestamp in
 *      microseconds.
 *
 *      Server Discovery and Monitoring Spec: "After a single-threaded client
 *      gets a network error trying to check a server, the client skips
 *      re-checking the server until cooldownMS has passed. This avoids
 *      spending connectTimeoutMS on each unavailable server during each scan.
 *      This value MUST be 5000 ms, and it MUST NOT be configurable."
 *
 *--------------------------------------------------------------------------
 */
bool
mongoc_topology_scanner_node_in_cooldown (mongoc_topology_scanner_node_t *node,
                                          int64_t when)
{
   if (node->last_failed == -1 || node->ts->bypass_cooldown) {
      return false; /* node is new, or connected */
   }

   return node->last_failed + 1000 * MONGOC_TOPOLOGY_COOLDOWN_MS >= when;
}

/*
 *--------------------------------------------------------------------------
 *
 * mongoc_topology_scanner_in_cooldown --
 *
 *      Return true if all nodes will be in cooldown at time @when, a
 *      timestamp in microseconds.
 *
 *--------------------------------------------------------------------------
 */

bool
mongoc_topology_scanner_in_cooldown (mongoc_topology_scanner_t *ts,
                                     int64_t when)
{
   mongoc_topology_scanner_node_t *node;

   if (ts->bypass_cooldown) {
      return false;
   }
   DL_FOREACH (ts->nodes, node)
   {
      if (!mongoc_topology_scanner_node_in_cooldown (node, when)) {
         return false;
      }
   }

   return true;
}


/*
 *--------------------------------------------------------------------------
 *
 * mongoc_topology_scanner_start --
 *
 *      Initializes the scanner and begins a full topology check. This
 *      should be called once before calling mongoc_topology_scanner_work()
 *      to complete the scan.
 *
 *      The topology mutex must be held by the caller.
 *
 *      If "obey_cooldown" is true, this is a single-threaded blocking scan
 *      that must obey the Server Discovery And Monitoring Spec's cooldownMS:
 *
 *      "After a single-threaded client gets a network error trying to check
 *      a server, the client skips re-checking the server until cooldownMS has
 *      passed.
 *
 *      "This avoids spending connectTimeoutMS on each unavailable server
 *      during each scan.
 *
 *      "This value MUST be 5000 ms, and it MUST NOT be configurable."
 *
 *--------------------------------------------------------------------------
 */

void
mongoc_topology_scanner_start (mongoc_topology_scanner_t *ts,
                               bool obey_cooldown)
{
   mongoc_topology_scanner_node_t *node, *tmp;
   bool skip;
   int64_t now;

   BSON_ASSERT (ts);

   _delete_retired_nodes (ts);

   now = bson_get_monotonic_time ();

   DL_FOREACH_SAFE (ts->nodes, node, tmp)
   {
      skip =
         obey_cooldown && mongoc_topology_scanner_node_in_cooldown (node, now);

      if (!skip) {
         mongoc_topology_scanner_node_setup (node, &node->last_error);
      }
   }
}

/*
 *--------------------------------------------------------------------------
 *
 * mongoc_topology_scanner_finish_scan --
 *
 *      Summarizes all scanner node errors into one error message,
 *      deletes retired nodes.
 *
 *--------------------------------------------------------------------------
 */

void
_mongoc_topology_scanner_finish (mongoc_topology_scanner_t *ts)
{
   mongoc_topology_scanner_node_t *node, *tmp;
   bson_error_t *error = &ts->error;
   bson_string_t *msg;

   memset (&ts->error, 0, sizeof (bson_error_t));

   msg = bson_string_new (NULL);

   DL_FOREACH_SAFE (ts->nodes, node, tmp)
   {
      if (node->last_error.code) {
         if (msg->len) {
            bson_string_append_c (msg, ' ');
         }

         bson_string_append_printf (msg, "[%s]", node->last_error.message);

         /* last error domain and code win */
         error->domain = node->last_error.domain;
         error->code = node->last_error.code;
      }
   }

   bson_strncpy ((char *) &error->message, msg->str, sizeof (error->message));
   bson_string_free (msg, true);

   _delete_retired_nodes (ts);
}

/*
 *--------------------------------------------------------------------------
 *
 * mongoc_topology_scanner_work --
 *
 *      Crank the knob on the topology scanner state machine. This should
 *      be called only after mongoc_topology_scanner_start() has been used
 *      to begin the scan.
 *
 *--------------------------------------------------------------------------
 */

void
mongoc_topology_scanner_work (mongoc_topology_scanner_t *ts)
{
   mongoc_async_run (ts->async);
   BSON_ASSERT (ts->async->ncmds == 0);
}

/*
 *--------------------------------------------------------------------------
 *
 * mongoc_topology_scanner_get_error --
 *
 *      Copy the scanner's current error; which may no-error (code 0).
 *
 *--------------------------------------------------------------------------
 */

void
mongoc_topology_scanner_get_error (mongoc_topology_scanner_t *ts,
                                   bson_error_t *error)
{
   BSON_ASSERT (ts);
   BSON_ASSERT (error);

   memcpy (error, &ts->error, sizeof (bson_error_t));
}

/*
 * Set a field in the topology scanner.
 */
bool
_mongoc_topology_scanner_set_appname (mongoc_topology_scanner_t *ts,
                                      const char *appname)
{
   if (!_mongoc_handshake_appname_is_valid (appname)) {
      MONGOC_ERROR ("Cannot set appname: %s is invalid", appname);
      return false;
   }

   if (ts->appname != NULL) {
      MONGOC_ERROR ("Cannot set appname more than once");
      return false;
   }

   ts->appname = bson_strdup (appname);
   return true;
}

/*
 * Set the scanner's clusterTime unconditionally: don't compare with prior
 * @cluster_time is like {clusterTime: <timestamp>}
 */
void
_mongoc_topology_scanner_set_cluster_time (mongoc_topology_scanner_t *ts,
                                           const bson_t *cluster_time)
{
   bson_destroy (&ts->cluster_time);
   bson_copy_to (cluster_time, &ts->cluster_time);
}

/* SDAM Monitoring Spec: send HeartbeatStartedEvent */
static void
_mongoc_topology_scanner_monitor_heartbeat_started (
   const mongoc_topology_scanner_t *ts, const mongoc_host_list_t *host)
{
   if (ts->apm_callbacks.server_heartbeat_started) {
      mongoc_apm_server_heartbeat_started_t event;
      event.host = host;
      event.context = ts->apm_context;
      event.awaited = false;
      ts->apm_callbacks.server_heartbeat_started (&event);
   }
}

/* SDAM Monitoring Spec: send HeartbeatSucceededEvent */
static void
_mongoc_topology_scanner_monitor_heartbeat_succeeded (
   const mongoc_topology_scanner_t *ts,
   const mongoc_host_list_t *host,
   const bson_t *reply,
   int64_t duration_usec)
{
   if (ts->apm_callbacks.server_heartbeat_succeeded) {
      mongoc_apm_server_heartbeat_succeeded_t event;
      bson_t ismaster_redacted;

      bson_init (&ismaster_redacted);
      bson_copy_to_excluding_noinit (
         reply, &ismaster_redacted, "speculativeAuthenticate", NULL);

      event.host = host;
      event.context = ts->apm_context;
      event.reply = reply;
      event.duration_usec = duration_usec;
      event.awaited = false;
      ts->apm_callbacks.server_heartbeat_succeeded (&event);

      bson_destroy (&ismaster_redacted);
   }
}

/* SDAM Monitoring Spec: send HeartbeatFailedEvent */
static void
_mongoc_topology_scanner_monitor_heartbeat_failed (
   const mongoc_topology_scanner_t *ts,
   const mongoc_host_list_t *host,
   const bson_error_t *error,
   int64_t duration_usec)
{
   if (ts->apm_callbacks.server_heartbeat_failed) {
      mongoc_apm_server_heartbeat_failed_t event;
      event.host = host;
      event.context = ts->apm_context;
      event.error = error;
      event.duration_usec = duration_usec;
      event.awaited = false;
      ts->apm_callbacks.server_heartbeat_failed (&event);
   }
}

/* this is for testing the dns cache timeout. */
void
_mongoc_topology_scanner_set_dns_cache_timeout (mongoc_topology_scanner_t *ts,
                                                int64_t timeout_ms)
{
   ts->dns_cache_timeout_ms = timeout_ms;
}

/* reset "retired" nodes that failed or were removed in the previous scan */
static void
_delete_retired_nodes (mongoc_topology_scanner_t *ts)
{
   mongoc_topology_scanner_node_t *node, *tmp;

   DL_FOREACH_SAFE (ts->nodes, node, tmp)
   {
      if (node->retired) {
         mongoc_topology_scanner_node_destroy (node, true);
      }
   }
}

static void
_cancel_commands_excluding (mongoc_topology_scanner_node_t *node,
                            mongoc_async_cmd_t *acmd)
{
   mongoc_async_cmd_t *iter;
   DL_FOREACH (node->ts->async->cmds, iter)
   {
      if ((mongoc_topology_scanner_node_t *) iter->data == node &&
          iter != acmd) {
         iter->state = MONGOC_ASYNC_CMD_CANCELED_STATE;
      }
   }
}

static int
_count_acmds (mongoc_topology_scanner_node_t *node)
{
   mongoc_async_cmd_t *iter;
   int count = 0;
   DL_FOREACH (node->ts->async->cmds, iter)
   {
      if ((mongoc_topology_scanner_node_t *) iter->data == node) {
         ++count;
      }
   }
   return count;
}

static void
_jumpstart_other_acmds (mongoc_topology_scanner_node_t *node,
                        mongoc_async_cmd_t *acmd)
{
   mongoc_async_cmd_t *iter;
   DL_FOREACH (node->ts->async->cmds, iter)
   {
      if ((mongoc_topology_scanner_node_t *) iter->data == node &&
          iter != acmd && acmd->initiate_delay_ms < iter->initiate_delay_ms) {
         iter->initiate_delay_ms =
            BSON_MAX (iter->initiate_delay_ms - HAPPY_EYEBALLS_DELAY_MS, 0);
      }
   }
}
