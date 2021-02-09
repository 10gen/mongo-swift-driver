#!/bin/bash
set -o xtrace   # Write all commands first to stderr
set -o errexit  # Exit the script with error if any of the commands fail

# variables
PROJECT_DIRECTORY=${PROJECT_DIRECTORY:-$PWD}
MONGODB_URI=${MONGODB_URI:-"NO_URI_PROVIDED"}
SWIFT_VERSION=${SWIFT_VERSION:-5.1}
INSTALL_DIR="${PROJECT_DIRECTORY}/opt"
TOPOLOGY=${TOPOLOGY:-single}
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
EXTRA_FLAGS="-Xlinker -rpath -Xlinker ${INSTALL_DIR}/lib"
RAW_TEST_RESULTS="${PROJECT_DIRECTORY}/rawTestResults"
XML_TEST_RESULTS="${PROJECT_DIRECTORY}/testResults.xml"
INSTALL_DEPS=${INSTALL_DEPS:-"false"}

# ssl setup
SSL=${SSL:-nossl}
if [ "$SSL" != "nossl" ]; then
   export SSL_KEY_FILE="$DRIVERS_TOOLS/.evergreen/x509gen/client.pem"
   export SSL_CA_FILE="$DRIVERS_TOOLS/.evergreen/x509gen/ca.pem"
fi

# if dependencies were not installed separately, do so now.
# this is used for continous matrix testing
if [ "$INSTALL_DEPS" == "true" ]; then
    SWIFT_VERSION=${SWIFT_VERSION} \
      sh ${PROJECT_DIRECTORY}/.evergreen/install-dependencies.sh
fi

# enable swiftenv
export SWIFTENV_ROOT="${INSTALL_DIR}/swiftenv"
export PATH="${SWIFTENV_ROOT}/bin:$PATH"
eval "$(swiftenv init -)"

# select the latest Xcode for Swift 5.1 support on MacOS
if [ "$OS" == "darwin" ]; then
    sudo xcode-select -s /Applications/Xcode11.3.app
fi

# switch swift version, and run tests
swiftenv local $SWIFT_VERSION

# build the driver
swift build $EXTRA_FLAGS

# test the driver
set +o errexit # even if tests fail we want to parse the results, so disable errexit
set -o pipefail # propagate error codes in the following pipes

MONGODB_TOPOLOGY=${TOPOLOGY} MONGODB_URI=$MONGODB_URI swift test $EXTRA_FLAGS 2>&1 | tee ${RAW_TEST_RESULTS}

# save tests exit code
EXIT_CODE=$?

# convert tests to XML
cat ${RAW_TEST_RESULTS} | swift "${PROJECT_DIRECTORY}/etc/convert-test-results.swift" > ${XML_TEST_RESULTS}

# exit with exit code for running the tests
exit $EXIT_CODE
