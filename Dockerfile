# syntax=docker/dockerfile:1

# --platform=$BUILDPLATFORM keeps the compiler on the build host's native
# arch; GOOS/GOARCH below cross-compile the output instead of emulating
# the whole build under QEMU.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY main.go ./

# Injected by buildx from the --platform flag.
ARG TARGETOS
ARG TARGETARCH

# CGO_ENABLED=0 -> static binary, no libc -> can use the "static" distroless
# base below. -trimpath -ldflags="-s -w" strips symbols and build-machine
# paths.
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/ping-pong-app .

# distroless static/nonroot: no shell, no package manager, no libc, uid
# 65532 by default. Nothing here for an attacker to do even with code
# execution.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/ping-pong-app /ping-pong-app

# Explicit despite being the base image default, so a future base-image
# swap can't silently drop it.
USER nonroot:nonroot

EXPOSE 8080

# Exec form, not CMD: the binary is PID 1 and gets SIGTERM directly (needed
# for the preStop/termination handling in k8s/02-deployment.yaml), and
# ENTRYPOINT still accepts appended args for CLI mode
# (`--mode=cli --password=... ping`).
ENTRYPOINT ["/ping-pong-app"]
