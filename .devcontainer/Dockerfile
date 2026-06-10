FROM ubuntu:24.04

ARG TARGETARCH
ENV YB_CLIENT_VERSION=2025.2.1.0
ENV YB_CLIENT_BUILD=b141

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        make \
        ca-certificates \
        curl \
        wget \
        python3 \
        python3-pip \
        python3-venv && \
    rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
      amd64) YB_ARCH=x86_64 ;; \
      arm64) YB_ARCH=aarch64 ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    wget -q "https://downloads.yugabyte.com/releases/${YB_CLIENT_VERSION}/yugabyte-client-${YB_CLIENT_VERSION}-${YB_CLIENT_BUILD}-linux-${YB_ARCH}.tar.gz" && \
    echo "$(curl -sL "https://downloads.yugabyte.com/releases/${YB_CLIENT_VERSION}/yugabyte-client-${YB_CLIENT_VERSION}-${YB_CLIENT_BUILD}-linux-${YB_ARCH}.tar.gz.sha") *yugabyte-client-${YB_CLIENT_VERSION}-${YB_CLIENT_BUILD}-linux-${YB_ARCH}.tar.gz" | shasum --check && \
    tar xfz "yugabyte-client-${YB_CLIENT_VERSION}-${YB_CLIENT_BUILD}-linux-${YB_ARCH}.tar.gz" -C /opt && \
    /opt/yugabyte-client-${YB_CLIENT_VERSION}/bin/post_install.sh && \
    ln -sf "/opt/yugabyte-client-${YB_CLIENT_VERSION}/bin/ysqlsh" /usr/local/bin/ysqlsh && \
    rm "yugabyte-client-${YB_CLIENT_VERSION}-${YB_CLIENT_BUILD}-linux-${YB_ARCH}.tar.gz"
