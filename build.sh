#!/usr/bin/env bash
#
# build.sh - Build the full sigrok stack + PulseView from source as native
#            Apple Silicon (arm64) binaries into ./dist.
#
# Usage:
#   ./build.sh                 # build everything (default order)
#   ./build.sh libserialport   # build one or more named components
#   ./build.sh clean           # remove src/ build dirs and dist/ (keeps checkouts' .git)
#
# Environment toggles:
#   JOBS=N          parallel make jobs (default: CPU count)
#   PIN_COMMITS=1   check out the exact commits recorded in BUILT_COMMITS.txt
#                   (reproducible rebuild; otherwise tracks each repo's default branch)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/env.sh"
source "$HERE/scripts/lib.sh"

# Ignore SIGHUP for the whole build. The non-interactive host environment
# otherwise delivers SIGHUP to long configure/make sub-probes ("Hangup: 1").
trap '' HUP

REPO_BASE="https://github.com/sigrokproject"

# Ordered list of all components.
ALL_COMPONENTS=(libserialport libsigrok libsigrokdecode firmware sigrok-cli pulseview)

# pinned_ref <dirname> : echo the recorded commit SHA when PIN_COMMITS=1.
pinned_ref() {
	[ "${PIN_COMMITS:-0}" = "1" ] || return 0
	[ -f "$COMMITS_FILE" ] || return 0
	awk -v d="$1" '$1==d {print $2}' "$COMMITS_FILE" | head -1
}

# =============================================================================
# Components
# =============================================================================

build_libserialport() {
	log "=== libserialport ==="
	clone_repo "$REPO_BASE/libserialport" libserialport "$(pinned_ref libserialport)"
	autotools_build libserialport
	verify_arm64 "$PREFIX/lib/libserialport.dylib"
	record_commit libserialport libserialport
	progress_mark libserialport
}

build_libsigrok() {
	log "=== libsigrok (+ C++ bindings libsigrokcxx) ==="
	clone_repo "$REPO_BASE/libsigrok" libsigrok "$(pinned_ref libsigrok)"
	# C++ bindings use glibmm-2.68 which requires C++17. Java bindings are not
	# needed for PulseView and pull in a JDK, so disable them. Python bindings
	# auto-disable when pygobject/numpy are absent (not needed for PulseView).
	# Pin PYTHON to the Homebrew interpreter so a stray `mise`/pyenv shim on PATH
	# cannot be picked up (that caused configure to hang previously).
	CXXFLAGS="${CXXSTD} -O2" autotools_build libsigrok \
		--enable-cxx --disable-python --disable-ruby --disable-java \
		"PYTHON=$PY_PREFIX/bin/python$PYVER"
	verify_arm64 "$PREFIX/lib/libsigrok.dylib"
	verify_arm64 "$PREFIX/lib/libsigrokcxx.dylib"
	make_check libsigrok
	record_commit libsigrok libsigrok
	progress_mark libsigrok
}

build_libsigrokdecode() {
	log "=== libsigrokdecode (protocol decoders) ==="
	clone_repo "$REPO_BASE/libsigrokdecode" libsigrokdecode "$(pinned_ref libsigrokdecode)"
	# Link against Homebrew's default python3 framework (the same one bundled
	# into the .app later). libsigrokdecode's interpreter variable is PYTHON3
	# (not PYTHON); set it explicitly so the interpreter matches the linked
	# libpython and no stray shim is used.
	autotools_build libsigrokdecode "PYTHON3=$PY_PREFIX/bin/python$PYVER"
	verify_arm64 "$PREFIX/lib/libsigrokdecode.dylib"
	make_check libsigrokdecode
	record_commit libsigrokdecode libsigrokdecode
	progress_mark libsigrokdecode
}

build_firmware() {
	log "=== sigrok-firmware-fx2lafw (FX2-based logic analyzer firmware) ==="
	clone_repo "$REPO_BASE/sigrok-firmware-fx2lafw" sigrok-firmware-fx2lafw \
		"$(pinned_ref sigrok-firmware-fx2lafw)"
	# The firmware is 8051 code cross-compiled with sdcc; it is architecture-
	# independent (not an arm64 Mach-O), so we verify the installed blobs instead.
	autotools_build sigrok-firmware-fx2lafw
	local n
	n="$(ls "$PREFIX"/share/sigrok-firmware/fx2lafw-*.fw 2>/dev/null | wc -l | tr -d ' ')"
	[ "$n" -gt 0 ] || die "no fx2lafw firmware installed in dist/share/sigrok-firmware"
	log_ok "installed $n fx2lafw firmware blob(s)"
	record_commit sigrok-firmware-fx2lafw sigrok-firmware-fx2lafw
	progress_mark firmware
}

build_sigrok_cli() {
	log "=== sigrok-cli (command-line frontend) ==="
	clone_repo "$REPO_BASE/sigrok-cli" sigrok-cli "$(pinned_ref sigrok-cli)"
	# Links the whole library stack (libsigrok + libsigrokdecode + glib).
	autotools_build sigrok-cli
	verify_arm64 "$PREFIX/bin/sigrok-cli"
	# Lightweight smoke test: print versions (loads libsigrok/libsigrokdecode).
	if "$PREFIX/bin/sigrok-cli" --version >/dev/null 2>&1 </dev/null; then
		log_ok "sigrok-cli --version runs"
	else
		log_warn "sigrok-cli --version returned non-zero"
	fi
	record_commit sigrok-cli sigrok-cli
	progress_mark sigrok-cli
}

build_pulseview() {
	log "=== PulseView (Qt6 GUI) ==="
	clone_repo "$REPO_BASE/pulseview" pulseview "$(pinned_ref pulseview)"
	# Qt6 is auto-selected (Qt5 is not on CMAKE_PREFIX_PATH). DISABLE_WERROR
	# avoids clang turning warnings into errors; ENABLE_TESTS builds the unit
	# tests (boost unit_test_framework).
	cmake_build pulseview -DDISABLE_WERROR=y -DENABLE_TESTS=y
	verify_arm64 "$PREFIX/bin/pulseview"
	run_make_target pulseview test
	record_commit pulseview pulseview
	progress_mark pulseview
}

# =============================================================================
# Orchestration
# =============================================================================

do_clean() {
	log "Cleaning build directories and dist/ ..."
	for c in "${ALL_COMPONENTS[@]}"; do
		[ "$c" = "firmware" ] && c="sigrok-firmware-fx2lafw"
		rm -rf "$SRC_DIR/$c/build" 2>/dev/null || true
	done
	rm -rf "$PREFIX"
	log_ok "Clean complete (git checkouts under src/ are preserved)."
}

usage() {
	cat <<EOF
Usage: ./build.sh [all | clean | <component>...]

  (no args) | all   Build every component in dependency order:
                    ${ALL_COMPONENTS[*]}
  clean             Remove dist/ and each component's build/ dir (keeps src/).
  <component>...    Build only the named component(s).

Environment toggles:
  JOBS=N            Parallel make jobs (default: CPU count = $JOBS).
  PIN_COMMITS=1     Check out the exact commits from BUILT_COMMITS.txt
                    (reproducible rebuild). Otherwise tracks each repo's
                    default branch and records the commits it built.
EOF
}

main() {
	local targets=() building_all=0
	if [ "$#" -eq 0 ] || [ "$1" = "all" ]; then
		targets=("${ALL_COMPONENTS[@]}"); building_all=1
	elif [ "$1" = "clean" ]; then
		do_clean; return 0
	elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
		usage; return 0
	else
		targets=("$@")
	fi

	log "Building: ${targets[*]}"
	log "PIN_COMMITS=${PIN_COMMITS:-0}  JOBS=$JOBS"
	echo

	for t in "${targets[@]}"; do
		case "$t" in
			libserialport)     build_libserialport ;;
			libsigrok)         build_libsigrok ;;
			libsigrokdecode)   build_libsigrokdecode ;;
			firmware)          build_firmware ;;
			sigrok-cli)        build_sigrok_cli ;;
			pulseview)         build_pulseview ;;
			*) die "Unknown component: $t (valid: ${ALL_COMPONENTS[*]}); see ./build.sh --help" ;;
		esac
	done

	# A full, successful build of every component means the end-to-end build
	# script is verified.
	if [ "$building_all" -eq 1 ]; then
		progress_mark build-script
	fi

	echo
	log_ok "Build finished for: ${targets[*]}"
	log "Commit manifest: BUILT_COMMITS.txt"
}

main "$@"
