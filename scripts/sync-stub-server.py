#!/usr/bin/env python3
"""Local SyncClipboard-protocol stub for development and simctl regression.

Implements just enough of `docs/SYNC_PROTOCOL.md` §2.1 (`GET SyncClipboard.json`)
to drive the iOS client's read path and error mapping. Other endpoints land
in later cycles alongside the corresponding client features.

Usage:

    # 200 + a known clipboard JSON (default)
    scripts/sync-stub-server.py

    # 401 — exercise the authFailed branch
    STUB_MODE=401 scripts/sync-stub-server.py

    # 500 / 404 / arbitrary HTTP status
    STUB_MODE=500 scripts/sync-stub-server.py
    STUB_MODE=418 scripts/sync-stub-server.py     # any int → that status

    # Different port
    STUB_PORT=9000 scripts/sync-stub-server.py

The 200 payload is byte-identical to `docs/examples/clipboard_text_short.json`,
which is the normative fixture round-tripped by the model tests.

iOS simulator note — to point a configured server at this stub from prefs,
write the value as `Data` (SettingsStore reads `Data`, not `String`):

    SCL='{"configs":[{"id":"stub","url":"http://127.0.0.1:8033/",'\\
        '"username":"u","password":"p","autoSwitchWifiNames":[]}],'\\
        '"activeConfigId":"stub"}'
    HEX=$(printf '%s' "$SCL" | xxd -p | tr -d '\\n')
    xcrun simctl spawn booted defaults delete app.uniclipboard.UniClipboard server_config 2>/dev/null
    xcrun simctl spawn booted defaults write  app.uniclipboard.UniClipboard server_config_list -data "$HEX"
"""

import http.server
import json
import os
import sys

PORT = int(os.environ.get("STUB_PORT", "8033"))
MODE = os.environ.get("STUB_MODE", "ok").lower()

# Mirrors docs/examples/clipboard_text_short.json.
OK_PAYLOAD = {
    "type": "Text",
    "hash": "3F4E62D9F184380BAD1B0F94B5518DCBF35ACB79B34F6D6E34F3DAB16CD7BC8F",
    "text": "Hello, SyncClipboard!",
    "hasData": False,
    "size": 21,
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):  # quiet by default
        pass

    def do_GET(self):
        if MODE == "ok":
            body = json.dumps(OK_PAYLOAD).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if MODE.isdigit():
            self.send_response(int(MODE))
            self.end_headers()
            return

        self.send_response(404)
        self.end_headers()


def main():
    print(f"sync-stub-server listening 127.0.0.1:{PORT} mode={MODE}", flush=True)
    try:
        http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
