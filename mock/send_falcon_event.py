#!/usr/bin/env python3
"""
send_falcon_event.py - plays the role of "Falcon detects it, Fusion fires the webhook".
SIMULATED: this is not CrowdStrike. It does two things, in order:
  1. registers an open finding with mock_falcon.py (so the mock status page shows it as OPEN)
  2. POSTs the same JSON a Fusion SOAR webhook action would send to your Event-Driven Ansible endpoint

Examples
  python3 send_falcon_event.py --host WS-0142 --cve DEMO-CVE-0001 \
      --mock-url http://<aap-private-ip>:9080 --eda-url <Event Stream URL> \
      --header "Authorization: <token>" --insecure

  # Token Event Stream credentials expect the token as-is (no "Bearer").
  # --insecure skips TLS verification for AAP's self-signed certificate.
"""
import argparse, json, ssl, sys, time, urllib.request, urllib.error

def post(url, body, headers=None, insecure=False):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **(headers or {})})
    ctx = ssl._create_unverified_context() if insecure else None
    with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
        return r.status

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True, help="Windows hostname as named in the AAP inventory, e.g. WS-0142")
    ap.add_argument("--cve", default="DEMO-CVE-0001", help="simulated vulnerability id (not a real CVE)")
    ap.add_argument("--app", default="Notepad++")
    ap.add_argument("--severity", default="HIGH")
    ap.add_argument("--mock-url", required=True, help="base URL of mock_falcon.py")
    ap.add_argument("--eda-url", required=True, help="Event-Driven Ansible webhook / Event Stream URL")
    ap.add_argument("--header", action="append", default=[], help='extra header, e.g. "Authorization: Bearer abc"')
    ap.add_argument("--insecure", action="store_true", help="skip TLS verification for the EDA URL (lab, self-signed cert)")
    a = ap.parse_args()

    headers = {}
    for h in a.header:
        k, v = h.split(":", 1)
        headers[k.strip()] = v.strip()

    print("=" * 62)
    print(" FALCON EVENT (SIMULATED)")
    print(f" {time.strftime('%H:%M:%S')}  {a.severity} finding: {a.cve} on {a.host} ({a.app})")
    print("=" * 62)
    try:
        post(a.mock_url.rstrip("/") + "/mock/findings", {"hostname": a.host, "cve": a.cve, "app": a.app})
        print("[1/2] finding registered in mock Falcon: OPEN")
        payload = {"severity": a.severity, "app": a.app, "cve": a.cve, "hostname": a.host}
        status = post(a.eda_url, payload, headers, a.insecure)
        print(f"[2/2] webhook delivered to Event-Driven Ansible: HTTP {status}")
        print("      payload:", json.dumps(payload))
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP error {e.code}: {e.read().decode(errors='replace')[:300]}")
    except Exception as e:
        sys.exit(f"Failed: {e}")

if __name__ == "__main__":
    main()
