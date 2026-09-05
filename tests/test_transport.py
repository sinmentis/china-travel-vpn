from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TransportTests(unittest.TestCase):
    def test_retry_does_not_mix_error_body_into_successful_json(self):
        class Handler(BaseHTTPRequestHandler):
            requests = 0

            def log_message(self, *_arguments):
                pass

            def do_GET(self):
                Handler.requests += 1
                status = 503 if Handler.requests == 1 else 200
                body = b"<html>retry later</html>" if status == 503 else b'{"account":{"balance":-10,"pending_charges":0}}'
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = HTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            with tempfile.TemporaryDirectory(prefix="vultr-transport-test-") as home:
                result = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c",
                     'source "$1"; API="$2"; VULTR_API_KEY=fixture; api_get /account',
                     "transport-test", str(ROOT / "scripts/lib/vultr.sh"),
                     f"http://127.0.0.1:{server.server_port}/v2"],
                    env={"PATH": os.environ["PATH"], "HOME": home},
                    capture_output=True, text=True, timeout=10,
                )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["account"]["balance"], -10)
            self.assertEqual(Handler.requests, 2)
        finally:
            server.shutdown()
            worker.join(timeout=5)
            server.server_close()


if __name__ == "__main__":
    unittest.main()
