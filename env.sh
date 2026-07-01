#!/usr/bin/env bash
#
# env.sh - Shared build environment for building the sigrok stack + PulseView
#          as NATIVE Apple Silicon (arm64) binaries.
#
# Source this file from the other scripts:  source "<workspace>/env.sh"
#
# It is intentionally self-locating: it discovers the workspace root from its
# own path, so the whole folder can be copied to another Mac and still work.

# --- Locate the workspace root (works when this file is sourced) -------------
_ENV_SH_SOURCE="${BASH_SOURCE[0]:-$0}"
ROOT="$(cd "$(dirname "$_ENV_SH_SOURCE")" && pwd)"
export ROOT

# --- Layout ------------------------------------------------------------------
export SRC_DIR="$ROOT/src"          # git checkouts
export PREFIX="$ROOT/dist"          # local install prefix (self-contained)
export LOG_DIR="$ROOT/logs"         # per-component build logs
export SCRIPTS_DIR="$ROOT/scripts"  # helper library + component scripts
export PROGRESS_FILE="$ROOT/PROGRESS.md"
export COMMITS_FILE="$ROOT/BUILT_COMMITS.txt"

mkdir -p "$SRC_DIR" "$PREFIX" "$LOG_DIR" "$SCRIPTS_DIR"

# --- Homebrew ----------------------------------------------------------------
# Never auto-update mid-build (keeps builds deterministic and quiet).
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

# Drop any sigrok redirection the user may have in their shell, so builds and
# smoke tests use OUR freshly built decoders/firmware, not a personal override.
unset SIGROKDECODE_DIR SIGROK_FIRMWARE_DIR 2>/dev/null || true

if ! command -v brew >/dev/null 2>&1; then
	echo "ERROR: Homebrew not found. Install it from https://brew.sh first." >&2
	return 1 2>/dev/null || exit 1
fi
HB="$(brew --prefix)"                # /opt/homebrew on Apple Silicon
export HB

# --- Toolchain ---------------------------------------------------------------
# Use the system clang/clang++ (native arm64). Do NOT use Homebrew gcc here:
# the sigrok C++ bindings + PulseView expect the platform toolchain.
export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"

# Parallel build jobs (override by exporting JOBS before sourcing).
export JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# --- Component versions / formula choices ------------------------------------
# Qt: use Qt 6 (native arm64). PulseView's CMake auto-selects Qt6 when Qt5 is
# absent from CMAKE_PREFIX_PATH.
export QT_FORMULA="qt"
export QT_PREFIX="$(brew --prefix "$QT_FORMULA")"

# Python: libsigrokdecode links Homebrew's DEFAULT python3 (it resolves the
# unversioned `python3-embed` pkg-config module). To keep the interpreter, the
# linked libpython, and the framework we bundle into the .app all identical, we
# track exactly that formula instead of pinning a different minor version.
export PY_PREFIX="$(brew --prefix python3)"          # e.g. /opt/homebrew/opt/python@3.14
export PYTHON_FORMULA="$(basename "$PY_PREFIX")"      # e.g. python@3.14
export PYVER="${PYTHON_FORMULA#python@}"              # e.g. 3.14

# glibmm: Homebrew's `glibmm` provides the glibmm-2.68 API which requires
# C++17. libsigrok's C++ bindings and PulseView are compiled accordingly.
export CXXSTD="-std=c++17"

# --- pkg-config search path --------------------------------------------------
# Our freshly built libs first, then the Homebrew formulae (including keg-only
# ones whose .pc files are not symlinked into the default prefix).
_pc_paths=("$PREFIX/lib/pkgconfig")
for _f in glib glibmm libffi nettle libzip libusb libftdi hidapi "$PYTHON_FORMULA" "$QT_FORMULA"; do
	_p="$(brew --prefix "$_f" 2>/dev/null)/lib/pkgconfig"
	[ -d "$_p" ] && _pc_paths+=("$_p")
done
export PKG_CONFIG_PATH="$(IFS=:; echo "${_pc_paths[*]}")"

# --- CMake search path (for PulseView) ---------------------------------------
export CMAKE_PREFIX_PATH="$QT_PREFIX:$(brew --prefix boost):$PREFIX"

# --- Runtime lookup for testing binaries straight from the prefix ------------
# Autotools installs dylibs with absolute install_names, so this is usually
# only a safety net.
export DYLD_FALLBACK_LIBRARY_PATH="$PREFIX/lib:${DYLD_FALLBACK_LIBRARY_PATH:-/usr/local/lib:/usr/lib}"

# Homebrew's libtool is keg-only and installs GNU tools as `glibtoolize` etc.
# Expose the un-prefixed GNU names (libtoolize/libtool) that autogen.sh expects.
_LIBTOOL_GNUBIN="$(brew --prefix libtool 2>/dev/null)/libexec/gnubin"
[ -d "$_LIBTOOL_GNUBIN" ] || _LIBTOOL_GNUBIN=""
export LIBTOOLIZE="glibtoolize"

# --- Sanitize PATH for a deterministic, repeatable build ---------------------
# Drop language version-manager shim/install dirs (mise, pyenv, rbenv, nvm,
# asdf, conda). Otherwise their python/node/ruby binaries get picked up by
# configure probes (e.g. libsigrokdecode found a stray `python3.8`), which is
# neither native-arm64-guaranteed nor reproducible on another Mac.
_clean_path=""
_IFS_SAVE="$IFS"; IFS=":"
for _d in $PATH; do
	[ -n "$_d" ] || continue
	case "$_d" in
		*/mise/*|*/.pyenv/*|*/.rbenv/*|*/.nvm/*|*/.asdf/*|*/miniconda*|*/anaconda*|*/conda/*) continue ;;
	esac
	_clean_path="${_clean_path:+$_clean_path:}$_d"
done
IFS="$_IFS_SAVE"
export PATH="$_clean_path"

# Make our built tools available on PATH during the build/test phase.
export PATH="${_LIBTOOL_GNUBIN:+$_LIBTOOL_GNUBIN:}$PREFIX/bin:$QT_PREFIX/bin:$PATH"
