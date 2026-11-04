"""Tests for nxplay_control.py against a synthetic local server: endpoint-file checks, auth header, no proxy, no
redirects, MCP stdio framing, exit codes, and that the token never reaches stdout or stderr. Standard library only;
runs on Python 3.8+ (python3 -m unittest discover -s Control -p 'test_*.py')."""

import contextlib
import http.server
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nxplay_control as nc  # noqa: E402

TOKEN = "ab" * 32


class FakeNXPlay(http.server.BaseHTTPRequestHandler):
    """Answers like NX Play's control API, for the adapter's side only."""

    seen = []
    redirect = False

    def log_message(self, *args):
        pass

    def _send(self, status, body, headers=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        if data:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _record(self, body=b""):
        FakeNXPlay.seen.append({"method": self.command, "path": self.path, "headers": dict(self.headers), "body": body})

    def do_GET(self):
        self._record()
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self._send(401, {"ok": False, "error": {"code": "unauthorized", "message": "no"}})
        if FakeNXPlay.redirect:
            return self._send(302, {"ok": False}, {"Location": "http://example.invalid/steal"})
        if self.path.startswith("/v1/status"):
            return self._send(200, {"ok": True, "result": {"app": {"name": "NX Play"}}})
        if self.path.startswith("/v1/events"):
            return self._send(200, {"ok": True, "result": {"events": [], "next_after": 0}})
        return self._send(404, {"ok": False, "error": {"code": "not_found", "message": "no"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self._record(body)
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self._send(401, {"ok": False, "error": {"code": "unauthorized", "message": "A bearer token is needed"}})
        if self.path == "/v1/invoke":
            request = json.loads(body)
            if request["command"] == "fails":
                return self._send(422, {"ok": False, "error": {"code": "command_failed", "message": "no"}})
            return self._send(200, {"ok": True, "result": request})
        if self.path == "/mcp":
            message = json.loads(body)
            if "id" not in message:
                return self._send(202, None)
            if message["method"] == "initialize":
                return self._send(200, {"jsonrpc": "2.0", "id": message["id"], "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}}})
            if message["method"] == "tools/list":
                tools = [{"name": "nx_games_list"}, {"name": "nxapi_status"}]
                return self._send(200, {"jsonrpc": "2.0", "id": message["id"], "result": {"tools": tools}})
            return self._send(200, {"jsonrpc": "2.0", "id": message["id"], "result": {"echo": message["method"]}})
        return self._send(404, {"ok": False})


class AdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), FakeNXPlay)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        FakeNXPlay.seen = []
        FakeNXPlay.redirect = False
        self.dir = tempfile.mkdtemp(prefix="nxplay-control-test-")
        os.chmod(self.dir, 0o700)
        self.endpoint = os.path.join(self.dir, "endpoint.json")
        self.write_endpoint()

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def write_endpoint(self, mode=0o600, **changes):
        endpoint = {"schema": nc.SCHEMA, "url": "http://127.0.0.1:%d" % self.port, "port": self.port, "token": TOKEN, "pid": 1}
        endpoint.update(changes)
        if os.path.lexists(self.endpoint):
            os.unlink(self.endpoint)
        fd = os.open(self.endpoint, os.O_WRONLY | os.O_CREAT, 0o600)
        os.write(fd, json.dumps(endpoint).encode())
        os.close(fd)
        os.chmod(self.endpoint, mode)

    def run_main(self, argv, stdin=""):
        out, err = io.StringIO(), io.StringIO()
        old_in = sys.stdin
        sys.stdin = io.StringIO(stdin)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = nc.main(["--endpoint", self.endpoint] + argv)
        finally:
            sys.stdin = old_in
        self.assertNotIn(TOKEN, out.getvalue())
        self.assertNotIn(TOKEN, err.getvalue())
        return code, out.getvalue(), err.getvalue()

    # endpoint file

    def test_a_private_endpoint_is_read_and_the_token_sent_but_never_printed(self):
        code, out, _ = self.run_main(["status"])
        self.assertEqual(code, nc.EXIT_OK)
        self.assertEqual(json.loads(out)["result"]["app"]["name"], "NX Play")
        headers = FakeNXPlay.seen[-1]["headers"]
        self.assertEqual(headers["Authorization"], "Bearer " + TOKEN)
        self.assertEqual(headers["Host"], "127.0.0.1:%d" % self.port)
        self.assertNotIn("Origin", headers)

    def test_an_endpoint_others_can_read_is_refused(self):
        self.write_endpoint(mode=0o644)
        code, _, err = self.run_main(["status"])
        self.assertEqual(code, nc.EXIT_UNREACHABLE)
        self.assertIn("other users", err)
        self.assertEqual(FakeNXPlay.seen, [])

    def test_a_folder_others_can_write_is_refused(self):
        os.chmod(self.dir, 0o777)
        try:
            self.assertEqual(self.run_main(["status"])[0], nc.EXIT_UNREACHABLE)
        finally:
            os.chmod(self.dir, 0o700)

    def test_a_linked_endpoint_is_refused(self):
        real = os.path.join(self.dir, "real.json")
        os.rename(self.endpoint, real)
        os.symlink(real, self.endpoint)
        self.assertEqual(self.run_main(["status"])[0], nc.EXIT_UNREACHABLE)
        self.assertEqual(FakeNXPlay.seen, [])

    def test_an_endpoint_naming_another_host_is_refused(self):
        self.write_endpoint(url="http://192.168.1.20:%d" % self.port)
        self.assertEqual(self.run_main(["status"])[0], nc.EXIT_UNREACHABLE)
        self.write_endpoint(token="short")
        self.assertEqual(self.run_main(["status"])[0], nc.EXIT_UNREACHABLE)
        self.write_endpoint(schema="other/1")
        self.assertEqual(self.run_main(["status"])[0], nc.EXIT_UNREACHABLE)
        self.assertEqual(FakeNXPlay.seen, [])

    def test_no_endpoint_is_unreachable(self):
        os.unlink(self.endpoint)
        code, _, err = self.run_main(["status"])
        self.assertEqual(code, nc.EXIT_UNREACHABLE)
        self.assertIn("No endpoint file", err)

    def test_endpoint_reports_without_the_token(self):
        code, out, _ = self.run_main(["endpoint"])
        self.assertEqual(code, nc.EXIT_OK)
        info = json.loads(out)
        self.assertTrue(info["answers"])
        self.assertEqual(info["token"], "present (not shown)")

    # transport

    def test_no_proxy_and_no_redirect(self):
        os.environ["HTTP_PROXY"] = os.environ["http_proxy"] = "http://127.0.0.1:9"
        try:
            FakeNXPlay.redirect = True
            code, out, _ = self.run_main(["status"])
        finally:
            del os.environ["HTTP_PROXY"], os.environ["http_proxy"]
        # the 302 is reported as a failure, never followed
        self.assertEqual(code, nc.EXIT_FAILED)
        self.assertEqual(len(FakeNXPlay.seen), 1)
        self.assertEqual(FakeNXPlay.seen[0]["path"], "/v1/status")

    def test_call_builds_arguments_and_exit_codes(self):
        code, out, _ = self.run_main(["call", "games.get", '{"game": "A"}', "--arg", "select=true", "--arg", "note=plain"])
        self.assertEqual(code, nc.EXIT_OK)
        sent = json.loads(FakeNXPlay.seen[-1]["body"])
        self.assertEqual(sent["command"], "games.get")
        self.assertEqual(sent["args"], {"game": "A", "select": True, "note": "plain"})
        self.assertEqual(sent["wait"], "answer")
        self.assertEqual(FakeNXPlay.seen[-1]["headers"]["Content-Type"], "application/json")
        self.assertEqual(self.run_main(["call", "fails"])[0], nc.EXIT_FAILED)
        self.assertEqual(self.run_main(["call", "x", "[1]"])[0], nc.EXIT_USAGE)
        self.assertEqual(self.run_main(["call", "x", "--arg", "novalue"])[0], nc.EXIT_USAGE)
        self.assertEqual(self.run_main(["nonsense"])[0], nc.EXIT_USAGE)

    def test_enable_and_disable_write_only_the_switch(self):
        folder = os.path.join(self.dir, "switch")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(nc.main(["--dir", folder, "enable"]), nc.EXIT_OK)
        self.assertTrue(os.path.exists(os.path.join(folder, "enabled")))
        self.assertEqual(os.stat(folder).st_mode & 0o777, 0o700)
        with contextlib.redirect_stdout(out):
            self.assertEqual(nc.main(["--dir", folder, "disable"]), nc.EXIT_OK)
        self.assertFalse(os.path.exists(os.path.join(folder, "enabled")))

    # MCP over stdio

    def test_mcp_forwards_each_message_and_prints_only_protocol(self):
        lines = "\n".join([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
            "{broken",
            "",
        ]) + "\n"
        code, out, _ = self.run_main(["mcp"], stdin=lines)
        self.assertEqual(code, nc.EXIT_OK)
        answers = [json.loads(line) for line in out.splitlines()]
        self.assertEqual([a.get("id") for a in answers], [1, 2, None])
        self.assertEqual(answers[2]["error"]["code"], -32700)
        # the negotiated version goes along after initialize
        self.assertEqual(FakeNXPlay.seen[-1]["headers"].get("MCP-Protocol-Version"), "2025-06-18")
        self.assertNotIn("MCP-Protocol-Version", FakeNXPlay.seen[0]["headers"])

    def test_mcp_meta_shows_only_the_api_tools(self):
        line = json.dumps({"jsonrpc": "2.0", "id": 9, "method": "tools/list"}) + "\n"
        _, out, _ = self.run_main(["mcp", "--tools", "meta"], stdin=line)
        self.assertEqual([t["name"] for t in json.loads(out)["result"]["tools"]], ["nxapi_status"])

    def test_mcp_when_nx_play_is_away_answers_requests_with_an_error(self):
        os.unlink(self.endpoint)
        lines = json.dumps({"jsonrpc": "2.0", "id": 7, "method": "ping"}) + "\n" + json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"
        code, out, err = self.run_main(["mcp"], stdin=lines)
        self.assertEqual(code, nc.EXIT_OK)
        answers = [json.loads(line) for line in out.splitlines()]
        self.assertEqual(len(answers), 1)
        self.assertEqual(answers[0]["id"], 7)
        self.assertEqual(answers[0]["error"]["code"], -32000)
        self.assertIn("No endpoint file", err)

    def test_mcp_with_a_wrong_token_is_a_json_rpc_error(self):
        self.write_endpoint(token="cd" * 32)
        line = json.dumps({"jsonrpc": "2.0", "id": 3, "method": "ping"}) + "\n"
        out = io.StringIO()
        old_in = sys.stdin
        sys.stdin = io.StringIO(line)
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                nc.main(["--endpoint", self.endpoint, "mcp"])
        finally:
            sys.stdin = old_in
        answer = json.loads(out.getvalue())
        self.assertEqual(answer["id"], 3)
        self.assertEqual(answer["error"]["code"], -32000)
        self.assertNotIn("cd" * 32, out.getvalue())


if __name__ == "__main__":
    unittest.main()
