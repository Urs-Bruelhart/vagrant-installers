#!/usr/bin/env bash
set -e

# Verify arguments
if [ "$#" -ne "2" ]; then
  echo "Usage: $0 SUBSTRATE-DIR VAGRANT-VERSION" >&2
  exit 1
fi

export MACOSX_DEPLOYMENT_TARGET="10.15"

# Get our directory
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ] ; do SOURCE="$(readlink "$SOURCE")"; done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

SUBSTRATE_DIR=$1
VAGRANT_VERSION=$2
OUTPUT_PATH="`pwd`/vagrant_${VAGRANT_VERSION}_x86_64.dmg"

echo "Rebuild rb-fsevent bin executable..."
pushd "${SUBSTRATE_DIR}/embedded/gems/${VAGRANT_VERSION}/gems/rb-fsevent-"*
rake -f ext/rakefile.rb replace_exe
popd

# Work in a temporary directory
rm -rf package-staging
mkdir -p package-staging
STAGING_DIR=$(cd package-staging; pwd)
pushd $STAGING_DIR
echo "Darwin staging dir: ${STAGING_DIR}"

# Set information used for package and code signing
PKG_SIGN_IDENTITY=${VAGRANT_PACKAGE_SIGN_IDENTITY:-D38WU7D763}
PKG_SIGN_CERT_PATH=${VAGRANT_PACKAGE_SIGN_CERT_PATH:-"/Users/vagrant/MacOS_PackageSigning.cert"}
PKG_SIGN_KEY_PATH=${VAGRANT_PACKAGE_SIGN_KEY_PATH:-"/Users/vagrant/MacOS_PackageSigning.key"}

CODE_SIGN_IDENTITY=${VAGRANT_CODE_SIGN_IDENTITY:-D38WU7D763}
CODE_SIGN_CERT_PATH=${VAGRANT_CODE_SIGN_CERT_PATH:-"/Users/vagrant/MacOS_CodeSigning.p12"}
SIGN_KEYCHAIN=${VAGRANT_SIGN_KEYCHAIN:-/Library/Keychains/System.keychain}

SIGN_REQUIRED="${VAGRANT_PACKAGE_SIGNING_REQUIRED}"
#-------------------------------------------------------------------------
# Resources
#-------------------------------------------------------------------------
echo "Copying installer resources..."
mkdir -p ${STAGING_DIR}/resources
cp "${DIR}/darwin/background.png" ${STAGING_DIR}/background.png
cp "${DIR}/darwin/welcome.html" ${STAGING_DIR}/welcome.html
cp "${DIR}/darwin/license.html" ${STAGING_DIR}/license.html

#-------------------------------------------------------------------------
# Scripts
#-------------------------------------------------------------------------
echo "Copying installer scripts.."
mkdir -p ${STAGING_DIR}/scripts

cat <<EOF >${STAGING_DIR}/scripts/preinstall
#!/usr/bin/env bash

[ -d /opt/vagrant ] && rm -rf /opt/vagrant/

exit 0

EOF
chmod 0755 ${STAGING_DIR}/scripts/preinstall

cat <<EOF >${STAGING_DIR}/scripts/postinstall
#!/usr/bin/env bash

if [ ! -d /usr/local/bin ]; then
  mkdir -p /usr/local/bin
fi

# Create the symlink so that vagrant is available on the
# PATH.
ln -Fs \$2/bin/vagrant /usr/local/bin/vagrant

# Remove old legacy Vagrant installation
[ -d /Applications/Vagrant ] && rm -rf /Applications/Vagrant

# In some cases the opt folder doesn't exists before Vagrant
# install. This folder must be always hidden.
chflags hidden /opt

# Exit with a success code
exit 0
EOF
chmod 0755 ${STAGING_DIR}/scripts/postinstall

# Install and enable package signing if available
if [[ -f "${PKG_SIGN_CERT_PATH}" && -f "${PKG_SIGN_KEY_PATH}" ]]
then
    set +e
    security find-identity | grep "Installer.*${PKG_SIGN_IDENTITY}"
    if [ $? -ne 0 ]; then
        security import "${PKG_SIGN_CERT_PATH}" -k "${SIGN_KEYCHAIN}" -T /usr/bin/codesign -T /usr/bin/pkgbuild -T /usr/bin/productbuild
        security import "${PKG_SIGN_KEY_PATH}" -k "${SIGN_KEYCHAIN}" -T /usr/bin/codesign -T /usr/bin/pkgbuild -T /usr/bin/productbuild
    fi
    SIGN_PKG="1"
    set -e
fi

# Install and enable code signing if available
if [[ -f "${CODE_SIGN_CERT_PATH}" && "${CODE_SIGN_PASS}" != "" ]]
then
    set +e
    security find-identity | grep "Application.*${CODE_SIGN_IDENTITY}"
    if [ $? -ne 0 ]; then
        echo "==> Installing code signing key..."
        security import "${CODE_SIGN_CERT_PATH}" -k "${SIGN_KEYCHAIN}" -P "${CODE_SIGN_PASS}" -T /usr/bin/codesign
    fi
    set -e
    SIGN_CODE="1"
fi

# Perform library scrubbing to remove files which will fail notarization
rm -rf "${SUBSTRATE_DIR}/embedded/gems/${VAGRANT_VERSION}/cache/"*
rm -rf "${SUBSTRATE_DIR}/embedded/gems/${VAGRANT_VERSION}/gems/rubyzip-"*/test/

#-------------------------------------------------------------------------
# Code sign
#-------------------------------------------------------------------------
# Sign all executables within package
if [[ "${SIGN_CODE}" -eq "1" ]]
then
    echo <<EOF >entitlements.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
</dict>
</plist>
EOF
    echo "Signing all substrate executables..."
    find "${SUBSTRATE_DIR}" -type f -perm +0111 -exec codesign --options=runtime --entitlements entitlements.plist -s "${CODE_SIGN_IDENTITY}" {} \;
    echo "Finding all substate bundles..."
    find "${SUBSTRATE_DIR}" -name "*.bundle" -exec codesign -s "${CODE_SIGN_IDENTITY}" {} \;
    echo "Finding all substrate shared library objects..."
    find "${SUBSTRATE_DIR}" -name "*.so" -exec codesign -s "${CODE_SIGN_IDENTITY}" {} \;
    rm entitlements.plist
fi

#-------------------------------------------------------------------------
# Pkg
#-------------------------------------------------------------------------
# Create the component package using pkgbuild. The component package
# contains the raw file structure that is installed via the installer package.
if [[ "${SIGN_PKG}" -eq "1" ]]
then
    echo "Building core.pkg..."
    pkgbuild \
        --root ${SUBSTRATE_DIR} \
        --identifier com.vagrant.vagrant \
        --version ${VAGRANT_VERSION} \
        --install-location "/opt/vagrant" \
        --scripts ${STAGING_DIR}/scripts \
        --timestamp=none \
        --sign "${PKG_SIGN_IDENTITY}" \
        ${STAGING_DIR}/core.pkg
else
    echo "Building core.pkg..."
    pkgbuild \
        --root ${SUBSTRATE_DIR} \
        --identifier com.vagrant.vagrant \
        --version ${VAGRANT_VERSION} \
        --install-location "/opt/vagrant" \
        --scripts ${STAGING_DIR}/scripts \
        --timestamp=none \
        ${STAGING_DIR}/core.pkg
fi

# Create the distribution definition, an XML file that describes what
# the installer will look and feel like.
cat <<EOF >${STAGING_DIR}/vagrant.dist
<installer-gui-script minSpecVersion="1">
    <title>Vagrant</title>

    <!-- Configure the visuals and the various pages that exist throughout
         the installation process. -->
    <background file="background.png"
        alignment="bottomleft"
        mime-type="image/png" />
    <welcome file="welcome.html"
        mime-type="text/html" />
    <license file="license.html"
        mime-type="text/html" />

    <!-- Don't let the user customize the install (i.e. choose what
         components to install. -->
    <options customize="never" />

    <!-- The "choices" for things that can be installed, although the
         user has no actually choice, they're still required so that
         the installer knows what to install. -->
    <choice description="Vagrant Application"
        id="choice-vagrant-application"
        title="Vagrant Application">
        <pkg-ref id="com.vagrant.vagrant">core.pkg</pkg-ref>
    </choice>

    <choices-outline>
        <line choice="choice-vagrant-application" />
    </choices-outline>
</installer-gui-script>
EOF

# Build the actual installer.
echo "Building Vagrant.pkg..."

# Check is signing certificate is available. Install
# and sign if found.
if [[ "${SIGN_PKG}" -eq "1" ]]
then
    productbuild \
        --distribution ${STAGING_DIR}/vagrant.dist \
        --resources ${STAGING_DIR}/resources \
        --package-path ${STAGING_DIR} \
        --timestamp=none \
        --sign "${PKG_SIGN_IDENTITY}" \
        ${STAGING_DIR}/Vagrant.pkg
else
    productbuild \
        --distribution ${STAGING_DIR}/vagrant.dist \
        --resources ${STAGING_DIR}/resources \
        --package-path ${STAGING_DIR} \
        --timestamp=none \
        ${STAGING_DIR}/Vagrant.pkg
fi
#-------------------------------------------------------------------------
# DMG
#-------------------------------------------------------------------------
# Stage the files
mkdir -p ${STAGING_DIR}/dmg
cp ${STAGING_DIR}/Vagrant.pkg ${STAGING_DIR}/dmg/vagrant.pkg
cp "${DIR}/darwin/uninstall.tool" ${STAGING_DIR}/dmg/uninstall.tool
chmod +x ${STAGING_DIR}/dmg/uninstall.tool

echo "Creating DMG"
dmgbuild -s "${DIR}/darwin/dmgbuild.py" -D srcfolder="${STAGING_DIR}/dmg" -D backgroundimg="${DIR}/darwin/background_installer.png" Vagrant "${OUTPUT_PATH}"

if [[ "${SIGN_PKG}" -ne "1" ]]
then
    if [[ "${SIGN_REQUIRED}" -eq "1" ]]
    then
        echo "Error: Package signing is required but package is not signed"
        exit 1
    fi
    set +x
    echo
    echo "!!!!!!!!!!!! WARNING !!!!!!!!!!!!"
    echo "! Vagrant installer package is  !"
    echo "! NOT signed. Rebuild using the !"
    echo "! signing key for release build !"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
    set -x
else
    echo "==> Signing DMG..."
    codesign -s "${PKG_SIGN_IDENTITY}" --timestamp "${OUTPUT_PATH}"
fi

if [ "${SIGN_PKG}" = "1" ] && [ "${SIGN_CODE}" = "1" ] && [ "${NOTARIZE_USERNAME}" != "" ]; then
    echo "==> Notarizing DMG..."
    export AC_USERNAME="${NOTARIZE_USERNAME}"
    export AC_PASSWORD="${NOTARIZE_PASSWORD}"
    cat <<EOF > config.hcl
notarize {
  path = "${OUTPUT_PATH}"
  bundle_id = "com.hashicorp.vagrant"
  staple = true
}
EOF
    if [ -z "${DISABLE_NOTARIZATION}" ]; then
        gon ./config.hcl
    else
        echo
        echo "!!!!!!!!!!!!WARNING!!!!!!!!!!!!!!!!!!!"
        echo "! Vagrant installer package is NOT   !"
        echo "! notarized. Notarization has been   !"
        echo "! expliticly disabled. Please enable !"
        echo "! package notarization and rebuild.  !"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi
else
    echo
    echo "!!!!!!!!!!!!WARNING!!!!!!!!!!!!!!!!!!"
    echo "! Vagrant installer package is NOT  !"
    echo "! notarized. Rebuild with proper    !"
    echo "! signing and credentials to enable !"
    echo "! package notarization.             !"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi
