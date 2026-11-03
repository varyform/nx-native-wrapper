#!/usr/bin/env python3
"""Make or check an NX Play repository catalog (Catalog/README.md has the format).

  nxplay_catalog.py generate <folder> [--name NAME] [--base-url URL] [-o catalog.json]
  nxplay_catalog.py check <catalog.json>

generate lists the NSP, NSZ, XCI and XCZ files under <folder> (hidden files, links and archives are left out),
reads each one's title ID and version from its name ("Game [0100000000010000][v0].nsp"), works out its SHA-256 and
size, and groups updates and DLC with their base game. Without --base-url, the file addresses are relative to
<folder>: save the catalog in <folder> and serve the folder as it is. check reads a catalog the way NX Play does
(a package's "sha256", else the "sha1" an archive publishes) and lists what it would leave out. Only the standard library; Python 3.9 or later.
"""

import argparse
import hashlib
import ipaddress
import json
import os
import re
import socket
import sys
import urllib.parse

FORMAT = 1
GAME_EXTENSIONS = {"nsp", "nsz", "xci", "xcz"}
ARCHIVE_EXTENSIONS = {"zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst", "lz4", "001"}
MAX_PACKAGE_BYTES = 64 * 1024 ** 3
MAX_ENTRIES = 50000
MAX_PACKAGES_PER_ENTRY = 2000
MAX_PACKAGES = 200000
# Where plain http may go (RepositoryAddress.isLocal): loopback, private and link-local addresses.
LOCAL_NETWORKS = [ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
    "::1/128", "fc00::/7", "fe80::/10")]
TITLE_RE = re.compile(r"\[([0-9A-Fa-f]{16})\]")
VERSION_RE = re.compile(r"\[v(\d+)\]")
HEX16 = re.compile(r"[0-9A-Fa-f]{16}")
# The checksums NX Play checks a file against (Checksum.swift), by their hex length: a "sha256" when a package has one,
# else its "sha1".
CHECKSUMS = (("sha256", 64), ("sha1", 40))
ID_RE = re.compile(r"[A-Za-z0-9._-]{1,64}")


def filename_problem(name):
    """Why NX Play would refuse `name` as a file in a game's folder (CatalogPackage.filenameProblem), or None."""
    if not name or len(name.encode("utf-8")) > 200:
        return "the filename is empty or too long"
    if "/" in name or "\\" in name or ":" in name:
        return name + ": the filename has a folder in it"
    if name.startswith("."):
        return name + ": the filename is hidden"
    if any(ord(c) < 32 or ord(c) == 127 for c in name):
        return "the filename has control characters"
    if name != name.strip(" "):
        return name + ": the filename starts or ends with a space"
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if ext in ARCHIVE_EXTENSIONS:
        return name + " is an archive: NX Play downloads only NSP, NSZ, XCI or XCZ files"
    if ext not in GAME_EXTENSIONS:
        return name + " isn't an NSP, NSZ, XCI or XCZ file"
    return None


def kind_of(title_id):
    """base, update or dlc, and the base game's title ID, from a title ID's last digits."""
    value = int(title_id, 16)
    low = value & 0xFFF
    if low == 0:
        return "base", "%016X" % value
    if low == 0x800:
        return "update", "%016X" % (value & ~0xFFF)
    return "dlc", "%016X" % ((value & ~0xFFF) - 0x1000)


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(8 * 1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def checksum_of(package):
    """The (algorithm, lowercased hex) NX Play checks the package against, or a problem string. Every checksum field
    present must be well formed; the first of sha256, sha1 is the one used."""
    found = []
    for algorithm, digits in CHECKSUMS:
        if algorithm in package:
            value = package[algorithm]
            if not isinstance(value, str) or not re.fullmatch("[0-9A-Fa-f]{%d}" % digits, value):
                return "\"%s\" isn't %d hex digits" % (algorithm, digits)
            found.append((algorithm, value.lower()))
    if not found:
        return "no \"sha256\" or \"sha1\" checksum"
    return found[0]


def display_name(filename):
    stem = filename.rsplit(".", 1)[0]
    stem = re.sub(r"\[[^\]]*\]|\([^)]*\)", " ", stem)
    return " ".join(stem.split())


def generate(folder, name="", base_url="", warn=None):
    """The catalog for the game files under `folder`, as a dict; `warn` hears each file left out."""
    warn = warn or (lambda message: print("skipped: " + message, file=sys.stderr))
    folder = os.path.abspath(folder)
    entries = {}
    for directory, subdirs, files in os.walk(folder, followlinks=False):
        subdirs[:] = sorted(d for d in subdirs if not d.startswith("."))
        for filename in sorted(files):
            path = os.path.join(directory, filename)
            relative = os.path.relpath(path, folder)
            if filename.startswith("."):
                continue
            if os.path.islink(path) or not os.path.isfile(path):
                warn(relative + ": a link or not a file")
                continue
            problem = filename_problem(filename)
            if problem:
                warn(relative + ": " + problem)
                continue
            match = TITLE_RE.search(filename)
            if not match:
                warn(relative + ": no [title ID] in its name")
                continue
            title_id = match.group(1).upper()
            kind, base_id = kind_of(title_id)
            size = os.path.getsize(path)
            if size <= 0 or size > MAX_PACKAGE_BYTES:
                warn(relative + ": empty or too large")
                continue
            quoted = urllib.parse.quote(relative.replace(os.sep, "/"))
            url = base_url.rstrip("/") + "/" + quoted if base_url else quoted
            package = {
                "kind": kind,
                "filename": filename,
                "url": url,
                "bytes": size,
                "sha256": sha256_of(path),
                "titleID": title_id,
            }
            version = VERSION_RE.search(filename)
            if version:
                package["version"] = int(version.group(1))
            entry = entries.setdefault(base_id, {"titleID": base_id, "packages": [], "names": {}})
            if any(p["filename"].lower() == filename.lower() for p in entry["packages"]):
                warn(relative + ": another file of this game has the same name")
                continue
            if any(p["sha256"] == package["sha256"] for p in entry["packages"]):
                warn(relative + ": the same file as another one of this game")
                continue
            entry["packages"].append(package)
            entry["names"].setdefault(kind, display_name(filename))
    result = []
    order = {"base": 0, "update": 1, "dlc": 2}
    for base_id, entry in entries.items():
        names = entry.pop("names")
        entry["id"] = base_id
        entry["name"] = names.get("base") or names.get("update") or names.get("dlc") or base_id
        entry["packages"].sort(key=lambda p: (order[p["kind"]], p.get("version", 0), p["filename"]))
        updates = [p.get("version", 0) for p in entry["packages"] if p["kind"] == "update"]
        if updates:
            entry["version"] = "v%d" % max(updates)
        result.append({key: entry[key] for key in ("id", "name", "titleID", "version", "packages") if key in entry})
    result.sort(key=lambda e: (e["name"].lower(), e["titleID"]))
    return {"nxplayCatalog": FORMAT, "name": name or os.path.basename(folder), "entries": result}


def is_local(host):
    """Whether plain http may go to `host`, as RepositoryAddress.isLocal decides: an IP address only when it's
    loopback, private or link-local (an IPv4 address mapped into v6 by the v4 rules), then a .local name, a name
    without dots or localhost. Numbers that aren't a plain dotted IPv4 address (16843009, 0x7f.1) are refused."""
    host = host.lower()
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    if host.endswith("."):
        host = host[:-1]
    if ":" in host:
        try:
            address = ipaddress.IPv6Address(host.split("%", 1)[0])
        except ValueError:
            return False
        if address.ipv4_mapped is not None:
            address = address.ipv4_mapped
        return any(address in network for network in LOCAL_NETWORKS)
    try:
        address = ipaddress.IPv4Address(host)
    except ValueError:
        address = None
    if address is not None:
        return any(address in network for network in LOCAL_NETWORKS)
    try:
        socket.inet_aton(host)
        return False
    except (OSError, ValueError):
        pass
    return host == "localhost" or host.endswith(".local") or (bool(host) and "." not in host)


def url_problem(url, base):
    """NX Play's RepositoryAddress rules for a package's address, relative ones against `base`."""
    full = urllib.parse.urljoin(base, url) if base else url
    parts = urllib.parse.urlsplit(full)
    if parts.scheme not in ("http", "https"):
        return "only http and https addresses work" if base or parts.scheme else None
    if not parts.hostname:
        return "the address has no host"
    if parts.username or parts.password:
        return "no user name or password in the address"
    if parts.scheme == "http" and not is_local(parts.hostname):
        return "plain http works only on the local network"
    return None


def check(catalog, base=""):
    """What NX Play would leave out of `catalog` (a dict), one line each; raises ValueError when it refuses all of it."""
    if not isinstance(catalog, dict) or catalog.get("nxplayCatalog") != FORMAT:
        raise ValueError("not an NX Play catalog of format %d" % FORMAT)
    entries = catalog.get("entries")
    if not isinstance(entries, list):
        raise ValueError("no \"entries\" list")
    if len(entries) > MAX_ENTRIES:
        raise ValueError("more than %d entries" % MAX_ENTRIES)
    total = sum(len(e["packages"]) for e in entries if isinstance(e, dict) and isinstance(e.get("packages"), list))
    if total > MAX_PACKAGES:
        raise ValueError("more than %d files" % MAX_PACKAGES)
    problems = []
    seen = set()
    for index, entry in enumerate(entries, 1):
        where = "Entry %d" % index
        if not isinstance(entry, dict):
            problems.append(where + ": not an object")
            continue
        title_id = entry.get("titleID")
        if not isinstance(title_id, str) or not HEX16.fullmatch(title_id):
            problems.append(where + ": no 16-digit hex \"titleID\"")
            continue
        if not str(entry.get("name") or "").strip():
            problems.append(where + ": no \"name\"")
            continue
        entry_id = entry.get("id", title_id.upper())
        if not isinstance(entry_id, str) or not ID_RE.fullmatch(entry_id):
            problems.append(where + ": the id isn't 1 to 64 letters, digits, . _ or -")
            continue
        if entry_id.lower() in seen:
            problems.append(where + ": a second entry with id " + entry_id)
            continue
        packages = entry.get("packages")
        if not isinstance(packages, list) or not packages:
            problems.append(where + ": no \"packages\"")
            continue
        if len(packages) > MAX_PACKAGES_PER_ENTRY:
            problems.append(where + ": more than %d packages" % MAX_PACKAGES_PER_ENTRY)
            continue
        good = 0
        names, hashes = set(), set()
        for number, package in enumerate(packages, 1):
            spot = "%s, package %d" % (where, number)
            if not isinstance(package, dict):
                problems.append(spot + ": not an object")
                continue
            if package.get("kind") not in ("base", "update", "dlc"):
                problems.append(spot + ": \"kind\" isn't base, update or dlc")
                continue
            filename = package.get("filename")
            problem = filename_problem(filename) if isinstance(filename, str) else "no \"filename\""
            if problem:
                problems.append(spot + ": " + problem)
                continue
            url = package.get("url")
            problem = url_problem(url, base) if isinstance(url, str) and url else "no \"url\""
            if problem:
                problems.append(spot + ": " + problem)
                continue
            size = package.get("bytes")
            if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= MAX_PACKAGE_BYTES:
                problems.append(spot + ": \"bytes\" isn't a whole number of bytes")
                continue
            checksum = checksum_of(package)
            if isinstance(checksum, str):
                problems.append(spot + ": " + checksum)
                continue
            digest = "%s:%s" % checksum
            package_tid = package.get("titleID")
            if package_tid is not None and (not isinstance(package_tid, str) or not HEX16.fullmatch(package_tid)):
                problems.append(spot + ": \"titleID\" isn't 16 hex digits")
                continue
            if filename.lower() in names or digest.lower() in hashes:
                problems.append(spot + ": the same name or file as another package")
                continue
            names.add(filename.lower())
            hashes.add(digest.lower())
            good += 1
        if good:
            seen.add(entry_id.lower())
        else:
            problems.append(where + ": no usable package")
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description="Make or check an NX Play repository catalog.")
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("generate", help="list the game files under a folder")
    make.add_argument("folder")
    make.add_argument("--name", default="", help="the catalog's name (the folder's, without it)")
    make.add_argument("--base-url", default="", help="where the folder is served (relative addresses without it)")
    make.add_argument("-o", "--output", help="the catalog file to write (standard output without it)")
    verify = commands.add_parser("check", help="read a catalog as NX Play does")
    verify.add_argument("catalog")
    verify.add_argument("--base-url", default="", help="the catalog's own address, for relative file addresses")
    args = parser.parse_args(argv)

    if args.command == "generate":
        if not os.path.isdir(args.folder):
            print("nxplay_catalog: no folder " + args.folder, file=sys.stderr)
            return 2
        catalog = generate(args.folder, args.name, args.base_url)
        text = json.dumps(catalog, indent=2, ensure_ascii=False) + "\n"
        if args.output:
            temporary = args.output + ".tmp"
            with open(temporary, "w", encoding="utf-8") as handle:
                handle.write(text)
            os.replace(temporary, args.output)
            count = sum(len(e["packages"]) for e in catalog["entries"])
            print("%d games, %d files: %s" % (len(catalog["entries"]), count, args.output), file=sys.stderr)
        else:
            sys.stdout.write(text)
        return 0

    try:
        with open(args.catalog, encoding="utf-8") as handle:
            catalog = json.load(handle)
        problems = check(catalog, args.base_url)
    except (OSError, ValueError) as error:
        print("nxplay_catalog: " + str(error), file=sys.stderr)
        return 1
    for problem in problems:
        print(problem)
    entries = len(catalog.get("entries", []))
    print("%d entries, %d problems" % (entries, len(problems)), file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
