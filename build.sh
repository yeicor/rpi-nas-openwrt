#!/usr/bin/env bash
# ==============================================================================
# OpenWrt Headless NAS Build Script for Raspberry Pi 4
# Automates image building with Docker, embedding all custom services & configs.
# ==============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Load user configuration from .env
if [ ! -f ".env" ]; then
    echo "Error: .env configuration file not found!" >&2
    echo "Please copy .env.example to .env and configure all mandatory variables." >&2
    exit 1
fi

echo "Loading user configuration from .env..."
# shellcheck disable=SC1091
source ".env"

# 2. Strict Configuration Validation (Fail loudly on missing or invalid config)
ERRORS=()

# Required core variables
[ -z "${OPENWRT_VERSION:-}" ] && ERRORS+=("OPENWRT_VERSION is required (e.g. 25.12.5).")
[ -z "${OPENWRT_TARGET:-}" ] && ERRORS+=("OPENWRT_TARGET is required (e.g. bcm27xx/bcm2711).")
[ -z "${OPENWRT_PROFILE:-}" ] && ERRORS+=("OPENWRT_PROFILE is required (e.g. rpi-4).")
[ -z "${DEVICE_HOSTNAME:-}" ] && ERRORS+=("DEVICE_HOSTNAME is required (e.g. rpi4nas).")
[ -z "${NAS_USER:-}" ] && ERRORS+=("NAS_USER is required.")
[ -z "${NAS_PASSWORD:-}" ] && ERRORS+=("NAS_PASSWORD is required.")
ROOT_PASSWORD="${ROOT_PASSWORD:-$NAS_PASSWORD}"
[ -z "${ROOT_PASSWORD:-}" ] && ERRORS+=("ROOT_PASSWORD is required.")
[ -z "${SSH_PUBLIC_KEY:-}" ] && ERRORS+=("SSH_PUBLIC_KEY is required.")

# Validate SSH Public Key
SSH_KEY_CONTENT=""
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    EXPANDED_KEY="${SSH_PUBLIC_KEY/#\~/$HOME}"
    if [ -f "$EXPANDED_KEY" ]; then
        SSH_KEY_CONTENT="$(cat "$EXPANDED_KEY")"
    elif [[ "$SSH_PUBLIC_KEY" =~ ^ssh-(ed25519|rsa|ecdsa) ]]; then
        SSH_KEY_CONTENT="$SSH_PUBLIC_KEY"
    else
        ERRORS+=("SSH_PUBLIC_KEY '$SSH_PUBLIC_KEY' is neither an existing file path nor a valid SSH public key string.")
    fi
fi

# Validate Cloudflare DDNS consistency
if [ -n "${DDNS_DOMAIN:-}" ] && [ -z "${DDNS_TOKEN:-}" ]; then
    ERRORS+=("DDNS_DOMAIN is set ('$DDNS_DOMAIN') but DDNS_TOKEN is missing.")
fi
if [ -z "${DDNS_DOMAIN:-}" ] && [ -n "${DDNS_TOKEN:-}" ]; then
    ERRORS+=("DDNS_TOKEN is set but DDNS_DOMAIN is empty.")
fi

# Validate ACME / Let's Encrypt consistency
if [ -n "${ACME_DOMAIN:-}" ]; then
    [ -z "${ACME_EMAIL:-}" ] && ERRORS+=("ACME_DOMAIN is set ('$ACME_DOMAIN') but ACME_EMAIL is missing.")
    [ -z "${ACME_CREDENTIALS:-}" ] && ERRORS+=("ACME_DOMAIN is set ('$ACME_DOMAIN') but ACME_CREDENTIALS is missing.")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "=================================================================" >&2
    echo " CONFIGURATION ERROR: The following required settings are missing or invalid in .env:" >&2
    for err in "${ERRORS[@]}"; do
        echo "  - $err" >&2
    done
    echo "=================================================================" >&2
    exit 1
fi

echo "================================================================="
echo " Building OpenWrt Headless NAS: ${DEVICE_HOSTNAME}"
echo " Release:  ${OPENWRT_VERSION} (${OPENWRT_TARGET}, profile: ${OPENWRT_PROFILE})"
echo " NAS User: ${NAS_USER}"
echo "================================================================="

# 3. Check Docker availability
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: docker command not found. Please install Docker first." >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "Error: Docker daemon is not running or accessible by current user." >&2
    exit 1
fi

# 4. Prepare build working directories
BUILD_DIR="$SCRIPT_DIR/build"
OVERLAY_DIR="$BUILD_DIR/overlay"
CACHE_DIR="$BUILD_DIR/cache"
OUTPUT_DIR="$SCRIPT_DIR/output"

rm -rf "$OVERLAY_DIR"
mkdir -p "$OVERLAY_DIR" "$CACHE_DIR" "$OUTPUT_DIR"

# Copy base template files into overlay
if [ -d "files" ]; then
    cp -r files/. "$OVERLAY_DIR/"
fi

# 5. Inject Dynamic Configurations into Overlay

# (a) NAS non-root user, root password, and password hashes
mkdir -p "$OVERLAY_DIR/etc" "$OVERLAY_DIR/etc/tailscale" "$OVERLAY_DIR/mnt/sda1"
rm -rf "$OVERLAY_DIR/var"
echo "$NAS_USER" > "$OVERLAY_DIR/etc/nas_user"

if command -v openssl >/dev/null 2>&1; then
    PASS_HASH="$(openssl passwd -6 "$NAS_PASSWORD")"
    echo "$PASS_HASH" > "$OVERLAY_DIR/etc/nas_pass_hash"
    ROOT_PASS_HASH="$(openssl passwd -6 "$ROOT_PASSWORD")"
    echo "$ROOT_PASS_HASH" > "$OVERLAY_DIR/etc/root_pass_hash"
else
    echo "Error: openssl command not found on host to generate password hash." >&2
    exit 1
fi

# (b) SSH Public Keys
mkdir -p "$OVERLAY_DIR/etc/dropbear" "$OVERLAY_DIR/root/.ssh" "$OVERLAY_DIR/home/$NAS_USER/.ssh"
echo "$SSH_KEY_CONTENT" > "$OVERLAY_DIR/etc/dropbear/authorized_keys"
echo "$SSH_KEY_CONTENT" > "$OVERLAY_DIR/root/.ssh/authorized_keys"
echo "$SSH_KEY_CONTENT" > "$OVERLAY_DIR/home/$NAS_USER/.ssh/authorized_keys"
chmod 700 "$OVERLAY_DIR/root" "$OVERLAY_DIR/root/.ssh" "$OVERLAY_DIR/home/$NAS_USER" "$OVERLAY_DIR/home/$NAS_USER/.ssh"
chmod 755 "$OVERLAY_DIR/home" 2>/dev/null || true
chmod 600 "$OVERLAY_DIR/etc/dropbear/authorized_keys" \
          "$OVERLAY_DIR/root/.ssh/authorized_keys" \
          "$OVERLAY_DIR/home/$NAS_USER/.ssh/authorized_keys"
echo "Injected SSH authorized keys."

# (c) Hostname injection
if [ -f "$OVERLAY_DIR/etc/config/system" ]; then
    sed -i "s/option hostname '.*'/option hostname '$DEVICE_HOSTNAME'/" "$OVERLAY_DIR/etc/config/system"
fi
if [ -f "$OVERLAY_DIR/etc/config/network" ]; then
    sed -i "s/option hostname '.*'/option hostname '$DEVICE_HOSTNAME'/" "$OVERLAY_DIR/etc/config/network"
fi

# (d) Tailscale Auth Key
if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    echo "$TAILSCALE_AUTH_KEY" > "$OVERLAY_DIR/etc/tailscale_auth_key"
    chmod 600 "$OVERLAY_DIR/etc/tailscale_auth_key"
    echo "Configured Tailscale zero-touch auto-join."
fi

# (e) Cloudflare Dynamic DNS
if [ -n "$DDNS_DOMAIN" ] && [ -f "$OVERLAY_DIR/etc/config/ddns" ]; then
    CF_DOMAIN="$DDNS_DOMAIN"
    # For Cloudflare v4 script, subdomains need format host@zone.tld (e.g. nas@example.com)
    if [[ ! "$CF_DOMAIN" =~ @ ]] && command -v curl >/dev/null 2>&1 && [ -n "$DDNS_TOKEN" ]; then
        ZONES_JSON="$(curl -s -H "Authorization: Bearer $DDNS_TOKEN" https://api.cloudflare.com/client/v4/zones 2>/dev/null || true)"
        MATCHED_ZONE="$(echo "$ZONES_JSON" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | while read -r z; do
            if [[ "$CF_DOMAIN" == *"$z" ]] && [ "$CF_DOMAIN" != "$z" ]; then
                echo "$z"
                break
            fi
        done)"
        if [ -n "$MATCHED_ZONE" ]; then
            SUB="${CF_DOMAIN%.$MATCHED_ZONE}"
            CF_DOMAIN="${SUB}@${MATCHED_ZONE}"
            echo "Auto-formatted Cloudflare DDNS domain: $CF_DOMAIN (zone: $MATCHED_ZONE)"
        fi
    fi
    LOOKUP_HOST="${CF_DOMAIN/@/.}"

    sed -i "s/option enabled '0'/option enabled '1'/" "$OVERLAY_DIR/etc/config/ddns"
    sed -i "s/option domain ''/option domain '$CF_DOMAIN'/" "$OVERLAY_DIR/etc/config/ddns"
    sed -i "s/option password ''/option password '$DDNS_TOKEN'/" "$OVERLAY_DIR/etc/config/ddns"
    echo -e "\toption lookup_host '$LOOKUP_HOST'" >> "$OVERLAY_DIR/etc/config/ddns"
    echo "Configured Cloudflare DDNS for host: $LOOKUP_HOST ($CF_DOMAIN)"
fi

# (f) ACME Let's Encrypt DNS-01
if [ -n "$ACME_DOMAIN" ] && [ -f "$OVERLAY_DIR/etc/config/acme" ]; then
    sed -i "s/option enabled '0'/option enabled '1'/" "$OVERLAY_DIR/etc/config/acme"
    sed -i "s/option account_email ''/option account_email '$ACME_EMAIL'/" "$OVERLAY_DIR/etc/config/acme"
    ACME_DNS="${ACME_DNS_PROVIDER:-dns_cf}"
    [ "$ACME_DNS" = "dns_cloudflare" ] && ACME_DNS="dns_cf"
    sed -i "s/option dns '.*'/option dns '$ACME_DNS'/" "$OVERLAY_DIR/etc/config/acme"
    sed -i "s/option staging '.*'/option staging '${ACME_STAGING:-0}'/" "$OVERLAY_DIR/etc/config/acme"
    sed -i "s/option calias ''/option calias ''\n\tlist domains '$ACME_DOMAIN'/" "$OVERLAY_DIR/etc/config/acme"
    if [ -n "$ACME_CREDENTIALS" ]; then
        echo -e "\tlist credentials '$ACME_CREDENTIALS'" >> "$OVERLAY_DIR/etc/config/acme"
    fi
    echo "Configured ACME Let's Encrypt for domain: $ACME_DOMAIN"
fi

# (g) WiFi Fallback Configuration (up to 2 saved networks)
WIFI_KEY_1="${WIFI_KEY_1:-${WIFI_PASSWORD_1:-}}"
WIFI_KEY_2="${WIFI_KEY_2:-${WIFI_PASSWORD_2:-}}"

if [ -n "${WIFI_SSID_1:-}" ] || [ -n "${WIFI_SSID_2:-}" ]; then
    cat <<EOF > "$OVERLAY_DIR/etc/nas_wifi.conf"
WIFI_SSID_1="${WIFI_SSID_1:-}"
WIFI_KEY_1="${WIFI_KEY_1:-}"
WIFI_SSID_2="${WIFI_SSID_2:-}"
WIFI_KEY_2="${WIFI_KEY_2:-}"
EOF
    chmod 600 "$OVERLAY_DIR/etc/nas_wifi.conf"
    echo "Configured WiFi fallback with saved networks: SSID1='${WIFI_SSID_1:-none}', SSID2='${WIFI_SSID_2:-none}'"
fi

# (h) Build Identification Metadata
BUILD_ID="$(date +%s)"
BUILD_DATE="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo 'release')"
cat <<EOF > "$OVERLAY_DIR/etc/nas_build_info"
BUILD_ID=${BUILD_ID}
BUILD_DATE="${BUILD_DATE}"
GIT_COMMIT=${GIT_COMMIT}
DEVICE_HOSTNAME=${DEVICE_HOSTNAME}
OPENWRT_VERSION=${OPENWRT_VERSION}
EOF
echo "$BUILD_ID" > "$OVERLAY_DIR/etc/nas_build_id"
mkdir -p "$OUTPUT_DIR"
cp -f "$OVERLAY_DIR/etc/nas_build_info" "$OUTPUT_DIR/build_info" 2>/dev/null || true
cp -f "$OVERLAY_DIR/etc/nas_build_id" "$OUTPUT_DIR/build_id" 2>/dev/null || true

# Ensure all scripts have execute permissions
find "$OVERLAY_DIR" -type f -name "*.sh" -exec chmod +x {} +
chmod +x "$OVERLAY_DIR/etc/uci-defaults/99-nas-setup" 2>/dev/null || true
chmod +x "$OVERLAY_DIR/etc/hotplug.d/"*/* 2>/dev/null || true
chmod +x "$OVERLAY_DIR/sbin/"* 2>/dev/null || true
chmod +x "$OVERLAY_DIR/usr/bin/"* 2>/dev/null || true
chmod +x "$OVERLAY_DIR/etc/init.d/"* 2>/dev/null || true
chmod +x "$OVERLAY_DIR/lib/upgrade/"*.sh 2>/dev/null || true
chmod +x "$OVERLAY_DIR/lib/preinit/"* 2>/dev/null || true


# 6. Build Docker Image
echo "Building builder container image..."
docker build -t rpi4-nas-builder .

# 7. Execute Build Container
echo "Running build container..."
docker run --rm \
    -v "$OUTPUT_DIR:/output" \
    -v "$CACHE_DIR:/builder/cache" \
    -v "$OVERLAY_DIR:/builder/overlay" \
    -e OPENWRT_VERSION="$OPENWRT_VERSION" \
    -e OPENWRT_TARGET="$OPENWRT_TARGET" \
    -e OPENWRT_PROFILE="$OPENWRT_PROFILE" \
    -e CUSTOM_PACKAGES="$CUSTOM_PACKAGES" \
    rpi4-nas-builder

echo ""
echo "================================================================="
echo " BUILD COMPLETE!"
echo " Images are saved in: $OUTPUT_DIR"
echo "   - Factory image (for initial SD card flashing):"
echo "     $(ls -1 "$OUTPUT_DIR"/*squashfs-factory.img* 2>/dev/null | head -n 1)"
echo "   - Sysupgrade image (for remote upgrades):"
echo "     $(ls -1 "$OUTPUT_DIR"/*squashfs-sysupgrade.img* 2>/dev/null | head -n 1)"
echo "================================================================="
