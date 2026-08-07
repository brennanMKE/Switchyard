# Distribution and sandboxing

Prepares guide §11's last open question for a decision. Written for #0073. **The recommendation is
direct distribution; the decision is Brennan's.**

---

## Why this is not a late question

Distribution decides sandboxing, and sandboxing is baked into identifiers that already exist in
`ServiceNames.swift`. It has two concrete consequences, not one, and the second is the dangerous one.

### 1. The Mach service name changes shape

A sandboxed app may only own Mach service names prefixed with an app-group identifier. So
`co.sstools.Switchyard.broker` becomes something like
`ABCDE12345.co.sstools.Switchyard.broker` — the Team ID prefix is not cosmetic, it changes the
launchd plist, the broker, the CLI's connection code, and every doc that names it.

### 2. The state directory silently diverges — and this is the one that bites

`ServiceNames.stateDirectory()` resolves `$XDG_STATE_HOME`, falling back to
`~/.local/state/switchyard/`. **In a sandboxed app, `NSHomeDirectory()` returns the container**, so
the same code resolves to:

```
~/Library/Containers/co.sstools.Switchyard/Data/.local/state/switchyard/
```

while `yard`, running unsandboxed from a shell, resolves to the real
`~/.local/state/switchyard/`.

Nothing fails. Both processes create their directory, write their registry, and read back exactly
what they wrote. They simply never see each other's data — the app shows one set of repositories and
recent operations, the CLI shows another, and neither reports an error. That is a bug that costs a
long day to find, and it is invisible to every test that does not run the app sandboxed *and* the CLI
unsandboxed at the same time.

## What the App Store would cost beyond that

- **The CLI cannot be installed from a sandboxed app.** `/usr/local/bin` is outside the container,
  and the privilege escalation #0051 uses is not available. The App Store version would ship without
  a working `yard` install path — which removes the entire agent-facing half of the product.
- **The launch agent.** `SMAppService` registration of an embedded login item is possible, but the
  broker exists to publish a Mach service that an *external* process connects to. A sandboxed
  service name is reachable only by processes in the same app group, and a CLI installed to
  `/usr/local/bin` is not.
- **Repository access.** A git client needs to read arbitrary paths the user chooses. Security-scoped
  bookmarks make this workable for the app, but hooks (#0041) run as ordinary subprocesses outside
  the container's grants.

Each is solvable in isolation. Together they mean the App Store build is a different product: a
graphical git client with no CLI, which is precisely the half that already exists elsewhere.

## Recommendation

**Direct distribution, unsandboxed, Developer ID signed and notarized.**

The project's stated differentiator is `review --wait` — an agent pushing a diff into a real macOS UI
and blocking on a human decision. That requires a CLI outside the container talking to an app inside
it, which is the one thing sandboxing most directly prevents.

Guide §1 already lists sandboxing under non-goals for exactly this reason. This document is the
evidence for keeping it there, not a new position.

**If the App Store is wanted later**, the honest shape is two products: a sandboxed, app-only build
with no CLI and no hooks, and the direct build that is the real thing. That is a decision to make
deliberately, not to back into by choosing a distribution channel first.

## What this settles

- `ServiceNames.machServiceName` keeps its unprefixed form.
- `stateDirectory()` stays as written, and the app and CLI genuinely share it.
- #0074's release script targets Developer ID plus notarization, not an App Store upload.
- Guide §11's open question 3 closes.

## What remains for Brennan

Notarization needs an Apple Developer account action and a Developer ID certificate. Per `CLAUDE.md`
that work is his: archives, notarization, and DMG creation run through Xcode's Distribute App flow,
and nothing here should create or modify a signing asset.
