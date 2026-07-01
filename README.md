# PulseView for Apple Silicon — build from source

This folder builds the complete [sigrok](https://sigrok.org) stack and
[PulseView](https://github.com/sigrokproject/pulseview) **from source** as
**native arm64 (Apple Silicon)** binaries, then packages PulseView into a
self-contained, ad-hoc-signed `PulseView.app` and a distributable `.dmg`.

Everything needed to reproduce the build lives in this folder, so the process
is repeatable on any Apple Silicon Mac.

## What gets built

From `git master` of each project:

| Component | What it is |
|-----------|------------|
| libserialport | serial port access library |
| libsigrok + libsigrokcxx | core acquisition library + C++ bindings |
| libsigrokdecode | protocol-decoder library (embeds Python) |
| sigrok-firmware-fx2lafw | FX2 logic-analyzer firmware (built with sdcc) |
| sigrok-cli | command-line frontend |
| PulseView | the Qt6 GUI |

## Outputs

After a successful run you get, in this folder:

- `PulseView.app` — self-contained app bundle; drag it to `/Applications`.
- `PulseView-<version>.dmg` — shareable disk image (open, then drag to Applications).
- `dist/` — the raw install prefix (also contains `sigrok-cli`).

The app bundles Qt 6, the Python framework, all sigrok libraries, ~130 protocol
decoders and the FX2 firmware, so it runs on a clean Mac with **no Homebrew
required**.

## Requirements

- An Apple Silicon Mac (arm64) running macOS 11 or newer.
- **Xcode Command Line Tools**: `xcode-select --install`
- **Homebrew** (`/opt/homebrew`): <https://brew.sh>

`./00-prereqs.sh` installs every other dependency for you.

## Quick start

```sh
./00-prereqs.sh     # verify/install Homebrew dependencies (native arm64)
./build.sh          # build the whole stack from source into ./dist
./package.sh        # assemble PulseView.app + PulseView-<version>.dmg
```

That's it. Open `PulseView.app` (see [Running](#running-the-app) for the
first-launch Gatekeeper step).

## The scripts

| Script | Purpose |
|--------|---------|
| `00-prereqs.sh` | Checks arm64 + Xcode CLT and installs the required Homebrew formulae. Pass `--check` to verify without installing. |
| `env.sh` | Shared build environment (sourced by the others). Self-locating, so the folder can be copied anywhere. |
| `build.sh` | Clones and builds each component into `./dist`. See usage below. |
| `package.sh` | Turns `./dist` into `PulseView.app` and the `.dmg`. |
| `scripts/lib.sh` | Helper functions used by the build. |

### build.sh usage

```sh
./build.sh                 # build everything, in dependency order
./build.sh all             # same as above
./build.sh libsigrok       # build only the named component(s)
./build.sh pulseview
./build.sh clean           # remove ./dist and each build/ dir (keeps ./src checkouts)
./build.sh --help

JOBS=8 ./build.sh          # override parallelism (default = CPU count)
PIN_COMMITS=1 ./build.sh   # reproducible rebuild (see Reproducible builds)
```

## Running the app

The app is **ad-hoc code-signed**, which is required for arm64 binaries to run
at all, but it is *not* notarized by Apple. On first launch macOS Gatekeeper
will warn that the developer can't be verified. Choose one:

- **Finder:** right-click `PulseView.app` → **Open** → **Open**. (Only needed once.)
- **Terminal:** clear the quarantine flag, then open normally:

  ```sh
  xattr -dr com.apple.quarantine /Applications/PulseView.app
  ```

To distribute without any warning you would need an Apple Developer ID and
notarization; that is out of scope here (see [Notes](#notes--limitations)).

### Command-line sanity check

```sh
# Prints versions and the full list of drivers/decoders (native arm64):
/Applications/PulseView.app/Contents/MacOS/pulseview --version
```

## Reproducible builds (pinning)

Every build records the exact commit it used for each repository in
`BUILT_COMMITS.txt`. To reproduce *this* build later (or on another Mac),
copy this whole folder (including `BUILT_COMMITS.txt`) and run:

```sh
PIN_COMMITS=1 ./build.sh
```

With `PIN_COMMITS=1`, `build.sh` checks out the recorded commit for each repo
instead of the latest `master`. Without it, the build tracks each project's
default branch and refreshes `BUILT_COMMITS.txt` with whatever it built.

## Continuous integration (GitHub Actions)

`.github/workflows/build.yml` builds everything on a **native Apple Silicon
runner** (`macos-14`) and uploads the `.dmg`:

- Runs on pushes to `main`, on `v*` tags, and manually (Actions → Run workflow).
- Steps are just `./00-prereqs.sh` → `./build.sh` → `./package.sh`, then it
  verifies the binary is arm64 and the signature is valid.
- The `.dmg` (plus `BUILT_COMMITS.txt`) is uploaded as a build artifact.
- Pushing a tag like `v0.5.0` also creates a GitHub Release with the `.dmg`
  attached.

Note: macOS runner minutes bill at a higher rate on **private** repos, but are
**free on public** repos — worth keeping in mind for a CI-heavy build like this.

### Simulate the CI build locally first

`scripts/ci-local.sh` runs the CI pipeline against a clean export of the
committed tree, so you can catch problems before pushing:

```sh
scripts/ci-local.sh --check   # fast: shell syntax + dependency detection (seconds)
scripts/ci-local.sh           # full clean build in a temp dir (like CI; slow)
```

Caveat: it runs on your Mac, which already has the Homebrew dependencies, so it
can't reproduce *which packages a fresh runner is missing*. `act` doesn't help
either — it only emulates Linux runners, not macOS. For a fully clean check,
build in a throwaway macOS VM.

## Progress and logs

- `PROGRESS.md` — a checklist that the scripts tick off as each step completes.
- `logs/<component>.log` — full configure/compile/test output per component.
- `logs/package.log` — macdeployqt output from packaging.

## Directory layout

```
build_pulseview_apple_silicon/
├── 00-prereqs.sh          # dependency check/installer
├── env.sh                 # shared build environment
├── build.sh               # builds the whole stack into dist/
├── package.sh             # builds PulseView.app + .dmg
├── scripts/lib.sh         # helper functions
├── src/                   # git checkouts (created by build.sh)
├── dist/                  # install prefix (created by build.sh)
├── logs/                  # per-component build logs
├── BUILT_COMMITS.txt      # exact commit built per repo (pinning manifest)
├── PROGRESS.md            # progress checklist
├── PulseView.app          # the packaged app (created by package.sh)
└── PulseView-<ver>.dmg    # the disk image (created by package.sh)
```

## Troubleshooting

- **`./00-prereqs.sh` reports a missing formula** — re-run it without `--check`
  to install, or `brew install <formula>` manually.
- **"PulseView is damaged / can't be opened"** — this is Gatekeeper on the
  quarantine flag. Use the right-click → Open step, or
  `xattr -dr com.apple.quarantine /Applications/PulseView.app`.
- **A build step fails** — read `logs/<component>.log`. You can rebuild a single
  component with `./build.sh <component>` after fixing the cause.
- **`python` version drift** — the build links whatever `brew --prefix python3`
  points to and bundles *that* framework, so the app is always self-consistent.
  If Homebrew upgrades its default Python, just re-run `./build.sh libsigrokdecode`
  then `./package.sh`.
- **A stray `SIGROKDECODE_DIR`/`SIGROK_FIRMWARE_DIR` in your shell** — `env.sh`
  unsets these for the build; the packaged app sets its own to point inside the
  bundle.

## Notes & limitations

- **Native arm64 only.** Every Mach-O in the bundle is arm64 (no Rosetta, no
  universal binary). Verify with:

  ```sh
  file PulseView.app/Contents/MacOS/pulseview.real
  ```

- **Ad-hoc signing.** Enough to run locally and on other Apple Silicon Macs
  (with the one-time Gatekeeper step). Not notarized — distributing without any
  warning requires a paid Apple Developer ID and a notarization pass.
- **Python is tracked, not pinned to a specific minor.** `libsigrokdecode`
  resolves Homebrew's default `python3` via `python3-embed`, so the build uses
  and bundles that exact framework for consistency.
- **Firmware.** `sigrok-firmware-fx2lafw` is compiled from source with `sdcc`.
  Other vendors' device firmware is not included.

## How it works (the Apple Silicon specifics)

A few things that make this build different from the stock sigrok macOS script:

- Targets **Qt 6** (the old script hardcodes Qt 5.5) and modern Homebrew
  (`/opt/homebrew`, `python@3.x`, clang) instead of Qt 5.5 / python@2 / gcc.
- `package.sh` relocates every `/opt/homebrew` dependency into the bundle with
  `install_name_tool`, rewriting references to `@executable_path/../Frameworks`
  (frameworks such as Qt and Python are kept as frameworks, not flattened).
- The embedded Python framework is bundled and `libsigrokdecode` is repointed at
  it via `@loader_path`; a launch wrapper sets `PYTHONHOME`,
  `SIGROKDECODE_DIR`, `SIGROK_FIRMWARE_DIR` and `PYTHONDONTWRITEBYTECODE=1`
  (the last keeps the code signature valid at runtime).
- The whole bundle is ad-hoc signed **after** all `install_name_tool` edits,
  because arm64 refuses to launch binaries with a broken/missing signature.

```
