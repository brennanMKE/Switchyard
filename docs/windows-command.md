# The `windows` command — finding and capturing app windows

`windows` (~/bin/windows, MIT, <https://github.com/brennanMKE/Windows>) lists every visible
window with its CoreGraphics window ID, process ID, bundle identifier, application name, and
title — tab-separated by default, `--json` for structured output. In this repository its
purpose is narrow and load-bearing: **getting the window ID that `screencapture -l` needs**,
so an issue can carry a screenshot of exactly one app window instead of a whole-screen grab
the reviewer has to squint at.

## The one recipe that matters

Capture a specific app's window as PNG evidence:

```sh
# find the window
windows | grep co.gitup.mac
# → 13003  63422  co.gitup.mac  GitUp  Batty

# capture just that window
screencapture -l 13003 gitup-batty.png
```

One line, JSON + jq spelling:

```sh
screencapture -l $(windows --json | jq '.[] | select(.appName == "GitUp") | .windowID' | head -1) out.png
```

## Output format

Tab-separated: `WindowID`, `PID`, `BundleID`, `AppName`, `Title`. `--json` emits the same
fields as an array. The WindowID is the identifier `screencapture -l` wants — not the
AppleScript window index, which is a different numbering.

## Caveats measured in this repository

- **Screen Recording permission**: window *titles* can require it; the window list itself
  usually does not. If titles come back empty, grant the permission to the calling terminal
  in System Settings → Privacy & Security → Screen Recording.
- Window IDs are **not stable** across launches — always look the ID up in the same script
  that uses it, never paste one from an earlier session.
- System windows (Dock, WindowServer) report `<none>` as the bundle ID; filter by bundle ID,
  never by position in the list.
- Screenshots taken as issue evidence belong under `build/` (gitignored), not the repo tree.

## Why this exists here

Issue evidence for the app's UI (the Settings surface, the transport pane, the commit graph)
needs to show what the user actually saw. A window-targeted capture is the difference between
"a screenshot of the bug" and "a screenshot of a desktop". The pattern used for #0354's
diagnosis: `windows | grep <bundle-id>` → `screencapture -l <id>` → attach the PNG to the
issue.
