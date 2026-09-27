#!/bin/zsh
# adhoc-seal-app.sh <path/to/Switchyard.app> — give an UNSIGNED build a real
# ad-hoc signature with a sealed resource directory (#0418).
#
# Why: CODE_SIGNING_ALLOWED=NO leaves every Mach-O "linker-signed" and the
# bundle with "Sealed Resources=none". SMAppService refuses to load the broker
# agent's plist from such a bundle — smd logs "Unable to validate code
# signature on plist ... Code: -67056" (errSecCSResourcesNotFound) — so launchd
# never owns co.sstools.Switchyard.broker and every CLI command exits 2.
# Measured 2026-09-26 in the Tart VM: the same build re-signed by this script
# registers the broker and `switchyard whereami` exits 0.
#
# Ad-hoc (`--sign -`) uses no certificate, no identity, no keychain and no
# provisioning profile. It is NOT a signing asset and cannot trigger Xcode's
# provisioning repair. No entitlements are applied: the app is unsandboxed by
# design (guide §11 decision 5).
#
# Inside-out: nested code first, the bundle last. `codesign --deep` does not
# reach Contents/Resources/bin, so the CLI is signed explicitly.
set -euo pipefail

APP="${1:?usage: adhoc-seal-app.sh <path/to/App.app>}"
[[ -d "$APP/Contents/MacOS" ]] || { print -u2 "adhoc-seal-app: not an app bundle: $APP"; exit 1; }

for nested in "$APP/Contents/Resources/bin/switchyard" "$APP/Contents/MacOS/BrokerAgent"; do
  if [[ -f "$nested" ]]; then
    codesign --force --sign - --options runtime "$nested"
  fi
done
codesign --force --sign - --options runtime "$APP"
codesign --verify --deep --strict "$APP"
print "adhoc-seal-app: sealed $APP (ad-hoc)"
