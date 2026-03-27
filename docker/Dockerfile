FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    tmux \
    build-essential \
    python3 \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm and Claude Code
RUN npm install -g pnpm @anthropic-ai/claude-code

WORKDIR /workspace

# Repo clone + deps install are appended by tgv init
# using --build-arg GH_TOKEN for private repos
