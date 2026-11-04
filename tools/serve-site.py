"""Read-only loopback server for the generated local site (stdlib only)."""

import argparse
import hashlib
import json
import mimetypes
from pathlib import Path
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parent.parent
SERVICE = "github-daily-picks-local-site-v1"
ROOT_SHA256 = hashlib.sha256(
    ROOT.as_posix().rstrip("/").lower().encode("utf-8")
).hexdigest()
ASSET_SUFFIXES = frozenset(
    ".css .js .png .jpg .jpeg .gif .svg .webp .avif .ico .bmp "
    ".woff .woff2 .ttf .otf .eot .mp4 .webm .mp3 .wav .ogg".split()
)
PAGE_SUFFIXES = frozenset({".html", ".js", ".css"})


def public_file(request_target):
    """Resolve a URL only if its final target remains in a public subtree."""
    try:
        target = urlsplit(request_target)
        if target.scheme or target.netloc or re.search(r"%(?![0-9a-fA-F]{2})", target.path):
            return None
        path = unquote(target.path, errors="strict")
        if not path.startswith("/") or "\\" in path or ":" in path or any(ord(c) < 32 for c in path):
            return None
        parts = path.lstrip("/").split("/")
        if any(part in {".", ".."} or part.startswith(".") for part in parts):
            return None
        if path == "/":
            parts = ["index.html"]
        if parts in (["index.html"], ["overview.html"]):
            expected = ROOT / parts[0]
            resolved = expected.resolve(strict=True)
            if resolved != expected:
                return None
        else:
            if parts[0] == "assets":
                boundary = ROOT / "assets"
                suffixes = ASSET_SUFFIXES
            elif parts[:2] == ["data", "site"]:
                boundary = ROOT / "data" / "site"
                suffixes = PAGE_SUFFIXES
            else:
                return None
            candidate = ROOT.joinpath(*parts)
            if candidate.suffix.lower() not in suffixes:
                return None
            resolved = candidate.resolve(strict=True)
            # Compare to the literal allowed subtree, not its resolved symlink.
            # This also rejects a replaced assets/site directory pointing elsewhere.
            if not resolved.is_relative_to(boundary):
                return None
        return resolved if resolved.is_file() else None
    except (OSError, ValueError, UnicodeError, RuntimeError):
        return None


class SiteHandler(BaseHTTPRequestHandler):
    server_version = "DailyLocalSite/1"
    sys_version = ""

    def log_message(self, format, *args):
        # No access log containing user filenames or query strings.
        pass

    def do_GET(self):
        self._serve(head=False)

    def do_HEAD(self):
        self._serve(head=True)

    def _serve(self, head):
        if self.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        if self.path == "/__daily_site_health":
            body = json.dumps(
                {"service": SERVICE, "root_sha256": ROOT_SHA256},
                separators=(",", ":"),
            ).encode("utf-8")
            self._reply(body, "application/json; charset=utf-8", head)
            return
        path = public_file(self.path)
        if path is None:
            self.send_error(404, "Not found")
            return
        try:
            body = path.read_bytes()
        except OSError:
            self.send_error(404, "Not found")
            return
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        if path.suffix.lower() in PAGE_SUFFIXES | {".svg"}:
            content_type += "; charset=utf-8"
        self._reply(body, content_type, head)

    def _reply(self, body, content_type, head):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if not head:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def _reject_write(self):
        self.send_response(405)
        self.send_header("Allow", "GET, HEAD")
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_POST = do_PUT = do_PATCH = do_DELETE = _reject_write
    do_OPTIONS = do_CONNECT = do_TRACE = _reject_write


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8788)
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("port must be between 0 and 65535")
    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), SiteHandler)
    except OSError:
        parser.exit(1, "Cannot bind local site port; check whether it is already in use.\n")
    with server:
        print(json.dumps({"service": SERVICE, "root_sha256": ROOT_SHA256,
                          "url": f"http://127.0.0.1:{server.server_port}/"}), flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
