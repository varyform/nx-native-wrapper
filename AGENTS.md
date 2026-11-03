# Contributing to NX Play

These conventions are for anyone changing this repo, and for the coding agents (Claude Code, Codex, …) working with them.

## The project

- **NX Play** is a SwiftUI macOS app. The app target is in `App/`; almost all the code is in the `Packages/NXPlayKit` Swift package.
- **NX Play for iPhone and iPad** is in `iOS/`. The Mac builds and installs it.
- **`nxplay`** is the bash script at the repo root, bundled into the app. It wraps [nxnative](https://github.com/seedds/nxnative)'s build scripts and plays the games it builds.

## Before you open a pull request

- **One change per pull request.** Separate features go in separate PRs, so each can be reviewed, merged or reverted on its own.
- **Run the checks CI runs:**
  - `swift test --package-path Packages/NXPlayKit` (or `mise run test`)
  - `shellcheck nxplay bin/*`
  - `bin/build CODE_SIGNING_ALLOWED=NO`, which should build with no warnings
- **Say what you tried on real hardware** and what you didn't (a Mac, an iPhone or iPad, a controller).

## Code

- **Keep Swift files under about 300 lines.** Split a bigger type into extensions in `Name+Part.swift` files, e.g. `Library+Remote.swift`.
- **Comments explain why**, not what the code does.
- **Tests use Swift Testing** (`import Testing`, `@Test`, `#expect`), in `Packages/NXPlayKit/Tests`.
- **Keep the stack as it is:** Swift for the apps and bash for `nxplay`. Don't add new languages or runtimes without asking first.

## Docs

- **Every user-visible change gets a [CHANGELOG.md](CHANGELOG.md) entry** under `## Unreleased`, in Added, Changed or Fixed. Released sections are never edited.
- **Update [README.md](README.md)** when behaviour changes.
- **Commit messages say why** the change is made; the diff already shows what changed.
