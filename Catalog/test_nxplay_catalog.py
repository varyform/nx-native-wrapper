"""Tests for nxplay_catalog.py, on made-up files (python3 -m unittest discover -s Catalog)."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nxplay_catalog  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))


class GenerateTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="nxplay-catalog-")
        self.files = {}

    def tearDown(self):
        for directory, subdirs, files in os.walk(self.folder, topdown=False):
            for name in files:
                os.unlink(os.path.join(directory, name))
            for name in subdirs:
                path = os.path.join(directory, name)
                os.unlink(path) if os.path.islink(path) else os.rmdir(path)
        os.rmdir(self.folder)

    def put(self, relative, data):
        path = os.path.join(self.folder, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)
        self.files[relative] = data

    def test_groups_updates_and_dlc_with_their_base_game(self):
        self.put("Sample [0100000000010000][v0].nsp", b"base" * 100)
        self.put("updates/Sample [0100000000010800][v65536].nsp", b"update" * 10)
        self.put("Sample Extra [0100000000011001][v0].nsz", b"dlc")
        self.put("Other (Rev 1) [0100000000020000].xci", b"other")
        skipped = []
        catalog = nxplay_catalog.generate(self.folder, name="Shelf", warn=skipped.append)
        self.assertEqual(catalog["nxplayCatalog"], 1)
        self.assertEqual(catalog["name"], "Shelf")
        self.assertEqual([e["name"] for e in catalog["entries"]], ["Other", "Sample"])
        sample = catalog["entries"][1]
        self.assertEqual(sample["titleID"], "0100000000010000")
        self.assertEqual(sample["version"], "v65536")
        self.assertEqual([p["kind"] for p in sample["packages"]], ["base", "update", "dlc"])
        update = sample["packages"][1]
        self.assertEqual(update["url"], "updates/Sample%20%5B0100000000010800%5D%5Bv65536%5D.nsp")
        self.assertEqual(update["bytes"], 60)
        self.assertEqual(update["sha256"], hashlib.sha256(b"update" * 10).hexdigest())
        self.assertEqual(update["version"], 65536)
        self.assertEqual(skipped, [])
        self.assertEqual(nxplay_catalog.check(catalog, "https://nas.example/shelf/catalog.json"), [])

    def test_base_url_makes_absolute_addresses(self):
        self.put("A [0100000000010000].nsp", b"a")
        catalog = nxplay_catalog.generate(self.folder, base_url="https://nas.example/games/", warn=lambda m: None)
        url = catalog["entries"][0]["packages"][0]["url"]
        self.assertEqual(url, "https://nas.example/games/A%20%5B0100000000010000%5D.nsp")

    def test_leaves_out_archives_hidden_files_links_and_untitled_files(self):
        self.put("Game [0100000000010000].zip", b"zip")
        self.put(".Hidden [0100000000010000].nsp", b"h")
        self.put("No title.nsp", b"n")
        self.put("notes.txt", b"t")
        os.symlink("/etc/hosts", os.path.join(self.folder, "Link [0100000000030000].nsp"))
        skipped = []
        catalog = nxplay_catalog.generate(self.folder, warn=skipped.append)
        self.assertEqual(catalog["entries"], [])
        text = "\n".join(skipped)
        self.assertIn("archive", text)
        self.assertIn("no [title ID]", text)
        self.assertIn("a link", text)
        self.assertIn("isn't an NSP", text)
        self.assertNotIn("Hidden", text)

    def test_the_command_writes_the_catalog_and_checks_it(self):
        self.put("A [0100000000010000].nsp", b"a")
        output = os.path.join(self.folder, "catalog.json")
        script = os.path.join(HERE, "nxplay_catalog.py")
        made = subprocess.run([sys.executable, "-I", script, "generate", self.folder, "-o", output],
                              capture_output=True, text=True)
        self.assertEqual(made.returncode, 0, made.stderr)
        checked = subprocess.run([sys.executable, "-I", script, "check", output], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        with open(output, encoding="utf-8") as handle:
            self.assertNotIn("catalog.json", json.dumps(json.load(handle)))


class CheckTests(unittest.TestCase):
    def test_the_documented_example_is_clean(self):
        with open(os.path.join(HERE, "example-catalog.json"), encoding="utf-8") as handle:
            catalog = json.load(handle)
        self.assertEqual(nxplay_catalog.check(catalog, "https://nas.example/games/catalog.json"), [])

    def test_lists_what_nx_play_would_leave_out(self):
        good = {"kind": "base", "filename": "A.nsp", "url": "A.nsp", "bytes": 1, "sha256": "a" * 64}
        catalog = {"nxplayCatalog": 1, "entries": [
            {"name": "A", "titleID": "0100000000010000", "packages": [
                good,
                dict(good, filename="../B.nsp", sha256="b" * 64),
                dict(good, filename="C.zip", sha256="c" * 64),
                dict(good, filename="D.nsp", sha256="d" * 64, url="http://files.example.com/D.nsp"),
                dict(good, filename="E.nsp", sha256="e" * 64, bytes=1.5),
                dict(good, filename="F.nsp"),
            ]},
            {"name": "A again", "titleID": "0100000000010000", "packages": [good]},
            {"name": "", "titleID": "0100000000020000", "packages": [good]},
        ]}
        problems = nxplay_catalog.check(catalog, "https://nas.example/catalog.json")
        text = "\n".join(problems)
        self.assertEqual(len(problems), 7, text)
        for expected in ("folder", "archive", "plain http", "whole number", "same name or file", "second entry",
                         "no \"name\""):
            self.assertIn(expected, text)

    def test_plain_http_only_to_local_addresses_as_nx_play_decides(self):
        # the same lists as RepositoryTests.addressesAreHTTPSOrTheLocalNetworkWithoutSecretsInThem
        local = ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.0.10", "169.254.1.1", "[::1]",
                 "[fc00::1]", "[fd12:3456::1]", "[fe80::1]", "[fe80::1%25en0]", "[::ffff:192.168.1.2]", "localhost",
                 "nas.local.", "nas.local", "nas"]
        remote = ["8.8.8.8", "1.1.1.1", "172.32.0.1", "100.64.0.1", "0.0.0.0", "[2606:4700:4700::1111]",
                  "[::ffff:8.8.8.8]", "[64:ff9b::808:808]", "[fec0::1]", "[::]", "16843009", "0x7f000001", "010.0.0.1",
                  "127.1", "games.example.com"]
        for host in local:
            self.assertIsNone(nxplay_catalog.url_problem("http://%s/A.nsp" % host, ""), host)
        for host in remote:
            self.assertIsNotNone(nxplay_catalog.url_problem("http://%s/A.nsp" % host, ""), host)
            self.assertIsNone(nxplay_catalog.url_problem("https://%s/A.nsp" % host, ""), host)

    def test_bounds_the_files_in_an_entry_and_the_catalog(self):
        package = {"kind": "dlc", "filename": "A.nsp", "url": "A.nsp", "bytes": 1, "sha256": "a" * 64}
        big = {"name": "Big", "titleID": "0100000000010000",
               "packages": [package] * (nxplay_catalog.MAX_PACKAGES_PER_ENTRY + 1)}
        problems = nxplay_catalog.check({"nxplayCatalog": 1, "entries": [big]})
        self.assertEqual(len(problems), 1)
        self.assertIn("more than 2000 packages", problems[0])
        many = dict(big, packages=[package] * nxplay_catalog.MAX_PACKAGES_PER_ENTRY)
        count = nxplay_catalog.MAX_PACKAGES // nxplay_catalog.MAX_PACKAGES_PER_ENTRY + 1
        with self.assertRaises(ValueError):
            nxplay_catalog.check({"nxplayCatalog": 1, "entries": [many] * count})

    def test_a_published_sha1_stands_in_for_a_sha256_but_never_a_bad_one(self):
        good = {"kind": "base", "filename": "A.nsp", "url": "A.nsp", "bytes": 1, "sha1": "a" * 40}
        catalog = {"nxplayCatalog": 1, "entries": [{"name": "A", "titleID": "0100000000010000", "packages": [
            good,
            dict(good, filename="B.nsp", sha1="b" * 40, sha256="b" * 64),
            dict(good, filename="C.nsp", sha1="c" * 39),
            dict(good, filename="D.nsp", sha1="d" * 64),
            dict(good, filename="E.nsp", sha1="e" * 40, sha256="xyz"),
            dict({k: v for k, v in good.items() if k != "sha1"}, filename="F.nsp", md5="f" * 32),
            dict(good, filename="G.nsp", sha1="\uff11" * 40),
        ]}]}
        problems = nxplay_catalog.check(catalog)
        self.assertEqual(len(problems), 5, problems)
        self.assertIn("\"sha1\" isn't 40 hex digits", problems[0])
        self.assertIn("\"sha1\" isn't 40 hex digits", problems[1])
        self.assertIn("\"sha256\" isn't 64 hex digits", problems[2])
        self.assertIn("no \"sha256\" or \"sha1\"", problems[3])
        self.assertIn("\"sha1\" isn't 40 hex digits", problems[4])

    def test_refuses_another_format(self):
        with self.assertRaises(ValueError):
            nxplay_catalog.check({"nxplayCatalog": 2, "entries": []})


if __name__ == "__main__":
    unittest.main()
