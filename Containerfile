FROM docker.io/ubuntu:24.04

# Version arguments (can be overridden at build time)
ARG NODE_VERSION=22
ARG PYTHON_VERSION=3.12
ARG INCLUDE_FIREWALL=true

# Set environment variables
ENV NODE_VERSION=${NODE_VERSION}
ENV PYTHON_VERSION=${PYTHON_VERSION}
ENV INCLUDE_FIREWALL=${INCLUDE_FIREWALL}
ENV NVM_DIR=/usr/local/nvm
ENV PATH="${NVM_DIR}/versions/node/v${NODE_VERSION}/bin:$PATH"

# Install base dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    iptables \
    dnsutils \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install nvm and Node.js
RUN mkdir -p ${NVM_DIR} \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
    && . ${NVM_DIR}/nvm.sh \
    && nvm install ${NODE_VERSION} \
    && nvm use ${NODE_VERSION} \
    && nvm alias default ${NODE_VERSION}

# Install uv and Python
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && . $HOME/.local/bin/env \
    && uv python install ${PYTHON_VERSION}

# Add uv to PATH
ENV PATH="/root/.local/bin:$PATH"

# Install Claude Code globally
RUN . ${NVM_DIR}/nvm.sh && npm install -g @anthropic-ai/claude-code

# Copy firewall script
COPY setup-firewall.sh /usr/local/bin/setup-firewall.sh
RUN chmod +x /usr/local/bin/setup-firewall.sh

# Create non-root user for safety
RUN useradd -m -s /bin/bash agent

# Setup nvm and uv for agent user
RUN mkdir -p /home/agent/.nvm \
    && cp -r ${NVM_DIR}/* /home/agent/.nvm/ \
    && chown -R agent:agent /home/agent/.nvm \
    && cp -r /root/.local /home/agent/.local \
    && chown -R agent:agent /home/agent/.local

# Set agent environment
ENV NVM_DIR=/home/agent/.nvm
ENV PATH="/home/agent/.local/bin:/home/agent/.nvm/versions/node/v${NODE_VERSION}/bin:$PATH"

WORKDIR /workspace

# Entrypoint script to setup firewall then run claude
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
