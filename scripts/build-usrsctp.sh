#!/bin/bash
set -euo pipefail

SOURCE=${1:?Usage: bash scripts/build-usrsctp.sh /path/to/usrsctp}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=$(cd "$SOURCE" && pwd)
REVISION=07f871bda23943c43c9e74cc54f25130459de830
CMAKE=${CMAKE:-cmake}
BUILD="$ROOT/.build/vendor/usrsctp-xcode"
FRAMEWORK="$ROOT/Vendor/usrsctp.xcframework/macos-arm64/usrsctp.framework"

if [[ $(git -C "$SOURCE" rev-parse HEAD) != "$REVISION" ]]; then
    echo "Expected usrsctp revision $REVISION" >&2
    exit 1
fi
git -C "$SOURCE" diff --exit-code HEAD -- usrsctplib CMakeLists.txt

"$CMAKE" -S "$SOURCE" -B "$BUILD" -G Xcode -Wno-dev \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_BUILD_TYPE=Release \
    '-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -Wno-unused-but-set-variable -Wno-strict-prototypes' \
    -Dsctp_build_programs=OFF \
    -Dsctp_build_shared_lib=OFF \
    -Dsctp_debug=OFF \
    -Dsctp_werror=ON

xcodebuild -project "$BUILD/usrsctplib.xcodeproj" -target usrsctp -parallelizeTargets \
    -configuration Release CODE_SIGNING_ALLOWED=NO \
    GCC_WARN_64_TO_32_BIT_CONVERSION=NO \
    CONFIGURATION_BUILD_DIR="$BUILD/products"

cp "$BUILD/products/libusrsctp.a" "$FRAMEWORK/usrsctp"
cp "$SOURCE/usrsctplib/usrsctp.h" "$FRAMEWORK/Headers/usrsctp.h"
shasum -a 256 "$FRAMEWORK/usrsctp"
