#!/bin/bash
# <xbar.title>TGV Sessions</xbar.title>
# <xbar.desc>Show active TGV remote coding sessions</xbar.desc>
# <xbar.author>Xavier</xbar.author>
# <xbar.version>1.2</xbar.version>

CONFIG="$HOME/.tgv/config.toml"

if [ ! -f "$CONFIG" ]; then
  echo "▲"
  echo "---"
  echo "Run tgv init first"
  exit 0
fi

# Parse SSH target from TOML config
HOST=$(grep '^host' "$CONFIG" | head -1 | sed 's/.*= *"\(.*\)"/\1/')
USER=$(grep '^user' "$CONFIG" | head -1 | sed 's/.*= *"\(.*\)"/\1/')
REPO=$(grep '^url' "$CONFIG" | head -1 | sed 's/.*= *"\(.*\)"/\1/')

if [ -z "$HOST" ] || [ -z "$USER" ]; then
  echo "▲"
  exit 0
fi

TARGET="$USER@$HOST"

# Fetch sessions via SSH (reuse multiplexed connection if available)
SOCKET="/tmp/tgv-s/$(echo "$TARGET" | shasum | cut -c1-8)"
SSH_BASE="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
DOCKER_CMD="docker ps -a --filter label=tgv.repo --format '{{.Names}}\t{{.Label \"tgv.branch\"}}\t{{.Status}}'"

SSH_OPTS="$SSH_BASE"
if [ -S "$SOCKET" ]; then
  SSH_OPTS="$SSH_BASE -o ControlPath=$SOCKET"
fi

OUTPUT=$(ssh $SSH_OPTS "$TARGET" "$DOCKER_CMD" 2>/dev/null)
RC=$?

# If multiplexed socket failed, remove it and retry with a fresh connection
if [ $RC -ne 0 ] && [ -S "$SOCKET" ]; then
  rm -f "$SOCKET"
  OUTPUT=$(ssh $SSH_BASE "$TARGET" "$DOCKER_CMD" 2>/dev/null)
  RC=$?
fi

if [ $RC -ne 0 ]; then
  echo "▲"
  echo "---"
  echo "$TARGET"
  echo "Could not connect | color=red"
  exit 0
fi

# Count sessions
TOTAL=$(echo "$OUTPUT" | grep -c '[a-z]' 2>/dev/null || echo 0)

if [ "$TOTAL" -eq 0 ]; then
  echo "▲"
  echo "---"
  echo "$TARGET"
  echo "No sessions"
  exit 0
fi

echo "▲"
echo "---"
echo "$TARGET | size=12"

while IFS=$'\t' read -r NAME BRANCH STATUS; do
  [ -z "$NAME" ] && continue

  if echo "$STATUS" | grep -q "Up"; then
    ICON="●"
  else
    ICON="○"
  fi

  # Read display name sidecar if available
  DISPLAY=$(ssh $SSH_OPTS "$TARGET" "cat /tmp/tgv-meta/$NAME.name 2>/dev/null" 2>/dev/null)
  if [ -n "$DISPLAY" ]; then
    LABEL="$DISPLAY ($BRANCH)"
  else
    LABEL="$BRANCH"
  fi

  echo "$ICON $LABEL"
done <<< "$OUTPUT"
