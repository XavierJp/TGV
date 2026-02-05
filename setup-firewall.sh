#!/bin/bash
# Allow only specific domains for Claude Code

# Flush existing rules
iptables -F OUTPUT

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow Anthropic API
iptables -A OUTPUT -d api.anthropic.com -j ACCEPT

# Allow npm registry
iptables -A OUTPUT -d registry.npmjs.org -j ACCEPT

# Allow GitHub
iptables -A OUTPUT -d github.com -j ACCEPT
iptables -A OUTPUT -d api.github.com -j ACCEPT
iptables -A OUTPUT -d raw.githubusercontent.com -j ACCEPT

# Allow Google Cloud (for Vertex AI if needed)
# iptables -A OUTPUT -d us-east5-aiplatform.googleapis.com -j ACCEPT

# Drop everything else
iptables -A OUTPUT -j DROP

echo "Firewall configured: limited network access enabled"
