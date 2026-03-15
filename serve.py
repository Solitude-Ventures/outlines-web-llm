#!/usr/bin/env python3
"""Dev server with cross-origin isolation headers required by SharedArrayBuffer / ONNX Runtime WASM threads."""
import http.server, functools, sys

class COIHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "credentialless")
        super().end_headers()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
with http.server.HTTPServer(("", port), functools.partial(COIHandler, directory=".")) as s:
    print(f"Serving on http://localhost:{port}  (cross-origin isolated)")
    s.serve_forever()
