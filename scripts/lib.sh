#!/usr/bin/env bash
#
# lib.sh - Shared helper functions for the build/package scripts.
# Source AFTER env.sh.

# --- Pretty logging ----------------------------------------------------------
_c() { printf '\033[%sm' "$1"; }   # color helper (no-op if not a tty)
if [ -t 1 ]; then C_BLUE="$(_c 34)"; C_GRN="$(_c 32)"; C_RED="$(_c 31)"; C_YEL="$(_c 33)"; C_RST="$(_c 0)"; else C_BLUE=; C_GRN=; C_RED=; C_YEL=; C_RST=; fi

log()      { printf '%s[%s]%s %s\n' "$C_BLUE" "$(date '+%H:%M:%S')" "$C_RST" "$*"; }
log_ok()   { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
log_warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
log_err()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()      { log_err "$*"; exit 1; }

# --- Architecture verification ----------------------------------------------
# Fails unless the given Mach-O file is (or contains) arm64.
verify_arm64() {
	local f="$1"
	[ -e "$f" ] || die "verify_arm64: missing file: $f"
	local archs
	archs="$(lipo -archs "$f" 2>/dev/null || true)"
	if [ -z "$archs" ]; then
		# Not a fat/thin Mach-O that lipo understands; fall back to `file`.
		archs="$(file -b "$f")"
	fi
	case "$archs" in
		*arm64*) log_ok "arm64 verified: $(basename "$f")  [$archs]" ;;
		*)       die "NOT arm64: $f  [$archs]" ;;
	esac
}

# --- Git checkout (shallow) --------------------------------------------------
# clone_repo <url> <dirname> [ref]
# Clones into $SRC_DIR/<dirname>. If it already exists, fetches. If [ref] is
# given (branch/tag/commit), checks it out (used by PIN_COMMITS mode).
clone_repo() {
	local url="$1" dir="$2" ref="${3:-}"
	local dest="$SRC_DIR/$dir"
	if [ -d "$dest/.git" ]; then
		log "Updating existing checkout: $dir"
		if [ -n "$ref" ] && [ -f "$dest/.git/shallow" ]; then
			# Need full history to check out an arbitrary pinned commit.
			git -C "$dest" fetch --unshallow --tags --quiet 2>/dev/null \
				|| git -C "$dest" fetch --all --tags --quiet || log_warn "fetch failed for $dir"
		else
			git -C "$dest" fetch --all --tags --quiet || log_warn "fetch failed for $dir (offline?)"
		fi
	else
		log "Cloning $url -> src/$dir"
		if [ -n "$ref" ]; then
			git clone --quiet "$url" "$dest"           # full clone so any commit is reachable
		else
			git clone --depth=1 --quiet "$url" "$dest" # shallow clone tracks tip only
		fi
	fi
	if [ -n "$ref" ]; then
		log "Checking out pinned ref for $dir: $ref"
		git -C "$dest" checkout --quiet "$ref"
	fi
}

# --- Commit recording --------------------------------------------------------
# record_commit <name> <dirname>  -> appends "name  <sha>  <subject>" to BUILT_COMMITS.txt
record_commit() {
	local name="$1" dir="$2"
	local dest="$SRC_DIR/$dir"
	local sha subject
	sha="$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo 'unknown')"
	subject="$(git -C "$dest" log -1 --pretty=%s 2>/dev/null || echo '')"
	# Remove any prior line for this component, then append the fresh one.
	if [ -f "$COMMITS_FILE" ]; then
		grep -v "^${name}[[:space:]]" "$COMMITS_FILE" > "$COMMITS_FILE.tmp" 2>/dev/null || true
		mv "$COMMITS_FILE.tmp" "$COMMITS_FILE"
	fi
	printf '%-22s %s  %s\n' "$name" "$sha" "$subject" >> "$COMMITS_FILE"
	log "Recorded commit for $name: ${sha:0:12}"
}

# --- PROGRESS.md checkbox flipping -------------------------------------------
# progress_mark <key>   flips "- [ ] ... <!-- key -->" to "- [x] ..." with a timestamp.
progress_mark() {
	local key="$1"
	[ -f "$PROGRESS_FILE" ] || return 0
	PROGRESS_FILE="$PROGRESS_FILE" python3 - "$key" <<'PY' 2>/dev/null || true
import os, sys, datetime
path = os.environ["PROGRESS_FILE"]; key = sys.argv[1]
ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
marker = "<!-- %s -->" % key
out = []
for ln in open(path, encoding="utf-8").read().splitlines():
    if marker in ln and ln.lstrip().startswith("- [ ]"):
        ln = ln.replace("- [ ]", "- [x]", 1)
        if "_(done" not in ln:
            ln = ln + ("  _(done %s)_" % ts)
    out.append(ln)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
	log_ok "PROGRESS: marked '$key' done"
}

# --- Standard autotools build ------------------------------------------------
# autotools_build <dirname> [extra configure args...]
# Runs autogen.sh, then an out-of-tree configure/make/make install into $PREFIX.
# Logs everything to $LOG_DIR/<dirname>.log.
autotools_build() {
	local dir="$1"; shift
	local src="$SRC_DIR/$dir"
	local logf="$LOG_DIR/${dir}.log"
	log "Building $dir (log: logs/${dir}.log)"
	(
		set -e
		# Ignore SIGHUP: the non-interactive host environment delivers SIGHUP to
		# configure sub-probes (python/swig/etc.), which would otherwise abort the
		# build with "Hangup: 1". This is exactly what nohup does.
		trap '' HUP
		cd "$src"
		if [ -x ./autogen.sh ]; then ./autogen.sh; fi
		rm -rf build && mkdir build && cd build
		../configure --prefix="$PREFIX" "$@"
		# Workaround: with very new autoconf (2.73) + libtool (2.5.x), the first
		# configure pass occasionally does not emit the `libtool` wrapper script.
		# Regenerate it explicitly so the compile step does not fail with
		# "./libtool: No such file or directory".
		if [ ! -f libtool ]; then ./config.status libtool; fi
		make -j"$JOBS"
		make install
	) >"$logf" 2>&1 </dev/null || { log_err "$dir build failed. Tail of log:"; tail -n 40 "$logf" >&2; return 1; }
	log_ok "$dir installed into dist/"
}

# --- Optional unit tests -----------------------------------------------------
# make_check <dirname> : run `make check` in the component's build dir. Appends
# to the component log. Non-fatal (warns on failure) since some suites need
# hardware; the summary line is surfaced either way.
make_check() {
	local dir="$1"
	local bld="$SRC_DIR/$dir/build"
	local logf="$LOG_DIR/${dir}.log"
	[ -d "$bld" ] || { log_warn "make_check: no build dir for $dir"; return 0; }
	log "Running 'make check' for $dir"
	if ( trap '' HUP; cd "$bld" && make check ) >>"$logf" 2>&1 </dev/null; then
		log_ok "$dir: make check passed"
	else
		log_warn "$dir: make check reported failures (see logs/${dir}.log)"
	fi
}

# run_make_target <dirname> <target> : run `make <target>` in the build dir,
# non-fatal (used for PulseView's `make test`). Appends to the component log.
run_make_target() {
	local dir="$1" target="$2"
	local bld="$SRC_DIR/$dir/build"
	local logf="$LOG_DIR/${dir}.log"
	[ -d "$bld" ] || { log_warn "run_make_target: no build dir for $dir"; return 0; }
	log "Running 'make $target' for $dir"
	if ( trap '' HUP; cd "$bld" && make "$target" ) >>"$logf" 2>&1 </dev/null; then
		log_ok "$dir: make $target passed"
	else
		log_warn "$dir: make $target reported failures (see logs/${dir}.log)"
	fi
}

# --- Standard CMake build ----------------------------------------------------
# cmake_build <dirname> [extra cmake args...]
# Out-of-tree CMake configure/build/install into $PREFIX. Logs to the component
# log. Same SIGHUP/stdin hardening as autotools_build.
cmake_build() {
	local dir="$1"; shift
	local src="$SRC_DIR/$dir"
	local logf="$LOG_DIR/${dir}.log"
	log "Building $dir with CMake (log: logs/${dir}.log)"
	(
		set -e
		trap '' HUP
		cd "$src"
		rm -rf build && mkdir build && cd build
		cmake -G "Unix Makefiles" \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_INSTALL_PREFIX="$PREFIX" \
			-DCMAKE_PREFIX_PATH="$CMAKE_PREFIX_PATH" \
			"$@" ..
		make -j"$JOBS"
		make install
	) >"$logf" 2>&1 </dev/null || { log_err "$dir build failed. Tail of log:"; tail -n 50 "$logf" >&2; return 1; }
	log_ok "$dir installed into dist/"
}
