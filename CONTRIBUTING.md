# Contributing to BetterWispr

Thanks for helping out. Bug reports, fixes and focused features are all welcome.

## Setup

You need macOS 14+, a Swift 6.2+ toolchain and Xcode or the Command Line Tools.
The first build downloads Swift package dependencies, so it needs internet.

```sh
git clone https://github.com/opennookorg/betterwispr.git
cd betterwispr
make dev
```

`make dev` builds, runs every check and launches `.build/debug/BetterWispr.app`.
Always launch through `make run` or `./scripts/run.sh` so macOS attaches
microphone and Accessibility permissions to the app bundle.

| Command | What it does |
| --- | --- |
| `make run` | Build and launch the debug app |
| `make test` | `swift test` plus the evaluator checks |
| `make lint` | Show compiler warnings |
| `make offline-test MODEL=parakeet-v3` | Transcribe with networking denied |
| `make help` | List every target |

`scripts/build-app.sh` signs with your first code-signing identity, or
`CODESIGN_IDENTITY` if set. With ad-hoc signing, macOS revokes Accessibility on
every rebuild, so paste falls back to copy.

Test a model without the UI:

```sh
swift run BetterWisprCLI --list-models
swift run BetterWisprCLI --download-model parakeet-v3
swift run BetterWisprCLI --transcribe-file audio.wav --model parakeet-v3 --language en
```

Check cleanup and Dictate and format on recorded clips. Each line of the
manifest is `{"id", "language", "audio", "reference"}`:

```sh
swift build -c release
.build/release/BetterWisprCLI --bench clips.jsonl --model parakeet-v3 --language en --cleanup medium
.build/release/BetterWisprCLI --bench clips.jsonl --model parakeet-v3 --language en --cleanup medium --format email
```

`--format` takes `email`, `work`, `personal`, `aiPrompts` or `documents`, the
kinds of app Dictate and format recognizes. Add `--notes-model builtin` to use
the built-in cleanup model instead of Apple Intelligence. Run
`swift run BetterWisprCLI --help` for every option.

## Checks

`make test` runs all of these except the speaker check. Run the ones that match your change on their own while you work:

| Command | When |
| --- | --- |
| `swift build` and `swift test --no-parallel` | Any Swift change |
| `python3 scripts/localization.py check` | Any change to interface text or `.strings` files |
| `python3 Tests/evaluate_check.py` | Evaluation or transcript normalization |
| `python3 Tests/live_speakers_check.py` | Meeting speaker labels |
| `python3 Tests/release_check.py` | Release scripts |

New interface text goes through `L10n.tr` and needs an entry in both
`en.lproj` and `fr.lproj` under `Sources/BetterWisprCore/Localization/Resources`.

## Project layout

```text
Sources/BetterWispr/       App composition, SwiftUI features, design components
Sources/BetterWisprCore/   Audio, speech providers, persistence, OS integrations
Sources/BetterWisprCLI/    Model install, file transcription and benchmarks for smoke tests
Tests/                     Swift tests and Python evaluation checks
scripts/                   Build, run, release and evaluation scripts
docs/                      Architecture, testing, accuracy and OSS provenance
betterwispr-frontend/      Website (betterwispr.com)
```

Read [docs/architecture.md](docs/architecture.md) before adding a model,
provider or integration. See [docs/localization.md](docs/localization.md) to add
an interface language using staged native resource folders.

## Ground rules

- **Local by default.** Built-in transcription stays on device. API providers are
  opt-in only and are never used as a fallback. Models download only after an
  explicit user action. API keys go in the Keychain.
- **Don't break safety checks.** Keep the permission checks, app-focus and
  clipboard safeguards, cancellation and audio cleanup. Never paste a stale result.
- **Concurrency.** UI state stays on the main actor. Don't block audio callbacks
  or silence Swift concurrency diagnostics without a documented reason.
- **Data.** Keep raw and corrected transcripts separate. Schema changes to saved
  data need a migration.
- **No invented numbers.** Don't claim accuracy or benchmark results you haven't measured.
- **Code style.** No code comments; names explain the code. Docstrings are one
  line. Imports go at the top of the file.
- **Never commit** models, recordings, transcripts, keys or signing assets.
- **Third-party code** keeps its license and is recorded in [docs/oss-reuse.md](docs/oss-reuse.md).

## Pull requests

1. Branch from `main` and keep the change focused.
2. Run `make test` and `make lint`.
3. For permission, shortcut, paste or offline behavior, follow the manual
   checklist in [docs/testing.md](docs/testing.md) and say in the PR what you
   tested by hand versus what only passed automated checks.
4. Add an entry to [CHANGELOG.md](CHANGELOG.md) for
   user-visible changes.
5. Use conventional commit prefixes, e.g. `feat(core):`, `fix(app):`, `chore(web):`.
6. Include before and after screenshots for UI changes.

## Releases (maintainers)

One-time setup, following BetterShot's Developer ID and Keychain workflow:

1. Make sure the **Developer ID Application** certificate and its private key
   are installed in Keychain for team `8JL39GK2DC`.
2. At [Apple Account](https://account.apple.com), open **Sign-In and Security →
   App-Specific Passwords**, generate a password and label it **BetterWispr**.
   See [Apple's instructions](https://support.apple.com/en-us/102654).
3. Run `make setup-notary`. Enter your Apple ID email, then paste that password
   into `notarytool`'s hidden prompt. Apple validates it before saving it in
   Keychain as `betterwispr-notary`. Keep the password out of source files,
   `.env` files and shell commands. Rerun this target to replace a revoked password.
4. Review any pending agreements in your
   [Apple Developer account](https://developer.apple.com/account/). An HTTP 403
   reporting a missing or expired agreement requires the account holder to
   resolve that agreement; generating a new password does not fix it.

For each release, update `VERSION`, run `make test`, then run `make ship`.
Shipping checks notarization access before rebuilding or replacing existing
release artifacts. Both setup and shipping accept a `NOTARY_PROFILE` environment
override if you deliberately use a different Keychain profile.

`make ship` builds, signs with Developer ID, notarizes and staples
separate `release/BetterWispr-arm64.dmg` (Apple Silicon) and
`release/BetterWispr-x86_64.dmg` (Intel) files. It checks each executable's
architecture and Gatekeeper acceptance, then signs both downloads for Sparkle
and writes `release/appcast.xml`. The feed lists the Apple Silicon item first
with Sparkle's `arm64` hardware requirement, so Intel receives the Intel build.
The stable DMG filenames keep the website's latest-download links working.
Wait for **Release Complete**, then publish all three files on a GitHub release
tagged `v<version>` using the command the script prints. `make ship` prepares
the files; it does not publish them.

`make ship` reuses saved credentials and does not ask for an Apple ID or
app-specific password. A macOS Keychain popup is a separate permission for
`codesign` or Sparkle's `sign_update` to access its signing key. Choose
**Always Allow** for the trusted tool to remember that permission, as described
in [Apple's Keychain guidance](https://support.apple.com/guide/keychain-access/kyca1243/mac).
Unlike BetterShot's current release script, BetterWispr also signs Sparkle
updates. No signing passwords or private keys are exported into project files.

To build one architecture locally, use `./scripts/build-app.sh release arm64`
or `./scripts/build-app.sh release x86_64`. Bundles are kept in their respective
SwiftPM architecture directories. With no architecture argument, local build
and run commands continue to use the host architecture.
