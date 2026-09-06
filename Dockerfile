FROM alpine:3.20

# Install tools needed by OpenWrt ImageBuilder and utilities
RUN apk add --no-cache \
    bash \
    make \
    curl \
    tar \
    zstd \
    perl \
    xz \
    python3 \
    gawk \
    bzip2 \
    openssl \
    git \
    file \
    unzip \
    findutils \
    coreutils \
    mtools \
    7zip \
    shadow \
    patch \
    diffutils \
    grep \
    gzip \
    wget

WORKDIR /builder

COPY entrypoint.sh /builder/entrypoint.sh
RUN chmod +x /builder/entrypoint.sh

ENTRYPOINT ["/builder/entrypoint.sh"]
