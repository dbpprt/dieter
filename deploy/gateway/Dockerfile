FROM --platform=$BUILDPLATFORM golang:1.27.2-alpine@sha256:f92b6ef800e499660581efdabdf25d9d817a9d124eaf900924f0504e7e27e12d AS build

ARG TARGETOS
ARG TARGETARCH
ARG RELEASE_VERSION=0.0.0-dev.0
ARG SOURCE_REVISION=unknown
ARG BUILT_AT=unknown

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY api ./api
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath \
    -ldflags="-s -w -X github.com/dbpprt/dieter/internal/platform/buildinfo.ReleaseVersion=$RELEASE_VERSION -X github.com/dbpprt/dieter/internal/platform/buildinfo.SourceRevision=$SOURCE_REVISION -X github.com/dbpprt/dieter/internal/platform/buildinfo.BuiltAt=$BUILT_AT" \
    -o /out/dieter-gateway ./cmd/dieter-gateway

FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk add --no-cache ca-certificates \
    && addgroup -S -g 101 dieter \
    && adduser -S -u 100 -G dieter -h /var/lib/dieter-gateway dieter \
    && install -d -o dieter -g dieter -m 0700 /var/lib/dieter-gateway
COPY --from=build /out/dieter-gateway /usr/local/bin/dieter-gateway
USER 100:101
VOLUME ["/var/lib/dieter-gateway"]
EXPOSE 4243
ENTRYPOINT ["/usr/local/bin/dieter-gateway"]
CMD ["--store", "/var/lib/dieter-gateway"]
