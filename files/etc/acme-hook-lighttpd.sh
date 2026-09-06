#!/bin/sh
# Hook executed upon successful certificate issuance / renewal
# Updates lighttpd SSL pemfile and reloads the web server

DOMAIN="$1"
if [ -z "$DOMAIN" ]; then
    DOMAIN="${main_domain:-$(uci -q get acme.nas_cert.domains | awk '{print $1}')}"
fi
[ -z "$DOMAIN" ] && exit 0

SSL_DIR="/etc/lighttpd/ssl"
mkdir -p "$SSL_DIR"

COMBINED=""
if [ -f "/etc/ssl/acme/$DOMAIN.combined.crt" ]; then
    COMBINED="/etc/ssl/acme/$DOMAIN.combined.crt"
elif [ -f "/etc/ssl/acme/${DOMAIN}_ecc/combined.cer" ]; then
    COMBINED="/etc/ssl/acme/${DOMAIN}_ecc/combined.cer"
elif [ -f "/etc/ssl/acme/$DOMAIN/combined.cer" ]; then
    COMBINED="/etc/ssl/acme/$DOMAIN/combined.cer"
elif [ -f "/etc/ssl/acme/$DOMAIN.key" ] && [ -f "/etc/ssl/acme/$DOMAIN.fullchain.crt" ]; then
    cat "/etc/ssl/acme/$DOMAIN.key" "/etc/ssl/acme/$DOMAIN.fullchain.crt" > "$SSL_DIR/acme.pem"
    COMBINED="$SSL_DIR/acme.pem"
elif [ -f "/etc/ssl/acme/$DOMAIN/key.pem" ] && [ -f "/etc/ssl/acme/$DOMAIN/fullchain.crt" ]; then
    cat "/etc/ssl/acme/$DOMAIN/key.pem" "/etc/ssl/acme/$DOMAIN/fullchain.crt" > "$SSL_DIR/acme.pem"
    COMBINED="$SSL_DIR/acme.pem"
fi

if [ -n "$COMBINED" ] && [ -f "$COMBINED" ]; then
    CERT_ISSUER="$(openssl x509 -in "$COMBINED" -issuer -noout 2>/dev/null || echo 'Unknown')"
    logger -t acme-hook "Updating Lighttpd SSL certificate for $DOMAIN ($CERT_ISSUER)"
    if [ "$COMBINED" != "$SSL_DIR/acme.pem" ]; then
        cp -f "$COMBINED" "$SSL_DIR/acme.pem"
    fi
    chmod 600 "$SSL_DIR/acme.pem"
    ln -sf "$SSL_DIR/acme.pem" "$SSL_DIR/server.pem"
    
    if [ -x /etc/init.d/lighttpd ]; then
        /etc/init.d/lighttpd restart 2>/dev/null || true
    fi
fi
