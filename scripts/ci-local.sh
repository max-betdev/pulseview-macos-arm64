#!/usr/bin/env bash
#
# ci-local.sh - Simulate the GitHub Actions build LOCALLY before pushing.
#
# It exports the *committed* HEAD (tracked files only, no src/dist/logs) into a
# clean temp directory and runs the exact CI pipeline there:
#     ./00-prereqs.sh  ->  ./build.sh  ->  ./package.sh  ->  verify
#
# Usage:
#   scripts/ci-local.sh            # full clean build (like CI; ~15-30 min)
#   scripts/ci-local.sh --check    # fast checks only: prereqs detection + shell
#                                    syntax of every script (a few seconds)
#
# IMPORTANT CAVEAT
#   This runs on YOUR Mac, which already has the Homebrew dependencies. It does
#   NOT reproduce differences in what a fresh CI runner has preinstalled, so it
#   cannot catch "a dependency was never installed on the runner" bugs. It DOES
#   catch fresh-checkout, path, packaging and script-logic bugs. For a truly
#   clean environment, use a throwaway macOS VM (e.g. `tart`).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-full}"

# --- Fast mode: syntax + dependency detection only ---------------------------
if [ "$MODE" = "--check" ]; then
	echo ">> shell syntax check"
	for s in env.sh 00-prereqs.sh build.sh package.sh scripts/lib.sh scripts/ci-local.sh; do
		bash -n "$ROOT/$s" && echo "   ok: $s"
	done
	echo ">> workflow YAML present"
	[ -f "$ROOT/.github/workflows/build.yml" ] && echo "   ok: .github/workflows/build.yml"
	echo ">> dependency detection (00-prereqs.sh --check)"
	"$ROOT/00-prereqs.sh" --check
	echo ">> OK (fast checks passed)"
	exit 0
fi

# --- Full mode: clean checkout + full pipeline -------------------------------
command -v git >/dev/null || { echo "git required"; exit 1; }
WORK="$(mktemp -d /tmp/pv-ci-local.XXXXXX)"
echo ">> exporting committed HEAD -> $WORK"
git -C "$ROOT" archive --format=tar HEAD | tar -x -C "$WORK"

cd "$WORK"
echo ">> [1/3] 00-prereqs.sh"; ./00-prereqs.sh
echo ">> [2/3] build.sh";      ./build.sh
echo ">> [3/3] package.sh";    ./package.sh

echo ">> verify"
file "PulseView.app/Contents/MacOS/pulseview.real"
lipo -archs "PulseView.app/Contents/MacOS/pulseview.real"
codesign --verify --strict "PulseView.app" && echo "   signature OK"

echo ">> SUCCESS. Artifacts in: $WORK"
echo "   (remove with: rm -rf \"$WORK\")"
