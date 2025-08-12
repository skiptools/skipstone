#!/bin/bash -ex
# need to first install OSS Swift toolchain from:
#
# https://www.swift.org/download/#releases
#
# and install Linux Static SDK toolchain with:
# swift sdk install https://download.swift.org/swift-6.1-release/static-sdk/swift-6.1-RELEASE/swift-6.1-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz --checksum 111c6f7d280a651208b8c74c0521dd99365d785c1976a6e23162f55f65379ac6
#
# SkipKey can be built and uploaded with:
#
# PRODUCT=SkipKey COPYPRODUCT=1 ./scripts/build_linux.sh

BUILD_ARCH=${BUILD_ARCH:-"x86_64"}
#BUILD_ARCH=${BUILD_ARCH:-"aarch64"}

#SWIFT_VERSION="6.0.3"
SWIFT_VERSION=${SWIFT_VERSION:-"6.1"}

SWIFT_TOOLCHAIN=${SWIFT_TOOLCHAIN:-"${HOME}/Library/Developer/Toolchains/swift-${SWIFT_VERSION}-RELEASE.xctoolchain/usr"}
CONFIGURATION=${CONFIGURATION:-"release"}

PRODUCT=${PRODUCT:-"SkipRunner"}
SKIPCMD=skip

# name the artifact the same as the tool
ARTIFACT=${SKIPCMD}
ARTIFACTBUNDLE="${ARTIFACT}.artifactbundle"
PLUGIN_ZIP="${ARTIFACT}-linux-${BUILD_ARCH}.zip"

DIR=.build/artifactbundle-linux

mv -vf "${DIR}/${ARTIFACTBUNDLE}" "${DIR}/${ARTIFACTBUNDLE}.bk.$(date +%s)" || true

for SDK in "${BUILD_ARCH}-swift-linux-musl"; do
    ${SWIFT_TOOLCHAIN}/bin/swift build --swift-sdk "${SDK}" --configuration "${CONFIGURATION}" --product "${PRODUCT}"
    if [[ "${PRODUCT}" == "SkipRunner" ]]; then
        mkdir -p "${DIR}/${ARTIFACTBUNDLE}/${SDK}"
        cp -av .build/${SDK}/${CONFIGURATION}/${PRODUCT} ${DIR}/${ARTIFACTBUNDLE}/${SDK}/${SKIPCMD}
    fi
done

SKIP_VERSION=${SKIP_VERSION:-"0.0.1"}

# finally copy up the binary to www.skip.tools with:
if [[ "$COPYPRODUCT" == "1" ]]; then
    scp .build/${BUILD_ARCH}-swift-linux-musl/${CONFIGURATION}/${PRODUCT} www.skip.tools:~/lib/${PRODUCT}
elif [[ "${PRODUCT}" == "SkipRunner" ]]; then
    cd ${DIR}
    cat > ${ARTIFACTBUNDLE}/info.json << EOF
{
    "schemaVersion": "1.0",
    "artifacts": {
        "${SKIPCMD}": {
            "type": "executable",
            "version": "${SKIP_VERSION}",
            "variants": [
                {
                    "path": "${BUILD_ARCH}-swift-linux-musl/${SKIPCMD}",
                    "supportedTriples": ["${BUILD_ARCH}-unknown-linux-gnu"]
                }
            ]
        }
    }
}
EOF
    tree "${ARTIFACTBUNDLE}"
    du -skh "${ARTIFACTBUNDLE}"

    # sync file times to git date for build reproducability
    #find ${ARTIFACTBUNDLE} -exec touch -d "${GITDATE:0:19}" {} \;
    zip -9 -q --symlinks -r ${PLUGIN_ZIP} ${ARTIFACTBUNDLE}

    unzip -l "${PLUGIN_ZIP}"
    du -skh "${PLUGIN_ZIP}"
    PLUGIN_CHECKSUM=$(shasum -a 256 ${PLUGIN_ZIP} | cut -f 1 -d ' ')
fi

