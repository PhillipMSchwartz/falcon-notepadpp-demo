#!/usr/bin/env python3
"""
mock_falcon.py - a labeled stand-in for the Falcon pieces this demo needs.
THIS IS NOT CROWDSTRIKE. Say so on camera: "Falcon is simulated in this lab."

What it fakes (response shapes are approximated from the real API):
  POST /oauth2/token                           fake bearer token (HTTP 201)
  GET  /spotlight/combined/vulnerabilities/v1  returns the finding as open for a registered host
                                               until it has been polled --close-after times, then closed
  POST /mock/findings   {"hostname","cve","app"}  registers an open finding (send_falcon_event.py does this)
  GET|POST /mock/reset                         clears all findings (re-arm between takes)
  GET  /                                       status page (auto-refreshes) showing findings Open -> Closed

Limitation: it closes after N polls; it does not check the endpoint. The Notepad++ update
on the Windows host is real; only the Falcon status is simulated.

Run:  python3 mock_falcon.py --port 8080 --close-after 3
"""
import argparse, html, json, re, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

findings = {}   # hostname -> dict
args = None

def now():
    return time.strftime("%H:%M:%S")

def banner(msg):
    print(f"[MOCK FALCON {now()}] {msg}", flush=True)

PAGE = """<!doctype html><html><head><meta charset=utf-8><meta http-equiv=refresh content=2>
<title>MOCK Falcon (stand-in)</title><style>
body{{background:#0c111a;color:#e6e9ef;font:15px system-ui,sans-serif;margin:0}}
.top{{background:#7a1010;padding:10px 18px;font-weight:700;letter-spacing:.03em}}
.wrap{{padding:18px}}table{{border-collapse:collapse;width:100%}}th,td{{text-align:left;padding:9px 10px;border-bottom:1px solid #26314a}}
th{{color:#8e98aa;font-weight:500}}.o{{color:#ff8a8a;font-weight:700}}.c{{color:#3ddc84;font-weight:700}}a{{color:#7ab8ff}}
</style></head><body><div class=top>MOCK FALCON: simulated stand-in for demonstration, not CrowdStrike</div>
<div class=wrap><h2>Vulnerability findings (simulated)</h2>
<table><tr><th>Host</th><th>Vulnerability (simulated id)</th><th>Application</th><th>Status</th><th>Detected</th><th>Closed</th><th>Polls</th></tr>{rows}</table>
<p><a href="/mock/reset">Reset all findings</a></p></div></body></html>"""

class Handler(BaseHTTPRequestHandler):
    def _json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _html(self, text):
        data = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        path = urlparse(self.path).path
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        if path == "/oauth2/token":
            banner("token issued (fake)")
            return self._json(201, {"access_token": "mock-token", "token_type": "bearer", "expires_in": 1799})
        if path == "/mock/findings":
            try:
                body = json.loads(raw or b"{}")
                host, cve = body["hostname"], body.get("cve", "CVE-UNKNOWN")
                app = body.get("app", "Notepad++")
            except Exception:
                return self._json(400, {"error": "need JSON with hostname"})
            findings[host] = {"cve": cve, "app": app, "status": "open", "polls": 0, "detected": now(), "closed": ""}
            banner(f"finding registered: {host} {cve} ({app}) OPEN")
            return self._json(200, {"registered": host})
        if path == "/mock/reset":
            findings.clear(); banner("reset")
            return self._json(200, {"reset": True})
        self._json(404, {"errors": [{"message": "not found"}]})

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            rows = "".join(
                f"<tr><td>{html.escape(h)}</td><td>{html.escape(f['cve'])}</td><td>{html.escape(f['app'])}</td>"
                f"<td class={'o' if f['status']=='open' else 'c'}>{f['status'].upper()}</td>"
                f"<td>{f['detected']}</td><td>{f['closed']}</td><td>{f['polls']}</td></tr>"
                for h, f in findings.items()) or "<tr><td colspan=7>No findings yet</td></tr>"
            return self._html(PAGE.format(rows=rows))
        if u.path == "/mock/reset":
            findings.clear(); banner("reset")
            self.send_response(302); self.send_header("Location", "/"); self.end_headers(); return
        if u.path == "/spotlight/combined/vulnerabilities/v1":
            flt = parse_qs(u.query).get("filter", [""])[0]
            m = re.search(r"host_info\.hostname:'([^']+)'", flt)
            host = m.group(1) if m else "unknown"
            f = findings.get(host)
            if f and f["status"] == "open":
                f["polls"] += 1
                if f["polls"] >= args.close_after:
                    f["status"], f["closed"] = "closed", now()
            is_open = bool(f and f["status"] == "open")
            banner(f"poll host={host} -> {'OPEN' if is_open else 'CLOSED / not found'}")
            res = [{"id": f"mock_{host}", "status": "open", "cve": {"id": f["cve"]},
                    "host_info": {"hostname": host}}] if is_open else []
            return self._json(200, {"meta": {"pagination": {"total": len(res)}}, "resources": res, "errors": []})
        self._json(404, {"errors": [{"message": "not found"}]})

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--close-after", type=int, default=3, help="polls before a finding shows closed")
    args = ap.parse_args()
    banner(f"listening on 0.0.0.0:{args.port}; findings close after {args.close_after} polls")
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
