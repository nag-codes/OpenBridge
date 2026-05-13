# Build stage: compile vmd
FROM docker.io/library/golang:1.25-alpine AS builder
WORKDIR /src
COPY . .
RUN go mod download
RUN CGO_ENABLED=0 go build -o /vmd ./cmd/vmd

# Runtime stage
FROM docker.io/library/debian:trixie-slim

# Install only essential system tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    openssh-client \
    curl \
    socat \
    iproute2 \
    udhcpc \
    ripgrep \
    fd-find \
    iputils-ping \
    python3 \
    python3-pip \
    python3-venv \
    python-is-python3 \
    file \
    jq \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/lib/python*/EXTERNALLY-MANAGED

RUN rm -rf /etc/ssh/ssh_host_*

# Copy vmd binary as init from builder stage
# vmd serves as init (PID 1) and sandbox daemon
COPY --from=builder --chmod=755 /vmd /sbin/init
