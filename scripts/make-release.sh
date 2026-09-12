#!/usr/bin/env zsh
#
# make-release.sh — produce a deployable Release build of Switchyard (#0356)
# and, with `package` (#0357), a drag-to-Applications .dmg beside it.
#
# Actions:  release (default) — build/Switchyard-<shortsha>.app
#           package           — the app, then build/Switchyard-<shortsha>.dmg
#
# Produces build/Switchyard-<shortsha>.app from a Release configuration via
# `xcodebuild archive` + `xcodebuild -exportArchive`. The default and only
# mode is UNSIGNED LOCAL: no signing identity, no provisioning, no keychain
# access of any kind. Developer ID signing and notarization are a later,
# explicitly out-of-scope concern — and when they arrive, every signing step
# in them is a human action (AGENTS.md Rule 2).
#
# Unsigned is the right default for same-user testing across two machines:
# Gatekeeper only blocks *quarantined* downloads, and an app copied directly
# (scp, AirDrop, USB) carries no quarantine attribute.
#
# Preflight fails fast with readable messages. The script cleans its own
# scratch under build/ and writes nowhere else.

set -euo pipefail

REPO_ROOT="${0:A:h:h}"
cd "$REPO_ROOT"

MODE="unsigned-local"
PROJECT="Switchyard.xcodeproj"
SCHEME="Switchyard"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/Switchyard.xcarchive"
EXPORT_DIR="$BUILD_DIR/release-export"
DERIVED_DATA="$BUILD_DIR/DerivedData"

die() {
  print -u2 "make-release: $1"
  exit 1
}

# Rule 2: any of these in xcodebuild output is a hard stop, not a retry.
SIGNING_STOP_WORDS=(
  "No signing certificate"
  "its private key is not installed"
  "errSecInternalComponent"
  "User interaction is not allowed"
  "Revoke certificate"
  "revoke"
  "Provisioning profile"
  "allowProvisioningUpdates"
)

ACTION="release"
if [[ $# -gt 1 ]]; then
  die "usage: make-release.sh [release|package]. Developer ID signing is out of scope (Rule 2: a human action, never scripted)."
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    release|package) ACTION="$1" ;;
    *) die "unknown action '$1' — usage: make-release.sh [release|package]" ;;
  esac
fi

# --- Preflight --------------------------------------------------------------

[[ -d .git || -f .git ]] || die "not a git work tree: $REPO_ROOT. Refusing to build an artifact whose provenance cannot be named."
command -v xcodebuild >/dev/null || die "xcodebuild not found on PATH — install Xcode command line tools."
[[ -d "$PROJECT" ]] || die "$PROJECT not found in $REPO_ROOT."
[[ -f YardKit/Package.swift ]] || die "YardKit/Package.swift not found — the app target embeds the CLI from this package."
if [[ $ACTION == package ]]; then
  command -v hdiutil >/dev/null || die "hdiutil not found on PATH — the package action builds the .dmg with it."
fi

SCHEMES="$(xcodebuild -list -project "$PROJECT" 2>/dev/null)" \
  || die "could not list schemes from $PROJECT — is the project readable?"
print -- "$SCHEMES" | grep -q "    $SCHEME\$" \
  || die "scheme '$SCHEME' not found in $PROJECT. Run: xcodebuild -list -project $PROJECT"

print "preflight: ok"
print "mode: $MODE (no signing — CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO; Developer ID/notarization out of scope)"

SHA="$(git rev-parse --short HEAD)" || die "git rev-parse failed inside $REPO_ROOT."
if [[ -n "$(git status --porcelain)" ]]; then
  SHA="$SHA-dirty"
  print "note: working tree has uncommitted changes; artifact stamped $SHA"
fi
ARTIFACT="$BUILD_DIR/Switchyard-$SHA.app"

# --- Idempotent cleanup of our own scratch -----------------------------------

rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$ARTIFACT"

# --- Archive -----------------------------------------------------------------

print "step: archiving (Release, $SCHEME) — this is the slow step"
mkdir -p "$BUILD_DIR" "$EXPORT_DIR"
ARCHIVE_LOG="$EXPORT_DIR/archive.log"
set +e
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -quiet >"$ARCHIVE_LOG" 2>&1
ARCHIVE_STATUS=$?
set -e

if [[ $ARCHIVE_STATUS -ne 0 ]]; then
  for word in "${SIGNING_STOP_WORDS[@]}"; do
    if grep -q "$word" "$ARCHIVE_LOG"; then
      print -u2 "make-release: ARCHIVE FAILED and output matches a Rule 2 signing stop-word ('$word')."
      print -u2 "STOP — do not retry, do not change signing settings. Report the error text."
      exit 2
    fi
  done
  print -u2 "make-release: archive failed (exit $ARCHIVE_STATUS). Last output:"
  tail -30 "$ARCHIVE_LOG" >&2 || true
  exit 1
fi
print "step: archive ok"

# --- Export ------------------------------------------------------------------
#
# Measured 2026-09-12 (issue #0356 round 1): export with method "mac-application"
# and signing disabled SUCCEEDS — this is the primary path. The copy fallback
# exists for environments where -exportArchive refuses an unsigned archive for
# a reason that is not a Rule 2 stop.

cat > "$EXPORT_DIR/exportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>mac-application</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

EXPORT_LOG="$EXPORT_DIR/export.log"
set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_DIR/exportOptions.plist" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >"$EXPORT_LOG" 2>&1
EXPORT_STATUS=$?
set -e

if [[ $EXPORT_STATUS -eq 0 ]]; then
  print "step: export via xcodebuild -exportArchive ok"
else
  STOPPED=""
  for word in "${SIGNING_STOP_WORDS[@]}"; do
    if grep -q "$word" "$EXPORT_LOG"; then
      STOPPED="$word"
      break
    fi
  done
  if [[ -n "$STOPPED" ]]; then
    print -u2 "make-release: EXPORT FAILED and output matches a Rule 2 signing stop-word ('$STOPPED')."
    print -u2 "STOP — do not retry, do not change signing settings. Report the error text."
    exit 2
  fi
  # Fallback (documented): copy the .app straight out of the archive. The
  # archive's Products/Applications copy is the same build the export would
  # have sealed; with signing disabled the export step is only packaging.
  print "note: -exportArchive failed (exit $EXPORT_STATUS) — using documented fallback: copying the .app out of the archive"
  tail -10 "$EXPORT_LOG" >&2 || true
  ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/Switchyard.app"
  [[ -d "$ARCHIVE_APP" ]] || die "fallback failed: $ARCHIVE_APP does not exist inside the archive."
  cp -R "$ARCHIVE_APP" "$EXPORT_DIR/Switchyard.app"
  print "step: export via archive copy fallback ok"
fi

mv "$EXPORT_DIR/Switchyard.app" "$ARTIFACT"
print "step: artifact staged at $ARTIFACT"

# --- Verify the bundle -------------------------------------------------------

fail=0
check_file() {
  if [[ -f "$ARTIFACT/$1" ]]; then
    print "verify: ok      $1"
  else
    print "verify: MISSING $1"
    fail=1
  fi
}

check_file "Contents/MacOS/Switchyard"
check_file "Contents/MacOS/BrokerAgent"
check_file "Contents/Library/LaunchAgents/co.sstools.Switchyard.broker.plist"
check_file "Contents/Resources/bin/switchyard"

# Every Mach-O we ship must link only against system libraries — no
# /opt/homebrew, no build-machine paths, no DerivedData. The paths the
# AgentRegistrar and the CLI installer expect are asserted above.
for macho in \
  "Contents/MacOS/Switchyard" \
  "Contents/MacOS/BrokerAgent" \
  "Contents/Resources/bin/switchyard"; do
  if [[ -f "$ARTIFACT/$macho" ]] && otool -L "$ARTIFACT/$macho" 2>/dev/null | grep -qE '/opt/homebrew|/Users/|DerivedData|Xcode\.app'; then
    print "verify: FAIL    $macho links build-machine paths:"
    otool -L "$ARTIFACT/$macho" | grep -E '/opt/homebrew|/Users/|DerivedData|Xcode\.app'
    fail=1
  else
    print "verify: ok      $macho — system libraries only"
  fi
done

if [[ $fail -ne 0 ]]; then
  die "bundle verification failed — $ARTIFACT is not deployable"
fi

if [[ $ACTION == release ]]; then
  print ""
  print "done: mode=$MODE"
  print "artifact: $ARTIFACT"
  print "sha: $SHA"
  print "copy it somewhere useful: cp -R $ARTIFACT /Applications/Switchyard.app"
  exit 0
fi

# --- Package (#0357): the drag-to-Applications .dmg --------------------------
#
# Measured 2026-09-12: create-dmg is not installed on this machine
# (command -v create-dmg → nothing), so the layout is hdiutil's own: a staged
# volume holding Switchyard.app beside an /Applications symlink — the standard
# drag-to-Applications window. Window positioning/background polish is
# optional per the issue and deferred; the criterion is the gesture working.

print "step: packaging $ARTIFACT into build/Switchyard-$SHA.dmg"
STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/Switchyard-$SHA.dmg"
rm -rf "$STAGING"
rm -f "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$ARTIFACT" "$STAGING/Switchyard.app"
ln -s /Applications "$STAGING/Applications"

DMG_LOG="$BUILD_DIR/dmg-create.log"
set +e
hdiutil create -volname Switchyard -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" \
  >"$DMG_LOG" 2>&1
DMG_STATUS=$?
set -e
if [[ $DMG_STATUS -ne 0 ]]; then
  print -u2 "make-release: hdiutil create failed (exit $DMG_STATUS). Last output:"
  tail -20 "$DMG_LOG" >&2 || true
  exit 1
fi
print "step: hdiutil create ok (UDZO)"

# Self-check: attach read-only, confirm the layout, detach. Nothing is left
# mounted and the staging tree is removed either way on success.
MOUNT="$REPO_ROOT/$BUILD_DIR/dmg-mount"
rm -rf "$MOUNT"
mkdir -p "$MOUNT"
set +e
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG_PATH" >/dev/null 2>&1
ATTACH_STATUS=$?
set -e
if [[ $ATTACH_STATUS -ne 0 ]]; then
  die "package: could not attach $DMG_PATH read-only for the layout check."
fi
if [[ ! -d "$MOUNT/Switchyard.app" || ! -L "$MOUNT/Applications" ]]; then
  hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  die "package: layout check failed — Switchyard.app or the Applications link is missing from $DMG_PATH."
fi
print "verify: ok      Switchyard.app + Applications link in the mounted volume"
set +e
hdiutil detach "$MOUNT" >/dev/null 2>&1
DETACH_STATUS=$?
set -e
if [[ $DETACH_STATUS -ne 0 ]]; then
  die "package: could not detach $MOUNT — detach it by hand before rebuilding."
fi
rm -rf "$STAGING"

print ""
print "done: mode=$MODE action=$ACTION"
print "artifact: $ARTIFACT"
print "dmg: $DMG_PATH"
print "sha: $SHA"
print "install gesture: open $DMG_PATH and drag Switchyard.app onto Applications"
