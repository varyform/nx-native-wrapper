# NX Play from Linux

`nxplay_remote.py` is a command-line client for the API that NX Play on the Mac serves to the iPhone & iPad App. You can use it from Linux, or from any computer with Python 3.9 or later. It needs only the standard library: no packages and no server.

It can:

- list the Mac's games with their Mac build state (not built, extracted, ready, kept)
- show what is installed on the chosen device, what was removed from it, and when an install expires
- list the iPhones and iPads the Mac reaches, and choose one
- ask the Mac to build a game signed with its team and install it on that device, then follow the job until it finishes

It does **not** run games, build them, compile shaders, or sign or install anything itself. All of that stays on the Mac, through nxnative, Xcode, Metal and `devicectl`, which only run on macOS. The Mac must be awake with NX Play open. Installs need a device that is paired with Xcode on the Mac, with Connect via network on.

## Setup

```sh
install -m 755 Linux/nxplay_remote.py ~/.local/bin/nxplay-remote
```

On the Mac, turn on NX Play › Settings › Devices › iPhone & iPad App. The Mac's address and pairing code are shown there.

```sh
nxplay-remote discover                 # optional: finds Macs over mDNS (needs avahi-browse, from avahi-utils)
nxplay-remote pair studio-mac.local    # prompts for the pairing code, so it stays out of ps and shell history
nxplay-remote devices
nxplay-remote use-device "Jess's iPhone"
nxplay-remote games
nxplay-remote install "Celeste"        # folder name, game name, title ID, or a unique part of the name
```

On Linux, `.local` names resolve only with mDNS (`avahi-daemon` and `nss-mdns`). Without mDNS, pair with the Mac's IP address. The `--json` option prints the Mac's own answers, for use in scripts.

## Exit status

| Code | Meaning |
|---|---|
| 0 | Done |
| 1 | The Mac refused (busy, no game files, a device it can't reach) or answered in a way the client doesn't recognise |
| 2 | Usage or setup error (not paired, no device chosen, unknown game) |
| 3 | The Mac can't be reached (name not found, nothing listening, no answer) |
| 4 | Wrong pairing code (for example, after **New Code** on the Mac) |
| 5 | The install job failed or was cancelled; its last log lines are printed |
| 130 | You stopped watching with Ctrl-C; the Mac carries on with the install |

## Security

- Settings are saved in `$XDG_CONFIG_HOME/nxplay/remote.json` (by default `~/.config/nxplay/remote.json`), with mode 0600 in a 0700 folder. `NXPLAY_CODE` overrides the saved code. The saved code is sent only to the host and port where it was paired.
- The client follows no redirects and uses no proxies, so the code goes only to the Mac. Answers are limited to 8 MiB.
- NX Play's server uses plain HTTP on the local network, the same as the iPhone app. Anyone who can watch that network can read the pairing code. Use it only on a network you trust. **New Code** on the Mac locks out old codes.

## Tests

```sh
python3 -m unittest discover -s Linux -v
```

The tests run against a fake server on 127.0.0.1. The fake copies the routes, pairing check and error answers of `Packages/NXPlayKit/Sources/NXPlayKit/Library+Remote.swift`, with made-up games and devices.
