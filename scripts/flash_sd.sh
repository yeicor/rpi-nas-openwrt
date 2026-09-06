#!/usr/bin/env bash
# ==============================================================================
# OpenWrt Headless NAS – Safe MicroSD Card Flashing Script
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"

# 1. Locate factory image
FACTORY_IMG="$(find "$OUTPUT_DIR" -type f -name "*squashfs-factory.img" 2>/dev/null | head -n 1 || true)"
FACTORY_GZ="$(find "$OUTPUT_DIR" -type f -name "*squashfs-factory.img.gz" 2>/dev/null | head -n 1 || true)"

IMAGE_FILE=""
if [ -n "$FACTORY_IMG" ] && [ -f "$FACTORY_IMG" ]; then
    IMAGE_FILE="$FACTORY_IMG"
elif [ -n "$FACTORY_GZ" ] && [ -f "$FACTORY_GZ" ]; then
    IMAGE_FILE="$FACTORY_GZ"
fi

if [ -z "$IMAGE_FILE" ] || [ ! -f "$IMAGE_FILE" ]; then
    echo "Error: No factory image found in $OUTPUT_DIR" >&2
    echo "Please run './build.sh' first to generate the image." >&2
    exit 1
fi

echo "================================================================="
echo " OpenWrt MicroSD Card Flasher"
echo " Image to write: $(basename "$IMAGE_FILE")"
echo "================================================================="

# 2. Target device selection
TARGET_DEV="$1"

if [ -z "$TARGET_DEV" ]; then
    echo ""
    echo "Available block devices:"
    lsblk -d -o NAME,SIZE,TYPE,TRAN,MODEL,RM,MOUNTPOINTS
    echo ""
    read -r -p "Enter target device name (e.g., /dev/sdb or /dev/mmcblk0): " TARGET_DEV
fi

if [ -z "$TARGET_DEV" ] || [ ! -b "$TARGET_DEV" ]; then
    echo "Error: '$TARGET_DEV' is not a valid block device." >&2
    exit 1
fi

# 3. Critical Safety Checks
ROOT_DISK="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE / 2>/dev/null || df / | tail -n 1 | awk '{print $1}')" 2>/dev/null || true)"
TARGET_NAME="$(basename "$TARGET_DEV")"

if [ "$TARGET_NAME" = "$ROOT_DISK" ] || [ "$TARGET_DEV" = "/dev/$ROOT_DISK" ]; then
    echo "CRITICAL ERROR: Refusing to write to '$TARGET_DEV' because it contains your host ROOT filesystem!" >&2
    exit 1
fi

if lsblk -no MOUNTPOINT "$TARGET_DEV"* 2>/dev/null | grep -E '^/(boot|home|usr|var)?$' >/dev/null; then
    echo "CRITICAL ERROR: Target device contains active system mountpoints!" >&2
    exit 1
fi

echo ""
echo "Target disk information:"
lsblk "$TARGET_DEV"
echo ""
echo "WARNING: ALL DATA ON '$TARGET_DEV' WILL BE PERMANENTLY ERASED!"
read -r -p "Are you ABSOLUTELY sure you want to proceed? [type 'yes' to continue]: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted by user."
    exit 0
fi

# 4. Unmount any mounted partitions on the target device
echo "Unmounting any active partitions on $TARGET_DEV..."
for part in $(lsblk -lno NAME "$TARGET_DEV" | tail -n +2); do
    sudo umount "/dev/$part" 2>/dev/null || true
done

# 5. Flash the image
echo "Writing image to $TARGET_DEV..."
if [[ "$IMAGE_FILE" == *.gz ]]; then
    gzip -dc "$IMAGE_FILE" | sudo dd of="$TARGET_DEV" bs=4M status=progress conv=fsync
else
    sudo dd if="$IMAGE_FILE" of="$TARGET_DEV" bs=4M status=progress conv=fsync
fi

echo "Flushing disk cache (sync)..."
sync

echo "================================================================="
echo " Flashing completed successfully!"
echo " You can now safely remove the microSD card, insert it into your"
echo " Raspberry Pi 4, plug in Ethernet, and power it on."
echo "================================================================="
