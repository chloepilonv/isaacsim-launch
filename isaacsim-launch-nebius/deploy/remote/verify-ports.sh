#!/usr/bin/env bash
# Runs ON the VM.  Shows what is actually listening, then sniffs for inbound UDP media packets.
set -uo pipefail
echo "--- listening sockets ---"
sudo ss -lntup | grep -E ':(8210|49100|47998)\b' || echo "(none of 8210/49100/47998 is bound yet)"
echo
echo "--- sniffing udp/47998 for 8s (send a probe from your laptop now) ---"
sudo timeout 8 tcpdump -n -i any udp port 47998 2>/dev/null | head -5
