#!/bin/bash
set -o errexit  # Exit the script with error if any of the commands fail

# variables
SWIFT_VERSION=${SWIFT_VERSION:-"MISSING_SWIFT_VERSION"}
PROJECT_DIRECTORY=${PROJECT_DIRECTORY:-"MISSING_PROJECT_DIRECTORY"}
INSTALL_DIR="${PROJECT_DIRECTORY}/opt"

# configure Swift
. ${PROJECT_DIRECTORY}/.evergreen/configure-swift.sh

# run the tests
ATLAS_REPL="$ATLAS_REPL" ATLAS_SHRD="$ATLAS_SHRD" ATLAS_FREE="$ATLAS_FREE" ATLAS_TLS11="$ATLAS_TLS11" ATLAS_TLS12="$ATLAS_TLS12" \
ATLAS_REPL_SRV="$ATLAS_REPL_SRV" ATLAS_SHRD_SRV="$ATLAS_SHRD_SRV" ATLAS_FREE_SRV="$ATLAS_FREE_SRV" ATLAS_TLS11_SRV="$ATLAS_TLS11_SRV" ATLAS_TLS12_SRV="$ATLAS_TLS12_SRV" \
swift run AtlasConnectivity $EXTRA_FLAGS
