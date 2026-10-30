# Changelog

User-visible changes to NX Play, `nxplay` and the setup. The format follows [Keep a Changelog](https://keepachangelog.com).

## Unreleased

### Added

- **Game settings, for all games and for each one:** the settings nxnative offers for each game, with the defaults it was tested with. Depending on the game: frame rate, render scale, docked or handheld, upscaling, language, window or full screen, rumble, and performance switches such as frame buffering and Metal 4 pipelines.
  - **Settings › Games** sets the values every game gets unless it has its own. It replaces the Playing tab: its language, full screen and HUD settings carry over, and the controllers are there too.
  - **Game › Game Settings…** (⌥⌘,) has one game's list, including settings only some games have, such as frame rate and render scale. Each one follows the global value until you change it.
  - Both look like the game's own settings window: switches, sliders with their percentage, and menus. The basic settings come first, the rest under Advanced settings. A changed value is tinted and has its own reset button.
  - A game that doesn't offer a global value keeps its tested default, and a game without the global language plays its regional twin. Settings apply at the game's next start, and the log lists the ones it used.
  - The game's Mac app shares a game's own values, so its settings window shows the same choices.
  - `nxplay` writes each game's list after a build, and NX Play asks it for any game still missing one. `nxplay --settings` writes the list for a game already built. A setting can also be given for one start: `DM_FPS_TARGET=30 nxplay <game folder>`.

- **Updates in Console Mode:** when an update is ready, a small "Update 1.8 ready" pill sits beside the logo in the top bar, and the hints show which button opens it. It never takes the focus. Press Y (U on the keyboard) or click the pill to see what's new, then A for **Restart to Update** or B for later.

### Changed

- **A gentler update reminder:** an update that has been waiting for three days or more says since when, and that Restart to Update takes only a few seconds. This shows in the library's banner and in Console Mode's pill.

- **Updates that can't install say why:** NX Play run from the DMG or from Downloads can't replace itself. Until now it failed quietly in Settings › Updates. Now a banner above the library asks you to move it into Applications, with **Show in Finder** and **Dismiss**. Problems that pass on their own, such as being offline, still stay in Settings.

## 1.7.9 — 2026-10-30

### Added

- **Remove Game…** (Game menu, ⌘⌫) deletes a game for good: its game files, its build, its IPAs and its Mac app. Anything else you keep in its folder stays, and the folder goes once it's empty. Its saves stay unless you also tick **Also remove its saves** and say why: you have a backup, or you don't need them. Kept saves wait in the folder; put the game files back and the game plays on from them. To confirm, type the phrase it shows, one of a few picked at random.

- **Free Up Space removes builds** ([#5](https://github.com/varyform/nx-native-wrapper/issues/5)): each game's `<title ID>_build` folder is listed with its size, and the next Play builds it again from the game files. Its saves stay, and so does when you last played it. A game whose game files are gone keeps its build, since that's how it still plays, and so does a kept build; a game's build and its game files can't be deleted together. A build can hold half a million files, so the window now lists everything at once and measures the builds and Xcode builds in the background, four at a time, each with a spinner until its size is in. Sizes are remembered between launches and measured again only once a folder changes, so the window fills in at once the next time.

- **Several controllers, several players:** every connected controller now drives NX Play and Console Mode, not only the last one connected, each with its own held direction. Console Mode's top bar shows each controller with its player number and battery. **Settings › Playing › Controllers** lists them with the player each one is in a game and chooses how players are given out: each controller a player of its own with the keyboard on player 1 (nxnative's default), the keyboard player 1 on its own with the controllers from player 2, or every controller player 1. NX Play passes the choice to each game it starts (nxnative's `DM_PAD_MERGE` and `DM_KBD_PLAYER`), and lights each controller's player lights to match while NX Play is in front.

## 1.7.8 — 2026-10-30

### Added

- **Game details in Console Mode:** press down (or click the game's name) and the banner and name slide up to show the game's eShop description, its facts (publisher, release date, players, genre, age rating, version) and its screenshots across the screen. Down scrolls the description, then moves to the screenshots: left and right choose one, and A (or a click) shows it full screen. Left and right on the description move to the next game. Up at the top, B or Esc close the details. Screenshots download the first time a game's details open.

### Changed

- **A game getting ready says so:** in the few seconds before a game starts or rebuilds, while `nxplay` checks nxnative for updates, the game's badge reads "Preparing…" instead of "Running", and Console Mode's footer shows "Preparing <game>" with a moving bar and what `nxplay` is doing, such as "nxnative: up to date" or "nxnative updated: 3 new commits, rebuilding". The library's status bar shows the same.

- **Console Mode shows more of the eShop page:** the game's tagline under its name, and its publisher and release year next to its version. Its tiles, the library's cards and list, and Free Up Space use the eShop's own icon once it's downloaded; it's sharper than the one in the game's files.

- **NX Play opens in the mode you left it in:** quit it in Console Mode and it opens in Console Mode next time, at the game you played last. Quit it in the library and it opens there.

## 1.7.7 — 2026-10-29

### Added

- **Cloud saves:** Settings › Saves can sync each game's save through iCloud Drive or a folder you pick, so the game's iPhone app plays on from the same save. Pick the same folder in the iPhone app's Cloud saves. This is nxnative's own sync: each game keeps one file, `<title ID>/save.dmsync`, which the game brings in when it starts and sends a few seconds after each save. When both sides changed, the newer save wins and the other is kept in the save's backups. A game picks the setting up at its next play; a build made before nxnative had cloud saves gets it when it rebuilds. A save made in the last seconds before you quit goes up at the game's next start.

- **How far nxnative has got with a game:** the badge in the top-left corner of a game's artwork now tells three cases apart. A green check means nxnative lists the game as tested. An orange hammer means its profile is still in bring-up, and hovering shows how far it has got, such as "on the Mac 3D World reaches World 1-1". A grey question mark means nxnative has no profile and guesses one. **Game › nxnative Notes…** (⌥⌘I) shows what nxnative writes about the game: its stage, the regression check's last green run, and the opening of the profile's notes, with a link to the full notes on GitHub.

- **Your games' fixes:** when nxnative has changed a game's profile since the game was built, a blue badge shows how many commits, and hovering lists them. NX Play checks nxnative for new commits about once an hour, without changing your copy, so the badge shows before you play. The commits are also in nxnative Notes. When a play pulls nxnative's update, the log lists that game's commits on their own, under "for this game:".

- **Search games:** the toolbar's search field (Edit › Find Games…, ⌘F) narrows the grid and the list to the games with every word you type in their name, title ID or folder name. Console Mode still shows every game.

- **Game artwork in Console Mode:** the selected game's official eShop banner fills the upper half of the screen edge to edge and fades into a dark, blurred copy of the game's cover, which fills the rest of the screen behind the games. The game's name sits over the banner's foot, with its badges: its state, how far nxnative has got with it, nxnative's new commits for it, Kept, its version and when you last played it. Games without a banner show just the blurred cover. The games row starts at the left and scrolls only when the selection would leave the screen. A build, such as a game rebuilding before it plays, shows its game, stage and percentage in the bottom-left corner, whichever game is selected. NX Play downloads the banners it doesn't have yet in the background, at launch and when a game is added, starting with the game Console Mode opens on. Each banner shows as soon as it arrives, and opening Console Mode tries the missing ones again. It looks them up by title ID in the community database [blawar/titledb](https://github.com/blawar/titledb), the same source NX2Apple uses, and takes the images only from Nintendo's image server. The banners stay in `~/Library/Caches/com.varyform.nxplay/Banners`.

### Changed

- **Console Mode hides the mouse pointer** when it opens and whenever the controller or the arrow keys move through it. Moving the mouse brings the pointer back.

## 1.7.6 — 2026-10-29

### Added

- **Known games are marked:** a green check in the top-left corner of a game's artwork (in the list, beside its other badges) means nxnative has a game profile for it. A game without one is packed from a profile guessed from its files, and may not boot. Hovering over a badge (the check, the lock of a kept build, IPA, Xcode) explains it again; the game's own tooltip used to cover theirs.

- **The changelog in the app:** Help › NX Play Changelog lists every release. When an update is ready, **What's New** beside Restart to Update shows what it changes since your version, every release you skipped included. The running version shows it, so it first appears for the update after this one.

### Fixed

- **Games with zstd-compressed code build:** games made with system 22.0.0 or later, such as Well Dweller, can store their code compressed with Nintendo's variant of zstd (ZBIC). nxnative decodes it with the `zbic` Python package, which setup didn't install, so the build stopped at the first step. Setup installs it now. NX Play shows the Setup banner once after this update, until Setup has run and added the package. When nxnative starts using another package, each play now names it in the log, with the command that adds it, before a build stops on it.

### Changed

- **A new app icon:** the two Joy-Cons joined as one controller around a play button, instead of a console with a screen. The colors are the same.

- **Controllers with a generic name show their kind:** an Xbox controller on a USB cable, which calls itself just "Controller", now shows as "Xbox Controller" in Console Mode. A controller with a name of its own still shows that name.

- **A game started from Console Mode returns to Console Mode when it quits,** whether with ⌘Q or a crash. Before, macOS brought forward the app you'd used last on the desktop. Console Mode now covers the screen on the desktop, with the menu bar and Dock hidden, instead of opening a full-screen Space of its own. A game that quits hands the screen back to the desktop, where Console Mode is now waiting.

- **The build's counts are back:** the progress text shows them, such as "4/6 shader split · splitting · 211,200/304,243 files · 69% · 0:04 left". The log again gets a line with the count every 30 seconds while a long stage runs, as before the switch to JSON progress. Each field of the build script's events is checked, so a field a later nxnative drops or changes only leaves that part out.

## 1.7.5 — 2026-10-28

### Added

- **About NX Play** now shows the copyright, who makes NX Play, and links: GitHub, Releases, Report a Problem, nxnative and the MIT License.
- **Uninstall NX Play also removes NX Play from the Dock** when you'd kept it there, so no icon pointing at the Trash stays behind. The Dock restarts for a moment to pick up the change.

### Changed

- **A build no longer makes its card taller:** its progress shows as a thin bar along the bottom of the game's artwork, and the badge shows the percentage ("Extracting · 64%"). The stage is in the card's tooltip. In the list, the bar sits beside the badge, so the row stays one line.
- Cards are a little wider at their narrowest: 180 points instead of 168, so the badge and the button fit side by side more easily. Their artwork now lines up with the section title, with the selection highlight reaching into the margin as in Photos, and the gap between artworks is even.
- **The log starts hidden for new users:** the status bar shows what's building, and a failed build opens the log on its game. If you already use NX Play, the log stays as you left it.
- **A status bar while the log is hidden** shows what's building: the game, its stage, the time left and Cancel. With several builds, it shows how many, how many are waiting, and their average progress. Click it to select the game, or show the log from it.
- **Build progress comes from nxnative's front-end interface:** the build script's `--progress json` events ([docs/frontends.md](https://github.com/seedds/nxnative/blob/main/docs/frontends.md)). NX Play no longer reads the text it prints for people. The progress bar, the card and the Dock follow exact stage fractions, and now also show the time left in a stage. The log shows the same lines as before. In a terminal, `nxplay` still shows the build's bar.

### Fixed

- **Updates retry opening the downloaded DMG** when macOS's disk service is briefly busy ("Resource temporarily unavailable"), and keep trying to detach it, so no image stays mounted.

## 1.7.2 — 2026-10-28

### Fixed

- **Uninstall NX Play no longer fails over Homebrew tools other software needs.** Removing the tools stopped the whole uninstall when Homebrew refused to remove one that other formulae depend on, such as zstd, which llvm, node and python use. Uninstall now removes only the tools nothing else needs, one at a time. It lists the others under Kept, with what needs them, and finishes even if one can't be removed.

## 1.7.1 — 2026-10-28

### Added

- **Check for Updates…** in the NX Play menu checks now and opens Settings › Updates to show the result.

- **Uninstall NX Play…** (in the NX Play menu) removes everything NX Play put on the Mac: `~/Library/Application Support/NX Play` with what Setup installed, the settings, caches and saved window state. The app goes to the Trash. A checkbox also removes the Homebrew tools Setup installs; it's off by default, since other software may use them. Your games folder (with the games, their builds and their saves), `prod.keys`, the save backup repository and Homebrew stay. It lists each item with its size first, and waits until no game or build is running.

### Changed

- **Settings has tabs:** General, Playing, Saves, Devices and Updates. With everything on one page, the window was taller than a laptop screen, and Check Now ended up behind the Dock.

## 1.7 — 2026-10-28

### Added

- **Download and set up from the app:** NX Play comes as a signed, notarized DMG. On first launch **Setup** (NX Play › Setup…) checks the Mac and Xcode, and **Install Missing** installs the Metal Toolchain, Homebrew's tools, Python with nxnative's packages, and nxnative itself. Homebrew is the one thing to install by hand. What Setup installs, apart from Homebrew's tools, goes into `~/Library/Application Support/NX Play`. A copy built from the source keeps using the checkout, as before.
- **Automatic updates** for the downloaded app: NX Play checks GitHub for a new release at launch and once a day, then downloads its DMG and checks it: the checksum GitHub publishes, the developer's signature, and notarization. The update installs when you quit, or now with **Restart to Update** (Settings › Updates, or the banner), which waits until no game or build is running. Copies built from the source update with `git pull` and `bin/install`.
- **Save backup to a private Git repository** (Settings): pick a clone of your own repository. While a game plays, NX Play copies its save into a folder named after the game and its title ID each time the game saves, then commits and pushes. It does this once more when the game quits. If another Mac pushed in the meantime, its commits are pulled in first. Pushing uses your own Git credentials, and each backup shows in the log.

### Changed

- **`bin/install` replaces a running NX Play safely.** It used to swap the app out from under a running game or build. Now it asks NX Play to quit once nothing is running in it (games, builds, Free Up Space deletions, save transfers), waits until it has, installs, and reopens it. Ctrl-C while it waits cancels the install and leaves NX Play open. NX Play 1.6 and older don't respond, so quit those by hand once.

### Fixed

- **A build no longer plays against files another build rewrote.** Install on Device, Build IPA and Make Mac App build in the same folder as the Mac build, and rewrite its patched game code and shader tables with the nxnative they run. If one of them pulled an nxnative update, the next Play skipped the rebuild and started the old Mac host with the new files. `nxplay` now records the nxnative code each Mac build was made with, in `start_mac.sh`, and rebuilds when the checkout's differs, whichever run pulled it. Builds made before this change don't have that record yet and pick it up at their next rebuild.
- **Keep This Build protects the build from those other builds too.** While a game is kept, Install on Device, Build IPA and Make Mac App are disabled, and `nxplay --ipa`, `--mac-app` and `--device` refuse to run. Turn off Keep This Build to use them.
- Console Mode keeps the game tiles in the middle of the screen. They used to jump up whenever a build's progress bar appeared under the selected game.

## 1.6 — 2026-10-27

### Added

- **Keep This Build** (Game menu and right-click menu): keeps a game that works from being rebuilt when nxnative updates, since an update can break a game that played fine. A lock badge marks it on the icon, and `nxplay` plays the kept build as it is, saying it does so without the new nxnative changes. Rebuild (`nxplay --rebuild`) still replaces it. It's a `keep` file in `<title ID>_build`.
- **Console Mode starts at the game you played last:** the carousel lists games by when you last played them, newest first, then the ones you haven't played yet by name. Below the title it shows when you last played the selected game. `nxplay` records the time when a game starts and when it ends, in `<title ID>_build/run/last_played`, so plays from the Terminal count too.
- **Progress on the Dock icon:** a bar along the bottom of NX Play's icon while extractions, rebuilds, IPAs or installs run (their average when there are several). A **!** badge marks a build that failed while NX Play was in the background, until you open it again.
- **Allow a Metal compiler nxnative didn't test** (Settings, and `nxplay --allow-other-metal`). nxnative now stops every build when Xcode's Metal compiler isn't the version it tested its shaders with, and a newer Xcode than that is common. The setting is off by default, as nxnative's. When a build stops for this reason, NX Play points to the setting, and `bin/setup --check` reports the mismatch.

## 1.5 — 2026-10-26

### Added

- **Console Mode** (toolbar, View › Console Mode ⇧⌘F, or a controller's Menu button): NX Play goes full screen with the games as a carousel of their artwork over a blurred backdrop of the selected one. It lists only the games ready to play, and shows the clock, the connected controller and its battery, and button hints in the controller's own symbols. Games started from it open full screen. B or Esc leaves it.
- **Start games in full screen:** a setting, and `nxplay --fullscreen` (nxnative's `DM_FULLSCREEN`).
- **Controller navigation** in the library and in Console Mode, with any controller macOS supports (Joy-Con, Pro Controller, Xbox, DualShock, DualSense, 8BitDo): the D-pad or left stick moves through the games, A plays or extracts, B backs out, Menu toggles Console Mode.
- **Game menu** in the menu bar with the selected game's commands, the same as its right-click menu, with shortcuts: Play or Extract ⌘↩, Stop or Cancel ⌘., Rebuild ⌘B, Transfer Saves ⇧⌘T, Show in Finder ⇧⌘R.
- **Xcode builds** in Tools › Free Up Space: the copy of the game that Install on Device keeps (`<title ID>_build/xcode-derived-data`, 5–10 GB for a big game). Deleting it only makes the next install slower.
- **Xcode badge** on the icon of games that have that build, next to the IPA badge.
- **List view** for the library, next to the grid (the toolbar switch, or View › as Grid ⌘1 / as List ⌘2). It shows one row per game with its icon, version, title ID, status and Play or Extract button. Like the grid, it has an Extracted section and a Not Extracted section with Extract All, each sortable by any column. The arrow keys move the selection, and double-click and the right-click menu work as on a card. NX Play remembers which view you chose.
- **Make Mac App** (and `nxplay --mac-app`): packs a standalone, double-clickable app of the game into its folder with nxnative's `--platform mac-app`, for the Dock or Launchpad. It's made of APFS clones, so it takes almost no extra space, and it keeps its own save in `~/Library/Application Support/nxnative`. An **App** badge marks games that have one, and the menus can open it or show it in Finder. NX Play itself still plays from the game folder.
- **Show or hide the log** with the toolbar button or View › Show Log (⇧⌘Y). The log opens by itself, on the failed game, when a build or game fails. NX Play remembers whether it's shown and how tall you dragged it.
- `bin/setup` downloads Xcode's Metal Toolchain when it's missing, since every build compiles shaders with it; `bin/setup --check` reports it.

- **Copying…** badge on a game while Finder is still copying it in, either the whole game folder or one of its files. Extract, Rebuild, Install on Device and Build IPA wait until the copy is complete, and the card updates by itself when it is.

### Changed

- Tools › Remove Game Files and Remove IPAs are now one window, **Free Up Space**. It lists every game's files of each kind, selectable one by one, per game or per kind. The full warning about game files shows only when they're selected.
- In the right-click menu, Stop and Cancel moved up next to Play.

### Fixed

- Transfer Saves with no paired device explains how to pair it with this Mac. It used to show every file as "Only on Mac".

## 1.0 — 2026-10-26

First public release.

### NX Play

- A library of the games in a folder, with their icons: extract them, play them on the Mac, rebuild them, Extract All. The selected game's output is shown live, in color.
- **Install on Device:** builds the game with Xcode, signed with your Apple team, then installs and starts it on an iPhone or iPad.
- **Build IPA** for sideloading, with an IPA badge on the game's icon.
- **Transfer Saves** between this Mac and a device. It compares the saves file by file, shows which one is newer, and keeps the replaced save in `run/save-backups`.
- **Tools › Remove Game Files / Remove IPAs** to free space. Game files go only for games built for the Mac, and only after typing "yes, I'm sure".
- Settings for the games folder, nxnative, `prod.keys`, the game language, the Apple team and the Metal performance HUD. **Game Controls** shows the keyboard controls.

### nxplay

- Builds a game once and starts it from the saved launcher afterwards, with `--build-only`, `--rebuild`, `--ipa`, `--device`, `--fps` and `--lang`.
- Updates nxnative before each run, lists the new commits, and rebuilds only when they change files. It also follows upstream force pushes when the checkout has no commits of its own.
- Repairs saved launchers after a game folder or nxnative moves.
- Keeps playing the existing build when a game's original files are gone, instead of failing to rebuild.

### Setup

- `bin/setup` installs everything in one go: Homebrew tools, nxnative's Python packages in a project `.venv` with uv, and a clone of nxnative. Then it builds and installs the app. `--check` only reports what is missing.
