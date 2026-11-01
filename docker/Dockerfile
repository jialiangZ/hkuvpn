ARG ALPINE_VERSION=3.23
# Digest pin: verify with `docker image inspect alpine:3.23 --format '{{json .RepoDigests}}'`
ARG ALPINE_DIGEST=sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0

FROM alpine:${ALPINE_VERSION}@${ALPINE_DIGEST} AS openconnect-builder

ARG OPENCONNECT_VERSION=9.21
ARG OPENCONNECT_SHA256=5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
# https://www.infradead.org/openconnect/download.html
ARG OPENCONNECT_SIGNING_FINGERPRINT=BE07D9FD54809AB2C4B0FF5F63762CDA67E2F359

WORKDIR /build

# HKU authenticates with username + Portal PIN + a web-form MFA code, so the
# build omits GSSAPI/Kerberos, SecurID (stoken), OATH, and smart-card support
# by not providing their dev packages; configure auto-disables those features.
RUN apk add --no-cache \
        autoconf \
        automake \
        build-base \
        curl \
        gnupg \
        intltool \
        libproxy-dev \
        libxml2-dev \
        linux-headers \
        lz4-dev \
        openssl-dev \
        pkgconf \
        python3-dev

COPY keys/openconnect-release-key.asc /tmp/openconnect-release-key.asc

RUN set -eux; \
    key_fingerprint="$(gpg --batch --show-keys --with-colons /tmp/openconnect-release-key.asc \
        | awk -F: '$1 == "fpr" { print $10; exit }')"; \
    test "$key_fingerprint" = "$OPENCONNECT_SIGNING_FINGERPRINT"; \
    gpg --batch --import /tmp/openconnect-release-key.asc; \
    curl -fsSLO "https://www.infradead.org/openconnect/download/openconnect-${OPENCONNECT_VERSION}.tar.gz"; \
    curl -fsSLO "https://www.infradead.org/openconnect/download/openconnect-${OPENCONNECT_VERSION}.tar.gz.asc"; \
    signature_status="$(gpg --batch --status-fd 1 \
        --verify "openconnect-${OPENCONNECT_VERSION}.tar.gz.asc" \
        "openconnect-${OPENCONNECT_VERSION}.tar.gz" 2>/dev/null)"; \
    echo "$signature_status" \
        | grep -F "[GNUPG:] VALIDSIG ${OPENCONNECT_SIGNING_FINGERPRINT} "; \
    echo "${OPENCONNECT_SHA256}  openconnect-${OPENCONNECT_VERSION}.tar.gz" | sha256sum -c -; \
    tar -xzf "openconnect-${OPENCONNECT_VERSION}.tar.gz"; \
    cd "openconnect-${OPENCONNECT_VERSION}"; \
    ./configure \
        --prefix=/usr \
        --sbindir=/usr/bin \
        --disable-static \
        --disable-rpath \
        --with-openssl \
        --with-vpnc-script=/etc/vpnc/vpnc-script \
        --disable-nls; \
    make -j"$(getconf _NPROCESSORS_ONLN)"; \
    make DESTDIR=/openconnect-root install-exec

FROM alpine:${ALPINE_VERSION}@${ALPINE_DIGEST}

# The vpnc package itself is not needed: openconnect only runs the standalone
# /etc/vpnc/vpnc-script shell script (COPY creates the directory).
RUN apk add --no-cache \
        curl \
        expect \
        iproute2 \
        libproxy \
        libxml2 \
        lz4-libs \
        openssl

COPY --from=openconnect-builder /openconnect-root/usr/ /usr/

# vpnc-script vendored from openconnect/vpnc-scripts at upstream commit
# ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101 (2025-07-27) instead of fetching
# the moving master branch at build time. SHA256 verified during the build.
ARG VPNC_SCRIPT_SHA256=f0c4d936a382f07711263242699b5e2d85d1ace37136bb78785d352997c17742
COPY etc/vpnc-script /etc/vpnc/vpnc-script
RUN echo "${VPNC_SCRIPT_SHA256}  /etc/vpnc/vpnc-script" | sha256sum -c - \
    && chmod +x /etc/vpnc/vpnc-script

# gost (static Go binary, MIT) provides both proxy listeners in one process;
# it replaces the previous Python pproxy + supervisord stack. Release artifact
# verified against the official checksums.txt for v3.3.0 (linux/amd64).
ARG GOST_VERSION=3.3.0
ARG GOST_SHA256=676fb7f78d267b6ae73df719c0c7f2b565dde7147da935cfafbc1e1da558b6d5
RUN curl -fsSLO "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_amd64.tar.gz" \
    && echo "${GOST_SHA256}  gost_${GOST_VERSION}_linux_amd64.tar.gz" | sha256sum -c - \
    && tar -xzf "gost_${GOST_VERSION}_linux_amd64.tar.gz" gost \
    && install -m 0755 gost /usr/local/bin/gost \
    && rm -f gost "gost_${GOST_VERSION}_linux_amd64.tar.gz"

COPY hku-connect.exp /usr/local/bin/hku-connect
RUN chmod +x /usr/local/bin/hku-connect

ENTRYPOINT ["/usr/local/bin/hku-connect"]
