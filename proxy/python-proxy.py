#!/usr/bin/env python3
"""
danmu_api 万能反代 —— Python 标准库版（零依赖，适合小盘 VPS）
=============================================================
和 cloudflare-worker.js / node-proxy.js 行为一致：
  GET /<SECRET>/https://target/path?query  →  取回并原样返回

适合 4–10 GB 小盘机器：不用 Docker、不用 Node，只要系统自带 python3。

用法：
  SECRET=my-long-secret PORT=8787 python3 python-proxy.py

环境变量：
  SECRET      必填，路径口令，不匹配一律 403
  PORT        默认 8787
  ALLOW_HOSTS 可选，逗号分隔白名单；空=允许所有（靠 SECRET 保护）
  UA          可选，覆盖 User-Agent
  TIMEOUT_MS  可选，默认 20000
"""

import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = (os.environ.get("SECRET") or "").strip()
PORT = int(os.environ.get("PORT") or 8787)
TIMEOUT = int(os.environ.get("TIMEOUT_MS") or 20000) / 1000.0
DEFAULT_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)
UA = os.environ.get("UA") or DEFAULT_UA
ALLOW_HOSTS = [h.strip().lower() for h in (os.environ.get("ALLOW_HOSTS") or "").split(",") if h.strip()]

if not SECRET:
    sys.stderr.write("[proxy] 必须设置 SECRET 环境变量\n")
    sys.exit(1)

PREFIX = "/" + SECRET + "/"
SKIP_REQ_HEADERS = {"host", "connection", "content-length", "accept-encoding", "transfer-encoding"}
SKIP_RES_HEADERS = {"transfer-encoding", "connection", "content-length", "keep-alive"}


def _urlopen(req):
    """先按标准校验证书；若目标站点证书链有问题（例如 rrsp.com.cn），
    退化为不校验证书重试一次——这些是中国弹幕源的公共接口，用自签/错配证书很常见。"""
    try:
        return urllib.request.urlopen(req, timeout=TIMEOUT)
    except urllib.error.URLError as e:
        reason = getattr(e, "reason", None)
        text = str(reason) + str(e)
        if isinstance(reason, ssl.SSLError) or "CERTIFICATE_VERIFY_FAILED" in text or "certificate verify failed" in text:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))
            sys.stderr.write("[proxy] TLS verify failed, retrying insecure: %s\n" % req.full_url)
            return opener.open(req, timeout=TIMEOUT)
        raise


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "danmu-proxy/1.0"

    def log_message(self, format, *args):  # noqa: A002 - 覆盖标准库签名
        sys.stderr.write("[proxy] %s - %s\n" % (self.address_string(), format % args))

    # ---------- helpers ----------
    def _json(self, status, obj):
        import json

        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _host_allowed(self, host):
        if not ALLOW_HOSTS:
            return True
        host = (host or "").lower()
        return any(host == a or host.endswith("." + a) for a in ALLOW_HOSTS)

    # ---------- verb handlers ----------
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,PATCH,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._proxy()

    def do_HEAD(self):
        self._proxy()

    def do_POST(self):
        self._proxy()

    def do_PUT(self):
        self._proxy()

    def do_PATCH(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def _proxy(self):
        raw_path = self.path
        if not raw_path.startswith(PREFIX):
            if raw_path in ("/", ""):
                return self._json(200, {"ok": True, "usage": "/{SECRET}/https://target/path"})
            return self._json(403, {"error": "forbidden"})

        target = raw_path[len(PREFIX):]
        if not target.lower().startswith(("http://", "https://")):
            return self._json(400, {"error": "only absolute http(s) target in path"})

        parsed = urllib.parse.urlsplit(target)
        if not self._host_allowed(parsed.hostname):
            return self._json(403, {"error": "host not allowed: %s" % parsed.hostname})

        body = None
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > 0:
            body = self.rfile.read(length)

        headers = {
            k: v for k, v in self.headers.items() if k.lower() not in SKIP_REQ_HEADERS
        }
        headers.setdefault("User-Agent", UA)
        headers.setdefault("Referer", "%s://%s/" % (parsed.scheme, parsed.netloc))

        req = urllib.request.Request(target, data=body, headers=headers, method=self.command)

        try:
            with _urlopen(req) as resp:
                payload = resp.read()
                status = resp.status
                res_headers = resp.headers
        except urllib.error.HTTPError as e:
            payload = e.read()
            status = e.code
            res_headers = e.headers
        except Exception as e:  # noqa: BLE001 - 网络错误统一回报
            return self._json(502, {"error": "%s: %s" % (type(e).__name__, e), "target": target})

        self.send_response(status)
        for k, v in res_headers.items():
            if k.lower() in SKIP_RES_HEADERS:
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("X-Proxy-Target", parsed.hostname or "")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print("[proxy] listening on :%d  prefix /%s/  hosts=%s"
          % (PORT, SECRET, ",".join(ALLOW_HOSTS) if ALLOW_HOSTS else "(all)"))
    handler = getattr(server, "serve_forever", None)
    if handler:
        handler()


if __name__ == "__main__":
    main()
