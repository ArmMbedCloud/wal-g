# syntax=docker/dockerfile:1.7
# wal-g v0.2.14 (PostgreSQL build) for platform/stolon (IzumaNetworks paas tools/stolon-image).
FROM --platform=linux/amd64 golang:1.11-stretch AS build
ARG DEP_VERSION=v0.5.4
ARG BROTLI_COMMIT=5805f99a533a8f8118699c0100d8c102f3605f65
ARG WALG_VERSION=v0.2.14
ARG WALG_REVISION=d372cbd
RUN sed -i -e 's|deb.debian.org|archive.debian.org|g' -e 's|security.debian.org|archive.debian.org|g' -e '/stretch-updates/d' /etc/apt/sources.list \
    && apt-get update && apt-get install -y --no-install-recommends liblzo2-dev cmake \
    && rm -rf /var/lib/apt/lists/*
ADD --chmod=0755 https://github.com/golang/dep/releases/download/${DEP_VERSION}/dep-linux-amd64 /usr/local/bin/dep
WORKDIR /go/src/github.com/wal-g/wal-g
COPY Gopkg.toml Gopkg.lock ./
RUN --mount=type=cache,target=/go/pkg/dep dep ensure -vendor-only
RUN git clone -q https://github.com/google/brotli.git submodules/brotli && git -C submodules/brotli checkout -q ${BROTLI_COMMIT}
COPY . .
RUN dep ensure -vendor-only \
    && sed -i 's|\(#cgo LDFLAGS:\) .*|\1 -Wl,-Bstatic -llzo2 -Wl,-Bdynamic|' vendor/github.com/cyberdelia/lzo/lzo.go \
    && ./link_brotli.sh \
    && cd main/pg && go build -tags "brotli lzo" -o /out/wal-g \
       -ldflags "-s -w -X github.com/wal-g/wal-g/cmd/pg.BuildDate=$(date -u +%Y.%m.%d_%H:%M:%S) -X github.com/wal-g/wal-g/cmd/pg.GitRevision=${WALG_REVISION} -X github.com/wal-g/wal-g/cmd/pg.WalgVersion=${WALG_VERSION}"

FROM --platform=linux/amd64 debian:buster-slim AS runtime
COPY --from=build /out/wal-g /usr/local/bin/wal-g
ENTRYPOINT ["/usr/local/bin/wal-g"]
CMD ["--help"]
