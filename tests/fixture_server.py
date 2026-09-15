#!/usr/bin/env python3
"""Fixture HTTP server for opencode-go-usage.sh tests.

Routes:
  GET /zen/go/v1/usage     usage API (401 unless Authorization: Bearer test-key)
  GET /workspace/<id>      dashboard HTML variants per workspace id
  GET|POST /_server?id=..  SolidStart server functions (workspaces / billing)
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

# Must match the constants in opencode-go-usage.sh.
WORKSPACES_ID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
BILLING_ID = "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"

USAGE = {
    "usage": {
        "rolling": {"status": "ok", "percent": 12, "resetsAt": "2026-09-14T20:00:00.000Z"},
        "weekly": {"status": "ok", "percent": 34, "resetsAt": "2026-09-21T00:00:00.000Z"},
        "monthly": {"status": "ok", "percent": 56, "resetsAt": "2026-10-01T00:00:00.000Z"},
    }
}

PAGE_WITH_BALANCE = (
    "<html><body><h1>Workspace</h1>"
    "<div>Current balance</div><span>$42.50</span></body></html>"
)
PAGE_PLAIN = "<html><body><h1>Workspace</h1><div>Usage overview</div></body></html>"
PAGE_LOGIN = "<html><body><h1>Sign in</h1><p>login to continue</p></body></html>"

BILLING_JSON = {"customerID": "cus_123", "balance": 4250000000}
BILLING_SERIALIZED = '$R[1]={customerID:$R[2]="cus_123",balance:$R[3]=4250000000};'
WORKSPACES = [{"id": "wrk_page", "name": "Test Workspace"}]


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, content_type="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _server(self, query):
        sid = query.get("id", [""])[0]
        if sid == WORKSPACES_ID:
            self._send(200, json.dumps(WORKSPACES))
        elif sid == BILLING_ID:
            args = query.get("args", [""])[0]
            if "wrk_serialized" in args:
                self._send(200, BILLING_SERIALIZED, "text/javascript")
            elif "wrk_billing" in args or "wrk_page" in args:
                self._send(200, json.dumps(BILLING_JSON))
            else:
                self._send(404, "{}")
        else:
            self._send(404, "{}")

    def do_GET(self):
        parsed = urlparse(self.path)
        path, query = parsed.path, parse_qs(parsed.query)

        if path == "/zen/go/v1/usage":
            if self.headers.get("Authorization") != "Bearer test-key":
                self._send(
                    401,
                    json.dumps(
                        {"type": "error", "error": {"type": "AuthError", "message": "Unauthorized"}}
                    ),
                )
            else:
                self._send(200, json.dumps(USAGE))
            return

        if path.startswith("/workspace/"):
            ws = path.rsplit("/", 1)[-1]
            if ws == "wrk_page":
                self._send(200, PAGE_WITH_BALANCE, "text/html")
            elif ws in ("wrk_billing", "wrk_serialized"):
                self._send(200, PAGE_PLAIN, "text/html")
            elif ws == "wrk_signedout":
                self._send(200, PAGE_LOGIN, "text/html")
            elif ws == "wrk_redirect":
                self.send_response(302)
                self.send_header("Location", "/auth")
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                self._send(404, "{}")
            return

        if path == "/_server":
            self._server(query)
            return

        self._send(404, "{}")

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/_server":
            self._server(parse_qs(parsed.query))
            return
        self._send(404, "{}")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
