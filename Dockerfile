
ARG NODE_VERSION=24.17.0
ARG NODE_ARCH="linux-x64"
ARG N8N_VERSION=2.26.7

# -----------------------------------------------------------------------------
# Node runtime stage
# -----------------------------------------------------------------------------
FROM ubuntu:24.04 AS node-runtime

ARG NODE_VERSION
ARG NODE_ARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        xz-utils; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    NODE_TARBALL="node-v${NODE_VERSION}-${NODE_ARCH}.tar.xz"; \
    NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}"; \
    curl -fsSL --compressed "${NODE_URL}" -o "/tmp/${NODE_TARBALL}"; \
    test -s "/tmp/${NODE_TARBALL}"; \
    tar -xJf "/tmp/${NODE_TARBALL}" -C /usr/local --strip-components=1 --no-same-owner; \
    ln -sf /usr/local/bin/node /usr/local/bin/nodejs; \
    node --version; \
    npm --version; \
    rm -f "/tmp/${NODE_TARBALL}"; \
    npm cache clean --force; \
    rm -rf /tmp/* /root/.npm /root/.cache


# -----------------------------------------------------------------------------
# n8n builder stage
# -----------------------------------------------------------------------------
FROM node-runtime AS n8n-builder

ARG N8N_VERSION

ENV NODE_ENV=production

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        python3 \
        make \
        g++; \
    rm -rf /var/lib/apt/lists/*

# Install n8n and custom community node package in the builder stage only.
RUN set -eux; \
    npm install -g --omit=dev --prefer-dedupe \
        full-icu \
        "n8n@${N8N_VERSION}" \
        n8n-nodes-aws-sdk-v3; \
    npm cache clean --force; \
    rm -rf /root/.npm /root/.cache /tmp/*

# Rebuild native dependencies against this Ubuntu/glibc runtime.
RUN set -eux; \
    cd /usr/local/lib/node_modules/n8n; \
    npm rebuild sqlite3 || true; \
    npm rebuild isolated-vm || true

# moderately aggressive cleanup.
# Avoid deleting *.ts blindly because some packages may reference shipped source/schema files.
RUN set -eux; \
    find /usr/local/lib/node_modules -type d \( \
        -name ".cache" -o \
        -name "test" -o \
        -name "tests" -o \
        -name "__tests__" -o \
        -name "coverage" -o \
        -name "docs" -o \
        -name "doc" -o \
        -name "example" -o \
        -name "examples" \
    \) -prune -exec rm -rf '{}' +; \
    find /usr/local/lib/node_modules -type f \( \
        -name "*.map" -o \
        -name "*.md" -o \
        -name "*.markdown" -o \
        -name "*.tsbuildinfo" \
    \) -delete; \
    rm -rf /root/.npm /root/.cache /tmp/*

# -----------------------------------------------------------------------------
# Final image
# -----------------------------------------------------------------------------
FROM ubuntu:24.04

ARG NODE_VERSION
ARG NODE_ARCH
ARG N8N_VERSION
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

ENV STEAMPIPE_INSTALL_DIR="/workdir/steampipe"
ENV STEAMPIPE_CACHE_MAX_TTL=432000
ENV STEAMPIPE_CACHE_TTL=432000
ENV STEAMPIPE_TELEMETRY=none

ENV POWERPIPE_INSTALL_DIR="/workdir/powerpipe"
ENV POWERPIPE_TELEMETRY=none

ENV NODE_ENV=production
ENV N8N_VERSION=${N8N_VERSION}
ENV NODE_PATH=/usr/local/lib/node_modules

RUN set -eux; \
    groupadd --system security; \
    useradd --create-home --system --shell /bin/bash -g security --uid 501 security

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gnupg \
        python3 \
        python3-pip \
        apt-transport-https \
        unzip \
        xz-utils; \
    mkdir -p /workdir/dashboards /workdir/reports; \
    chown -R security:security /workdir; \
    rm -rf /var/lib/apt/lists/* /tmp/* /root/.cache

# Copy complete Node runtime from the node-runtime stage.
# Do not copy npm/npx as isolated files; their wrappers/symlinks depend on the surrounding /usr/local layout.
COPY --from=node-runtime /usr/local/bin/ /usr/local/bin/
COPY --from=node-runtime /usr/local/include/ /usr/local/include/
COPY --from=node-runtime /usr/local/lib/ /usr/local/lib/
COPY --from=node-runtime /usr/local/share/ /usr/local/share/

# Copy only the prepared n8n runtime artefacts from the n8n builder.
COPY --from=n8n-builder /usr/local/lib/node_modules/n8n /usr/local/lib/node_modules/n8n
COPY --from=n8n-builder /usr/local/lib/node_modules/full-icu /usr/local/lib/node_modules/full-icu
COPY --from=n8n-builder /usr/local/lib/node_modules/n8n-nodes-aws-sdk-v3 /usr/local/lib/node_modules/n8n-nodes-aws-sdk-v3

RUN set -eux; \
    ln -sf /usr/local/lib/node_modules/n8n/bin/n8n /usr/local/bin/n8n; \
    node --version; \
    npm --version; \
    npx --version; \
    n8n --version; \
    rm -rf /root/.npm /root/.cache /tmp/*

# Optional: remove npm/npx if you do not need to install packages at runtime.
# This saves only a small amount, usually ~20MB, but reduces runtime surface.
# RUN set -eux; \
#     rm -rf /usr/local/lib/node_modules/npm \
#            /usr/local/bin/npm \
#            /usr/local/bin/npx

# AWS CLI. Architecture-aware and removes installer residue.
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) AWS_ARCH="x86_64" ;; \
        arm64) AWS_ARCH="aarch64" ;; \
        *) echo "Unsupported TARGETARCH for AWS CLI: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip; \
    unzip -q /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install; \
    aws --version; \
    rm -rf /tmp/aws /tmp/awscliv2.zip /aws /root/.cache

# Install Steampipe, Powerpipe and Tailpipe.
RUN set -eux; \
    /bin/sh -c "$(curl -fsSL https://powerpipe.io/install/powerpipe.sh)"; \
    /bin/sh -c "$(curl -fsSL https://steampipe.io/install/steampipe.sh)"; \
    /bin/sh -c "$(curl -fsSL https://tailpipe.io/install/tailpipe.sh)"; \
    rm -rf /tmp/* /root/.cache

USER security

RUN set -eux; \
    steampipe plugin install aws; \
    steampipe plugin install slack; \
    steampipe plugin install github; \
    steampipe plugin install theapsgroup/gitlab; \
    steampipe plugin install datadog; \
    steampipe plugin install googleworkspace; \
    steampipe plugin install okta; \
    steampipe plugin install googledirectory; \
    steampipe plugin install terraform; \
    steampipe plugin install trivy; \
    steampipe plugin install kubernetes; \
    rm -rf /home/security/.cache /tmp/*

RUN set -eux; \
    cd /workdir/dashboards; \
    powerpipe mod init; \
    powerpipe mod install github.com/turbot/steampipe-mod-aws-compliance; \
    powerpipe mod install github.com/turbot/steampipe-mod-aws-well-architected; \
    powerpipe mod install github.com/turbot/steampipe-mod-terraform-aws-compliance; \
    powerpipe mod install github.com/turbot/steampipe-mod-aws-insights; \
    powerpipe mod install github.com/turbot/steampipe-mod-aws-perimeter; \
    powerpipe mod install github.com/turbot/tailpipe-mod-aws-cost-and-usage-insights; \
    powerpipe mod install github.com/turbot/tailpipe-mod-aws-vpc-flow-log-detections; \
    powerpipe mod install github.com/turbot/steampipe-mod-github-insights; \
    powerpipe mod install github.com/turbot/steampipe-mod-github-compliance; \
    powerpipe mod install github.com/turbot/steampipe-mod-googleworkspace-compliance; \
    powerpipe mod install github.com/turbot/steampipe-mod-kubernetes-compliance; \
    rm -rf /home/security/.cache /tmp/*

RUN set -eux; \
    tailpipe plugin install aws; \
    tailpipe plugin install github; \
    rm -rf /home/security/.cache /tmp/*

WORKDIR /workdir

EXPOSE 9193
EXPOSE 9033

CMD ["steampipe", "service", "start"]