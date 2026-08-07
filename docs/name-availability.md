# Name availability findings

Checked 2026-08-06 for #0071, before the identifiers in guide §3 are relied on further.

**Headline: `yard` is not available as a CLI name. `Switchyard` as a product name is crowded but
workable.**

---

## `yard` — the binary name

**The Ruby documentation tool YARD ships an executable named exactly `yard`.**

| Evidence | Value |
|---|---|
| RubyGems downloads | **230,081,312** |
| Current version | 0.9.45 |
| Declared executables | `s.executables = ['yard', 'yardoc', 'yri']` |
| Default gem executable directory on this machine | `/usr/local/bin` |

That last row is the problem. Guide §3 specifies our install location as **`/usr/local/bin/yard`**,
and RubyGems' default executable directory on this machine is **the same `/usr/local/bin`**. Any
developer who has ever run `gem install yard` — or installed a gem that depends on it, which is
common in Ruby projects — either already owns that path or will overwrite ours later.

It is free on this machine right now (`ls /usr/local/bin/yard` → absent), which is exactly how this
kind of collision stays invisible until a user hits it.

**Why this matters more than an ordinary name clash:** #0051 makes the CLI installer detect `PATH`
shadowing and refuse to clobber. So the good outcome is that Switchyard *refuses to install* for
Ruby developers, and the bad outcome is that a gem install silently replaces our symlink and
`yard whereami` starts printing YARD's usage text to an agent that cannot interpret it.

### Options

1. **Rename the binary.** `switchyard` is long to type; `syd`, `swy`, or `yrd` are free-looking but
   cryptic. A distinct name costs one rename now — `ServiceNames.cliName`, `cliInstallPath`, the
   skill (#0066), every doc example — and the rename is cheap **today** and expensive after M1's
   command surface and JSON schemas are published.
2. **Keep `yard` and rely on collision detection.** #0051 already has to detect shadowing. This
   accepts that some Ruby developers cannot install the CLI under its default name.
3. **Keep `yard` but install as something else by default**, with `yard` offered as an optional
   alias the user opts into. Best of both, at the cost of two names in the documentation.

**Recommendation: option 1, decided now.** The install path collision is real and in the default
location for both tools, and every day of delay makes the rename touch more surface.

---

## `Switchyard` — the product name

Not exclusive, but no blocking conflict found in this space.

| Ecosystem | Result |
|---|---|
| **Homebrew formula** `switchyard` | No formula (404) — available |
| **Homebrew formula** `yard` | No formula — YARD is distributed as a gem, not a formula |
| **npm** `switchyard` | **Taken** — v0.1.0, "Dynamic routing library for express.js applications", 3 versions |
| **crates.io** `switchyard` | **Taken** — "Real-time compute focused async executor" |
| **GitHub** | `NVIDIA-NeMo/Switchyard` (193★), `alyraffauf/switchyard` (108★), `BVE-Reborn/switchyard` (74★, the Rust crate), `jboss-switchyard/quickstarts` (62★, a retired Red Hat ESB) |

None of these is a Mac git client, so there is no trademark-style conflict in category. The npm and
crates.io names are unavailable, but Switchyard publishes to neither — a Homebrew cask and a direct
download are the distribution paths, and the Homebrew name is free.

The JBoss SwitchYard association is the weakest point: it was a well-known Red Hat ESB product, so
searches for "switchyard" surface enterprise middleware. That is a discoverability cost, not a
blocker.

### Not yet checked

- **Domain availability** — needs a registrar lookup, not an API this document can cite.
- **App Store name** — only checkable through App Store Connect, which requires signing in as
  Brennan. Deferred to him; it is also only needed if #0073 chooses App Store distribution.

---

## What this blocks

`ServiceNames.cliName` and `cliInstallPath` (#0007) are already committed with `yard`. They are one
constant each and a test asserts the install path ends with the CLI name, so a rename is currently a
two-line change plus documentation. After M1 publishes the command surface and JSON schemas (#0026)
and the generated skill (#0066), the same rename touches agent-facing contracts that other people's
tooling may depend on.
