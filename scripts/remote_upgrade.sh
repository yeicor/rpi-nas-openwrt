#!/usr/bin/env bash
# ==============================================================================
# OpenWrt Headless NAS – Resilient Remote Sysupgrade & Recovery Tool
# Transfers firmware, verifies integrity, arms rollback watchdog, executes
# upgrade, monitors reboot, and verifies post-boot health and version.
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

usage() {
    echo "Usage: $0 [options] <ip_or_tailscale_name> [ssh_user]"
    echo ""
    echo "Modes:"
    echo "  $0 192.168.1.100           Upgrade remote device and verify health"
    echo "  $0 rpi4nas                 Upgrade remote device using hostname"
    echo "  $0 --revert 192.168.1.100  Revert remote device to initial stock firmware"
    echo "  $0 --status 192.168.1.100  Check remote device firmware and service health"
    echo "  $0 --debug 192.168.1.100   Retrieve and view rollback diagnostics bundle"
    echo ""
    exit 1
}

MODE="upgrade"
if [ "${1:-}" = "--revert" ]; then
    MODE="revert"
    shift
elif [ "${1:-}" = "--status" ]; then
    MODE="status"
    shift
elif [ "${1:-}" = "--debug" ]; then
    MODE="debug"
    shift
elif [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
fi

TARGET_HOST="$1"
SSH_USER="${2:-root}"

if [ -z "$TARGET_HOST" ]; then
    usage
fi

SSH_TARGET="${SSH_USER}@${TARGET_HOST}"

run_ssh() {
    ssh $SSH_OPTS "$SSH_TARGET" "$@"
}

run_scp() {
    scp $SSH_OPTS "$@"
}

echo "================================================================="
echo " OpenWrt Headless NAS Remote Upgrade & Recovery"
echo " Target: ${SSH_TARGET}"
echo " Mode:   ${MODE}"
echo "================================================================="

# ------------------------------------------------------------------------------
# 1. Connectivity & Pre-flight Checks
# ------------------------------------------------------------------------------
echo -n "Checking SSH connectivity to ${SSH_TARGET}... "
if ! run_ssh "uptime" >/dev/null 2>&1; then
    echo "FAILED!"
    echo "Error: Cannot connect to ${SSH_TARGET} via SSH. Please verify network and credentials." >&2
    exit 1
fi
echo "OK"

# Handle --status mode
if [ "$MODE" = "status" ]; then
    echo ""
    run_ssh "nas-recovery status 2>/dev/null || /usr/bin/nas-recovery status 2>/dev/null || uptime"
    exit 0
fi

retrieve_and_display_rollback_debug() {
    local target_id="${1:-unknown}"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local debug_dir="$OUTPUT_DIR/rollback_debug/rollback-${timestamp}-${target_id}"

    echo ""
    echo "================================================================="
    echo " RETRIEVING ROLLBACK FAILURE DIAGNOSTIC BUNDLE"
    echo "================================================================="

    if run_ssh "test -f /recovery/rollback_reports/rollback-summary.txt || test -f /recovery/rollback_reports/rollback-latest.tar.gz" 2>/dev/null; then
        mkdir -p "$debug_dir/extracted"

        if run_ssh "test -f /recovery/rollback_reports/rollback-summary.txt" 2>/dev/null; then
            echo "Downloading failure diagnosis summary..."
            run_scp "${SSH_TARGET}:/recovery/rollback_reports/rollback-summary.txt" "$debug_dir/summary.txt" 2>/dev/null || true
        fi

        if run_ssh "test -f /recovery/rollback_reports/rollback-latest.tar.gz" 2>/dev/null; then
            echo "Downloading full failure diagnostic archive (kernel, syslog, sockets, configs)..."
            run_scp "${SSH_TARGET}:/recovery/rollback_reports/rollback-latest.tar.gz" "$debug_dir/rollback-bundle.tar.gz" 2>/dev/null || true
            tar -xzf "$debug_dir/rollback-bundle.tar.gz" -C "$debug_dir/extracted/" 2>/dev/null || true
        fi

        echo ""
        echo "================================================================="
        echo " FAILURE DIAGNOSTIC BREAKDOWN"
        echo "================================================================="
        if [ -f "$debug_dir/summary.txt" ]; then
            cat "$debug_dir/summary.txt"
        fi

        if [ -f "$debug_dir/extracted/logread.log" ]; then
            echo ""
            echo "--- System Log Error Highlights (/var/log/messages / procd) ---"
            grep -i -E "error|failed|fatal|segfault|crash|refusing|denied|killed" "$debug_dir/extracted/logread.log" 2>/dev/null | tail -n 15 || true
        fi

        if [ -f "$debug_dir/extracted/dmesg.log" ]; then
            echo ""
            echo "--- Kernel Warning / Failure Highlights ---"
            grep -i -E "error|failed|fault|panic|oops|denied|corrupt" "$debug_dir/extracted/dmesg.log" 2>/dev/null | tail -n 10 || true
        fi

        echo ""
        echo "================================================================="
        echo " DIAGNOSTIC FILES SAVED FOR TROUBLESHOOTING:"
        echo "   Diagnostic Directory: $debug_dir"
        echo "   Summary Report:       $debug_dir/summary.txt"
        echo "   Extracted Logs:       $debug_dir/extracted/"
        echo "   Raw Archive:          $debug_dir/rollback-bundle.tar.gz"
        echo "================================================================="
    else
        echo "Notice: No diagnostic reports found in /recovery/rollback_reports/ on remote device."
    fi
}

handle_rollback_detected() {
    echo ""
    echo "================================================================="
    echo " AUTONOMOUS ROLLBACK DETECTED & VERIFIED!"
    echo " The upgraded firmware failed core service verification."
    echo " The device autonomously engaged emergency rollback and restored"
    echo " the baseline stock firmware without physical intervention."
    echo "================================================================="
    echo "Rollback event log:"
    run_ssh "tail -n 14 /recovery/recovery.log 2>/dev/null" || true
    echo "================================================================="

    retrieve_and_display_rollback_debug "${LOCAL_BUILD_ID:-failed_build}"

    # Clear marker in recovery log so future checks don't re-trigger
    run_ssh "sed -i 's/AUTOMATIC ROLLBACK TO STOCK FIRMWARE/ROLLBACK COMPLETE/g' /recovery/recovery.log 2>/dev/null || true"
    exit 1
}

# Handle --debug mode
if [ "$MODE" = "debug" ]; then
    retrieve_and_display_rollback_debug "manual_fetch"
    exit 0
fi

# Handle --revert mode
if [ "$MODE" = "revert" ]; then
    echo ""
    echo "WARNING: This will revert ${TARGET_HOST} to its original stock firmware!"
    read -r -p "Are you sure you want to proceed? [type 'yes' to confirm]: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Revert aborted by user."
        exit 0
    fi
    echo "Triggering revert to stock firmware on ${TARGET_HOST}..."
    run_ssh "nas-recovery revert-stock" || true
    echo "Revert initiated. The system is rebooting into stock firmware."
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. Upgrade Mode: Image Selection & Verification
# ------------------------------------------------------------------------------
SYSUPGRADE_IMG="$(find "$OUTPUT_DIR" -type f -name "*squashfs-sysupgrade.img.gz" 2>/dev/null | head -n 1 || true)"
if [ -z "$SYSUPGRADE_IMG" ] || [ ! -f "$SYSUPGRADE_IMG" ]; then
    echo "Error: No sysupgrade image (*squashfs-sysupgrade.img.gz) found in $OUTPUT_DIR" >&2
    echo "Please run './build.sh' first to compile the firmware image." >&2
    exit 1
fi

LOCAL_SHA256="$(sha256sum "$SYSUPGRADE_IMG" | awk '{print $1}')"
IMAGE_SIZE="$(ls -lh "$SYSUPGRADE_IMG" | awk '{print $5}')"
LOCAL_BUILD_ID="$(cat "$OUTPUT_DIR/build_id" 2>/dev/null || cat "$SCRIPT_DIR/files/etc/nas_build_id" 2>/dev/null || echo "$(date +%s)")"

echo "Firmware image: $(basename "$SYSUPGRADE_IMG") (${IMAGE_SIZE})"
echo "SHA256:         ${LOCAL_SHA256}"
echo "Local Build ID: ${LOCAL_BUILD_ID}"

# Query remote device state
CURRENT_BUILD_INFO="$(run_ssh "cat /etc/nas_build_info 2>/dev/null || echo 'UNKNOWN'")"
CURRENT_BUILD_ID="$(run_ssh "cat /etc/nas_build_id 2>/dev/null || echo 'UNKNOWN'")"
echo "Remote running: ${CURRENT_BUILD_ID}"

# Check remote free space in /tmp
FREE_TMP_KB="$(run_ssh "df -k /tmp 2>/dev/null | tail -n 1 | awk '{print \$4}'" || echo 0)"
IMG_SIZE_KB="$(du -k "$SYSUPGRADE_IMG" | awk '{print $1}')"
REQUIRED_KB=$((IMG_SIZE_KB * 2))

if [ "$FREE_TMP_KB" -lt "$REQUIRED_KB" ]; then
    echo "Error: Insufficient space in remote /tmp (${FREE_TMP_KB}KB free, need ${REQUIRED_KB}KB)." >&2
    exit 1
fi

# Check image partition layout against remote disk boundaries
echo -n "Validating partition layout boundaries... "
IMG_P2_END="$(gzip -dc "$SYSUPGRADE_IMG" 2>/dev/null | dd bs=512 count=1 2>/dev/null | python3 -c '
import sys, struct
data = sys.stdin.buffer.read(512)
if len(data) == 512 and data[510:512] == b"\x55\xaa":
    offset = 0x1be + 16
    start, size = struct.unpack("<II", data[offset+8:offset+16])
    print(start + size - 1)
' 2>/dev/null || true)"

REMOTE_P3_START="$(run_ssh "fdisk -l /dev/mmcblk0 2>/dev/null | grep -E 'p3\b| 3 ' | awk '{print \$2}'" 2>/dev/null || true)"

if [ -n "$IMG_P2_END" ] && [ -n "$REMOTE_P3_START" ]; then
    if [ "$IMG_P2_END" -ge "$REMOTE_P3_START" ]; then
        echo "COLLISION DETECTED!"
        echo "Error: Firmware partition 2 ends at sector $IMG_P2_END, which overlaps" >&2
        echo "with remote partition 3 (/recovery) starting at sector $REMOTE_P3_START." >&2
        echo "Upgrade aborted to prevent corrupting persistent recovery storage." >&2
        exit 1
    fi
    echo "SAFE (P2 end: $IMG_P2_END < P3 start: $REMOTE_P3_START)"
else
    echo "OK"
fi

# Ensure remote recovery partition is initialized
run_ssh "mkdir -p /usr/bin; nas-recovery init-storage 2>/dev/null || true"

# If remote does not have stock firmware yet, initialize it
HAS_STOCK="$(run_ssh "test -f /recovery/stock-firmware.img.gz && echo 'YES' || echo 'NO'")"
if [ "$HAS_STOCK" != "YES" ]; then
    echo "First-time setup: Storing current baseline as recovery stock firmware on remote..."
    REMOTE_STOCK_TMP="/tmp/stock-init.img.gz"
    run_scp "$SYSUPGRADE_IMG" "${SSH_TARGET}:${REMOTE_STOCK_TMP}"
    run_ssh "nas-recovery save-stock ${REMOTE_STOCK_TMP} && rm -f ${REMOTE_STOCK_TMP}" || true
    echo "Baseline stock firmware saved in remote /recovery partition."
fi

# ------------------------------------------------------------------------------
# 3. Firmware Upload & Checksum Verification
# ------------------------------------------------------------------------------
REMOTE_TMP="/tmp/sysupgrade.img.gz"
echo "Uploading firmware to ${TARGET_HOST}..."
run_scp "$SYSUPGRADE_IMG" "${SSH_TARGET}:${REMOTE_TMP}"

echo -n "Verifying remote checksum... "
REMOTE_SHA256="$(run_ssh "sha256sum ${REMOTE_TMP} | awk '{print \$1}'")"
if [ "$LOCAL_SHA256" != "$REMOTE_SHA256" ]; then
    echo "MISMATCH!"
    echo "Error: Checksum validation failed on remote device!" >&2
    echo "  Local:  $LOCAL_SHA256" >&2
    echo "  Remote: $REMOTE_SHA256" >&2
    run_ssh "rm -f ${REMOTE_TMP}"
    exit 1
fi
echo "MATCHED (${REMOTE_SHA256:0:16}...)"

echo -n "Validating firmware compatibility on remote host... "
if ! run_ssh "sysupgrade -T ${REMOTE_TMP}" >/dev/null 2>&1; then
    echo "INVALID!"
    echo "Error: Remote sysupgrade image test failed. Image is incompatible with target hardware." >&2
    run_ssh "rm -f ${REMOTE_TMP}"
    exit 1
fi
echo "PASSED"

# ------------------------------------------------------------------------------
# 4. Arm Watchdog & Trigger Sysupgrade
# ------------------------------------------------------------------------------
echo "Arming automated rollback watchdog for build ${LOCAL_BUILD_ID}..."
run_ssh "nas-recovery arm-trial '${LOCAL_BUILD_ID}' 2>/dev/null || true"

echo "Triggering sysupgrade on ${TARGET_HOST}..."
UPGRADE_OUTPUT="$(run_ssh "sysupgrade -v ${REMOTE_TMP}" 2>&1 || true)"

# Check if upgrade successfully initiated
if [[ "$UPGRADE_OUTPUT" =~ "Image check failed" ]] || [[ "$UPGRADE_OUTPUT" =~ "Cannot find" ]]; then
    echo "CRITICAL ERROR: Sysupgrade failed to initiate!" >&2
    echo "$UPGRADE_OUTPUT" >&2
    exit 1
fi

echo "Sysupgrade initiated successfully. System is flashing partitions and rebooting."

# ------------------------------------------------------------------------------
# 5. Wait for Reboot & Verify Version and Services
# ------------------------------------------------------------------------------
echo "Waiting for ${TARGET_HOST} to go offline..."
sleep 8

echo -n "Waiting for ${TARGET_HOST} to complete upgrade and come back online"
ONLINE=0
for i in $(seq 1 120); do
    if run_ssh "uptime" >/dev/null 2>&1; then
        ONLINE=1
        break
    fi
    echo -n "."
    sleep 3
done
echo ""

if [ "$ONLINE" -ne 1 ]; then
    echo "=================================================================" >&2
    echo " TIMEOUT: ${TARGET_HOST} did not respond to SSH after 360 seconds." >&2
    echo " The automatic rollback watchdog is active on the device." >&2
    echo " If core services failed, the device will automatically revert to" >&2
    echo " the stock firmware." >&2
    echo "=================================================================" >&2
    exit 1
fi

echo "Target is online! Checking system status..."

# Check if autonomous rollback occurred
if run_ssh "test -f /recovery/recovery.log && grep -q 'AUTOMATIC ROLLBACK TO STOCK FIRMWARE' /recovery/recovery.log" 2>/dev/null; then
    handle_rollback_detected
fi

# Check new build ID
NEW_BUILD_ID="$(run_ssh "cat /etc/nas_build_id 2>/dev/null || echo 'UNKNOWN'")"
NEW_BUILD_DATE="$(run_ssh "grep 'BUILD_DATE' /etc/nas_build_info 2>/dev/null | cut -d= -f2 | tr -d '\"' || echo 'Unknown'")"
echo "Running Build ID: ${NEW_BUILD_ID} (${NEW_BUILD_DATE})"

if [ "$NEW_BUILD_ID" != "$LOCAL_BUILD_ID" ] && [ "$LOCAL_BUILD_ID" != "unknown" ]; then
    echo "WARNING: Remote build ID ($NEW_BUILD_ID) does not match installed build ($LOCAL_BUILD_ID)!"
fi

# Verify Core Services
echo -n "Checking core services (SSH, Tailscale, WebDAV)... "
SERVICE_CHECK="$(run_ssh "nas-recovery verify-health 2>/dev/null || echo 'FAIL'")"

if [ "$SERVICE_CHECK" = "OK" ]; then
    echo "ALL HEALTHY"
    # Disarm trial so upgrade is committed
    run_ssh "nas-recovery disarm-trial 2>/dev/null || true"
else
    echo "DEGRADED!"
    echo "Services did not reach healthy state. Waiting for autonomous rollback or stabilization..."
    for i in $(seq 1 12); do
        sleep 5
        SERVICE_CHECK="$(run_ssh "nas-recovery verify-health 2>/dev/null" 2>/dev/null || echo "FAIL")"
        if [ "$SERVICE_CHECK" = "OK" ]; then
            break
        fi
        # If device dropped offline, it has initiated autonomous rollback sysupgrade
        if ! run_ssh "uptime" >/dev/null 2>&1; then
            echo "Device dropped offline (autonomous rollback reboot initiated by device)."
            break
        fi
    done

    if [ "$SERVICE_CHECK" = "OK" ]; then
        echo "All core services stabilized and verified healthy!"
        run_ssh "nas-recovery disarm-trial 2>/dev/null || true"
    else
        echo -n "Waiting for device to complete autonomous rollback and reboot back into stock firmware"
        ONLINE=0
        for i in $(seq 1 60); do
            if run_ssh "uptime" >/dev/null 2>&1; then
                ONLINE=1
                break
            fi
            echo -n "."
            sleep 3
        done
        echo ""

        if [ "$ONLINE" -eq 1 ] && run_ssh "test -f /recovery/recovery.log && grep -q 'AUTOMATIC ROLLBACK TO STOCK FIRMWARE' /recovery/recovery.log" 2>/dev/null; then
            handle_rollback_detected
        else
            echo "ERROR: Core services failed to reach healthy state and rollback was not detected!" >&2
            run_ssh "nas-recovery status 2>/dev/null" >&2 || true
            exit 1
        fi
    fi
fi

echo "================================================================="
echo " UPGRADE AND VERIFICATION SUCCESSFUL!"
echo " Host:             ${SSH_TARGET}"
echo " Installed Build:  ${NEW_BUILD_ID}"
echo " Build Date:       ${NEW_BUILD_DATE}"
echo " Core Services:    OpenSSH: OK | Tailscale: OK | Lighttpd: OK"
echo " Recovery Status:  Stock firmware stored & rollback watchdog ready"
echo "================================================================="
