#!/bin/bash
set -eo pipefail

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.5}"
OPENWRT_TARGET="${OPENWRT_TARGET:-bcm27xx/bcm2711}"
OPENWRT_PROFILE="${OPENWRT_PROFILE:-rpi-4}"
CUSTOM_PACKAGES="${CUSTOM_PACKAGES:-}"
CACHE_DIR="${CACHE_DIR:-/builder/cache}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
FILES_DIR="${FILES_DIR:-/builder/overlay}"

TARGET_SLUG="${OPENWRT_TARGET//\//-}"
IB_ARCHIVE_NAME="openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET_SLUG}.Linux-x86_64.tar.zst"
IB_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${IB_ARCHIVE_NAME}"

mkdir -p "$CACHE_DIR" "$OUTPUT_DIR"

echo "================================================================="
echo " Building OpenWrt Headless NAS Image for Raspberry Pi 4"
echo " OpenWrt Version: ${OPENWRT_VERSION}"
echo " Target:          ${OPENWRT_TARGET}"
echo " Profile:         ${OPENWRT_PROFILE}"
echo "================================================================="

# 1. Download OpenWrt ImageBuilder if not cached
IB_CACHE_FILE="${CACHE_DIR}/${IB_ARCHIVE_NAME}"
if [ ! -f "$IB_CACHE_FILE" ]; then
    echo "Downloading ImageBuilder from ${IB_URL}..."
    curl -f -L --progress-bar "$IB_URL" -o "${IB_CACHE_FILE}.tmp"
    mv "${IB_CACHE_FILE}.tmp" "$IB_CACHE_FILE"
    echo "Download completed."
else
    echo "Using cached ImageBuilder: ${IB_CACHE_FILE}"
fi

# 2. Extract ImageBuilder
BUILD_DIR="/builder/work"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
echo "Extracting ImageBuilder..."
tar -I zstd -xf "$IB_CACHE_FILE" -C "$BUILD_DIR" --strip-components=1

cd "$BUILD_DIR"
mkdir -p tmp

# 3. Setup package cache if available
if [ -d "${CACHE_DIR}/packages" ]; then
    echo "Linking package cache..."
    mkdir -p packages
    cp -rn "${CACHE_DIR}/packages/." packages/ 2>/dev/null || true
fi

# 4. Define package list
DEFAULT_NAS_PACKAGES="
    sudo
    shadow-useradd
    shadow-groupadd
    shadow-usermod
    libpam
    lighttpd
    lighttpd-mod-auth
    lighttpd-mod-authn_pam
    lighttpd-mod-webdav
    lighttpd-mod-openssl
    lighttpd-mod-alias
    tailscale
    -dropbear
    openssh-server
    openssh-keygen
    openssh-sftp-server
    acme
    acme-acmesh-dnsapi
    ca-certificates
    curl
    ddns-scripts
    ddns-scripts-cloudflare
    luci-app-ddns
    luci-ssl
    block-mount
    kmod-usb-storage
    kmod-usb-storage-uas
    kmod-usb2
    kmod-usb3
    kmod-fs-ext4
    kmod-fs-exfat
    kmod-fs-ntfs3
    kmod-nls-utf8
    e2fsprogs
    fdisk
    usbutils
    mount-utils
"

ALL_PACKAGES="${DEFAULT_NAS_PACKAGES} ${CUSTOM_PACKAGES}"
# Normalize whitespace
ALL_PACKAGES="$(echo "$ALL_PACKAGES" | xargs)"

echo "Packages to embed:"
for pkg in $ALL_PACKAGES; do
    echo "  + $pkg"
done

# 5. Build Image
echo "-----------------------------------------------------------------"
echo "Starting ImageBuilder compilation..."
echo "-----------------------------------------------------------------"

# Patch bcm27xx image generation to use deterministic hardware root device (/dev/mmcblk0p2)
# rather than fragile PARTUUID which causes "Unable to mount root fs" on UUID mismatches.
find . -path "*/bcm27xx/image/cmdline.txt" -exec sed -i 's#@ROOT@#/dev/mmcblk0p2#g' {} +
find . -path "*/bcm27xx/image/Makefile" -exec sed -i 's#PARTUUID=\$(IMG_PART_SIGNATURE)-02#/dev/mmcblk0p2#g' {} +

MAKE_CMD="make image PROFILE=${OPENWRT_PROFILE} PACKAGES=\"${ALL_PACKAGES}\" DISABLED_SERVICES=\"dropbear\""
if [ -d "$FILES_DIR" ] && [ "$(ls -A "$FILES_DIR")" ]; then
    # In OpenWrt, /var must remain a symlink to /tmp. If a 'var' directory exists in the overlay,
    # ImageBuilder will delete the /var -> /tmp symlink, breaking early boot (ubus, procd, tmpfs).
    if [ -d "${FILES_DIR}/var" ]; then
        echo "Removing unexpected var directory from overlay (${FILES_DIR}/var) to preserve /var -> /tmp symlink..."
        rm -rf "${FILES_DIR}/var"
    fi
    echo "Embedding rootfs overlay from $FILES_DIR"
    MAKE_CMD="$MAKE_CMD FILES=${FILES_DIR}"
fi

eval "$MAKE_CMD"

# 6. Cache downloaded packages
if [ -d "packages" ]; then
    mkdir -p "${CACHE_DIR}/packages"
    cp -rn packages/. "${CACHE_DIR}/packages/" 2>/dev/null || true
fi

# 7. Collect and export images to output directory
echo "-----------------------------------------------------------------"
echo "Exporting generated images to ${OUTPUT_DIR}..."
echo "-----------------------------------------------------------------"

BIN_TARGET_DIR="$(find bin/targets -type d -name "bcm2711" | head -n 1)"
if [ -z "$BIN_TARGET_DIR" ] || [ ! -d "$BIN_TARGET_DIR" ]; then
    BIN_TARGET_DIR="$(find bin/targets -type d | tail -n 1)"
fi

# Copy SquashFS factory and sysupgrade images
cp -v "${BIN_TARGET_DIR}"/*squashfs* "${OUTPUT_DIR}/" || cp -v "${BIN_TARGET_DIR}"/* "${OUTPUT_DIR}/"

# Also extract uncompressed .img for direct convenience if needed
cd "$OUTPUT_DIR"
for gz in *squashfs-factory.img.gz; do
    if [ -f "$gz" ]; then
        IMG_NAME="${gz%.gz}"
        echo "Decompressing $gz -> $IMG_NAME for immediate flashing..."
        gzip -dc "$gz" > "$IMG_NAME"
    fi
done

# Compute checksums on generated image files
find . -maxdepth 1 -type f ! -name "sha256sums.txt" -exec sha256sum {} + > sha256sums.txt

echo "================================================================="
echo " Build Succeeded! Ready-to-flash images:"
ls -lh "$OUTPUT_DIR"
echo "================================================================="
