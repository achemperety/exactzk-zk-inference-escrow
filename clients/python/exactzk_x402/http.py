"""Serving a ProofGatedMiddleware over HTTP: the standard library's server, or any WSGI server."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXPOSE = "PAYMENT-REQUIRED, PAYMENT-RESPONSE"


def _answer(mw, url, raw, headers):
    try:
        body = json.loads(raw or b"{}")
        if not isinstance(body, dict):
            raise ValueError
    except ValueError:
        return 400, {"error": "the body must be a JSON object"}, {}
    try:
        return mw.handle(url, body, headers)
    except Exception as exc:  # an answer, not a dropped connection
        return 500, {"error": f"server error: {type(exc).__name__}"}, {}


def serve(mw, host="127.0.0.1", port=8402, path="/infer"):
    """Serve `path` until interrupted. Binds to localhost unless told otherwise."""

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            if self.path != path:
                return self.reply(404, {"error": "not found"}, {})
            raw = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
            url = f"http://{self.headers.get('Host')}{path}"
            self.reply(*_answer(mw, url, raw, dict(self.headers.items())))

        def reply(self, status, body, headers):
            data = json.dumps(body).encode()
            self.send_response(status)
            for k, v in {"Content-Type": "application/json", "Cache-Control": "no-store",
                         "Access-Control-Expose-Headers": EXPOSE, **headers, "Content-Length": str(len(data))}.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt, *args):
            pass

    ThreadingHTTPServer((host, port), Handler).serve_forever()


def wsgi_app(mw, path="/infer"):
    """A WSGI application for `path` (gunicorn, uwsgi, waitress, ...)."""

    def app(environ, start_response):
        if environ.get("REQUEST_METHOD") != "POST" or environ.get("PATH_INFO") != path:
            status, body, headers = 404, {"error": "not found"}, {}
        else:
            raw = environ["wsgi.input"].read(int(environ.get("CONTENT_LENGTH") or 0))
            headers = {k[5:].replace("_", "-"): v for k, v in environ.items() if k.startswith("HTTP_")}
            url = f"{environ.get('wsgi.url_scheme', 'http')}://{environ.get('HTTP_HOST', '')}{path}"
            status, body, headers = _answer(mw, url, raw, headers)
        data = json.dumps(body).encode()
        start_response(f"{status} {'OK' if status == 200 else 'Payment Required' if status == 402 else 'Error'}",
                       [("Content-Type", "application/json"), ("Access-Control-Expose-Headers", EXPOSE),
                        ("Content-Length", str(len(data))), *headers.items()])
        return [data]

    return app
