#!/bin/bash
set -e

# Firewall control:
#   INCLUDE_FIREWALL (build-time): if "false", firewall is not available
#   ENABLE_FIREWALL (runtime): if "false", skip firewall even if included
if [ "${INCLUDE_FIREWALL:-true}" = "false" ]; then
    echo "Firewall not included in this build (INCLUDE_FIREWALL=false)"
elif [ "${ENABLE_FIREWALL:-true}" = "true" ]; then
    /usr/local/bin/setup-firewall.sh
else
    echo "Firewall disabled at runtime (ENABLE_FIREWALL=false)"
fi

# Drop to agent user and run claude with proper environment
exec su - agent -c "
    export NVM_DIR=/home/agent/.nvm
    . \$NVM_DIR/nvm.sh
    export PATH=/home/agent/.local/bin:\$PATH
    cd /workspace
    claude --dangerously-skip-permissions $*
"
