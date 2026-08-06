# Switchyard — agent instructions

`CLAUDE.md` at the repo root is the canonical working agreement and this file must be kept in sync
with it. The two rules below are duplicated here **verbatim in substance** because they are
non-negotiable and a pointer is not good enough: violating either causes damage that is not a bug
and cannot be fixed by editing code.

Read `CLAUDE.md` in full before writing any code. Read `docs/switchyard-development-guide.md` for
scope and architecture, and `docs/switchyard-git-internals-and-undo.md` before touching the journal,
the ref layer, or worktrees. Tasks are in `issues/`; `issues/Issues.md` defines the workflow.

## Rule 1 — Licensing. Switchyard is MIT. GitUp is GPLv3.

`../GitUp` (relative to the repo root) is **GPL v3**, copyright 2015-2018 Pierre-Olivier Latour,
GitUpKit included. Switchyard is **MIT**. MIT output cannot carry GPL-derived code, which makes this
strict rather than optional:

- **Never copy GitUp source into Switchyard**, in any language.
- **Never translate GitUp Objective-C into Swift**, line by line or otherwise. That is a derivative
  work regardless of how it is phrased.
- **Never copy GitUp's test fixtures**, including the graph-layout DAG fixtures. Test data counts.
- **Do** read GitUp to understand *what a component solves* and *why it is shaped that way*, then
  close the file and design the Swift equivalent independently. Write the idea into `docs/` in your
  own words and implement from that note, not from the source.

`../../RemoteControl` is MIT by the same author. Its code **may** be copied and adapted freely;
retain the copyright notice where substantial portions are reused. The two sibling repositories have
opposite rules — confusing them is the most likely way this project acquires a legal problem.

If you are unsure whether something is derived from GitUp, stop and ask. Do not guess.

## Rule 2 — Never modify Apple signing assets.

- Do not pass `-allowProvisioningUpdates` or `-allowProvisioningDeviceRegistration`.
- Do not create, revoke, delete, or renew certificates or provisioning profiles — not via
  `xcodebuild`, `security`, `codesign`, `fastlane`, the App Store Connect API, or the developer
  portal. Never delete anything from a keychain.
- Do not change `CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`, or
  `PROVISIONING_PROFILE_SPECIFIER` to make a signing error go away.
- **Build unsigned by default:** `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`.
- **Stop, do not retry**, on: `No signing certificate ... found`, `its private key is not installed
  in your keychain`, `errSecInternalComponent`, `User interaction is not allowed`, or any offer to
  revoke or replace a certificate. Drop to an unsigned build, diagnose read-only, then report and
  wait.

Certificate revocation is remote, account-wide, and irreversible. On 2026-07-24, repeated signed
builds against a sibling project drove Xcode to revoke and reissue the Apple Development certificate
twice.

## Rule 3 — Do not claim verification you did not perform.

"It compiles" is not verification. Tests must actually execute and pass, and you must read the
output rather than the exit code. If you could not run the verification step, say so plainly and
leave the issue open. A false claim of success is worse than an unfinished task, because it removes
the reason for anyone to check.

## Build commands

```sh
# Package tests — the primary suite, touches no signing assets
cd YardKit && swift build && swift test

# Unsigned compile check
xcodebuild build -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet

# Unit tests only — UI tests cannot run headless here
xcodebuild -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' -only-testing:SwitchyardTests test
```

`YardKit/` does not exist yet. The repository is a stock SwiftUI template plus documents and tasks.
