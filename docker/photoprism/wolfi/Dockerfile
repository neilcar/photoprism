##################################################### BUILD STAGE ######################################################
FROM ghcr.io/neilcar/distroless/photoprism-base:latest-dev@sha256:fa23f362b5c1a19d6f86659c111c39e5fe7190fe69a8af23d3c5dff39328e178 AS build

# Declare build parameters.
ARG TARGETARCH
ARG BUILD_TAG

USER root

# Copy source to image.
WORKDIR "/go/src/github.com/photoprism/photoprism"
COPY . .

# Install the TensorFlow headers and library for linking; "make install" bundles its own copy
# in /opt/photoprism/lib, which the binary finds through its rpath.
RUN env TMPDIR=/tmp ./scripts/dist/install-tensorflow.sh /usr

# Build app.
RUN make all install DESTDIR=/opt/photoprism

################################################# PARALLEL INDEX STAGE ##################################################
FROM ghcr.io/neilcar/distroless/photoprism-base:latest-dev@sha256:fa23f362b5c1a19d6f86659c111c39e5fe7190fe69a8af23d3c5dff39328e178 AS parallel-index-build

USER root

# Build the parallel-index binary from the named build context "parallel-index".
WORKDIR /src
COPY --from=parallel-index . .
RUN CGO_ENABLED=0 go build -trimpath -o /out/parallel-index ./cmd/parallel-index

################################################## PRODUCTION STAGE ####################################################
#### Base Image: photoprism-base (Wolfi, no shell)
FROM ghcr.io/neilcar/distroless/photoprism-base:latest@sha256:bbcfc372aa126f1f9b7af69442d729f036c940cb2617ba338d68b048fa716356

# Declare build parameters.
ARG TARGETARCH
ARG BUILD_TAG
ARG REVISION

# Add Open Container Initiative (OCI) annotations.
# See: https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL org.opencontainers.image.title="photoprism-index"
LABEL org.opencontainers.image.source="https://github.com/neilcar/photoprism-k8s"
LABEL org.opencontainers.image.revision="$REVISION"

# Set environment variables, see https://docs.photoprism.app/getting-started/config-options/.
ENV DO_NOT_TRACK=true \
    ORT_DISABLE_TELEMETRY=1 \
    PATH="/opt/photoprism/bin:/usr/bin:/bin" \
    PHOTOPRISM_CONTAINER=true \
    PHOTOPRISM_ARCH=$TARGETARCH \
    DOCKER_TAG=$BUILD_TAG \
    TMPDIR="/tmp" \
    TF_CPP_MIN_LOG_LEVEL=4 \
    TF_ENABLE_ONEDNN_OPTS=1 \
    MALLOC_ARENA_MAX=2 \
    PHOTOPRISM_ASSETS_PATH="/opt/photoprism/assets" \
    PHOTOPRISM_IMPORT_PATH="/photoprism/import" \
    PHOTOPRISM_ORIGINALS_PATH="/photoprism/originals" \
    PHOTOPRISM_STORAGE_PATH="/photoprism/storage" \
    PHOTOPRISM_BACKUP_PATH="/photoprism/storage/backups" \
    PHOTOPRISM_LOG_FILENAME="/photoprism/storage/photoprism.log" \
    PHOTOPRISM_PID_FILENAME="/photoprism/storage/photoprism.pid" \
    PHOTOPRISM_DEBUG="false" \
    PHOTOPRISM_PUBLIC="false" \
    PHOTOPRISM_READONLY="false" \
    PHOTOPRISM_UPLOAD_NSFW="true" \
    PHOTOPRISM_DETECT_NSFW="false" \
    PHOTOPRISM_EXPERIMENTAL="false" \
    PHOTOPRISM_SITE_URL="http://localhost:2342/" \
    PHOTOPRISM_HTTP_HOST="0.0.0.0" \
    PHOTOPRISM_HTTP_PORT="2342" \
    PHOTOPRISM_DATABASE_DRIVER="sqlite" \
    PHOTOPRISM_DATABASE_SERVER="" \
    PHOTOPRISM_DATABASE_NAME="photoprism" \
    PHOTOPRISM_DATABASE_USER="photoprism" \
    PHOTOPRISM_DISABLE_CHOWN="false" \
    PHOTOPRISM_DISABLE_WEBDAV="false" \
    PHOTOPRISM_DISABLE_SETTINGS="false" \
    PHOTOPRISM_DISABLE_BACKUPS="false" \
    PHOTOPRISM_DISABLE_EXIFTOOL="false" \
    PHOTOPRISM_DISABLE_PLACES="false" \
    PHOTOPRISM_DISABLE_TENSORFLOW="false" \
    PHOTOPRISM_DISABLE_FACES="false" \
    PHOTOPRISM_RAW_PRESETS="false" \
    PHOTOPRISM_THUMB_UNCACHED="false" \
    PHOTOPRISM_AUTO_INDEX="300" \
    PHOTOPRISM_AUTO_IMPORT="-1" \
    PHOTOPRISM_INIT="https"

# Restrict ImageMagick to the formats PhotoPrism converts.
COPY --chown=root:root --chmod=644 scripts/dist/convert/policy.xml /etc/ImageMagick-7/policy.xml

# Copy app files.
COPY --from=build --chown=root:root /opt/photoprism/ /opt/photoprism
COPY --from=parallel-index-build --chown=root:root --chmod=755 /out/parallel-index /opt/parallel-index/bin/parallel-index

# Set default working directory.
WORKDIR /photoprism

# Expose HTTP(S) ports.
EXPOSE 2342 2443

USER 0:0
ENTRYPOINT ["/opt/photoprism/bin/photoprism"]
CMD ["--help"]
