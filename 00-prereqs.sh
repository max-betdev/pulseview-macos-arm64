#!/usr/bin/env bash
#
# 00-prereqs.sh - Verify (and optionally install) all prerequisites for a
#                 native Apple Silicon build of the sigrok stack + PulseView.
#
# Usage:
#   ./00-prereqs.sh            # verify only; installs anything missing
#   ./00-prereqs.sh --check    # verify only; do NOT install (exit 1 if missing)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/env.sh"
source "$HERE/scripts/lib.sh"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# Formulae required to build the full stack from source.
FORMULAE=(
	autoconf automake libtool pkgconf cmake git
	glib glibmm boost
	libusb libftdi libzip nettle hidapi
	"$QT_FORMULA" "$PYTHON_FORMULA"
	sdcc                      # 8051 compiler for sigrok-firmware-fx2lafw
)
# Optional (tests / docs). Missing ones are only warned about.
OPTIONAL=( check doxygen )

log "Workspace : $ROOT"
log "Prefix    : $PREFIX"
log "Homebrew  : $HB"
log "Qt        : $QT_PREFIX"
log "Python    : $PY_PREFIX  (python$PYVER)"
log "Jobs      : $JOBS"
echo

# 1) Hard requirement: we must be on Apple Silicon.
arch="$(uname -m)"
if [ "$arch" != "arm64" ]; then
	die "This machine reports arch '$arch', not 'arm64'. Run on Apple Silicon (or a native arm64 shell, not Rosetta)."
fi
log_ok "CPU architecture: arm64"

# 2) Command Line Tools (clang, make, install_name_tool, lipo, codesign...).
xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools missing. Run: xcode-select --install"
log_ok "Xcode Command Line Tools present ($(xcode-select -p))"

# 3) Homebrew formulae.
# NOTE: use `brew list --versions`, NOT `brew --prefix`. The latter prints a
# path and exits 0 even for a formula that is not installed, so it cannot tell
# "installed" from "known but absent" (this silently skipped installing Qt on a
# clean CI runner).
is_installed() { brew list --versions "$1" >/dev/null 2>&1; }

missing=()
for f in "${FORMULAE[@]}"; do
	if is_installed "$f"; then
		log_ok "formula present: $f"
	else
		log_warn "formula MISSING: $f"
		missing+=("$f")
	fi
done
for f in "${OPTIONAL[@]}"; do
	is_installed "$f" && log_ok "optional present: $f" || log_warn "optional missing: $f (tests/docs may be skipped)"
done

if [ "${#missing[@]}" -gt 0 ]; then
	if [ "$CHECK_ONLY" -eq 1 ]; then
		die "Missing formulae: ${missing[*]}  (re-run without --check to install)"
	fi
	log "Installing missing formulae: ${missing[*]}"
	brew install "${missing[@]}"
fi

# 4) Sanity: confirm the toolchain and key tools resolve and are native arm64.
log "clang: $($CC --version | head -1)"
verify_arm64 "$(brew --prefix "$QT_FORMULA")/bin/macdeployqt"
verify_arm64 "$(command -v python$PYVER || echo "$PY_PREFIX/bin/python$PYVER")"

progress_mark prereqs

echo
log_ok "All prerequisites satisfied. Next: ./build.sh"
