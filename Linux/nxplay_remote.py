#!/usr/bin/env python3
"""nxplay-remote: NX Play's library from Linux, or any computer with Python 3.9 or later.

A client for the API NX Play on the Mac serves to the iPhone & iPad App (Packages/NXPlayKit/Sources/NXPlayKit/
Library+Remote.swift has the other side, iOS/Sources/MacClient.swift the iPhone's client). It lists the Mac's games
with their build and install state, picks a device the Mac reaches, and asks the Mac to build a game signed with its
team and install it there. The games, their builds, the signing and the install all stay on the Mac: this only asks.

    nxplay-remote pair <mac>.local                   asks for the pairing code from Settings › Devices on the Mac
    nxplay-remote games                              the library, and what's on the chosen device
    nxplay-remote devices                            the devices the Mac reaches
    nxplay-remote use-device <udid or name>          the device installs go to
    nxplay-remote install <game>                     build on the Mac, install on the device, follow it to the end

Exit status: 0 done, 1 the Mac refused or failed, 2 usage or setup, 3 the Mac can't be reached, 4 wrong pairing code,
5 the install job failed or was cancelled, 130 stopped watching (the Mac carries on).
"""

import argparse
import getpass
import http.client
import json
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

DEFAULT_PORT = 47474  # RemoteServer.defaultPort
SERVICE_TYPE = "_nxplay._tcp"
# listing a device's apps asks devicectl on the Mac, a few seconds; installs are followed by polling, never waited on
TIMEOUT = 30
# the largest answer read: a big library's JSON is far smaller
MAX_BODY = 8 * 1024 * 1024
# Personal Team installs stop opening after 7 days; within 2 the iPhone app offers Renew (iOS/Sources/Expiry.swift)
EXPIRY_WARNING = 2 * 24 * 3600

EXIT_OK, EXIT_API, EXIT_USAGE, EXIT_UNREACHABLE, EXIT_AUTH, EXIT_JOB = 0, 1, 2, 3, 4, 5

PAIRING_HINT = "NX Play › Settings › Devices › iPhone & iPad App on the Mac"
DEVICE_HINT = (
    "Not listed? Pair the device with Xcode on the Mac (Window › Devices and Simulators), tick Connect via network, "
    "and turn on Developer Mode on the device."
)


class Failure(Exception):
    def __init__(self, message, code=EXIT_API):
        super().__init__(message)
        self.message = message
        self.code = code


# MARK: - Settings


def config_path():
    explicit = os.environ.get("NXPLAY_REMOTE_CONFIG")
    if explicit:
        return explicit
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "nxplay", "remote.json")


def load_config(path=None, required=True):
    path = path or config_path()
    try:
        with open(path, encoding="utf-8") as file:
            mode = os.fstat(file.fileno()).st_mode
            config = json.load(file)
    except FileNotFoundError:
        if required:
            raise Failure("Not paired with a Mac yet: run `nxplay-remote pair <mac>.local`", EXIT_USAGE)
        return {}
    except (OSError, ValueError) as error:
        raise Failure(f"Can't read {path}: {error}", EXIT_USAGE)
    if not isinstance(config, dict):
        raise Failure(f"{path} isn't nxplay-remote's settings: pair again", EXIT_USAGE)
    if os.name == "posix" and mode & 0o077:
        warn(f"{path} holds the pairing code and others can read it: chmod 600 it")
    return config


def save_config(config, path=None):
    """Written whole and readable by this user only: the pairing code lets anyone on the network install from the Mac."""
    path = path or config_path()
    folder = os.path.dirname(path)
    os.makedirs(folder, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".remote-", dir=folder)  # mkstemp makes it 0600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            json.dump(config, file, indent=2, sort_keys=True)
            file.write("\n")
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


# MARK: - Addresses and codes


def parse_address(text, port=None):
    """`mac.local`, `mac.local:47474`, `192.168.1.20`, `[fe80::1%en0]:47474` → (host, port). No scheme or path: the
    client only ever talks to NX Play's own paths."""
    text = (text or "").strip()
    if not text or any(c.isspace() or ord(c) < 0x20 for c in text) or re.search(r"[/@?#\\]", text):
        raise Failure(f"Not a Mac's address: {text!r} (use a name like mac.local, or an IP address)", EXIT_USAGE)
    host, found_port = text, None
    if text.startswith("["):
        end = text.find("]")
        if end < 0:
            raise Failure(f"Not a Mac's address: {text!r}", EXIT_USAGE)
        host, rest = text[1:end], text[end + 1 :]
        if rest:
            if not rest.startswith(":"):
                raise Failure(f"Not a Mac's address: {text!r}", EXIT_USAGE)
            found_port = rest[1:]
    elif text.count(":") == 1:
        host, found_port = text.split(":")
    elif text.count(":") > 1:
        host = text  # a bare IPv6 address
    port = found_port if found_port is not None else port if port is not None else DEFAULT_PORT
    try:
        port = int(port)
    except (TypeError, ValueError):
        port = 0
    if not host or not 0 < port < 65536:
        raise Failure(f"Not a Mac's address: {text!r}", EXIT_USAGE)
    return host, port


def check_code(code):
    """The pairing code as the Mac shows it ("abcd-efgh-jkmn"). It goes in a header, so nothing that could end one."""
    code = (code or "").strip()
    if not code:
        raise Failure(f"No pairing code: it's under the address in {PAIRING_HINT}", EXIT_USAGE)
    if not all(0x21 <= ord(c) <= 0x7E for c in code):
        raise Failure("A pairing code is letters, digits and dashes only", EXIT_USAGE)
    # the Mac makes them lowercase (Library.newRemoteToken); a phone keyboard or caps lock may not
    if re.fullmatch(r"[A-Za-z2-9]{4}-[A-Za-z2-9]{4}-[A-Za-z2-9]{4}", code):
        code = code.lower()
    return code


# MARK: - The Mac


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    # NX Play never redirects; following one would send the pairing code wherever it points
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None



def validate_reply(parts, value):
    """Reject malformed nested API fields before rendering or changing pairing state."""
    def reject():
        raise Failure("The Mac sent malformed NX Play data")

    def record(item, strings=(), booleans=()):
        if not isinstance(item, dict):
            reject()
        for key in strings:
            if item.get(key) is not None and not isinstance(item[key], str):
                reject()
        for key in booleans:
            if key in item and not isinstance(item[key], bool):
                reject()

    def job(item):
        record(item, ("kind", "device", "status", "text"))
        if not isinstance(item.get("kind"), str) or not isinstance(item.get("status"), str):
            reject()
        fraction = item.get("fraction")
        if fraction is not None and (type(fraction) not in (int, float) or not math.isfinite(fraction)):
            reject()
        if item.get("exitCode") is not None and type(item["exitCode"]) is not int:
            reject()
        lines = item.get("lastLines", [])
        if not isinstance(lines, list) or any(not isinstance(line, str) for line in lines):
            reject()

    if parts == ["v1", "info"]:
        record(value, ("name", "version"))
        if value.get("team") is not None:
            record(value["team"], ("name",), ("free",))
    elif parts == ["v1", "games"]:
        for item in value:
            record(item, ("id", "name", "titleID", "version", "state", "expires"),
                   ("kept", "canInstall", "hasIcon"))
            if not isinstance(item.get("id"), str):
                reject()
            if item.get("job") is not None:
                job(item["job"])
    elif parts == ["v1", "devices"]:
        for item in value:
            record(item, ("id", "name", "model", "os"))
            if not isinstance(item.get("id"), str):
                reject()
    elif parts[-1] == "apps":
        apps, removed = value.get("apps", []), value.get("removed", [])
        if not isinstance(apps, list) or not isinstance(removed, list):
            reject()
        for item in apps:
            record(item, ("titleID", "version", "bundleID"))
        if any(not isinstance(item, str) for item in removed):
            reject()
    elif parts[-1] == "install":
        job(value)


def check_install_job(job, device):
    if not isinstance(job, dict) or job.get("kind") != "install" or job.get("device") != device:
        raise Failure("The install was replaced by another operation or device on the Mac")


def positive_seconds(text):
    try:
        value = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError("seconds must be a positive finite number")
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("seconds must be a positive finite number")
    return value


class MacClient:
    def __init__(self, host, port, token, timeout=TIMEOUT):
        self.host, self.port, self.token, self.timeout = host, port, check_code(token), timeout
        # no proxy either: the Mac is on the local network, and a proxy would see the code
        self._opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirects)

    @property
    def address(self):
        return f"{self._url_host()}:{self.port}"

    def info(self):
        return self._json(["v1", "info"], dict)

    def games(self):
        games = self._json(["v1", "games"], list)
        for game in games:
            if not isinstance(game, dict) or not isinstance(game.get("id"), str):
                raise Failure(f"{self.address} sent a game list nxplay-remote doesn't understand")
        return games

    def devices(self):
        return self._json(["v1", "devices"], list)

    def installed(self, device):
        return self._json(["v1", "devices", device, "apps"], dict)

    def install(self, game_id, device):
        return self._json(["v1", "games", game_id, "install"], dict, query={"device": device}, method="POST")

    def _url_host(self):
        return f"[{self.host}]" if ":" in self.host else self.host

    def _json(self, parts, kind, query=None, method="GET"):
        body = self._request(parts, query, method)
        try:
            value = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise Failure(f"{self.address} answered, but not as NX Play does: is this the right Mac and port?")
        if not isinstance(value, kind):
            raise Failure(f"{self.address} sent an answer nxplay-remote doesn't understand (NX Play too new or old?)")
        validate_reply(parts, value)
        return value

    def _request(self, parts, query, method):
        # each part percent-encoded on its own, "/" too: a game folder can't reach another path ("Animal Well [NSP]")
        path = "/".join(urllib.parse.quote(part, safe="") for part in parts)
        url = f"http://{self._url_host()}:{self.port}/{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query, quote_via=urllib.parse.quote)
        request = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {self.token}"})
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                return _read(response, self.address)
        except urllib.error.HTTPError as error:
            raise self._refusal(error) from None
        except urllib.error.URLError as error:
            raise self._unreachable(error.reason) from None
        except (http.client.HTTPException, ConnectionError) as error:
            raise Failure(f"{self.address} hung up without an answer NX Play would give ({error.__class__.__name__})")
        except (socket.timeout, TimeoutError):
            raise Failure(
                f"{self.address} didn't answer in {self.timeout:g} seconds: is the Mac awake, with NX Play open?",
                EXIT_UNREACHABLE,
            ) from None
        except ValueError as error:  # an address urllib can't make a URL of
            raise Failure(f"Not a Mac's address: {self.address} ({error})", EXIT_USAGE) from None

    def _refusal(self, error):
        try:
            message = json.loads(_read(error, self.address).decode("utf-8")).get("error")
        except Exception:
            message = None
        finally:
            error.close()
        if not isinstance(message, str):
            message = None
        if 300 <= error.code < 400:
            return Failure(f"{self.address} tried to redirect: NX Play never does, so nxplay-remote didn't follow")
        if error.code == 401:
            return Failure(
                (message or "Wrong pairing code")
                + ". The code may have been renewed: run `nxplay-remote pair` with the current one",
                EXIT_AUTH,
            )
        return Failure(message or f"The Mac answered {error.code}", EXIT_API)

    def _unreachable(self, reason):
        where = self.address
        if isinstance(reason, socket.gaierror):
            hint = ""
            if self.host.endswith(".local"):
                hint = (
                    ": .local names need mDNS on this computer (avahi-daemon with nss-mdns), "
                    "or pair with the Mac's IP address instead"
                )
            return Failure(f"Can't find {self.host}{hint}", EXIT_UNREACHABLE)
        if isinstance(reason, ConnectionRefusedError):
            return Failure(
                f"Nothing answers at {where}: on the Mac, open NX Play and turn on Settings › Devices › "
                "iPhone & iPad App",
                EXIT_UNREACHABLE,
            )
        if isinstance(reason, (socket.timeout, TimeoutError)):
            return Failure(
                f"{where} didn't answer in {self.timeout:g} seconds: is the Mac awake, with NX Play open?",
                EXIT_UNREACHABLE,
            )
        return Failure(f"Can't reach {where}: {reason}", EXIT_UNREACHABLE)


def _read(response, address):
    body = response.read(MAX_BODY + 1)
    if len(body) > MAX_BODY:
        raise Failure(f"{address} sent more than NX Play ever does; stopped reading")
    return body


# MARK: - Finding Macs


def discover(timeout=5, run=subprocess.run):
    """The Macs advertising `_nxplay._tcp`, through Avahi (Linux's Bonjour): [{name, host, address, port}]."""
    browse = shutil.which("avahi-browse")
    if not browse:
        raise Failure(
            "Looking for Macs needs avahi-browse (the avahi-utils package); "
            "or pair by address: `nxplay-remote pair <mac>.local`",
            EXIT_USAGE,
        )
    try:
        result = run(
            [browse, "--resolve", "--parsable", "--terminate", SERVICE_TYPE],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise Failure(f"avahi-browse found nothing in {timeout} seconds", EXIT_UNREACHABLE)
    if result.returncode != 0:
        detail = (result.stderr or "").strip().splitlines()
        raise Failure(
            "avahi-browse failed" + (f": {detail[-1]}" if detail else "") + " (is avahi-daemon running?)",
            EXIT_UNREACHABLE,
        )
    return parse_avahi(result.stdout)


def parse_avahi(output):
    found = {}
    for line in output.splitlines():
        # =;interface;protocol;name;type;domain;host name;address;port;txt
        fields = line.split(";")
        if len(fields) < 10 or fields[0] != "=" or fields[4] != SERVICE_TYPE:
            continue
        txt = dict(item.split("=", 1) for item in re.findall(r'"([^"]*)"', ";".join(fields[9:])) if "=" in item)
        name = _avahi_unescape(fields[3])
        try:
            port = int(txt.get("port") or fields[8])
        except ValueError:
            continue
        mac = {"name": name, "host": txt.get("host") or fields[6], "address": fields[7], "port": port}
        # IPv4 first when a Mac shows up on both
        if name not in found or fields[2] == "IPv4":
            found[name] = mac
    return sorted(found.values(), key=lambda mac: mac["name"])


def _avahi_unescape(text):
    # avahi-browse writes a name's dots and spaces as \046 and \032 (decimal)
    return re.sub(r"\\(\d{3})", lambda m: chr(int(m.group(1))), text)


# MARK: - What a game shows


MAC_STATES = {"notExtracted": "Not built", "extracted": "Extracted", "ready": "Ready on Mac"}


def job_active(job):
    return isinstance(job, dict) and job.get("status") in ("queued", "running")


def job_line(job):
    text = job.get("text") or f"{job.get('kind', 'job')} {job.get('status', '')}".strip()
    fraction = job.get("fraction") or 0
    return f"{text} ({fraction:.0%})" if job.get("status") == "running" and fraction else text


def expiry_text(expires, now=None):
    """"Expires in 3 days", "Expires today", "Expired", as the iPhone app says it."""
    left = (expires - (now or datetime.now(timezone.utc))).total_seconds()
    if left <= 0:
        return "Expired"
    days = int(left // 86400)
    return "Expires today" if days == 0 else f"Expires in {days} day{'' if days == 1 else 's'}"


def parse_date(text):
    if not isinstance(text, str):
        return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        return parsed if parsed.tzinfo is not None else None
    except ValueError:
        return None


def game_status(game, installed=None, removed=(), device_name="the device", now=None):
    """One line, in the order the iPhone app's tile picks (iOS/Sources/LibraryView.swift)."""
    job = game.get("job")
    if job_active(job):
        return job_line(job)
    title = (game.get("titleID") or "").upper()
    if installed is not None and title in installed:
        expires = parse_date(game.get("expires"))
        now = now or datetime.now(timezone.utc)
        if expires and (expires - now).total_seconds() < EXPIRY_WARNING:
            return f"On {device_name} · {expiry_text(expires, now)}"
        return f"On {device_name} · {installed[title] or 'installed'}"
    if isinstance(job, dict) and job.get("status") == "failed":
        return "Install failed" if job.get("kind") == "install" else f"{job.get('kind', 'Job')} failed on the Mac"
    if title and title in removed:
        return f"Removed from {device_name}"
    if game.get("canInstall"):
        return "Can install"
    return "Kept build: Rebuild on the Mac first" if game.get("kept") else "No game files on the Mac to build from"


def find_game(games, wanted):
    """By folder name, then name or title ID, then a unique part of the name."""
    lowered = wanted.casefold()
    for test in (
        lambda g: g["id"] == wanted,
        lambda g: str(g.get("name", "")).casefold() == lowered or str(g.get("titleID") or "").casefold() == lowered,
        lambda g: lowered in str(g.get("name", "")).casefold() or lowered in g["id"].casefold(),
    ):
        matches = [g for g in games if test(g)]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            names = ", ".join(sorted(g["id"] for g in matches))
            raise Failure(f"More than one game matches {wanted!r}: {names}", EXIT_USAGE)
    raise Failure(f"No game {wanted!r} on the Mac: `nxplay-remote games` lists them", EXIT_USAGE)


def find_device(devices, wanted):
    lowered = wanted.casefold()
    for test in (lambda d: d.get("id") == wanted, lambda d: str(d.get("name", "")).casefold() == lowered):
        matches = [d for d in devices if isinstance(d, dict) and test(d)]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise Failure(f"More than one device is called {wanted!r}: use its UDID", EXIT_USAGE)
    listed = ", ".join(f"{d.get('name')} ({d.get('id')})" for d in devices if isinstance(d, dict)) or "none"
    raise Failure(f"The Mac doesn't reach a device {wanted!r}. It reaches: {listed}. {DEVICE_HINT}", EXIT_USAGE)


def looks_like_udid(text):
    return re.fullmatch(r"[0-9A-Fa-f]{8}-?[0-9A-Fa-f]{16}|[0-9A-Fa-f-]{36,40}", text) is not None


# MARK: - Commands


def warn(text):
    print(text, file=sys.stderr)


def client_from(args, config):
    if args.host:
        host, port = parse_address(args.host, args.port)
    elif config.get("host"):
        host, port = config["host"], args.port or config.get("port") or DEFAULT_PORT
    else:
        raise Failure("Not paired with a Mac yet: run `nxplay-remote pair <mac>.local`", EXIT_USAGE)
    # the saved code is only ever sent to the Mac it came from, at the address it was paired on
    paired = (config.get("host"), config.get("port") or DEFAULT_PORT)
    saved = config.get("token") if (host, port) == paired else None
    token = os.environ.get("NXPLAY_CODE") or saved
    if not token:
        raise Failure(f"No pairing code: run `nxplay-remote pair`, or set NXPLAY_CODE ({PAIRING_HINT})", EXIT_USAGE)
    return MacClient(host, port, token, timeout=args.timeout)


def describe_team(info):
    team = info.get("team")
    if not isinstance(team, dict):
        return "no Apple team (installs need one: Xcode › Settings › Apple Accounts on the Mac)"
    return f"team {team.get('name')}" + (" (Personal Team: installs open for 7 days)" if team.get("free") else "")


def cmd_pair(args, out):
    host, port = parse_address(args.address, args.port)
    code = args.code or os.environ.get("NXPLAY_CODE")
    if not code:
        if not sys.stdin.isatty():
            raise Failure("No pairing code: pass it, or set NXPLAY_CODE", EXIT_USAGE)
        code = getpass.getpass(f"Pairing code (under the address in {PAIRING_HINT}): ")
    client = MacClient(host, port, code, timeout=args.timeout)
    info = client.info()
    previous = load_config(required=False)
    config = {"host": host, "port": port, "token": client.token, "name": info.get("name") or host}
    # the chosen device stays when it's the same Mac again (a renewed code)
    if (previous.get("host"), previous.get("port") or DEFAULT_PORT) == (host, port) and previous.get("device"):
        config["device"], config["deviceName"] = previous["device"], previous.get("deviceName")
    save_config(config)
    print(f"Paired with {config['name']} at {client.address}: NX Play {info.get('version') or '?'}, "
          f"{describe_team(info)}", file=out)
    if not config.get("device"):
        print("Next: `nxplay-remote devices`, then `nxplay-remote use-device <udid or name>`", file=out)
    return EXIT_OK


def cmd_unpair(args, out):
    path = config_path()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    print(f"Forgot the Mac and its pairing code ({path})", file=out)
    return EXIT_OK


def cmd_discover(args, out):
    macs = discover(timeout=args.seconds)
    if args.json:
        print(json.dumps(macs, indent=2), file=out)
        return EXIT_OK
    if not macs:
        print(f"No Mac running NX Play found. On the Mac: {PAIRING_HINT}, with installs from devices on", file=out)
    for mac in macs:
        print(f"{mac['name']}\t{mac['host']}:{mac['port']}\t{mac['address']}", file=out)
    return EXIT_OK


def cmd_info(args, out):
    config = load_config(required=not args.host)
    client = client_from(args, config)
    info = client.info()
    if args.json:
        print(json.dumps(info, indent=2, sort_keys=True), file=out)
        return EXIT_OK
    print(f"{info.get('name')} at {client.address}: NX Play {info.get('version') or '?'}, {describe_team(info)}",
          file=out)
    if config.get("device"):
        print(f"Installs go to {config.get('deviceName') or config['device']} ({config['device']})", file=out)
    return EXIT_OK


def cmd_games(args, out):
    config = load_config(required=not args.host)
    client = client_from(args, config)
    games = client.games()
    device = args.device or config.get("device")
    installed, removed = None, set()
    device_name = (config.get("deviceName") if device == config.get("device") else None) or device
    if device and not args.mac_only:
        try:
            apps = client.installed(device)
            installed = {str(a.get("titleID", "")).upper(): a.get("version") for a in apps.get("apps", [])}
            removed = {str(t).upper() for t in apps.get("removed", [])}
        except Failure as failure:
            if failure.code == EXIT_AUTH:
                raise
            warn(f"What's on {device_name} is unknown: {failure.message}")
    if args.json:
        print(json.dumps({"games": games, "device": device, "installed": installed,
                          "removed": sorted(removed)}, indent=2, sort_keys=True), file=out)
        return EXIT_OK
    if not games:
        print("No games in NX Play's games folder on the Mac", file=out)
        return EXIT_OK
    rows = [("GAME", "TITLE ID", "MAC BUILD", "STATUS")]
    on_device = lambda g: installed is not None and str(g.get("titleID") or "").upper() in installed
    for game in sorted(games, key=lambda g: (0 if on_device(g) else 1, str(g.get("name", "")).casefold())):
        rows.append((
            str(game.get("name") or game["id"]),
            str(game.get("titleID") or "-"),
            MAC_STATES.get(game.get("state"), str(game.get("state"))) + (" (kept)" if game.get("kept") else ""),
            game_status(game, installed, removed, device_name or "the device"),
        ))
    widths = [max(len(row[i]) for row in rows) for i in range(3)]
    for row in rows:
        print("  ".join(cell.ljust(width) for cell, width in zip(row, widths)) + "  " + row[3], file=out)
    failed = [g for g in games if isinstance(g.get("job"), dict) and g["job"].get("status") == "failed"]
    for game in failed:
        lines = game["job"].get("lastLines") or []
        if lines:
            print(f"\n{game.get('name')}: last lines of the failed {game['job'].get('kind')}:", file=out)
            print("\n".join("  " + str(line) for line in lines), file=out)
    if installed is None and not device:
        print("\nChoose a device to see what's on it: `nxplay-remote devices`, then `use-device`", file=out)
    return EXIT_OK


def cmd_devices(args, out):
    config = load_config(required=not args.host)
    devices = client_from(args, config).devices()
    if args.json:
        print(json.dumps(devices, indent=2, sort_keys=True), file=out)
        return EXIT_OK
    if not devices:
        print(f"The Mac reaches no device. {DEVICE_HINT}", file=out)
    for device in devices:
        chosen = " (chosen)" if device.get("id") == config.get("device") else ""
        print(f"{device.get('name')}\t{device.get('model')} · {device.get('os')}\t{device.get('id')}{chosen}",
              file=out)
    return EXIT_OK


def cmd_use_device(args, out):
    config = load_config()
    client = client_from(args, config)
    if (client.host, client.port) != (config.get("host"), config.get("port") or DEFAULT_PORT):
        raise Failure("Pair with this Mac before saving its device selection", EXIT_USAGE)
    device = find_device(client.devices(), args.device)
    config["device"], config["deviceName"] = device["id"], device.get("name")
    save_config(config)
    print(f"Installs go to {device.get('name')} ({device.get('model')}, {device['id']})", file=out)
    return EXIT_OK


def cmd_apps(args, out):
    config = load_config(required=not args.host)
    device = args.device or config.get("device")
    if not device:
        raise Failure("No device chosen: `nxplay-remote devices`, then `use-device`, or pass --device", EXIT_USAGE)
    apps = client_from(args, config).installed(device)
    if args.json:
        print(json.dumps(apps, indent=2, sort_keys=True), file=out)
        return EXIT_OK
    for app in apps.get("apps", []):
        print(f"{app.get('titleID')}\t{app.get('version')}\t{app.get('bundleID')}", file=out)
    for title in apps.get("removed", []):
        print(f"{title}\tremoved", file=out)
    if not apps.get("apps") and not apps.get("removed"):
        print("No NX Play games on the device", file=out)
    return EXIT_OK


def cmd_install(args, out, sleep=time.sleep):
    config = load_config(required=not args.host)
    client = client_from(args, config)
    device = args.device or config.get("device")
    if not device:
        raise Failure("No device chosen: `nxplay-remote devices`, then `use-device`, or pass --device", EXIT_USAGE)
    device_name = config.get("deviceName") if device == config.get("device") else None
    if not looks_like_udid(device):
        found = find_device(client.devices(), device)
        device, device_name = found["id"], found.get("name")
    device_name = device_name or device
    game = find_game(client.games(), args.game)
    job = client.install(game["id"], device)
    check_install_job(job, device)
    print(f"{game.get('name')}: the Mac builds it signed with its team, then installs it on {device_name}", file=out)
    if not args.wait:
        print(job_line(job), file=out)
        return EXIT_OK
    return follow(client, game, device, job, out, args.interval, sleep)


def follow(client, game, device, job, out, interval, sleep):
    """Polls the game list, as the iPhone app does while a build runs, until the install ends."""
    last, misses = None, 0
    try:
        while True:
            check_install_job(job, device)
            line = job_line(job)
            if line != last:
                print(line, file=out, flush=True)
                last = line
            if not job_active(job):
                break
            sleep(interval)
            try:
                games = client.games()
                misses = 0
            except Failure as failure:
                # Wi-Fi drops for a moment; the Mac carries on meanwhile
                misses += 1
                if failure.code != EXIT_UNREACHABLE or misses > 5:
                    raise
                warn(f"{failure.message} (trying again)")
                continue
            current = next((g for g in games if g["id"] == game["id"]), None)
            if current is None:
                raise Failure(f"{game.get('name')} left the Mac's library while installing")
            job = current.get("job")
            if not isinstance(job, dict) or job.get("kind") != "install" or job.get("device") != device:
                raise Failure(f"{game.get('name')}'s install was replaced by another job on the Mac")
    except KeyboardInterrupt:
        print("\nStopped watching; the Mac carries on with the install", file=out)
        return 130
    status = job.get("status")
    if status == "succeeded":
        print(f"Installed {game.get('name')}", file=out)
        return EXIT_OK
    reason = job.get("lastLines") or []
    exit_code = job.get("exitCode")
    print(f"The install {status}" + (f" (exit {exit_code})" if exit_code is not None else ""), file=out)
    if reason:
        print("\n".join("  " + str(line) for line in reason), file=out)
    print("The full log is in NX Play on the Mac", file=out)
    return EXIT_JOB


def build_parser():
    parser = argparse.ArgumentParser(
        prog="nxplay-remote",
        description="Browse NX Play's library on a Mac and install games on the devices it reaches.",
        epilog="Settings: $XDG_CONFIG_HOME/nxplay/remote.json (0600). NXPLAY_CODE overrides the saved pairing code.",
    )
    parser.add_argument("--host", help="the Mac for this command, instead of the paired one (mac.local[:port])")
    parser.add_argument("--port", type=int, help=f"NX Play's port (default {DEFAULT_PORT})")
    parser.add_argument("--timeout", type=positive_seconds, default=TIMEOUT, help="seconds to wait for each answer")
    parser.add_argument("--json", action="store_true", help="print the Mac's answers as JSON")
    commands = parser.add_subparsers(dest="command", required=True)

    pair = commands.add_parser("pair", help="pair with a Mac by its pairing code")
    pair.add_argument("address", help="mac.local, mac.local:47474 or an IP address")
    pair.add_argument("code", nargs="?", help="the pairing code (asked for when left out, which keeps it off ps)")
    pair.set_defaults(run=cmd_pair)
    commands.add_parser("unpair", help="forget the Mac and its code").set_defaults(run=cmd_unpair)
    discover_parser = commands.add_parser("discover", help="look for Macs running NX Play (needs avahi-browse)")
    discover_parser.add_argument("--seconds", type=positive_seconds, default=5, help="how long to look (default 5)")
    discover_parser.set_defaults(run=cmd_discover)
    commands.add_parser("info", help="the Mac, NX Play's version and the Apple team").set_defaults(run=cmd_info)

    games = commands.add_parser("games", help="the library, with build and install state")
    games.add_argument("--device", help="the device whose games to show (default: the chosen one)")
    games.add_argument("--mac-only", action="store_true", help="don't ask the device what's installed")
    games.set_defaults(run=cmd_games)
    commands.add_parser("devices", help="the devices the Mac reaches").set_defaults(run=cmd_devices)
    use = commands.add_parser("use-device", help="choose the device installs go to")
    use.add_argument("device", help="its UDID or name, from `devices`")
    use.set_defaults(run=cmd_use_device)
    apps = commands.add_parser("apps", help="the NX Play games installed on a device, and the ones removed")
    apps.add_argument("--device", help="UDID (default: the chosen device)")
    apps.set_defaults(run=cmd_apps)

    install = commands.add_parser("install", help="build a game on the Mac and install it on the device")
    install.add_argument("game", help="folder name, game name, title ID or a unique part of the name")
    install.add_argument("--device", help="UDID or name (default: the chosen device)")
    install.add_argument("--no-wait", dest="wait", action="store_false", help="return once the Mac has queued it")
    install.add_argument("--interval", type=positive_seconds, default=2.0, help="seconds between progress checks")
    install.set_defaults(run=cmd_install)
    return parser


def main(argv=None, out=None):
    out = out or sys.stdout
    args = build_parser().parse_args(argv)
    try:
        return args.run(args, out)
    except Failure as failure:
        warn(f"nxplay-remote: {failure.message}")
        return failure.code


if __name__ == "__main__":
    sys.exit(main())
