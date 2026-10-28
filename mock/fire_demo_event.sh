#!/usr/bin/env bash
# fire_demo_event.sh - sends the simulated Falcon event with no long command to type on camera.
#
# Reads settings from /etc/falcon-demo.env (EDA_URL, MOCK_URL) and the Event Stream token from
# ~/.falcon-demo-token, which you create yourself:
#   umask 077; printf '%s' 'YOUR_TOKEN' > ~/.falcon-demo-token
#
# Usage: fire_demo_event.sh [hostname]     (default WS-0142)
set -euo pipefail

[ -r /etc/falcon-demo.env ] && . /etc/falcon-demo.env
TOKEN_FILE="${FALCON_DEMO_TOKEN_FILE:-$HOME/.falcon-demo-token}"
: "${EDA_URL:?set EDA_URL in /etc/falcon-demo.env}"
: "${MOCK_URL:?set MOCK_URL in /etc/falcon-demo.env}"
[ -r "$TOKEN_FILE" ] || { echo "Missing $TOKEN_FILE (see the header of this script)" >&2; exit 1; }

exec python3 -B /opt/mock-falcon/send_falcon_event.py \
  --host "${1:-WS-0142}" --cve DEMO-CVE-0001 \
  --mock-url "$MOCK_URL" --eda-url "$EDA_URL" \
  --header "Authorization: $(tr -d '\r\n' < "$TOKEN_FILE")" --insecure
