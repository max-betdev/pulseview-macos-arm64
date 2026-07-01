# Build progress

Native Apple Silicon (arm64) build of the sigrok stack + PulseView.

Checkboxes below are flipped automatically by the build/package scripts as each
step completes. See `logs/` for full per-component output and `BUILT_COMMITS.txt`
for the exact git commit built for each repository.

## Tasks

- [x] Prerequisites verified (Homebrew arm64 deps, Xcode CLT) <!-- prereqs -->  _(done 2026-07-01 12:31:33)_
- [x] libserialport built <!-- libserialport -->  _(done 2026-07-01 11:59:53)_
- [x] libsigrok + libsigrokcxx built <!-- libsigrok -->  _(done 2026-07-01 12:13:44)_
- [x] libsigrokdecode built <!-- libsigrokdecode -->  _(done 2026-07-01 12:14:58)_
- [x] sigrok-firmware-fx2lafw built <!-- firmware -->  _(done 2026-07-01 12:21:03)_
- [x] sigrok-cli built <!-- sigrok-cli -->  _(done 2026-07-01 12:21:53)_
- [x] PulseView (Qt6) built <!-- pulseview -->  _(done 2026-07-01 12:25:49)_
- [x] End-to-end build.sh verified <!-- build-script -->  _(done 2026-07-01 12:35:50)_
- [x] PulseView.app assembled <!-- app-bundle -->  _(done 2026-07-01 12:36:55)_
- [x] Ad-hoc signed + .dmg created <!-- dmg -->  _(done 2026-07-01 12:51:22)_
- [x] README + repeatability verified <!-- readme -->  _(done 2026-07-01 13:08:17)_
