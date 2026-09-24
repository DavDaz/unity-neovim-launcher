# Unity Neovim Launcher for Ghostty

Open Unity scripts and Console errors directly in Neovim inside a terminal, preserving the file, line, and column selected in Unity.

When a compatible Herdr server is running, the launcher opens files in a dedicated Herdr workspace for the Unity project. When Herdr is absent, not running, or incompatible, it falls back to creating a Ghostty window directly. Either way, each canonical Unity project gets exactly one Neovim server.

## Quick setup

### Requirements

- macOS 13 or newer
- Unity with **External Tools** preferences
- Unity's Rider IDE package (`com.unity.ide.rider`)
- Neovim with client/server support (`--listen`, `--server`, and `--remote`)
- `/usr/bin/python3` (provided by macOS developer tools) — required for the Herdr path, which parses Herdr's JSON responses
- Optional but preferred: the `herdr` CLI, with a compatible Herdr server already running
- Ghostty 1.3 or newer with AppleScript enabled — used as the direct fallback when Herdr is unavailable

The launcher prefers Neovim in this order:

1. `/opt/homebrew/bin/nvim`
2. `nvim` from `PATH`
3. `/usr/local/bin/nvim`

Override with the `UNITY_NVIM_LAUNCHER_NVIM` environment variable (absolute path to an executable). Herdr is discovered from `PATH` or overridden with `UNITY_NVIM_LAUNCHER_HERDR` (an explicitly set but non-executable path means "Herdr unavailable").

### How the launcher chooses a host

For every request the launcher:

1. Probes the project's Neovim server socket. If a live server answers, the file is opened in that existing session through Neovim RPC — no new pane or window is created. When the session lives in the project's verified launcher-owned Herdr workspace and Ghostty is not running, the launcher additionally launches a single Ghostty surface that attaches the Herdr TUI to the already-running server, then focuses the workspace (both steps are best-effort).
2. Otherwise, if the `herdr` CLI is available and `herdr status --json` reports a running, compatible server, Neovim starts in the project's dedicated Herdr workspace.
3. Otherwise, a new Ghostty window is created in the Unity project directory and Neovim starts there.

### Install

Copy the application bundle to a stable user location and ad-hoc sign it:

```sh
mkdir -p "$HOME/Applications"
ditto UnityNeovimLauncher.app "$HOME/Applications/UnityNeovimLauncher.app"
codesign --force --deep --sign - "$HOME/Applications/UnityNeovimLauncher.app"
codesign --verify --deep --strict "$HOME/Applications/UnityNeovimLauncher.app"
```

To keep generated C# project files synchronized when scripts are created,
moved, or deleted, copy the included Unity Editor integration into each Unity
project:

```sh
mkdir -p "/absolute/path/to/UnityProject/Assets/Editor"
cp UnityProjectSync/Editor/UnityNeovimProjectSync.cs \
  "/absolute/path/to/UnityProject/Assets/Editor/"
```

Unity imports the integration and regenerates the solution after script reloads.
It also adds **Tools → Neovim → Regenerate C# Project Files** for manual recovery.

Do not install it from a Unity project's `Library` directory. Unity can delete that directory.

### Configure Unity

Open:

```text
Unity → Settings → External Tools
```

Set **External Script Editor** to:

```text
~/Applications/UnityNeovimLauncher.app
```

Set **External Script Editor Args** exactly to:

```text
"$(ProjectPath)" "$(File)" $(Line) $(Column)
```

Unity replaces those placeholders whenever a script or navigable Console error is opened.

No per-project Unity configuration beyond this is needed for Herdr: the launcher creates and reuses the project's Herdr workspace automatically on first use.

### Verify

1. Double-click a `.cs` file in Unity.
2. Confirm a terminal opens with Neovim at the selected file — inside the project's Herdr workspace when Herdr is running and compatible, otherwise in a new Ghostty window.
3. Double-click a Console error that includes a file and line.
4. Confirm the existing Neovim session is reused (no new pane) and the cursor moves to the reported location.

macOS asks whether Unity, the launcher, or `osascript` can control Ghostty only when the Ghostty fallback runs. Allow it under:

```text
System Settings → Privacy & Security → Automation
```

## How it works

```text
Unity
  └─ file + line + column
       └─ UnityNeovimLauncher.app
            ├─ Herdr running + compatible → dedicated per-project workspace
            └─ otherwise → Ghostty AppleScript API
                 └─ one Neovim server per Unity project
```

Each canonical Unity project path maps to a stable Neovim socket and Herdr workspace label with the same hash:

```text
/tmp/unl-<32-hex-project-hash>.sock
unl-<32-hex-project-hash>              (Herdr workspace label)
```

### Per-project workspace (Herdr path)

With a compatible Herdr server running:

- The first request for a project creates a Herdr workspace labelled `unl-<hash>` whose working directory is the Unity project, and starts Neovim with `--listen` in the workspace's fresh root pane.
- A later request that must start Neovim again (socket dead) reuses the launcher-owned workspace but always creates a fresh tab pane. The launcher never sends a command to a pane it did not create in that invocation.
- While the project's Neovim server is live, every further click reuses that single session: the file is opened and the cursor is positioned over the one socket, and no new pane is created.
- If the live session's workspace is verified against the Herdr listing but Ghostty is not running (checked with a read-only `pgrep -x ghostty` probe — the installed app bundle's lowercase process name — that sends no Apple Events), the workspace has no visible terminal. The launcher then launches one Ghostty surface whose command is `exec <herdr>` — the Herdr TUI attaching to the already-running compatible server — and afterwards asks Herdr to focus the project workspace. It never starts a second Neovim session, pane, or workspace for this, and a failure of either best-effort step is only a stderr warning: the navigation itself still succeeds.

After the server is up, the launcher asks Herdr to focus the project workspace. Focus is best-effort: a failed `workspace focus` is reported as a warning, and the launcher does not guarantee that the window is raised to the macOS foreground. The file is already open and positioned at that point.

### Ghostty fallback

When Herdr is unavailable (and the socket is dead, so no duplicate session can result):

1. Creates a Ghostty window in the Unity project directory with an explicit launch command (no text is injected into an existing terminal).
2. Starts Neovim with `--listen`.
3. Waits up to two seconds for the server socket.
4. Opens the requested file and positions the cursor through Neovim RPC.

### What happens when Herdr errors occur

The launcher never guesses from ambiguous state, never writes into an existing pane, and never risks a duplicate session:

- The Herdr workspace listing is ambiguous (duplicate `unl-` labels, or a matching workspace without a usable id) → when the project's Neovim session is already live, the launcher reuses that session remotely, prints a warning that it is skipping Herdr focus, and exits 0. When the socket is dead and a workspace would be needed, the launcher refuses to create a duplicate workspace and exits with an error.
- `tab create`, `workspace create`, or `pane run` fails, the response has no fresh pane id, or the Neovim server does not come up within about five seconds → the error (and Herdr's output, when captured) is reported and the launcher exits. It does not silently fall back to Ghostty, because a fallback could create a second session for the project.
- `workspace focus` fails → a warning is printed; the file is already open and positioned, so nothing is lost.
- Herdr is absent, not running, or reports incompatible, and the socket is dead → the launcher falls back to direct Ghostty.

All launcher errors go to stderr. Unity does not show stderr, so run the executable directly from a terminal to see them (see Troubleshooting).

## Moving to another Mac

Copy or clone these files:

```text
UnityNeovimLauncher/
├── README.md
├── test-launcher.sh
├── UnityProjectSync/
│   └── Editor/
│       └── UnityNeovimProjectSync.cs
└── UnityNeovimLauncher.app/
    └── Contents/
        ├── Info.plist
        └── MacOS/
            └── UnityNeovimLauncher
```

Then:

1. Install Neovim, the `herdr` CLI (optional, preferred host), and Ghostty 1.3+.
2. Run the staging tests:

   ```sh
   ./test-launcher.sh
   ```

3. Copy and sign the `.app` using the installation commands above.
4. Select the launcher in each Unity installation's **External Tools** preferences.
5. Enter the exact Unity argument template.
6. Approve the macOS Automation permission if prompted (only needed for the Ghostty fallback).
7. Test both a script double-click and a Console error double-click, once with Herdr running and once with it stopped.

Unity's editor selection is a machine-level preference. Copying a Unity project does not automatically configure the launcher on another Mac.

## C# completion and diagnostics

This launcher only handles opening and navigation. It does not contain machine-specific Neovim configuration, language servers, or generated Unity project files.

The optional `UnityProjectSync` Editor integration asks Unity's Rider IDE package
to regenerate those generated files after script reloads. This keeps newly
created MonoBehaviour scripts visible to OmniSharp without editing `.csproj`
files by hand.

For the portable OmniSharp, .NET 8, Mason, Treesitter, and Unity project-file setup, see [Neovim Unity C# LSP setup](NEOVIM-UNITY-LSP.md).

If completion becomes stale after adding or moving scripts, use **Tools → Neovim
→ Regenerate C# Project Files** before debugging the Neovim LSP configuration.

## Limitations

- Herdr focus is best-effort: the launcher does not guarantee that Herdr raises the workspace window to the macOS foreground.
- The Ghostty-running probe is a plain `pgrep -x ghostty` check; if `pgrep` is missing or fails, the launcher conservatively assumes Ghostty is running and only focuses the Herdr workspace.
- Focusing a reused old Ghostty session is unreliable: Ghostty's AppleScript API can report an empty working directory for a terminal that is already running Neovim, so the matching terminal may not be found. The file still opens in the existing Neovim session and the cursor still moves; only the window focus can be lost. This limitation is one reason Herdr is the preferred host.
- The launcher only ever runs a command in a pane it created during that invocation; existing panes are never reused or written to.
- Ghostty 1.3+ is required for the fallback because the launcher uses its AppleScript surface API.
- Project and file paths containing newline or carriage-return characters are rejected before any terminal or RPC action.
- Spaces, apostrophes, semicolons, dollar signs, and ordinary shell metacharacters are supported.
- Unity messages without a source file and location cannot navigate to a specific line in any editor.
- The launcher waits up to two seconds for a newly created Neovim server after a Ghostty launch, and about five seconds inside a Herdr pane.

## Troubleshooting

### Unity opens nothing

Run the executable directly to expose errors:

```sh
"$HOME/Applications/UnityNeovimLauncher.app/Contents/MacOS/UnityNeovimLauncher" \
  "/absolute/path/to/UnityProject" \
  "/absolute/path/to/UnityProject/Assets/Scripts/Example.cs" \
  10 \
  1
```

Then check:

- `herdr status --json` succeeds and reports `running` and `compatible` as `true` (or stop Herdr intentionally to use the Ghostty fallback).
- `/usr/bin/python3` exists — without it the Herdr JSON responses cannot be parsed.
- Ghostty is installed in `/Applications/Ghostty.app`.
- Ghostty AppleScript support is enabled.
- macOS Automation permission was granted (Ghostty fallback only).
- Neovim is installed in one of the supported locations.

### Herdr reports an error

Messages such as `herdr workspace list was ambiguous`, `refusing to create a duplicate workspace`, `herdr tab create failed for workspace …`, `herdr pane run failed`, or `timed out waiting for the Neovim server in the Herdr pane` mean the launcher stopped instead of guessing. Re-running the same click retries the operation. A `workspace create` that succeeded before a `pane run` failure or timeout can leave the launcher-owned workspace behind; the next attempt reuses it, and no duplicate Neovim session is ever started and no existing pane is written to.

`could not launch a Ghostty surface for the Herdr session` means the file was already opened in the live Neovim session, but the best-effort attempt to show the Herdr TUI in a new Ghostty surface failed (the `osascript` output is printed right after the warning). The navigation itself succeeded; check Ghostty's AppleScript support and the macOS Automation permission.

To check the launcher's workspace state:

```sh
herdr workspace list
```

Launcher-owned workspaces are labelled `unl-<project-hash>`. Do not create a second workspace with the same label; delete or rename the conflicting one instead.

### A new window opens for every click

Check whether the project socket exists and responds:

```sh
ls /tmp/unl-*.sock
nvim --server /tmp/unl-<project-hash>.sock --remote-expr '1'
```

A stale socket can remain after an abnormal Neovim exit. Remove only the socket confirmed to belong to the closed project session. A dead socket makes the next click start a fresh Neovim instance (in a fresh Herdr pane or a new Ghostty window), which is why one window per click usually means a stale socket.

With Herdr running and a dead project socket, an ambiguous workspace listing makes the launcher exit with an error instead of creating a duplicate workspace. When the project's Neovim session is still live, the launcher reuses it and only skips the best-effort Herdr focus.

## What to put in Git

Commit the portable source bundle, not the installed user copy:

```text
README.md
LICENSE
UnityNeovimLauncher.app/Contents/Info.plist
UnityNeovimLauncher.app/Contents/MacOS/UnityNeovimLauncher
test-launcher.sh
```

Do not commit:

```text
.DS_Store
UnityNeovimLauncher.app/Contents/_CodeSignature/
/tmp/unl-*.sock
Unity project Library/, Temp/, Logs/, or Obj/ directories
personal Unity preferences
```

The `_CodeSignature` directory is machine/build-specific. Users should sign their local installed copy after cloning.

Before publishing, run:

```sh
./test-launcher.sh
sh -n UnityNeovimLauncher.app/Contents/MacOS/UnityNeovimLauncher
plutil -lint UnityNeovimLauncher.app/Contents/Info.plist
```
