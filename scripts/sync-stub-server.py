#!/usr/bin/env python3
"""Local SyncClipboard-protocol stub for development and simctl regression.

Implements enough of `docs/SYNC_PROTOCOL.md` to drive the iOS client's
read paths:

- §2.1 `GET SyncClipboard.json` — current clipboard JSON
- §2.7 `POST /api/history/query` — paginated history (returns one page,
  then an empty page to signal end-of-list)
- §2.11 `GET /api/history/<id>/data` — record payload bytes (synthetic;
  matches the hash advertised in §2.7 so client-side §4.2 verify passes
  for `photo_2026.png`, mock bytes for other ids)

Other endpoints land in later cycles alongside the corresponding client
features.

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

import datetime
import hashlib
import http.server
import json
import os
import sys

PORT = int(os.environ.get("STUB_PORT", "8033"))
MODE = os.environ.get("STUB_MODE", "ok").lower()


def _iso(delta_seconds: float) -> str:
    """ISO-8601 fractional-Z timestamp `<now> + delta_seconds`."""
    when = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
        seconds=delta_seconds
    )
    # Match the iOS client's expected fractional-seconds shape.
    return when.strftime("%Y-%m-%dT%H:%M:%S.") + f"{when.microsecond // 1000:03d}Z"


def _file_hash(name: str, body: bytes) -> str:
    """§4.2 — SHA256(basename + '|' + SHA256(bytes).hex.upper).hex.upper."""
    content = hashlib.sha256(body).hexdigest().upper()
    combined = f"{name}|{content}".encode("utf-8")
    return hashlib.sha256(combined).hexdigest().upper()


def _stub_payload(name: str, size: int) -> bytes:
    """Deterministic per-name byte stream of the requested length. Real
    PNGs/PDFs aren't needed — we just want a stable blob whose §4.2 hash
    can be computed up front and advertised on the §2.7 record so the
    iOS client's hash-verify path passes end-to-end."""
    seed = (name.encode("utf-8") + b"\x00") * (size // (len(name) + 1) + 1)
    return seed[:size]


# Live clipboard (§2.1) payload — also mirrored in docs/examples/clipboard_text_short.json
OK_PAYLOAD = {
    "type": "Text",
    "hash": "3F4E62D9F184380BAD1B0F94B5518DCBF35ACB79B34F6D6E34F3DAB16CD7BC8F",
    "text": "Hello, SyncClipboard!",
    "hasData": False,
    "size": 21,
}

# Stub byte payloads + their §4.2 hashes, used for §2.11. The hashes are
# computed at import time so the §2.7 records advertise them consistently
# and the iOS client's verify step passes for each `保存` action.
_PHOTO_NAME = "photo_2026.png"
_PHOTO_BODY = _stub_payload(_PHOTO_NAME, 184_320)
_PHOTO_HASH = _file_hash(_PHOTO_NAME, _PHOTO_BODY)

_REPORT_NAME = "report.pdf"
_REPORT_BODY = _stub_payload(_REPORT_NAME, 1_048_576)
_REPORT_HASH = _file_hash(_REPORT_NAME, _REPORT_BODY)

# profileId → bytes lookup for §2.11. Keyed by `<type>-<hash>` (composite).
_HISTORY_PAYLOADS: dict[str, bytes] = {
    f"Image-{_PHOTO_HASH}":  _PHOTO_BODY,
    f"File-{_REPORT_HASH}":  _REPORT_BODY,
}


def _history_page():
    """Three sample HistoryRecords covering text / image / file types
    across today / yesterday / earlier. Hashes are stable per process so
    the dedup paths in the iOS client behave predictably across pulls,
    and image/file records advertise hashes the iOS client can actually
    verify against the bytes returned by §2.11."""
    return [
        {
            "hash": OK_PAYLOAD["hash"],
            "type": "Text",
            "text": OK_PAYLOAD["text"],
            "hasData": False,
            "size": OK_PAYLOAD["size"],
            "createTime": _iso(-60),                  # 1 min ago
            "lastModified": _iso(-60),
            "starred": False,
            "pinned": False,
            "version": 0,
            "isDeleted": False,
        },
        {
            "hash": _PHOTO_HASH,
            "type": "Image",
            "text": _PHOTO_NAME,
            "hasData": True,
            "size": len(_PHOTO_BODY),
            "createTime": _iso(-26 * 3600),           # ~1 day ago
            "lastModified": _iso(-26 * 3600),
            "starred": False,
            "pinned": False,
            "version": 0,
            "isDeleted": False,
        },
        {
            "hash": _REPORT_HASH,
            "type": "File",
            "text": _REPORT_NAME,
            "hasData": True,
            "size": len(_REPORT_BODY),
            "createTime": _iso(-3 * 86400),           # 3 days ago
            "lastModified": _iso(-3 * 86400),
            "starred": False,
            "pinned": False,
            "version": 0,
            "isDeleted": False,
        },
    ]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args, **kwargs):  # quiet by default
        pass

    # --- §2.1 GET SyncClipboard.json

    def do_GET(self):
        # §2.11 GET /api/history/<id>/data — record's payload bytes.
        # Path form: /api/history/<type>-<hash>/data
        if self.path.startswith("/api/history/") and self.path.endswith("/data"):
            profile_id = self.path[len("/api/history/"):-len("/data")]
            if MODE.isdigit():
                self.send_response(int(MODE))
                self.end_headers()
                return
            body = _HISTORY_PAYLOADS.get(profile_id)
            if body is None:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # §2.1 GET SyncClipboard.json — current clipboard
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

    # --- §2.7 POST /api/history/query

    def do_POST(self):
        if self.path != "/api/history/query":
            self.send_response(404)
            self.end_headers()
            return

        if MODE.isdigit():
            # Same blanket-error mode as GETs — useful for exercising
            # the client's best-effort fallback on history-API failures.
            self.send_response(int(MODE))
            self.end_headers()
            return

        # Read + discard the multipart body. We don't bother parsing the
        # `page` / `modifiedAfter` filters; the iOS client paginates
        # until an empty page, so a deterministic "page 1 = three
        # records, page 2 = []" works for end-to-end UI seeding.
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b""

        # Crude "is this page 1?" check: look for `name="page"\r\n\r\n1`
        # in the multipart body. Default to page 1 if `page` is missing
        # (matches the spec — omitted page starts at the head).
        is_page_one = (b'name="page"\r\n\r\n1\r\n' in raw) or (b'name="page"' not in raw)

        body = json.dumps(_history_page() if is_page_one else []).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    print(
        f"sync-stub-server listening 127.0.0.1:{PORT} mode={MODE} "
        f"(§2.1 + §2.7 + §2.11)",
        flush=True,
    )
    try:
        http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
