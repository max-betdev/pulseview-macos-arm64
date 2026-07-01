#!/usr/bin/env bash
#
# package.sh - Assemble a self-contained, ad-hoc-signed PulseView.app from the
#              contents of ./dist, then build a distributable .dmg.
#
# Prerequisite: ./build.sh has populated ./dist (pulseview, libs, decoders,
# firmware). Run:  ./package.sh
#
# Output (in the workspace root):
#   PulseView.app          - drag to /Applications
#   PulseView-<ver>.dmg    - shareable disk image
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/env.sh"
source "$HERE/scripts/lib.sh"
trap '' HUP

APP="PulseView"
BIN="pulseview"
APP_BUNDLE="$ROOT/$APP.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"
RES="$CONTENTS/Resources"
SHARE="$CONTENTS/share"
PLUGINS="$CONTENTS/PlugIns"
LOGF="$LOG_DIR/package.log"

# Python framework details (must match what libsigrokdecode linked against).
PY_FRAMEWORK_SRC="$PY_PREFIX/Frameworks/Python.framework"
PY_DYLIB_OLD="$PY_PREFIX/Frameworks/Python.framework/Versions/$PYVER/Python"

APPVER="0.5.0-git-$(git -C "$SRC_DIR/pulseview" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# -----------------------------------------------------------------------------
require_built() {
	[ -x "$PREFIX/bin/$BIN" ] || die "dist/bin/$BIN not found. Run ./build.sh first."
	[ -d "$PREFIX/share/libsigrokdecode/decoders" ] || die "decoders missing in dist/. Run ./build.sh."
	[ -d "$PY_FRAMEWORK_SRC/Versions/$PYVER" ] || die "Python framework not found: $PY_FRAMEWORK_SRC/Versions/$PYVER"
	log "Packaging $APP $APPVER (python $PYVER, Qt from $QT_PREFIX)"
}

# 1) Lay out the .app skeleton and copy in the binary, decoders and firmware.
stage_skeleton() {
	log "Staging app skeleton"
	rm -rf "$APP_BUNDLE"
	mkdir -p "$MACOS" "$FRAMEWORKS" "$RES" "$SHARE"
	cp "$PREFIX/bin/$BIN" "$MACOS/$BIN"

	cp -R "$PREFIX/share/libsigrokdecode" "$SHARE/"
	cp -R "$PREFIX/share/sigrok-firmware" "$SHARE/"
	# Strip build/browsing artifacts so the embedded interpreter does not try to
	# import them as decoders and so the bundle stays clean.
	find "$SHARE/libsigrokdecode" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
	find "$SHARE" -name '.DS_Store' -delete 2>/dev/null || true
	log_ok "skeleton staged ($(ls "$SHARE/libsigrokdecode/decoders" | wc -l | tr -d ' ') decoder entries)"
}

# 2) Info.plist BEFORE macdeployqt, so it can locate the executable reliably.
write_info_plist() {
	log "Writing Info.plist"
	cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>              <string>$APP</string>
	<key>CFBundleDisplayName</key>       <string>$APP</string>
	<key>CFBundleExecutable</key>        <string>$BIN</string>
	<key>CFBundleIdentifier</key>        <string>org.sigrok.PulseView</string>
	<key>CFBundleVersion</key>           <string>$APPVER</string>
	<key>CFBundleShortVersionString</key><string>$APPVER</string>
	<key>CFBundlePackageType</key>       <string>APPL</string>
	<key>CFBundleSignature</key>         <string>????</string>
	<key>CFBundleIconFile</key>          <string>$BIN.icns</string>
	<key>NSHighResolutionCapable</key>   <true/>
	<key>NSPrincipalClass</key>          <string>NSApplication</string>
	<key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>    <string>11.0</string>
</dict>
</plist>
PLIST
}

# 3) Let Qt bundle its frameworks, plugins, qt.conf and the linked dylibs.
run_macdeployqt() {
	log "Running macdeployqt (bundling Qt + dependent dylibs)"
	( "$QT_PREFIX/bin/macdeployqt" "$APP_BUNDLE" -verbose=1 ) >"$LOGF" 2>&1 </dev/null \
		|| { log_err "macdeployqt failed. Tail:"; tail -n 30 "$LOGF" >&2; return 1; }
	log_ok "macdeployqt done"
}

# 3b) Bundle the "offscreen" QPA plugin in addition to "cocoa". It lets the app
#     run headless (CI / automated smoke tests) and is otherwise harmless. Its
#     Qt framework deps are fixed up by relocate_deps.
add_offscreen_plugin() {
	local plat="$PLUGINS/platforms" src
	# -L: the Homebrew qt prefix is a symlink, so follow it while searching.
	src="$(find -L "$QT_PREFIX" -name 'libqoffscreen.dylib' 2>/dev/null | head -1)"
	if [ -n "$src" ] && [ -d "$plat" ]; then
		cp "$src" "$plat/" && chmod u+w "$plat/libqoffscreen.dylib"
		log_ok "added offscreen QPA plugin"
	else
		log_warn "offscreen plugin not found; headless run unavailable (GUI still works)"
	fi
}

# 4) Bundle the Python framework that libsigrokdecode dlopen()s, and repoint it.
bundle_python() {
	log "Bundling Python $PYVER framework"
	local dest="$FRAMEWORKS/Python.framework"
	rm -rf "$dest"
	mkdir -p "$dest/Versions/$PYVER"
	# Copy the version payload (dereferences symlinks) and recreate the symlinks.
	cp -R "$PY_FRAMEWORK_SRC/Versions/$PYVER/" "$dest/Versions/$PYVER/"
	( cd "$dest/Versions" && ln -sfn "$PYVER" Current )
	( cd "$dest" && ln -sfn "Versions/Current/Python" Python && ln -sfn "Versions/Current/Resources" Resources 2>/dev/null || true )

	# Trim things not needed at runtime to keep the bundle small.
	local V="$dest/Versions/$PYVER"
	chmod -R u+w "$V"
	rm -rf "$V/Headers" "$V/bin" "$V/include" "$V/share" \
		"$V/lib/pkgconfig" \
		"$V/Resources/Python.app" \
		"$V/lib/python$PYVER/test" "$V/lib/python$PYVER/idlelib" \
		"$V/lib/python$PYVER/tkinter" "$V/lib/python$PYVER/turtledemo" \
		"$V/lib/python$PYVER/lib2to3" 2>/dev/null || true
	find "$V" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
	find "$V" -name '.DS_Store' -delete 2>/dev/null || true

	# Repoint libsigrokdecode (copied into Frameworks by macdeployqt) at the
	# bundled framework instead of the Homebrew one. Discover the exact current
	# reference (it may use the opt/ or Cellar/ path) rather than assuming.
	local srd cur
	srd="$(ls "$FRAMEWORKS"/libsigrokdecode.*.dylib 2>/dev/null | head -1)"
	if [ -n "$srd" ]; then
		cur="$(otool -L "$srd" | awk '/Python\.framework.*\/Python /{print $1; exit}')"
		if [ -n "$cur" ]; then
			# Use @loader_path (relative to libsigrokdecode itself, which lives in
			# Frameworks/) so resolution does NOT depend on an LC_RPATH existing.
			install_name_tool -change "$cur" \
				"@loader_path/Python.framework/Versions/$PYVER/Python" "$srd"
			log_ok "repointed $(basename "$srd") Python ref -> bundled framework"
		fi
	else
		log_warn "libsigrokdecode not found in Frameworks (macdeployqt may not have copied it)"
	fi
	# Give the bundled Python dylib a bundle-relative id.
	install_name_tool -id "@executable_path/../Frameworks/Python.framework/Versions/$PYVER/Python" \
		"$V/Python" 2>/dev/null || true
}

# 4b) Relocate any remaining Homebrew deps into the bundle and fix their install
#     names. macdeployqt copies the top-level dylibs but leaves some inter-lib
#     references absolute (e.g. libbrotlidec -> libbrotlicommon) and does not
#     touch the Python C-extensions' deps (openssl, sqlite, mpdecimal, ...).
#     dylibbundler follows the whole graph and rewrites everything to
#     @executable_path/../Frameworks. The Python framework's own binary is a
#     framework (not a flat dylib) and is intentionally not relocated.
relocate_deps() {
	log "Relocating Homebrew dependencies into the bundle"
	local rp="@executable_path/../Frameworks"
	# Ensure @rpath resolves inside the bundle (macdeployqt may not add one).
	install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/$BIN.real" 2>/dev/null || true
	local -a queue=()

	# Seed set: files whose OWN identity we keep, but whose external deps we
	# bundle. The Python framework binary is a seed (kept as a framework) so its
	# deps (e.g. libintl) get relocated without turning it into a flat dylib.
	queue+=("$MACOS/$BIN.real")
	local f
	while IFS= read -r -d '' f; do queue+=("$f"); done \
		< <(find "$FRAMEWORKS" -maxdepth 1 -type f -name '*.dylib' -print0)
	[ -f "$FRAMEWORKS/Python.framework/Versions/$PYVER/Python" ] && \
		queue+=("$FRAMEWORKS/Python.framework/Versions/$PYVER/Python")
	while IFS= read -r -d '' f; do queue+=("$f"); done \
		< <(find "$FRAMEWORKS/Python.framework" -name '*.so' -print0)
	# Qt plugins (cocoa/offscreen/imageformats/styles). macdeployqt already fixed
	# the ones it copied; a manually added offscreen plugin still needs fixing.
	while IFS= read -r -d '' f; do queue+=("$f"); done \
		< <(find "$CONTENTS/PlugIns" -type f -name '*.dylib' -print0 2>/dev/null)

	# Process the queue to a fixpoint: newly copied libs are appended and later
	# scanned for their own external deps (transitive closure).
	local i=0 copied=0
	while [ "$i" -lt "${#queue[@]}" ]; do
		local file="${queue[$i]}"; i=$((i+1))
		[ -f "$file" ] || continue
		local own_id dep base dest fwname fwrest
		own_id="$(otool -D "$file" 2>/dev/null | tail -n +2 | head -1)"
		while IFS= read -r dep; do
			# Only relocate absolute Homebrew / build-prefix references.
			case "$dep" in
				/opt/homebrew/*|"$PREFIX"/*) : ;;
				*) continue ;;
			esac
			# Never rewrite a file's own install-id as if it were a dependency.
			[ "$dep" = "$own_id" ] && continue

			if [[ "$dep" == *.framework/* ]]; then
				# Framework dependency (Qt*, Python): point at the copy macdeployqt
				# already placed in Frameworks/. Do NOT flatten it into a dylib.
				fwname="$(basename "${dep%%.framework/*}").framework"   # e.g. QtGui.framework
				fwrest="${dep#*.framework/}"                            # e.g. Versions/A/QtGui
				install_name_tool -change "$dep" "$rp/$fwname/$fwrest" "$file" 2>/dev/null || true
				continue
			fi

			# Plain dylib: copy into Frameworks (once) and repoint.
			base="$(basename "$dep")"
			dest="$FRAMEWORKS/$base"
			if [ ! -f "$dest" ]; then
				cp "$dep" "$dest" 2>/dev/null || { log_warn "copy failed: $dep"; continue; }
				chmod u+w "$dest"
				install_name_tool -id "$rp/$base" "$dest" 2>/dev/null || true
				queue+=("$dest"); copied=$((copied+1))
			fi
			install_name_tool -change "$dep" "$rp/$base" "$file" 2>/dev/null || true
		done < <(otool -L "$file" 2>/dev/null | tail -n +2 | awk '{print $1}')
	done

	# Some libs macdeployqt copied still advertise an absolute install-id (e.g.
	# libbrotlicommon). Rewrite the id of every flat dylib in Frameworks so no
	# self-reference points back at Homebrew.
	while IFS= read -r -d '' f; do
		local oid; oid="$(otool -D "$f" 2>/dev/null | tail -n +2 | head -1)"
		case "$oid" in
			/opt/homebrew/*|"$PREFIX"/*)
				install_name_tool -id "$rp/$(basename "$f")" "$f" 2>/dev/null || true ;;
		esac
	done < <(find "$FRAMEWORKS" -maxdepth 1 -type f -name '*.dylib' -print0)

	log_ok "relocation complete ($copied additional lib(s) bundled)"
}

# 8) Ad-hoc code-sign everything. On Apple Silicon an invalid/missing signature
#    (which our install_name_tool edits create) causes the kernel to SIGKILL the
#    process, so this is REQUIRED to run, not just for distribution. Sign
#    inside-out: nested Mach-O first, frameworks next, then the whole .app.
codesign_bundle() {
	log "Ad-hoc code-signing the bundle"
	# Remove any bytecode caches first: if they exist at signing time they get
	# sealed, but a later interpreter run could still differ. We both strip them
	# here AND set PYTHONDONTWRITEBYTECODE in the wrapper so nothing appears
	# post-signing to invalidate the seal.
	find "$APP_BUNDLE" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
	find "$APP_BUNDLE" -name '.DS_Store' -delete 2>/dev/null || true
	local f
	# All plain Mach-O libraries and Python extension modules.
	while IFS= read -r -d '' f; do
		codesign --force --sign - --timestamp=none "$f" 2>/dev/null || log_warn "sign failed: ${f#$APP_BUNDLE/}"
	done < <(find "$APP_BUNDLE" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)
	# Framework bundles (Qt*, Python).
	while IFS= read -r -d '' f; do
		codesign --force --sign - --timestamp=none "$f" 2>/dev/null || true
	done < <(find "$APP_BUNDLE" -type d -name '*.framework' -print0)
	# The real Mach-O executable.
	codesign --force --sign - --timestamp=none "$MACOS/$BIN.real"
	# Finally seal the whole app (also covers the wrapper script + resources).
	codesign --force --sign - --timestamp=none --deep "$APP_BUNDLE"
	if codesign --verify --verbose=2 "$APP_BUNDLE" >/dev/null 2>&1; then
		log_ok "ad-hoc signature valid"
	else
		log_warn "codesign --verify reported issues (see below)"
		codesign --verify --verbose=2 "$APP_BUNDLE" 2>&1 | tail -5 >&2 || true
	fi
}

# 9) Build a distributable disk image with a drag-to-Applications shortcut.
make_dmg() {
	local dmg="$ROOT/$APP-$APPVER.dmg"
	local stage="$ROOT/.dmg_stage"
	log "Creating DMG"
	rm -rf "$stage" "$dmg"; mkdir -p "$stage"
	ditto "$APP_BUNDLE" "$stage/$APP.app"   # ditto preserves signatures + xattrs
	ln -s /Applications "$stage/Applications"
	hdiutil create "$dmg" -volname "$APP $APPVER" -fs HFS+ \
		-srcfolder "$stage" -ov -quiet
	rm -rf "$stage"
	log_ok "DMG created: $(basename "$dmg")  ($(du -h "$dmg" | awk '{print $1}'))"
	progress_mark dmg
}

# 5) Wrapper executable: sets PYTHONHOME + sigrok dirs, then execs the real bin.
install_wrapper() {
	log "Installing launch wrapper"
	mv "$MACOS/$BIN" "$MACOS/$BIN.real"
	cat > "$MACOS/$BIN" <<'WRAP'
#!/bin/sh
# PulseView.app launcher: make the app self-contained WITHOUT discarding a
# user-provided custom decoder directory.
here="$(cd "$(dirname "$0")" && pwd)"
contents="$(cd "$here/.." && pwd)"
export PYTHONHOME="$contents/Frameworks/Python.framework/Versions/__PYVER__"
export SIGROK_FIRMWARE_DIR="$contents/share/sigrok-firmware"
# Never write .pyc caches: doing so would modify the (signed) bundle at runtime
# and invalidate its code signature, which macOS then refuses to launch.
export PYTHONDONTWRITEBYTECODE=1

# The app ships its own decoders. libsigrokdecode reads SIGROKDECODE_DIR as a
# single directory and SIGROKDECODE_PATH as a colon-separated list. If the user
# already set SIGROKDECODE_DIR to their own decoders, keep the app's built-in
# set on SIGROKDECODE_DIR and forward the user's directory (plus any existing
# SIGROKDECODE_PATH) via SIGROKDECODE_PATH, so BOTH are searched. libsigrokdecode
# adds the PATH entries last, so the user's decoders take precedence on clashes.
_user_srd_dir="$SIGROKDECODE_DIR"
export SIGROKDECODE_DIR="$contents/share/libsigrokdecode/decoders"
if [ -n "$_user_srd_dir" ] && [ "$_user_srd_dir" != "$SIGROKDECODE_DIR" ]; then
	export SIGROKDECODE_PATH="${_user_srd_dir}${SIGROKDECODE_PATH:+:$SIGROKDECODE_PATH}"
fi

exec "$here/pulseview.real" "$@"
WRAP
	sed -i '' "s/__PYVER__/$PYVER/g" "$MACOS/$BIN"
	chmod 755 "$MACOS/$BIN"
	log_ok "wrapper installed (PYTHONHOME + SIGROKDECODE_DIR + SIGROK_FIRMWARE_DIR)"
}

# 6) Best-effort app icon generated from PulseView's logo.
make_icon() {
	log "Generating app icon (best effort)"
	# 1) Preferred: the official multi-resolution PulseView .icns from the sigrok
	#    project (best quality). Best-effort; skipped cleanly when offline.
	local official="https://raw.githubusercontent.com/sigrokproject/sigrok-util/master/cross-compile/macosx/contrib/pulseview.icns"
	if curl -fsSL --max-time 20 "$official" -o "$RES/$BIN.icns" 2>/dev/null && [ -s "$RES/$BIN.icns" ]; then
		log_ok "icon: official pulseview.icns"
		return 0
	fi

	# 2) Fallback: build an .icns from the logo PNG shipped in the source. The
	#    iconset directory MUST end in .iconset for iconutil to accept it.
	local src_png="$SRC_DIR/pulseview/icons/pulseview.png"
	[ -f "$src_png" ] || src_png="$(find "$SRC_DIR/pulseview" -type f -iname 'pulseview.png' 2>/dev/null | head -1)"
	if [ -n "$src_png" ] && [ -f "$src_png" ]; then
		local iconset="$ROOT/.pulseview.iconset"
		rm -rf "$iconset"; mkdir -p "$iconset"
		local s
		for s in 16 32 128 256 512; do
			sips -z $s $s        "$src_png" --out "$iconset/icon_${s}x${s}.png"    >/dev/null 2>&1 || true
			sips -z $((s*2)) $((s*2)) "$src_png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
		done
		if iconutil -c icns "$iconset" -o "$RES/$BIN.icns" >/dev/null 2>&1 && [ -s "$RES/$BIN.icns" ]; then
			log_ok "icon: generated from source logo (upscaled from $(sips -g pixelWidth "$src_png" 2>/dev/null | awk '/pixelWidth/{print $2}')px)"
			rm -rf "$iconset"
			return 0
		fi
		rm -rf "$iconset"
	fi

	# 3) No icon: drop the key so Finder uses the generic app icon.
	log_warn "could not build an icon; using the default app icon"
	/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$CONTENTS/Info.plist" 2>/dev/null || true
}

# 7) Report any dependency still pointing outside the bundle (should be none,
#    except system libs under /usr/lib and /System).
verify_selfcontained() {
	log "Verifying the bundle is self-contained"
	local leftovers
	leftovers="$(find "$APP_BUNDLE" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null \
		| xargs -0 otool -L 2>/dev/null \
		| grep -E "$(printf '%s' "$PREFIX")|/opt/homebrew" || true)"
	if [ -n "$leftovers" ]; then
		log_warn "External references still present:"
		printf '%s\n' "$leftovers" | sed 's/^/    /' | head -40 >&2
		return 1
	fi
	log_ok "no references to /opt/homebrew or the build prefix remain"
}

main() {
	require_built
	stage_skeleton
	write_info_plist
	run_macdeployqt
	add_offscreen_plugin
	bundle_python
	install_wrapper       # renames binary to pulseview.real (needed by relocate_deps)
	relocate_deps
	make_icon
	verify_selfcontained || log_warn "bundle has external refs; see above (may need extra relocation)"
	progress_mark app-bundle
	log_ok "PulseView.app assembled at $APP_BUNDLE"
	codesign_bundle       # must be AFTER all install_name_tool / file edits
	make_dmg
	echo
	log_ok "Packaging complete:"
	log "  $APP_BUNDLE"
	log "  $ROOT/$APP-$APPVER.dmg"
}

main "$@"
