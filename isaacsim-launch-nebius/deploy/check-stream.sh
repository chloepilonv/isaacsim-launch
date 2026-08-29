#!/usr/bin/env bash
# Proves the three streaming ports are actually reachable from THIS machine.
# TCP is checked directly; UDP is checked by sending a probe while the VM sniffs for it.
. "$(dirname "$0")/common.sh"
load_state

need nc "install netcat"
echo "target: $HOST  (ssh: $SSH_TARGET)"

for p in 8210 49100; do
  if nc -z -w4 "$HOST" "$p" 2>/dev/null; then echo "  [ok]   tcp/$p reachable"
  else echo "  [FAIL] tcp/$p blocked or not listening"; fi
done

echo "  ...    udp/47998: sniffing on the VM while probing from here"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sudo timeout 8 tcpdump -n -i any -c 1 udp port 47998 2>/dev/null' > /tmp/isaac_udp_probe.txt &
SNIFF=$!
sleep 2
for _ in 1 2 3; do printf 'isaac-udp-probe' | nc -u -w1 "$HOST" 47998 >/dev/null 2>&1 || true; sleep 1; done
wait $SNIFF || true
if grep -q '47998' /tmp/isaac_udp_probe.txt 2>/dev/null; then
  echo "  [ok]   udp/47998 packets arrive at the VM — WebRTC media can flow"
else
  echo "  [FAIL] udp/47998 never arrived — the cloud firewall is dropping UDP."
  echo "         WebRTC video will stay black. Fix the security group, or move provider."
fi
echo
echo "Open: http://$HOST:8210"
