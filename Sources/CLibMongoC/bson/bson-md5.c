#include "CLibMongoC_bson-compat.h"

#include "CLibMongoC_bson-md5.h"
#include "CLibMongoC_common-md5-private.h"


void
bson_md5_init (bson_md5_t *pms)
{
   COMMON_PREFIX (_bson_md5_init (pms));
}


void
bson_md5_append (bson_md5_t *pms, const uint8_t *data, uint32_t nbytes)
{
   COMMON_PREFIX (_bson_md5_append (pms, data, nbytes));
}

void
bson_md5_finish (bson_md5_t *pms, uint8_t digest[16])
{
   COMMON_PREFIX (_bson_md5_finish (pms, digest));
}