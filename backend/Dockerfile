# syntax=docker/dockerfile:1
# Keep this exact version aligned with go.mod; fail rather than download another toolchain.
FROM golang:1.26.2-alpine AS build
WORKDIR /src
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
COPY go.mod go.sum ./
RUN test "$(go env GOVERSION)" = "go$(awk '$1 == "go" {print $2}' go.mod)"
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -o /out/bin/api ./cmd/api && \
    go build -trimpath -o /out/bin/migrate ./cmd/migrate && \
    go build -trimpath -o /out/bin/admin ./cmd/admin

FROM alpine:3.23 AS runtime
# HTTPS for Resend, and IANA zones for profile validation. No Go compiler in this stage.
RUN apk add --no-cache ca-certificates tzdata && \
    addgroup -S -g 10001 veea && adduser -S -D -H -u 10001 -G veea veea
WORKDIR /app
COPY --from=build /out/bin/ ./bin/
ENV PATH="/app/bin:${PATH}"
USER 10001:10001
EXPOSE 18386
CMD ["/app/bin/api"]
