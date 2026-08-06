# Switchyard

A SwiftUI macOS git client with an agent-facing CLI (`yard`). Successor in spirit to GitUp, built
so a coding agent is a first-class user of the repository alongside a human.

`switchyard-development-guide.md` is the design document — scope, architecture, CLI surface,
milestones — and it is current. Read it before designing anything. This file is the working
agreement: rules, commands, and traps. Settled decisions live in guide §11; if you make a new one,
record it there rather than only here.

## Licensing — read before writing any code

Switchyard is **MIT** (`LICENSE`). Two reference projects sit next to it and they are not
interchangeable.

**GitUp — `../GitUp` — is GPLv3.** Copyright 2015-2018 Pierre-Olivier Latour. GitUpKit too.
Switchyard is a clean-room reimplementation, and MIT output makes this stricter, not looser:

- **Never copy GitUp source into Switchyard**, in any language. A line-by-line Objective-C to Swift
  translation is a derivative work.
- **Never paste GitUp source into the context window and ask for a Swift port.** Same thing, worse.
- **Never copy GitUp's test fixtures**, including the graph-layout DAG fixtures. They are GPL.
- **Do** read GitUp to understand *what a component solves* and *why it is shaped that way*, then
  close the file and design the Swift equivalent independently.
- When a GitUp idea informs a decision, write the idea into `docs/` in your own words and implement
  from that note, not from the source.

If the plan ever becomes "port it," stop and revisit the license with Brennan before writing code.

**RemoteControl — `../../RemoteControl` — is MIT, same author.** Its code may be copied and adapted
freely. Retain the copyright notice where substantial portions are reused. Port the XPC and CLI
install patterns from it directly; do not reinvent them.

## The agent surface

The CLI is the product for agents. Three rules make it usable by one:

- **`--json` on every command, and `"schemaVersion": 1` in every response.** Human-readable output
  is a courtesy; JSON is the contract. Errors are structured too — a failure in `--json` mode emits
  `{"schemaVersion":1,"ok":false,"error":{"code":"…","message":"…","hint":"…"}}` on stdout.
- **Nothing is interactive unless the command name says so.** No editor, no pager, no prompt.
  `GIT_EDITOR` is never invoked. Interactive commands (`review`, `ask`, `resolve --interactive`)
  fail with exit 3 when the app is not running rather than silently falling back — an agent told to
  get human approval must not proceed without it.
- **Exit codes are meaningful.** Codes 2-5 match RemoteControl exactly; do not renumber them.

**There is no MCP server** — decided, with the reasoning and the conditions for revisiting in guide
§8. Do not add one, and do not let anything depend on one existing.

The skill teaching agents to drive `yard` lives in `skills/yard/SKILL.md` and is **generated from
the same command metadata that builds `--help`**, so it cannot drift from the binary. Hand-written
prose that restates flags will go stale within a milestone. Package it per client (Claude Code
plugin, OpenCode) on top of that one source; do not maintain parallel copies. A command lands with
its documentation regenerated or it does not land.

## Code signing

**Never modify Apple signing assets.** Do not pass `-allowProvisioningUpdates` or
`-allowProvisioningDeviceRegistration`. Do not create, revoke, delete, or renew certificates or
provisioning profiles — not via `xcodebuild`, `security`, `codesign`, `fastlane`, the App Store
Connect API, or the developer portal. Never delete anything from a keychain. Do not change
`CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`, or `PROVISIONING_PROFILE_SPECIFIER` to
make a signing error go away without asking first.

**Build unsigned by default.** Signing is only needed for archives, device installs, and tests that
verify signatures.

**Stop, do not retry, on these stop-words.** `No signing certificate ... found`, `its private key is
not installed in your keychain`, `errSecInternalComponent`, `User interaction is not allowed`, or
any offer to revoke or replace a certificate. Drop to an unsigned build to prove the code compiles,
diagnose read-only, then report and wait.

This is not hypothetical. On 2026-07-24, 52 signed `xcodebuild` runs against RemoteControl — with
Xcode open and automatic signing on — drove `IDEProvisioningRepair` to revoke and reissue the Apple
Development certificate twice. Revocation is remote, account-wide, and irreversible.

**Archives, notarization, and DMG creation are run by a human**, through Xcode's Product → Archive →
Distribute App flow. Prepare commands and hand them over; do not run them. Brennan prefers GUI paths
(Xcode, Keychain Access, Finder, Disk Utility) for anything touching certificates or signing — give
menu paths, not shell.

## Building and testing

```sh
# Unsigned compile check (the default — see above)
xcodebuild build -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet

# Unit tests. UI tests cannot run under CLI-driven xcodebuild here — the runner times out
# enabling automation mode without Accessibility rights. Always scope to SwitchyardTests.
xcodebuild -project Switchyard.xcodeproj -scheme Switchyard \
  -destination 'platform=macOS' -only-testing:SwitchyardTests test

# The Swift package (engine, XPC protocols, CLI). Touches no signing assets — prefer it.
cd YardKit && swift build && swift test
```

`YardKit/` does not exist yet. Until it does, the app target is a stock SwiftUI template — see
[Current state](#current-state).

## Layering

**Everything shareable lives in the package.** The app target owns only SwiftUI views, agent
embedding, `SMAppService` registration, and presentation of results. Anything with logic worth
testing goes in `YardKit` and has unit tests.

**`yard` must work without the app running.** This is the most important architectural constraint in
the project. If the CLI needs Switchyard.app, it is useless in CI, over SSH, and in headless agent
runs — which is most of the addressable use. `YardGit` is standalone; all reads and all
non-interactive mutations run in-process in the CLI with no app, no XPC, no launch agent. The XPC
connection is optional enrichment for `review`, `ask`, `resolve --interactive`, and `watch`.

`ServiceNames.swift` in `YardKit` is the single source of truth for the bundle identifier, Mach
service name, agent plist name, URL scheme, and log subsystem. Nothing else hardcodes those strings.

## Gotchas that have already caused bugs elsewhere

- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** is set on the app target (it already is, in
  `project.pbxproj`). Objective-C callback closures the XPC framework invokes off the main queue —
  `remoteObjectProxyWithErrorHandler`, `interruptionHandler`, `invalidationHandler` — must be marked
  `@Sendable`, or they inherit main-actor isolation and **crash with `SIGTRAP` at runtime with no
  compiler warning**. Pure helpers need explicit `nonisolated` to stay unit-testable.
- **`SMAppService.status` can disagree with launchd.** Drive repair from an actually-failed broker
  call, at most once per launch, rather than trusting the reported status.
- **Keep exactly one copy of the built app on disk.** `SMAppService` registration is keyed to the
  bundle; a DerivedData copy plus one in `/Applications` confuses launchd.
- **`log` is a zsh builtin.** Use `/usr/bin/log stream --predicate 'subsystem ==
  "co.sstools.Switchyard"'`.
- **Xcode rewrites `project.pbxproj` while it has the project open**, and has silently dropped
  hand-added build configurations mid-edit. Verify with `xcodebuild -showBuildSettings` rather than
  trusting the file you just wrote. New Swift files under synchronized groups need no pbxproj edit.
- **libgit2 does not run hooks.** Silently skipping a repo's hooks is a correctness bug, not a
  simplification. Shell out to `git` for hooks, network operations, and signing — every shell-out
  centralized in one `GitProcess` type so the boundary is visible and testable.

## Current state

The repository is a stock SwiftUI macOS template plus the development guide. Nothing in the
architecture above is built yet.

**Milestone 0 is the engine spike, and nothing else starts until it lands.** It answers three
questions in `docs/engine-findings.md` — SSH-signed commits through libgit2, graph layout
performance on a 50k-commit repo, and how libgit2 packages into SwiftPM in 2026 — then the spike
code is deleted. Do not scaffold the app first. If the signing or performance question fails, stop
and escalate; the project's premise depends on both.
