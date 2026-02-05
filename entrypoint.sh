#!/bin/bash
set -e

# Setup firewall only if enabled (default: true)
if [ "${ENABLE_FIREWALL:-true}" = "true" ]; then
    /usr/local/bin/setup-firewall.sh
else
    echo "Firewall disabled (ENABLE_FIREWALL=false)"
fi

# Drop to agent user and run claude with proper environment
exec su - agent -c "
    export NVM_DIR=/home/agent/.nvm
    . \$NVM_DIR/nvm.sh
    export PATH=/home/agent/.local/bin:\$PATH
    cd /workspace
    claude --dangerously-skip-permissions $*
"
