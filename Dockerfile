FROM ghcr.io/project-osrm/osrm-backend:latest AS osrm

# ---------------------------------------------------------------------------
# Builder stage: compile osmium-tool from source.
# Alpine doesn't package osmium-tool, so we build it once into a static-ish
# binary and COPY it into the runtime image.
# ---------------------------------------------------------------------------
FROM alpine:3.20 AS osmium-builder

RUN apk add --no-cache \
    g++ \
    cmake \
    make \
    git \
    boost-dev \
    expat-dev \
    bzip2-dev \
    zlib-dev \
    xz-dev

WORKDIR /build
RUN git clone --depth 1 --branch v1.7.1 https://github.com/mapbox/protozero.git && \
    git clone --depth 1 --branch v2.20.0 https://github.com/osmcode/libosmium.git && \
    git clone --depth 1 --branch v1.16.0 https://github.com/osmcode/osmium-tool.git && \
    cd osmium-tool && \
    mkdir build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DPROTOZERO_INCLUDE_DIR=/build/protozero/include \
        -DOSMIUM_INCLUDE_DIR=/build/libosmium/include && \
    make -j"$(nproc)" && \
    make install && \
    strip /usr/local/bin/osmium

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM alpine:3.20

COPY --from=osrm /usr/local /usr/local
COPY --from=osrm /opt /opt
COPY --from=osmium-builder /usr/local/bin/osmium /usr/local/bin/osmium

RUN apk add --no-cache \
    bash \
    wget \
    nginx \
    supervisor \
    boost-program_options \
    boost-iostreams \
    expat \
    bzip2 \
    zlib \
    xz-libs \
    && mkdir -p /var/log/supervisor /run/nginx \
    && rm -f /etc/nginx/http.d/default.conf

WORKDIR /data

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
