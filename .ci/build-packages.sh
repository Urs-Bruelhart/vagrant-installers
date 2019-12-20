#!/usr/bin/env bash

export SLACK_USERNAME="Vagrant"
export SLACK_ICON="https://avatars.slack-edge.com/2017-10-17/257000837696_070f98107cdacc0486f6_36.png"
export SLACK_TITLE="Vagrant Packaging"
export PACKET_EXEC_DEVICE_NAME="${PACKET_EXEC_DEVICE_NAME:-ci-installers}"
export PAKCET_EXEC_DEVICE_NAME="${PACKET_EXEC_DEVICE_SIZE:-baremetal_1}"
export PAKCET_EXEC_PREFER_FACILITIES="${PACKET_EXEC_PREFER_FACILITIES:-iad1,iad2,ewr1,dfw2,sea1,sjc1,lax1}"
export PACKET_EXEC_OPERATING_SYSTEM="${PACKET_EXEC_OPERATING_SYSTEM:-ubuntu_18_04}"
export PACKET_EXEC_PRE_BUILTINS="${PACKET_EXEC_PRE_BUILTINS:-InstallVmware,InstallVagrant,InstallVagrantVmware}"

if [ "${DEBUG}" = "1" ]; then
    set -x
    output="/dev/stdout"
else
    output="/dev/null"
fi

function fail() {
    (>&2 echo "ERROR: ${1}")
    if [ -f ".output" ]; then
        slack -s error -m "ERROR: ${1}" -f .output -T 5
    else
        slack -s error -m "ERROR: ${1}"
    fi
    exit 1
}

function warn() {
    (>&2 echo "WARN:  ${1}")
    if [ -f ".output" ]; then
        slack -s warn -m "WARNING: ${1}" -f .output
    else
        slack -s warn -m "WARNING: ${1}"
    fi
}

function cleanup() {
    (>&2 echo "Cleaning up any guests on packet device")
    if [ "${PKG_VAGRANT_BUILD_TYPE}" = "package" ]; then
        export PKT_VAGRANT_BUILD_TYPE="substrate"
        packet-exec run -- vagrant destroy -f
    fi
    unset PACKET_EXEC_PERSIST
    export PKT_VAGRANT_BUILD_TYPE="package"
    packet-exec run -- vagrant destroy -f
}

trap cleanup EXIT

csource="${BASH_SOURCE[0]}"
while [ -h "$csource" ] ; do csource="$(readlink "$csource")"; done
root="$( cd -P "$( dirname "$csource" )/../" && pwd )"

pushd "${root}" > "${output}"

# Set variables we'll need later
declare -A substrate_list=(
    [*centos_x86_64.zip]="centos-6"
    [*centos_i686.zip]="centos-6-i386"
    [*darwin_x86_64.zip]="osx-10.15"
    [*ubuntu_x86_64.zip]="ubuntu-14.04"
    [*ubuntu_i686.zip]="ubuntu-14.04-i386"
    [*windows_x86_64.zip]="win-7"
    [*windows_i686.zip]="win-7"
)

declare -A package_list=(
    [*amd64.zip]="appimage"
    [*x86_64.tar.xz]="archlinux"
    [*x86_64.rpm]="centos-6"
    [*i686.rpm]="centos-6-i386"
    [*x86_64.dmg]="osx-10.15"
    [*x86_64.deb]="ubuntu-14.04"
    [*i686.deb]="ubuntu-14.04-i386"
    [*x86_64.msi]="win-7"
    [*i686.msi]="win-7"
)

full_sha="${GITHUB_SHA}"
short_sha="${full_sha:0:8}"
ident_ref="${GITHUB_REF#*/*/}"
if [[ "${GITHUB_REF}" == *"refs/tags/"* ]]; then
    tag="${GITHUB_REF##*tags/}"
    if [[ "${tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        release=1
    fi
fi
repository="${GITHUB_REPOSITORY}"
repo_owner="${repository%/*}"
repo_name="${repository#*/}"
s3_substrate_dst="${ASSETS_PRIVATE_LONGTERM}/${repository}/${short_sha}"
if [ "${tag}" != "" ]; then
    if [[ "${tag}" = *"+"* ]]; then
        s3_package_dst="${ASSETS_PRIVATE_LONGTERM}/${repository}/${tag}"
    else
        s3_package_dst="${ASSETS_PRIVATE_BUCKET}/${repository}/${tag}"
    fi
else
    s3_package_dst="${ASSETS_PRIVATE_LONGTERM}/${repository}/${ident_ref}/${short_sha}"
fi
job_id=$(uuidgen)
export PACKET_EXEC_REMOTE_DIRECTORY="${job_id}"
export PACKET_EXEC_PERSIST="1"
export PKT_VAGRANT_INSTALLERS_VAGRANT_PACKAGE_SIGNING_REQUIRED=1

# Grab the vagrant gem the installer is building around

echo -n "Fetching Vagrant RubyGem for installer build... "
if [ "${tag}" = "" ]; then
    aws s3 cp ${ASSETS_PRIVATE_BUCKET}/${repo_owner}/vagrant/vagrant-master.gem vagrant-master.gem > .output 2>&1
    result=$?
else
    url=$(curl -SsL -H "Content-Type: application/json" "https://api.github.com/repos/${repository}/releases/tags/${tag}" | jq -r '.assets[] | select(.name | contains(".gem")) | .url')
    curl -H "Accept: application/octet-stream" -SsL -o "vagrant-${tag}.gem" "${url}" > .output 2>&1
    result=$?
fi
if [ $result -ne 0 ]; then
    echo "error"
    fail "Failed to download Vagrant RubyGem"
fi
echo "done"
rm .output

# Extract out Vagrant version information from gem

vagrant_version="$(gem specification vagrant-*.gem version)"
vagrant_version="${vagrant_version##*version: }"

# Ensure we have a packet device to connect
echo "Creating packet device if needed..."
packet-exec create > .output 2>&1 &
pid=$!
until [ -f .output ]; do
    sleep 0.1
done
tail -f --quiet --pid "${pid}" .output
wait "${pid}"
if [ $? -ne 0 ]; then
    fail "Failed to create packet device"
fi
rm .output

# Build our substrates
mkdir -p substrate-assets pkg

echo -n "Fetching any prebuilt substrates and/or packages... "

# If there are existing substrates or packages already built, download them
aws s3 sync "${s3_substrate_dst}/" ./substrate-assets/ > "${output}" 2>&1
aws s3 sync "${s3_package_dst}/" ./pkg/ > "${output}" 2>&1

echo "done"

echo -n "Setting up remote packet device for current job... "
# NOTE: We only need to call packet-exec with the -upload option once
#       since we are persisting the job directory. This dummy command
#       is used simply to seed the work directory.
packet-exec run -upload -- /bin/true > .output 2>&1
if [ $? -eq 0 ]; then
    echo "done"
    rm .output
else
    fail "Failed to setup packet device"
fi

for p in "${!substrate_list[@]}"; do
    path=(substrate-assets/${p})
    if [ ! -f "${path}" ]; then
        substrates_needed="${substrates_needed},${substrate_list[${p}]}"
    fi
done
substrates_needed="${substrates_needed#,}"

if [ "${substrates_needed}" = "" ]; then
    echo "All substrates currently exist. No build required."
else
    export PKT_VAGRANT_ONLY_BOXES="${substrates_needed}"
    export PKT_VAGRANT_BUILD_TYPE="substrate"

    echo "Starting Vagrant substrate guests..."
    packet-exec run -upload -- vagrant up --no-provision > .output 2>&1 &
    pid=$!
    until [ -f .output ]; do
        sleep 0.1
    done
    tail -f --quiet --pid "${pid}" .output
    wait "${pid}"
    if [ $? -ne 0 ]; then
        fail "Failed to start builder guests on packet device for substrates"
    fi
    rm .output

    echo "Start Vagrant substrate builds..."
    packet-exec run -download "./substrate-assets/*:./substrate-assets" -- vagrant provision > .output 2>&1 &
    pid=$!
    until [ -f .output ]; do
        sleep 0.1
    done
    tail -f --quiet --pid "${pid}" .output
    wait "${pid}"
    result=$?

    # If the command failed, run something known to succeed so any available substrate
    # assets can be pulled back in and stored
    if [ $result -ne 0 ]; then
        packet-exec run -download "./substrate-assets/*:./substrate-assets" -- /bin/true > "${output}" 2>&1
    fi

    echo -n "Storing any built substrates... "
    # Store all built substrates
    aws sync ./substrate-assets/ "${s3_substrate_dst}" > "${output}" 2>&1
    echo "done"

    # Now we can bail if the substrate build generated an error
    if [ $result -ne 0 ]; then
        slack -s error -m "Failure encountered during substrate build" -f .output -T 10
        exit $result
    fi
    rm .output

    echo "Destroying existing Vagrant guests..."
    # Clean up the substrate VMs
    packet-exec run -- vagrant destroy -f
fi

for p in "${!package_list[@]}"; do
    path=(pkg/${p})
    if [ ! -f "${path}" ]; then
        packages_needed="${packages_needed},${package_list[${p}]}"
    fi
done
packages_needed="${packages_needed#,}"

if [ "${packages_needed}" = "" ]; then
    echo "All packages currently exist. No build required."
else
    export PKT_VAGRANT_ONLY_BOXES="${packages_needed}"
    export PKT_VAGRANT_BUILD_TYPE="package"

    echo "Starting Vagrant package guests... "
    packet-exec run -- vagrant up --no-provision > .output 2>&1 &
    pid=$!
    until [ -f .output ]; do
        sleep 0.1
    done
    tail -f --quiet --pid "${pid}" .output
    wait "${pid}"
    result=$?

    if [ $result -ne 0 ]; then
        fail "Failed to start builder guests on packet device for packaging"
    fi
    rm .output

    echo "Start Vagrant package builds..."
    packet-exec run -download "./pkg/*:./pkg" -- vagrant provision > .output 2>&1 &
    pid=$!
    until [ -f .output ]; do
        sleep 0.1
    done
    tail -f --quiet --pid "${pid}" .output
    wait "${pid}"
    result=$?

    # If the command failed, run something known to succeed so any available package
    # assets can be pulled back in and stored
    if [ $result -ne 0 ]; then
        packet-exec run -download "./pkg/*:./pkg" -- /bin/true > "${output}" 2>&1
    fi

    # Store all built substrates
    echo -n "Storing any built packages... "
    aws sync ./pkg/ "${s3_package_dst}" > "${output}" 2>&1
    echo "done"

    # Now we can bail if the package build generated an error
    if [ $result -ne 0 ]; then
        fail "Failure encountered during package build"
    fi
    rm .output

    echo "Destroying existing Vagrant guests..."
    packet-exec run -- vagrant destroy -f
fi

# Validate all expected packages were built
for p in "${!package_list[@]}"; do
    path=(pkg/${p})
    if [ ! -f "${path}" ]; then
        packages_missing="${packages_missing},${p}"
    fi
done
packages_missing="${packages_missing#,}"

if [ "${packages_missing}" != "" ]; then
    fail "Missing Vagrant package assets matching patterns: ${packages_missing}"
fi

# If this is a release build sign our package assets and then upload
# via the hc-releases binary
if [ "${release}" = "1" ]; then
    # TODO: REMOVE
    fail "Release is currently stubbed"

    echo -n "Cloning Vagrant repository for signing process... "
    git clone git://github.com/hashicorp/vagrant vagrant > .output 2>&1
    if [ $? -ne 0 ]; then
        echo "error"
        fail "Failed to clone Vagrant repository"
    fi
    rm .output
    echo "done"
    mkdir -p vagrant/pkg/dist
    mv pkg/* vagrant/pkg/dist/
    pushd vagrant > "${output}"
    echo "Signing installer packages for Vagrant version ${vagrant_version}..."
    packet-exec run -upload -download "./pkg/dist/*SHA256SUMS*:./pkg/dist" -- ./scripts/sign.sh "${vagrant_version}" > .output 2>&1 &
    pid=$!
    until [ -f .output ]; do
        sleep 0.1
    done
    tail -f --quiet --pid "${pid}" .output
    wait "${pid}"
    if [ $? -ne 0 ]; then
        fail "Failed to sign packages for release"
    fi
    rm .output
    popd > "${output}"
    mv vagrant/pkg/dist/* pkg/

    echo -n "Validating generated package checksum values and signature... "
    gpg --batch --import "${HASHICORP_PUBLIC_GPG_KEY_PATH}" > .output 2>&1
    if [ $? -ne 0 ]; then
        echo "error"
        fail "Failed to import HashiCorp public GPG key"
    fi
    rm .output

    pushd ./pkg > "${output}"
    gpg --batch --verify vagrant_*_SHA256SUMS.sig vagrant_*_SHA256SUMS > .output 2>&1
    if [ $? -ne 0 ]; then
        echo "error"
        fail "Package checksum signature validation failed"
    fi
    rm .output

    sha256sum --check vagrant_*_SHA256SUMS > .output 2>&1
    if [ $? -ne 0 ]; then
        echo "error"
        fail "Package checksum validation failed"
    fi
    rm .output
    echo "done"

    popd > "${output}"

    # Upload release assets to the release bucket
    oid="${AWS_ACCESS_KEY_ID}"
    okey="${AWS_SECRET_ACCESS_KEY}"
    export AWS_ACCESS_KEY_ID="${RELEASE_AWS_ACCESS_KEY_ID}"
    export AWS_SECRET_ACCESS_KEY="${RELEASE_AWS_SECRET_ACCESS_KEY}"
    echo -n "Uploading Vagrant release ${vagrant_version} to HashiCorp releases... "
    hc-releases upload ./pkg > .output 2>&1
    if [ $? -ne 0 ]; then
        export AWS_ACCESS_KEY_ID="${oid}"
        export AWS_SECRET_ACCESS_KEY="${okey}"
        echo "error"
        fail "Failed to upload packages to HashiCorp releases"
    fi
    rm .output
    echo "done"

    echo -n "Publishing Vagrant release ${vagrant_version}... "
    hc-releases publish > .output 2>&1
    result=$?
    export AWS_ACCESS_KEY_ID="${oid}"
    export AWS_SECRET_ACCESS_KEY="${okey}"
    if [ $result -ne 0 ]; then
        echo "error"
        fail "Failed to publish Vagrant release ${vagrant_version}"
    fi
    echo "done"

    slack -m "New Vagrant release has been published! - *${vagrant_version}*\n\nAssets: https://releases.hashicorp.com/vagrant/${vagrant_version}"
else
    if [ "${tag}" != "" ]; then
        prerelease_version="${tag}"
    else
        prerelease_version="${vagrant_version}+${ident_ref}"
    fi

    echo -n "Generating GitHub pre-release packages for Vagrant version ${prerelease_version}... "
    export GITHUB_TOKEN="${HASHIBOT_TOKEN}"
    ghr -u "${repo_owner}" -r "${repo_name}" -c "${full_sha}" -prerelease \
        -delete -replace "${prerelease_version}" ./pkg/ > .output 2>&1
    if [ $? -ne 0 ]; then
        echo "error"
        fail "Failed to create GitHub pre-release for Vagrant version ${prerelease_version}"
    fi
    rm .output
    echo "done"
    slack -m "New Vagrant development installers available:\n> https://github.com/${respository}/releases/${prerelease_version}"
fi
