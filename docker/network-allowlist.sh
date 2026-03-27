#!/bin/bash
# Setup iptables rules to restrict Docker network to allowed domains only.
# Usage: ./network-allowlist.sh <docker-network-name> <domain1> <domain2> ...

set -e

NETWORK="$1"
shift
DOMAINS=("$@")

if [ -z "$NETWORK" ] || [ ${#DOMAINS[@]} -eq 0 ]; then
    echo "Usage: $0 <network-name> <domain1> [domain2] ..."
    exit 1
fi

# Get the network's subnet
SUBNET=$(docker network inspect "$NETWORK" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')
if [ -z "$SUBNET" ]; then
    echo "Could not find subnet for network $NETWORK"
    exit 1
fi

# Get the bridge interface for this network
BRIDGE=$(docker network inspect "$NETWORK" --format '{{index .Options "com.docker.network.bridge.name"}}')
if [ -z "$BRIDGE" ]; then
    # Docker auto-generates bridge name
    NETWORK_ID=$(docker network inspect "$NETWORK" --format '{{.Id}}')
    BRIDGE="br-${NETWORK_ID:0:12}"
fi

echo "Network: $NETWORK"
echo "Subnet: $SUBNET"
echo "Bridge: $BRIDGE"

# Create a custom iptables chain for tgv
CHAIN="TGV-${NETWORK:0:8}"
iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"

# Allow established connections
iptables -A "$CHAIN" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS (needed for domain resolution)
iptables -A "$CHAIN" -p udp --dport 53 -j ACCEPT
iptables -A "$CHAIN" -p tcp --dport 53 -j ACCEPT

# Resolve and allow each domain
for DOMAIN in "${DOMAINS[@]}"; do
    # Strip wildcard prefix for resolution
    RESOLVE_DOMAIN="${DOMAIN#\*.}"
    echo "Allowing: $DOMAIN (resolving $RESOLVE_DOMAIN)"

    # Resolve domain to IPs
    IPS=$(dig +short "$RESOLVE_DOMAIN" A 2>/dev/null | grep -E '^[0-9]' || true)
    if [ -z "$IPS" ]; then
        IPS=$(getent ahosts "$RESOLVE_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)
    fi

    for IP in $IPS; do
        iptables -A "$CHAIN" -d "$IP" -p tcp --dport 443 -j ACCEPT
        iptables -A "$CHAIN" -d "$IP" -p tcp --dport 80 -j ACCEPT
    done

    # Also allow by domain via string match for wildcard support
    if [[ "$DOMAIN" == \** ]]; then
        # For wildcard domains, allow the parent IP range
        echo "  (wildcard — IPs resolved from $RESOLVE_DOMAIN)"
    fi
done

# Drop everything else from this network
iptables -A "$CHAIN" -j DROP

# Insert the chain into FORWARD for traffic from our network
iptables -D FORWARD -s "$SUBNET" -j "$CHAIN" 2>/dev/null || true
iptables -I FORWARD -s "$SUBNET" -j "$CHAIN"

echo "Allowlist applied for network $NETWORK"
