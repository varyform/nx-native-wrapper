"""nxplay-remote against a stand-in for NX Play's server: the routes, pairing check and answers of
Packages/NXPlayKit/Sources/NXPlayKit/Library+Remote.swift and Model/RemoteHTTP.swift, with made-up games and devices.
Everything listens on 127.0.0.1 only. Run: python3 -m unittest discover -s Linux -v"""

import contextlib
import io
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nxplay_remote as remote  # noqa: E402

CODE = "abcd-efgh-jkmn"
PHONE = "00008150-001A2B3C4D5E6F70"
SOON = (datetime.now(timezone.utc) + timedelta(hours=20)).strftime("%Y-%m-%dT%H:%M:%SZ")


def game(folder, name, title, state="ready", kept=False, can=True, job=None, expires=None):
    return {
        "id": folder, "name": name, "titleID": title, "version": "1.0.0", "state": state, "kept": kept,
        "canInstall": can, "hasIcon": False, "job": job, "expires": expires,
    }


def job(status, fraction=0.0, text="", device=PHONE, kind="install", lines=None, code=None):
    return {
        "kind": kind, "device": device if kind == "install" else None, "status": status, "exitCode": code,
        "fraction": fraction, "text": text, "lastLines": lines or [],
    }


class FakeMac:
    """NX Play's server as far as the client sees it. `installs` scripts what /v1/games shows after each poll."""

    def __init__(self):
        self.requests = []
        self.code = CODE
        self.games = [
            game("Animal Well [NSP]", "ANIMAL WELL", "010020D01AD24000"),
            game("Celeste", "Celeste", "01002B30028F6000", expires=SOON),
            game("Dread", "Metroid Dread", "010093801237C000", kept=True, can=False),
            game("Loose", "Loose Files", "0100000000001000", state="notExtracted", can=False),
            game("Balatro", "Balatro", "0100CD801CE5E000",
                 job=job("failed", kind="ipa", lines=["error: no signing team"], code=65)),
        ]
        self.devices = [{"id": PHONE, "name": "Jess's iPhone", "model": "iPhone 18 Pro", "os": "27.1"}]
        self.apps = {
            "apps": [{"bundleID": "org.nxnative.01002B30028F6000", "titleID": "01002B30028F6000", "version": "1.4"}],
            "removed": ["010020D01AD24000"],
        }
        self.installs = []  # jobs the game shows, one per poll after the install starts
        self.install_answer = None  # (status, body) to answer the install with instead
        self.raw = None  # (status, headers, body) to answer every request with
        self.delay = 0
        mac = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.answer()

            def do_POST(self):
                self.answer()

            def answer(self):
                mac.requests.append((self.command, self.path, dict(self.headers)))
                if mac.delay:
                    time.sleep(mac.delay)
                if mac.raw:
                    status, headers, body = mac.raw
                    self.send(status, body, headers)
                    return
                status, value = mac.respond(self.command, self.path, self.headers.get("Authorization"))
                self.send(status, json.dumps(value, sort_keys=True).encode())

            def send(self, status, body, headers=None):
                self.send_response(status)
                for key, value in (headers or {"Content-Type": "application/json"}).items():
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, args=(0.05,), daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def respond(self, method, raw, authorization):
        # RemoteRequest.parse: URLComponents' path is percent-decoded, then split on "/" without empty parts
        url = urllib.parse.urlsplit(raw)
        path = [part for part in urllib.parse.unquote(url.path).split("/") if part]
        query = dict(urllib.parse.parse_qsl(url.query))
        if authorization != f"Bearer {self.code}":
            return 401, {"error": "Wrong pairing code: see NX Play › Settings › Devices on the Mac"}
        if (method, path) == ("GET", ["v1", "info"]):
            return 200, {"name": "Studio Mac", "version": "1.9.0", "team": {"name": "Jess Test", "free": True}}
        if (method, path) == ("GET", ["v1", "games"]):
            if self.installs and any(g["job"] and g["job"]["kind"] == "install" for g in self.games):
                self.by_id("Animal Well [NSP]")["job"] = self.installs.pop(0)
            return 200, self.games
        if (method, path) == ("GET", ["v1", "devices"]):
            return 200, self.devices
        if method == "GET" and len(path) == 4 and path[:2] == ["v1", "devices"] and path[3] == "apps":
            if path[2] != PHONE:
                return 404, {"error": "No such device"}
            return 200, self.apps
        if method == "POST" and len(path) == 4 and path[:2] == ["v1", "games"] and path[3] == "install":
            if self.install_answer:
                return self.install_answer
            found = self.by_id(path[2])
            if not found:
                return 404, {"error": f"No game {path[2]}"}
            if query.get("device") != PHONE:
                return 400, {"error": "The Mac can't reach that device: pair it with Xcode, with Connect via network on"}
            found["job"] = job("queued", text="Queued")
            return 202, found["job"]
        return 404, {"error": f"No such API: {method} /{'/'.join(path)}"}

    def by_id(self, folder):
        return next((g for g in self.games if g["id"] == folder), None)


class Case(unittest.TestCase):
    def setUp(self):
        self.mac = FakeMac()
        self.addCleanup(self.mac.close)
        self.home = tempfile.mkdtemp()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", self.home]))
        self.config = os.path.join(self.home, "config", "nxplay", "remote.json")
        patch = mock.patch.dict(os.environ, {"NXPLAY_REMOTE_CONFIG": self.config})
        patch.start()
        self.addCleanup(patch.stop)
        os.environ.pop("NXPLAY_CODE", None)

    def run_cli(self, *argv, sleep=None):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err):
            if sleep is not None:
                with mock.patch.object(remote.time, "sleep", sleep):
                    code = remote.main(list(argv), out=out)
            else:
                code = remote.main(list(argv), out=out)
        return code, out.getvalue(), err.getvalue()

    def pair(self, device=True):
        code, out, err = self.run_cli("--timeout", "5", "pair", f"127.0.0.1:{self.mac.port}", CODE)
        self.assertEqual(code, 0, err)
        if device:
            self.assertEqual(self.run_cli("use-device", "Jess's iPhone")[0], 0)
        self.mac.requests.clear()
        return out


class PairingTests(Case):
    def test_pairing_saves_the_code_for_this_user_only(self):
        out = self.pair(device=False)
        self.assertIn("Paired with Studio Mac", out)
        self.assertIn("Personal Team", out)
        self.assertIn("use-device", out)
        self.assertNotIn(CODE, out)
        if os.name == "posix":
            self.assertEqual(stat.S_IMODE(os.stat(self.config).st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.config)).st_mode), 0o700)
        with open(self.config) as file:
            saved = json.load(file)
        self.assertEqual((saved["host"], saved["port"], saved["token"]), ("127.0.0.1", self.mac.port, CODE))

    def test_a_wrong_code_is_refused_and_nothing_is_saved(self):
        code, out, err = self.run_cli("pair", f"127.0.0.1:{self.mac.port}", "zzzz-zzzz-zzzz")
        self.assertEqual(code, remote.EXIT_AUTH)
        self.assertIn("Wrong pairing code", err)
        self.assertIn("nxplay-remote pair", err)
        self.assertNotIn("zzzz-zzzz-zzzz", err + out)
        self.assertFalse(os.path.exists(self.config))

    def test_a_renewed_code_on_the_mac_locks_this_client_out(self):
        self.pair()
        self.mac.code = "pppp-qqqq-rrrr"
        code, _, err = self.run_cli("games")
        self.assertEqual(code, remote.EXIT_AUTH)
        self.assertIn("renewed", err)

    def test_a_code_that_could_end_the_header_never_leaves(self):
        code, _, err = self.run_cli("pair", f"127.0.0.1:{self.mac.port}", "abcd\r\nX-Evil: 1")
        self.assertEqual(code, remote.EXIT_USAGE)
        self.assertEqual(self.mac.requests, [])

    def test_uppercase_codes_are_typed_codes(self):
        self.assertEqual(remote.check_code(" ABCD-EFGH-JKMN "), CODE)
        self.assertEqual(remote.check_code("Custom-Token"), "Custom-Token")

    def test_the_saved_code_only_goes_to_its_mac(self):
        self.pair()
        other = FakeMac()
        self.addCleanup(other.close)
        code, _, err = self.run_cli("--host", f"127.0.0.1:{other.port}", "games")
        self.assertEqual(code, remote.EXIT_USAGE)
        self.assertIn("NXPLAY_CODE", err)
        self.assertEqual(other.requests, [])
        # the same Mac named again keeps it
        self.assertEqual(self.run_cli("--host", f"127.0.0.1:{self.mac.port}", "info")[0], 0)

    def test_a_readable_settings_file_is_flagged(self):
        if os.name != "posix":
            self.skipTest("POSIX permissions")
        self.pair()
        os.chmod(self.config, 0o644)
        _, _, err = self.run_cli("info")
        self.assertIn("chmod 600", err)

    def test_unpair_forgets(self):
        self.pair()
        self.assertEqual(self.run_cli("unpair")[0], 0)
        code, _, err = self.run_cli("games")
        self.assertEqual(code, remote.EXIT_USAGE)
        self.assertIn("Not paired", err)


class AddressTests(unittest.TestCase):
    def test_addresses(self):
        self.assertEqual(remote.parse_address("mac.local"), ("mac.local", 47474))
        self.assertEqual(remote.parse_address("mac.local:5000"), ("mac.local", 5000))
        self.assertEqual(remote.parse_address("10.0.0.2", 81), ("10.0.0.2", 81))
        self.assertEqual(remote.parse_address("[fe80::1]:47474"), ("fe80::1", 47474))
        self.assertEqual(remote.parse_address("fe80::1"), ("fe80::1", 47474))
        for bad in ("http://mac.local", "mac.local/v1", "user@mac", "mac.local:0", "mac.local:x", "", "a b",
                    "[fe80::1", "mac?x"):
            with self.assertRaises(remote.Failure, msg=bad):
                remote.parse_address(bad)


class LibraryTests(Case):
    def test_games_show_mac_build_and_device_state(self):
        self.pair()
        code, out, err = self.run_cli("games")
        self.assertEqual(code, 0, err)
        lines = {line.split("  ")[0]: line for line in out.splitlines()}
        self.assertIn("On Jess's iPhone · Expires today", lines["Celeste"])
        self.assertIn("Removed from Jess's iPhone", lines["ANIMAL WELL"])
        self.assertIn("Kept build: Rebuild on the Mac first", lines["Metroid Dread"])
        self.assertIn("Ready on Mac (kept)", lines["Metroid Dread"])
        self.assertIn("Not built", lines["Loose Files"])
        self.assertIn("No game files on the Mac to build from", lines["Loose Files"])
        self.assertIn("ipa failed on the Mac", lines["Balatro"])
        self.assertIn("error: no signing team", out)
        # games on the device first
        self.assertTrue(out.splitlines()[1].startswith("Celeste"))

    def test_games_still_list_when_the_device_cant_be_asked(self):
        self.pair()
        code, out, err = self.run_cli("games", "--device", "gone")
        self.assertEqual(code, 0)
        self.assertIn("What's on gone is unknown: No such device", err)
        self.assertIn("Can install", out)

    def test_json_is_the_macs_answer(self):
        self.pair()
        code, out, _ = self.run_cli("--json", "games")
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual(data["games"], self.mac.games)
        self.assertEqual(data["removed"], ["010020D01AD24000"])

    def test_devices_and_choosing_one(self):
        self.pair(device=False)
        code, out, _ = self.run_cli("devices")
        self.assertIn(PHONE, out)
        code, _, err = self.run_cli("use-device", "Someone's iPad")
        self.assertEqual(code, remote.EXIT_USAGE)
        self.assertIn("Jess's iPhone", err)
        self.assertIn("Connect via network", err)
        self.assertEqual(self.run_cli("use-device", PHONE)[0], 0)
        self.assertIn("(chosen)", self.run_cli("devices")[1])

    def test_apps(self):
        self.pair()
        code, out, _ = self.run_cli("apps")
        self.assertEqual(code, 0)
        self.assertIn("01002B30028F6000\t1.4", out)
        self.assertIn("010020D01AD24000\tremoved", out)


class InstallTests(Case):
    def test_an_install_is_followed_to_the_end(self):
        self.pair()
        self.mac.installs = [
            job("running", 0.5, "3/6 Shaders · ANIMAL WELL"),
            job("running", 0.5, "3/6 Shaders · ANIMAL WELL"),
            job("succeeded", 1, "Done"),
        ]
        code, out, err = self.run_cli("install", "animal", sleep=lambda _: None)
        self.assertEqual(code, 0, err)
        self.assertEqual(out.count("3/6 Shaders · ANIMAL WELL (50%)"), 1)
        self.assertIn("Installed ANIMAL WELL", out)
        method, path, headers = self.mac.requests[1]
        self.assertEqual(method, "POST")
        # the folder is one path component, its space and brackets encoded
        self.assertEqual(path, f"/v1/games/Animal%20Well%20%5BNSP%5D/install?device={PHONE}")
        self.assertEqual(headers["Authorization"], f"Bearer {CODE}")

    def test_a_failed_install_says_why(self):
        self.pair()
        self.mac.installs = [job("failed", text="6/6 Install", code=1, lines=["devicectl: device is locked"])]
        code, out, _ = self.run_cli("install", "ANIMAL WELL", sleep=lambda _: None)
        self.assertEqual(code, remote.EXIT_JOB)
        self.assertIn("The install failed (exit 1)", out)
        self.assertIn("devicectl: device is locked", out)

    def test_the_mac_refusing_shows_its_reason(self):
        self.pair()
        for answer, text in (
            ((409, {"error": "ANIMAL WELL is busy on the Mac"}), "busy on the Mac"),
            ((422, {"error": "ANIMAL WELL has no game files to build from"}), "no game files"),
        ):
            self.mac.install_answer = answer
            code, _, err = self.run_cli("install", "Animal Well [NSP]")
            self.assertEqual(code, remote.EXIT_API)
            self.assertIn(text, err)

    def test_a_device_the_mac_cant_reach(self):
        self.pair()
        code, _, err = self.run_cli("install", "Celeste", "--device", "00008150-0000000000000000")
        self.assertEqual(code, remote.EXIT_API)
        self.assertIn("pair it with Xcode", err)

    def test_no_device_chosen(self):
        self.pair(device=False)
        code, _, err = self.run_cli("install", "Celeste")
        self.assertEqual(code, remote.EXIT_USAGE)
        self.assertIn("use-device", err)
        self.assertEqual(self.mac.requests, [])

    def test_unknown_and_ambiguous_games(self):
        self.pair()
        self.assertIn("No game", self.run_cli("install", "Zelda")[2])
        self.assertIn("More than one", self.run_cli("install", "e")[2])

    def test_a_job_replacing_the_install_stops_watching(self):
        self.pair()
        self.mac.installs = [job("running", kind="play", text="Playing")]
        code, _, err = self.run_cli("install", "animal", sleep=lambda _: None)
        self.assertEqual(code, remote.EXIT_API)
        self.assertIn("replaced", err)

    def test_watching_survives_a_moment_offline(self):
        client = mock.Mock()
        offline = remote.Failure("Can't reach it", remote.EXIT_UNREACHABLE)
        done = game("G", "G", "01", job=job("succeeded"))
        client.games.side_effect = [offline, offline, [done]]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err):
            code = remote.follow(client, done, PHONE, job("queued", text="Queued"), out, 0, lambda _: None)
        self.assertEqual(code, 0)
        self.assertEqual(err.getvalue().count("trying again"), 2)

    def test_ctrl_c_leaves_the_mac_installing(self):
        def interrupt(_):
            raise KeyboardInterrupt
        out = io.StringIO()
        code = remote.follow(mock.Mock(), {"id": "G"}, PHONE, job("queued"), out, 0, interrupt)
        self.assertEqual(code, 130)
        self.assertIn("the Mac carries on", out.getvalue())


class NetworkTests(Case):
    def test_nothing_listening(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        os.environ["NXPLAY_CODE"] = CODE
        code, _, err = self.run_cli("--host", f"127.0.0.1:{port}", "info")
        self.assertEqual(code, remote.EXIT_UNREACHABLE)
        self.assertIn("iPhone & iPad App", err)
        self.assertNotIn(CODE, err)

    def test_a_mac_that_doesnt_answer(self):
        self.pair()
        self.mac.delay = 1
        code, _, err = self.run_cli("--timeout", "0.2", "info")
        self.assertEqual(code, remote.EXIT_UNREACHABLE)
        self.assertIn("awake", err)

    def test_redirects_are_not_followed(self):
        self.pair()
        elsewhere = FakeMac()
        self.addCleanup(elsewhere.close)
        self.mac.raw = (302, {"Location": f"http://127.0.0.1:{elsewhere.port}/v1/info"}, b"")
        code, _, err = self.run_cli("info")
        self.assertEqual(code, remote.EXIT_API)
        self.assertIn("redirect", err)
        self.assertEqual(elsewhere.requests, [])

    def test_proxies_never_see_the_code(self):
        self.pair()
        proxy = FakeMac()
        self.addCleanup(proxy.close)
        environment = {"http_proxy": f"http://127.0.0.1:{proxy.port}", "HTTP_PROXY": f"http://127.0.0.1:{proxy.port}",
                       "no_proxy": "", "NO_PROXY": ""}
        with mock.patch.dict(os.environ, environment):
            self.assertEqual(self.run_cli("info")[0], 0)
        self.assertEqual(proxy.requests, [])

    def test_something_that_isnt_nx_play(self):
        self.pair()
        self.mac.raw = (200, {"Content-Type": "text/html"}, b"<html>router login</html>")
        code, _, err = self.run_cli("info")
        self.assertEqual(code, remote.EXIT_API)
        self.assertIn("right Mac and port", err)

    def test_an_endless_answer_is_cut_off(self):
        self.pair()
        self.mac.raw = (200, {"Content-Type": "application/json"}, b" " * (remote.MAX_BODY + 10))
        code, _, err = self.run_cli("info")
        self.assertEqual(code, remote.EXIT_API)
        self.assertIn("stopped reading", err)

    def test_a_folder_name_cant_reach_another_route(self):
        client = remote.MacClient("127.0.0.1", self.mac.port, CODE)
        with self.assertRaises(remote.Failure) as raised:
            client.install("../../info", PHONE)
        self.assertIn("No such API", raised.exception.message)
        self.assertEqual(self.mac.requests[0][1], f"/v1/games/..%2F..%2Finfo/install?device={PHONE}")

    def test_a_missing_local_name_explains_mdns(self):
        failure = remote.MacClient("nowhere.local", 47474, CODE)._unreachable(socket.gaierror(-2, "Name unknown"))
        self.assertEqual(failure.code, remote.EXIT_UNREACHABLE)
        self.assertIn("nss-mdns", failure.message)


class DiscoveryTests(unittest.TestCase):
    AVAHI = "\n".join([
        "+;wlan0;IPv4;Studio\\032Mac;_nxplay._tcp;local",
        '=;wlan0;IPv6;Studio\\032Mac;_nxplay._tcp;local;Studio-Mac.local;fe80::1;47474;"port=47474" "host=Studio-Mac.local" "v=1"',
        '=;wlan0;IPv4;Studio\\032Mac;_nxplay._tcp;local;Studio-Mac.local;192.168.1.20;47474;"port=47474" "host=Studio-Mac.local" "v=1"',
        '=;wlan0;IPv4;Other;_ssh._tcp;local;other.local;192.168.1.30;22;',
        '=;wlan0;IPv4;Mini;_nxplay._tcp;local;mini.local;192.168.1.21;47474;"v=1" "host=" "port=5000"',
    ])

    def test_avahi_output(self):
        self.assertEqual(remote.parse_avahi(self.AVAHI), [
            {"name": "Mini", "host": "mini.local", "address": "192.168.1.21", "port": 5000},
            {"name": "Studio Mac", "host": "Studio-Mac.local", "address": "192.168.1.20", "port": 47474},
        ])

    def test_without_avahi(self):
        with mock.patch.object(remote.shutil, "which", return_value=None):
            with self.assertRaises(remote.Failure) as raised:
                remote.discover()
        self.assertIn("avahi-utils", raised.exception.message)
        self.assertEqual(raised.exception.code, remote.EXIT_USAGE)

    def test_with_avahi(self):
        ran = []

        def run(argv, **options):
            ran.append(argv)
            return subprocess.CompletedProcess(argv, 0, self.AVAHI, "")
        with mock.patch.object(remote.shutil, "which", return_value="/usr/bin/avahi-browse"):
            macs = remote.discover(run=run)
        self.assertEqual(ran[0][1:], ["--resolve", "--parsable", "--terminate", "_nxplay._tcp"])
        self.assertEqual(len(macs), 2)


class StatusTests(unittest.TestCase):
    def test_expiry_words_match_the_iphone_app(self):
        now = datetime(2026, 11, 3, tzinfo=timezone.utc)
        self.assertEqual(remote.expiry_text(now - timedelta(seconds=1), now), "Expired")
        self.assertEqual(remote.expiry_text(now + timedelta(hours=3), now), "Expires today")
        self.assertEqual(remote.expiry_text(now + timedelta(days=1, hours=1), now), "Expires in 1 day")
        self.assertEqual(remote.expiry_text(now + timedelta(days=6, hours=1), now), "Expires in 6 days")

    def test_an_active_job_wins(self):
        running = game("G", "G", "01", job=job("running", 0.25, "2/6 Extract"))
        self.assertEqual(remote.game_status(running, {"01": "1.0"}), "2/6 Extract (25%)")



class ReviewRegressionTests(Case):
    def test_initial_result_must_match_install_and_device(self):
        self.pair()
        for answer in (job('succeeded', kind='play'), job('succeeded', device='other')):
            self.mac.install_answer = (202, answer)
            code, out, err = self.run_cli('install', 'animal')
            self.assertEqual(code, remote.EXIT_API)
            self.assertNotIn('Installed', out)
            self.assertIn('replaced', err)

    def test_override_cannot_save_into_another_pairing(self):
        self.pair()
        with open(self.config) as stream:
            before = stream.read()
        with mock.patch.dict(os.environ, {'NXPLAY_CODE': CODE}):
            code, _, _ = self.run_cli('--host', 'other-mac.local', 'use-device', PHONE)
        self.assertEqual(code, remote.EXIT_USAGE)
        with open(self.config) as stream:
            self.assertEqual(stream.read(), before)
        self.assertEqual(self.mac.requests, [])

    def test_malformed_nested_replies_fail_cleanly(self):
        self.pair()
        for command, data in (
            (['devices'], [4]),
            (['apps'], {'apps': [4]}),
            (['games', '--mac-only'], [dict(self.mac.games[0], titleID=[])]),
            (['games', '--mac-only'], [dict(self.mac.games[0], job=job('running', fraction='bad'))]),
            (['games', '--mac-only'], [dict(self.mac.games[0], state={})]),
        ):
            self.mac.raw = (200, {}, json.dumps(data).encode())
            code, _, err = self.run_cli(*command)
            self.assertEqual(code, remote.EXIT_API, err)
            self.assertIn('malformed', err)

    def test_numeric_auth_error_is_safe(self):
        self.pair()
        self.mac.raw = (401, {}, b'{"error": 42}')
        self.assertEqual(self.run_cli('info')[0], remote.EXIT_AUTH)

    def test_invalid_interval_never_sends_install(self):
        self.pair()
        for interval in ('-1', '0', 'nan', 'inf'):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
                remote.main(['install', 'animal', '--interval', interval])
            self.assertEqual(caught.exception.code, 2)
        self.assertEqual(self.mac.requests, [])

    def test_pairing_another_port_forgets_previous_device(self):
        self.pair()
        other = FakeMac()
        self.addCleanup(other.close)
        code, _, err = self.run_cli('pair', '127.0.0.1:' + str(other.port), CODE)
        self.assertEqual(code, 0, err)
        self.assertNotIn('device', remote.load_config())


if __name__ == "__main__":
    unittest.main()
