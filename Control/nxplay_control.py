#!/usr/bin/env python3
"""NX Play's local control API from the command line, and as an MCP server over stdio.

Standard library only (Python 3.8+). It reads NX Play's endpoint file (the URL and the token NX Play writes when its
control API starts) for every request, so a restarted NX Play is picked up. It talks only to 127.0.0.1 with
http.client: no proxy is ever used and no redirect is followed. It refuses an endpoint file another user could read,
and never prints the token.

    nxplay_control.py status
    nxplay_control.py commands [--query WORDS] [--group GROUP]
    nxplay_control.py describe games.extract
    nxplay_control.py call games.list
    nxplay_control.py call games.extract --arg game="Metroid Dread"
    nxplay_control.py call settings.update '{"patch": {"viewStyle": "list"}}'
    nxplay_control.py job job-3 --wait-ms 60000
    nxplay_control.py cancel job-3
    nxplay_control.py events --follow --names build,download
    nxplay_control.py endpoint            # where the file is and whether NX Play answers (never the token)
    nxplay_control.py enable | disable    # the switch NX Play reads at launch
    nxplay_control.py mcp [--tools meta]  # MCP over stdio

Exit codes: 0 ok, 1 the call failed, 2 usage, 3 NX Play's control API isn't reachable.
"""

import argparse
import http.client
import json
import os
import re
import stat
import sys

SCHEMA = "nxplay-control-api/1"
DEFAULT_DIR = os.path.expanduser("~/Library/Application Support/NX Play/control-api")
EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_UNREACHABLE = 0, 1, 2, 3
TIMEOUT = 660  # a call may wait up to 600 s for its work


class Unreachable(Exception):
    """No endpoint file, an unsafe one, or nothing answering at its address."""


def control_dir(args_dir=None):
    if args_dir:
        return os.path.abspath(os.path.expanduser(args_dir))
    env = os.environ.get("NXPLAY_CONTROL_DIR", "")
    if env.startswith("/"):
        return env
    return DEFAULT_DIR


def read_endpoint(path):
    """The endpoint file's contents, checked: this user's own regular file, readable by nobody else, in a folder
    nobody else can write to, naming 127.0.0.1 and a token of the right form."""
    folder = os.path.dirname(path) or "."
    try:
        info = os.stat(folder)
    except OSError:
        raise Unreachable("No control API folder at %s: is NX Play running with its control API on?" % folder)
    if info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise Unreachable("%s isn't private to this user: refusing it" % folder)
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    except OSError:
        raise Unreachable("No endpoint file at %s: is NX Play running with its control API on?" % path)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise Unreachable("%s isn't a regular file" % path)
        if info.st_uid != os.getuid():
            raise Unreachable("%s belongs to another user: refusing it" % path)
        if info.st_mode & 0o077:
            raise Unreachable("%s can be read by other users (mode %o): refusing it" % (path, info.st_mode & 0o777))
        data = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
            if len(data) > 65536:
                raise Unreachable("%s is too big to be an endpoint file" % path)
    finally:
        os.close(fd)
    try:
        endpoint = json.loads(data.decode("utf-8"))
    except ValueError:
        raise Unreachable("%s isn't JSON" % path)
    if not isinstance(endpoint, dict) or endpoint.get("schema") != SCHEMA:
        raise Unreachable("%s isn't an NX Play control API endpoint (%s)" % (path, SCHEMA))
    port = endpoint.get("port")
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        raise Unreachable("%s has no valid port" % path)
    if endpoint.get("url") != "http://127.0.0.1:%d" % port:
        raise Unreachable("%s names an address other than 127.0.0.1: refusing it" % path)
    token = endpoint.get("token")
    if not isinstance(token, str) or not re.fullmatch(r"[0-9a-f]{64}", token):
        raise Unreachable("%s has no valid token" % path)
    return endpoint


class Client(object):
    def __init__(self, endpoint_path):
        self.endpoint_path = endpoint_path

    def request(self, method, path, body=None, headers=None, timeout=TIMEOUT):
        """(status, raw bytes). Raises Unreachable when NX Play doesn't answer."""
        endpoint = read_endpoint(self.endpoint_path)
        connection = http.client.HTTPConnection("127.0.0.1", endpoint["port"], timeout=timeout)
        sent = {"Authorization": "Bearer " + endpoint["token"], "Accept": "application/json"}
        payload = None
        if body is not None:
            payload = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
            sent["Content-Type"] = "application/json"
        sent.update(headers or {})
        try:
            connection.request(method, path, body=payload, headers=sent)
            response = connection.getresponse()
            data = response.read()
            return response.status, data
        except (OSError, http.client.HTTPException) as error:
            raise Unreachable("NX Play's control API doesn't answer at 127.0.0.1:%d (%s)" % (endpoint["port"], error))
        finally:
            connection.close()

    def json(self, method, path, body=None, timeout=TIMEOUT):
        status, data = self.request(method, path, body, timeout=timeout)
        try:
            return status, json.loads(data.decode("utf-8")) if data else {}
        except ValueError:
            return status, {"ok": False, "error": {"code": "bad_response", "message": "NX Play answered with something other than JSON"}}


def quote(text):
    from urllib.parse import quote as q
    return q(text, safe="")


def parse_value(text):
    try:
        return json.loads(text)
    except ValueError:
        return text


def print_json(value):
    sys.stdout.write(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def finish(status, answer):
    print_json(answer)
    if status >= 400 or (isinstance(answer, dict) and answer.get("ok") is False):
        return EXIT_FAILED
    return EXIT_OK


# MARK: - MCP over stdio


def mcp(client, tools):
    """Forwards each JSON-RPC line on stdin to NX Play's /mcp and prints each answer on stdout. stdout carries
    protocol messages only; anything else goes to stderr."""
    version = None
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            write_message(out, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            continue
        msg_id = message.get("id") if isinstance(message, dict) else None
        is_request = isinstance(message, dict) and "method" in message and "id" in message
        headers = {"MCP-Protocol-Version": version} if version else {}
        try:
            status, data = client.request("POST", "/mcp", line.encode("utf-8"), headers=headers)
        except Unreachable as error:
            log("nxplay-control: %s" % error)
            if is_request:
                write_message(out, {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32000, "message": str(error)}})
            continue
        if status == 202 or not data:
            continue
        try:
            answer = json.loads(data.decode("utf-8"))
        except ValueError:
            if is_request:
                write_message(out, {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32603, "message": "NX Play answered with something other than JSON (HTTP %d)" % status}})
            continue
        if not (isinstance(answer, dict) and answer.get("jsonrpc") == "2.0"):
            # an HTTP-level refusal (401, 403…): said as a JSON-RPC error
            error = answer.get("error", {}) if isinstance(answer, dict) else {}
            if is_request:
                write_message(out, {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32000, "message": error.get("message", "HTTP %d" % status)}})
            continue
        if isinstance(message, dict) and message.get("method") == "initialize":
            version = (answer.get("result") or {}).get("protocolVersion") or version
        if tools == "meta" and isinstance(message, dict) and message.get("method") == "tools/list":
            result = answer.get("result") or {}
            result["tools"] = [t for t in result.get("tools", []) if t.get("name", "").startswith("nxapi_")]
        write_message(out, answer)
    return EXIT_OK


def write_message(out, message):
    out.write(json.dumps(message, separators=(",", ":"), ensure_ascii=False) + "\n")
    out.flush()


def log(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


# MARK: - Command line


def build_parser():
    parser = argparse.ArgumentParser(prog="nxplay_control.py", description="NX Play's local control API.")
    parser.add_argument("--dir", help="The control API's folder (default: ~/Library/Application Support/NX Play/control-api, or NXPLAY_CONTROL_DIR)")
    parser.add_argument("--endpoint", help="The endpoint file itself")
    sub = parser.add_subparsers(dest="action")
    sub.add_parser("status", help="NX Play, the API and the library")
    p = sub.add_parser("commands", help="List the commands")
    p.add_argument("--query")
    p.add_argument("--group")
    p = sub.add_parser("describe", help="One command in full")
    p.add_argument("name")
    p = sub.add_parser("call", help="Run a command")
    p.add_argument("name")
    p.add_argument("json_args", nargs="?", help="The arguments as a JSON object")
    p.add_argument("--arg", action="append", default=[], metavar="KEY=VALUE", help="One argument (VALUE read as JSON when it is)")
    p.add_argument("--wait", action="store_true", help="Wait for the work it starts to end too")
    p.add_argument("--timeout-ms", type=int, default=30000)
    sub.add_parser("jobs", help="The API's jobs")
    p = sub.add_parser("job", help="One job")
    p.add_argument("id")
    p.add_argument("--wait-ms", type=int, default=0)
    p = sub.add_parser("cancel", help="Cancel a job's work")
    p.add_argument("id")
    p = sub.add_parser("events", help="The event log")
    p.add_argument("--after", type=int, default=0)
    p.add_argument("--names")
    p.add_argument("--limit", type=int, default=200)
    p.add_argument("--wait-ms", type=int, default=0)
    p.add_argument("--follow", action="store_true", help="Keep printing events as they come (Ctrl-C stops)")
    p = sub.add_parser("settings", help="Read the settings, or change them with a JSON patch")
    p.add_argument("patch", nargs="?")
    sub.add_parser("limitations", help="What the API doesn't do")
    sub.add_parser("endpoint", help="Where the endpoint file is and whether NX Play answers (never the token)")
    sub.add_parser("enable", help="Turn the control API on at NX Play's next launch")
    sub.add_parser("disable", help="Leave it off at the next launch")
    p = sub.add_parser("mcp", help="MCP over stdio")
    p.add_argument("--tools", choices=["all", "meta"], default="all", help="meta: only the nxapi_* tools")
    return parser


def main(argv=None):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit:
        return EXIT_USAGE if exit.code else EXIT_OK
    if not args.action:
        parser.print_help(sys.stderr)
        return EXIT_USAGE
    folder = control_dir(args.dir)
    endpoint_path = os.path.abspath(os.path.expanduser(args.endpoint)) if args.endpoint else os.path.join(folder, "endpoint.json")
    client = Client(endpoint_path)

    if args.action == "enable":
        os.makedirs(folder, mode=0o700, exist_ok=True)
        os.chmod(folder, 0o700)
        fd = os.open(os.path.join(folder, "enabled"), os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        os.close(fd)
        print_json({"enabled": True, "note": "NX Play turns its control API on at its next launch"})
        return EXIT_OK
    if args.action == "disable":
        try:
            os.unlink(os.path.join(folder, "enabled"))
        except FileNotFoundError:
            pass
        print_json({"enabled": False, "note": "NX Play leaves its control API off from its next launch"})
        return EXIT_OK
    if args.action == "mcp":
        return mcp(client, args.tools)

    try:
        if args.action == "endpoint":
            info = {"path": endpoint_path, "exists": os.path.exists(endpoint_path)}
            try:
                endpoint = read_endpoint(endpoint_path)
                info.update({"url": endpoint["url"], "pid": endpoint.get("pid"), "app_version": endpoint.get("app_version"), "token": "present (not shown)"})
                status, answer = client.json("GET", "/v1/status", timeout=5)
                info["answers"] = status == 200
            except Unreachable as error:
                info["answers"] = False
                info["problem"] = str(error)
            print_json(info)
            return EXIT_OK if info["answers"] else EXIT_UNREACHABLE
        if args.action == "status":
            return finish(*client.json("GET", "/v1/status"))
        if args.action == "commands":
            query = []
            if args.query:
                query.append("query=" + quote(args.query))
            if args.group:
                query.append("group=" + quote(args.group))
            return finish(*client.json("GET", "/v1/commands" + ("?" + "&".join(query) if query else "")))
        if args.action == "describe":
            return finish(*client.json("GET", "/v1/commands/" + quote(args.name)))
        if args.action == "call":
            call_args = {}
            if args.json_args:
                call_args = parse_value(args.json_args)
                if not isinstance(call_args, dict):
                    log("The arguments must be a JSON object")
                    return EXIT_USAGE
            for pair in args.arg:
                if "=" not in pair:
                    log("--arg takes KEY=VALUE: %s" % pair)
                    return EXIT_USAGE
                key, value = pair.split("=", 1)
                call_args[key] = parse_value(value)
            body = {"command": args.name, "args": call_args, "wait": "done" if args.wait else "answer", "timeout_ms": args.timeout_ms}
            return finish(*client.json("POST", "/v1/invoke", body))
        if args.action == "jobs":
            return finish(*client.json("GET", "/v1/jobs"))
        if args.action == "job":
            return finish(*client.json("GET", "/v1/jobs/%s?wait_ms=%d" % (quote(args.id), args.wait_ms)))
        if args.action == "cancel":
            return finish(*client.json("POST", "/v1/jobs/%s/cancel" % quote(args.id), {}))
        if args.action == "settings":
            if args.patch:
                patch = parse_value(args.patch)
                if not isinstance(patch, dict):
                    log("The patch must be a JSON object")
                    return EXIT_USAGE
                return finish(*client.json("POST", "/v1/settings", {"patch": patch}))
            return finish(*client.json("GET", "/v1/settings"))
        if args.action == "limitations":
            return finish(*client.json("GET", "/v1/limitations"))
        if args.action == "events":
            after = args.after
            names = "&names=" + quote(args.names) if args.names else ""
            while True:
                wait = args.wait_ms if not args.follow else max(args.wait_ms, 25000)
                status, answer = client.json("GET", "/v1/events?after=%d&limit=%d&wait_ms=%d%s" % (after, args.limit, wait, names))
                if not args.follow:
                    return finish(status, answer)
                if status != 200:
                    return finish(status, answer)
                result = answer.get("result", {})
                for event in result.get("events", []):
                    write_message(sys.stdout, event)
                after = result.get("next_after", after)
    except Unreachable as error:
        log("nxplay-control: %s" % error)
        return EXIT_UNREACHABLE
    except KeyboardInterrupt:
        return EXIT_OK
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
