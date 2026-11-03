# Repository catalogs

A **source** in NX Play (Tools › Sources…) is a catalog of your own game files on a server you run: a NAS, a home server or any static web server. NX Play lists the games, downloads the files you pick into your games folder, and checks each file's size and checksum (SHA-256, or the SHA-1 an archive publishes) against the catalog before the library sees it. NX Play comes with no sources and knows no sites. The catalog is plain data with nothing in it that runs.

## Make a catalog

```sh
python3 Catalog/nxplay_catalog.py generate /Volumes/Shelf/switch -o /Volumes/Shelf/switch/catalog.json
python3 Catalog/nxplay_catalog.py check /Volumes/Shelf/switch/catalog.json
```

`generate` lists the NSP, NSZ, XCI and XCZ files under the folder. It reads each file's title ID and version from its name (`Game [0100000000010000][v0].nsp`), works out its SHA-256 and size, and groups updates (title IDs ending in `800`) and DLC with their base game. Hidden files, links, archives and files without a `[title ID]` are left out, and each one is reported on stderr. File addresses are relative to the folder, so save the catalog inside it and serve the folder as it is, or pass `--base-url https://nas.example/switch/`. Run `generate` again after you add files. `check` reads a catalog the way NX Play does and lists what NX Play would leave out. The script needs only the Python standard library (3.9 or later).

## Serve it

Any server that answers a plain GET works:

- On the local network: `python3 -m http.server 8080 --directory /Volumes/Shelf/switch`. The source is then `http://<mac-or-nas>.local:8080/catalog.json`.
- Anywhere else: https, for example with Caddy or nginx in front of the folder.

Plain http works only on the local network: a `.local` name, a name without dots, `localhost`, or a loopback, private or link-local IP address (`127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `::1`, `fc00::/7`, `fe80::/10`, and those IPv4 ranges mapped into IPv6). Any other address, a public IP address included, needs https, and a redirect from https to plain http is refused. Addresses written as bare numbers other than a plain dotted IPv4 address (`http://16843009/`, `http://0x7f.1/`, `http://010.0.0.1/`) are refused too.

**Access token.** If the server asks for one, enter it when you add the source. NX Play keeps it in your login Keychain (service `com.varyform.nxplay.repository`), never in its settings or a log. It sends it as `Authorization: Bearer <token>` only to the catalog's own origin (scheme, host and port). A file hosted on another server, or a redirect to another origin, gets no token. When the catalog's address redirects, relative file addresses resolve against where the catalog was finally read from, and the token still goes only to the origin of the address you added. If the Keychain refuses to save, read or delete a token, NX Play says so: the source isn't added, the old token is kept, or the source shows the error and Access Token… can save it again. It never sends a request without a token it couldn't read. Addresses with a user name and password in them (`https://me:pw@…`), or with a query parameter that looks like a credential (`?token=`, `?key=`, `?sig=`…), are refused, since the address is saved in NX Play's settings.

## Format

```json
{
  "nxplayCatalog": 1,
  "name": "Shelf",
  "entries": [
    {
      "id": "sample-game-one",
      "name": "Sample Game One",
      "titleID": "0100000000010000",
      "version": "1.0.1",
      "publisher": "Example Studio",
      "description": "Text shown with the game.",
      "packages": [
        {
          "kind": "base",
          "filename": "Sample Game One [0100000000010000][v0].nsp",
          "url": "files/Sample%20Game%20One%20%5B0100000000010000%5D%5Bv0%5D.nsp",
          "bytes": 1048576,
          "sha256": "<64 hex digits>",
          "titleID": "0100000000010000",
          "version": 0
        }
      ]
    }
  ]
}
```

[`example-catalog.json`](example-catalog.json) is a complete synthetic example with a base game, an update and a DLC. Its checksums are placeholders.

| Field | Required | |
| --- | --- | --- |
| `nxplayCatalog` | yes | The format version: `1`. NX Play refuses any other. |
| `name` | no | The catalog's own name. |
| `entries[].titleID` | yes | The base game's title ID, 16 hex digits. |
| `entries[].name` | yes | The game's name. It also names the game's folder (`Name [TITLEID]`) unless the library already has the game. |
| `entries[].id` | no | 1 to 64 letters, digits, `.`, `_` or `-`, unique in the catalog. Defaults to the title ID. |
| `entries[].version`, `publisher`, `description` | no | Shown with the game. |
| `packages[].kind` | yes | `base`, `update` or `dlc`. |
| `packages[].filename` | yes | The file's name in the game's folder. Plain name only (no folders, no `..`, not hidden), and an `.nsp`, `.nsz`, `.xci` or `.xcz` file. |
| `packages[].url` | yes | Where the file is, http(s), relative to the catalog's address (after any redirect) or absolute. |
| `packages[].bytes` | yes | The exact size, a whole number. |
| `packages[].sha256` | one of the two | The file's SHA-256, 64 hex digits. `generate` always writes it. |
| `packages[].sha1` | one of the two | The file's SHA-1, 40 hex digits, for a file whose host publishes only that (the Internet Archive does). Used only when there's no `sha256`. |
| `packages[].titleID`, `version` | no | The package's own title ID and title version (65536 for an update to 1.0.1…). |

**Checksums.** Each package needs a `sha256` or a `sha1`. With both, the SHA-256 is the one checked, and the SHA-1 must still be 40 hex digits. A field that's there but isn't the right number of hex digits leaves the package out: NX Play never falls back to the other one, and never downloads a file without a checksum it can check (an `md5` alone isn't one). NX Play shows the algorithm with each file, on the Mac and on the iPhone or iPad. SHA-1 shows that a file arrived whole and is the file the catalog lists. It isn't collision-resistant, so it doesn't show who made the file or that it is safe: trust the catalog itself as much as you trust where it came from. NX Play versions from before SHA-1 leave a SHA-1-only package out, as having no `sha256`.

A bad entry or package doesn't take the rest of the catalog with it. NX Play leaves it out and shows why under the source. An entry with more than 2,000 packages is left out. A catalog larger than 16 MB, or with more than 50,000 entries or 200,000 packages in all, is refused whole. NX Play reads a catalog in the background, so a big one doesn't hold up the app.

**Archives** (`.zip`, `.7z`, `.rar`…) are refused before anything is downloaded. What's inside an archive can't be checked until it is unpacked, and unpacking it would put unchecked files in your library. Host the game file itself.

## What a download does

1. It checks there's room on the games folder's volume for the files plus 2 GB to spare. It refuses a file that's already downloading, and it allows 20 downloads waiting at most.
2. It streams each file into `.nxplay-downloads/<id>/` inside the games folder. That folder is hidden, so the library doesn't see a half-written game, and it's on the same volume, so publishing is a rename. The checksum, by the algorithm the catalog names, is worked out as the bytes arrive. Only an HTTP 200 counts. A size that differs from the catalog stops the download at once, and so does a server sending more bytes than the catalog says.
3. Once every file's size and checksum match, it moves the files into the game's folder. That's the library's own folder for the game when it has it, built or not: found by the build's title ID, a `[TITLEID]` in the folder's name, or a game file's name in it (`Game [0100000000010000][v0].nsp`; an update's or DLC's title ID counts for its base game). Otherwise it's the folder another download of the game is going to or went to, otherwise a new `Name [TITLEID]` folder. So an update or DLC goes beside its base game, even from another catalog that names the game differently. A file already there is never replaced, and a link where a folder should be is refused.
4. The library looks again and shows the game, ready to build. Installing it on a device is the usual Install, when you choose it.

Downloads run one at a time. Cancel deletes the partial file. Retry starts again with the source's current catalog. Files that download already put in the game's folder count as done, if they are still the very files it put there and their bytes still match their checksum, read again by its own algorithm. Anything else in a file's place (your own file, a folder, a link) is left as it is, and the download stays failed until you move it out of the way. The status of each download is kept across launches in `~/Library/Application Support/NX Play/Repositories/downloads.json`, without addresses or tokens. A download cut short by quitting shows as failed, and its staging folder is cleared on the next launch.

## iPhone and iPad

NX Play on an iPhone or iPad browses the Mac's sources through the paired API (Settings › Devices on the Mac) and asks the Mac to download a game. The phone shows the download's progress and can cancel or retry it. Once the game is in the Mac's games folder, **Install…** opens its sheet in the library, and Install there builds and installs it as for any other game. Sources are added and removed only on the Mac.

| Request | |
| --- | --- |
| `GET /v1/sources` | The sources, each with its catalog's state, and its entry and problem counts. |
| `POST /v1/sources/refresh[?source=<id>]` | Reads the catalogs again. |
| `GET /v1/sources/<id>/entries[?q=<words>]` | A source's games, with each file's `present`, `download` and `checksum` (`sha256` or `sha1`: the algorithm it's checked by). A file's `id` is its SHA-256, or `sha1:<hex>`. |
| `GET /v1/downloads` | The downloads: state, `bytesDone`/`totalBytes`, `message`, and `libraryGame` once there is one. |
| `POST /v1/downloads?source=<id>&entry=<id>[&packages=<file id>,…]` | Queues a download (202). Answers 409 if it's already there or already downloading, 507 if there's not enough room, 429 if too many are waiting. |
| `POST /v1/downloads/<id>/cancel`, `…/retry` | |

Every request needs the pairing code (`Authorization: Bearer <code>`), as the rest of the API does.
