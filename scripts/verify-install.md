# Manual verification: installing and uninstalling the `switchyard` CLI (#0222)

**Every scenario below is UNRUN.** They need a human at this machine with a real, installed
app — a round may not install anything, and no test can create the authentication dialog,
`/usr/local/bin`, or `~/.local/bin`. When you run one: paste what you actually saw, flip its
mark to **RUN** with the date, and state the machine. This file is the install/uninstall
sibling of `scripts/verify-xpc.md` (which cites scenarios the same way).

The flows under test: **File ▸ Install Command Line Tool…** and
**File ▸ Uninstall Command Line Tool**, backed by `Switchyard/CLIInstallActions.swift`
(in-process `NSAppleScript` with administrator privileges) and the pure command builders in
`YardKit/Sources/YardKit/CLIInstaller.swift`.

## Preconditions

1. **The app is installed in `/Applications`** — not launched from Xcode or a build
   directory. Check: `ls -d /Applications/Switchyard.app` → the directory. Launching the
   DerivedData copy instead is scenario 4's subject, not a precondition.
2. **The CLI is embedded** (the #0050 embed step ran):
   `ls -l /Applications/Switchyard.app/Contents/Resources/bin/switchyard` → an executable
   Mach-O file, not "No such file".
3. **A repo-built `switchyard` binary is NOT on `PATH`** for these scenarios — it would
   confuse "the command works" with "the link works". Check `command -v switchyard`;
   if it prints anything, remove or rename that copy first.
4. **A new terminal** for every command-substitution check below: `PATH` is read once per
   shell, and a shell opened before an install will not see a fresh `/usr/local/bin` entry
   in its command cache. Run `hash -r` (or open a new tab) after each install/uninstall.

---

## Scenario 1 — Install from /Applications, approve the dialog — UNRUN

1. Launch `/Applications/Switchyard.app`.
2. Choose **File ▸ Install Command Line Tool…**.
   - **Expected:** the standard macOS administrator dialog appears, branded **Switchyard**
     (its icon and name — not Script Editor's; the runner is in-process `NSAppleScript`),
     asking for an administrator password with the prompt text:
     `Switchyard needs administrator access to create a symlink in /usr/local/bin.`
3. Enter the password and click **OK**.
   - **Expected:** an informational alert titled `Command line tool installed.` whose text
     is `/usr/local/bin/switchyard` now points into this app, followed by
     `Open a new terminal and run:  switchyard --help`.
4. `ls -l /usr/local/bin/switchyard`
   - **Expected:** a symlink owned by `root`, pointing into the app:
     `lrwxr-xr-x 1 root wheel <len> <date> /usr/local/bin/switchyard -> /Applications/Switchyard.app/Contents/Resources/bin/switchyard`
5. In a new terminal: `switchyard --help`
   - **Expected:** the CLI's usage output (the same text `swift run switchyard --help`
     prints from the package).

## Scenario 2 — Cancelling the authentication dialog — UNRUN

1. Uninstall first if scenario 1 ran (see scenario 6), then choose
   **File ▸ Install Command Line Tool…** again.
2. In the administrator dialog, click **Cancel**.
   - **Expected: nothing happens.** No alert, no banner, no sound. The AppleScript error
     number `-128` (`userCanceledErr`) is classified as a user decision, and the action
     presents nothing. This is the behaviour the issue calls out by name.
3. `ls -l /usr/local/bin/switchyard`
   - **Expected:** `No such file or directory` — cancelling installed nothing.

## Scenario 3 — The legacy link is swept first, in the same step — UNRUN

`~/.local/bin/switchyard` is where an earlier scheme installed, and it sits earlier on
`PATH` than `/usr/local/bin` on many machines — leaving it would shadow the new install.

1. Uninstall first if scenario 1 ran, then stage the shadow yourself:
   ```sh
   mkdir -p ~/.local/bin
   ln -sfn /Applications/Switchyard.app/Contents/Resources/bin/switchyard ~/.local/bin/switchyard
   ls -l ~/.local/bin/switchyard   # the staged link exists
   ```
2. Choose **File ▸ Install Command Line Tool…** and approve the dialog.
   - **Expected:** the usual success alert (scenario 1, step 3).
3. `ls -l ~/.local/bin/switchyard`
   - **Expected:** `No such file or directory` — the legacy link was removed **first**, in
     the same privileged command (`rm -f <legacy> && ln -sfn <new>`), not left to shadow.
4. `ls -l /usr/local/bin/switchyard`
   - **Expected:** the scenario 1, step 4 symlink.
5. In a new terminal: `command -v switchyard`
   - **Expected:** `/usr/local/bin/switchyard` — nothing earlier on `PATH` wins.

## Scenario 4 — Refusal from a build directory — UNRUN

1. Launch the app from Xcode (or any DerivedData / `Build/Products` copy).
2. Choose **File ▸ Install Command Line Tool…**.
   - **Expected:** immediately a warning alert titled
     `This copy of Switchyard is running from a build directory.` explaining that the
     destination would be linked into a path deleted on the next clean, and to move the app
     to the Applications folder. **No authentication dialog appears** and no command runs —
     the refusal precedes the prompt.
3. `ls -l /usr/local/bin/switchyard`
   - **Expected:** unchanged from before step 2 (no link created).

## Scenario 5 — A real file in the way is never clobbered — UNRUN

1. Uninstall first (scenario 6), then place a regular file at the destination:
   ```sh
   sudo touch /usr/local/bin/switchyard
   ```
2. Choose **File ▸ Install Command Line Tool…**.
   - **Expected:** a warning alert titled `Something else is already at /usr/local/bin/switchyard.`
     saying it is a regular file, not a symlink, so it was left alone — with no
     authentication dialog. The installer never replaces a file it did not create.
3. `file /usr/local/bin/switchyard`
   - **Expected:** `ASCII text` (still the empty file, untouched).
4. Clean up: `sudo rm /usr/local/bin/switchyard`

## Scenario 6 — Uninstall — UNRUN

1. With scenario 1's install in place, choose **File ▸ Uninstall Command Line Tool**.
   - **Expected:** the administrator dialog, prompt text
     `Switchyard needs administrator access to remove the symlink from /usr/local/bin.`
2. Approve it.
   - **Expected:** an informational alert titled `Command line tool removed.` whose text is
     `/usr/local/bin/switchyard` has been deleted.
3. `ls -l /usr/local/bin/switchyard`
   - **Expected:** `No such file or directory`.
4. If scenario 3's legacy link was staged again, it is swept in the same `rm -f`:
   `ls -l ~/.local/bin/switchyard` → `No such file or directory`.
5. In a new terminal: `command -v switchyard`
   - **Expected:** empty output — nothing of Switchyard's is left on `PATH`.
6. Reopen the **File** menu.
   - **Expected:** the state machine now reports `notInstalled`: **Install Command Line
     Tool…** is enabled and **Uninstall Command Line Tool** is greyed out.

## Scenario 7 — Menu enablement tracks state — UNRUN

1. Fresh state (nothing installed): open the **File** menu.
   - **Expected:** **Install Command Line Tool…** enabled (with the ellipsis — it opens a
     dialog before completing); **Uninstall Command Line Tool** disabled.
2. Install (scenario 1), then open the menu again.
   - **Expected:** the reverse — Install disabled (the link already points here), Uninstall
     enabled. Both items are always present; the inapplicable one greys out. A stale
     grey-out after a change made outside the app self-corrects when the item is clicked:
     the action re-inspects before doing anything.

## Scenario 8 — Cancelling the uninstall dialog — UNRUN

1. With the tool installed, choose **File ▸ Uninstall Command Line Tool** and click
   **Cancel** in the dialog.
   - **Expected: nothing.** No alert; the link survives
     (`ls -l /usr/local/bin/switchyard` still shows the symlink).
