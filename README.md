# Unity Neovim Launcher for Ghostty

Open Unity scripts and Console errors directly in Neovim inside Ghostty, preserving the file, line, and column selected in Unity.

## Quick setup

### Requirements

- macOS 13 or newer
- Unity with **External Tools** preferences
- Ghostty 1.3 or newer with AppleScript enabled
- Neovim with client/server support (`--listen`, `--server`, and `--remote`)

The launcher prefers Neovim in this order:

1. `/opt/homebrew/bin/nvim`
2. `nvim` from `PATH`
3. `/usr/local/bin/nvim`

### Install

Copy the application bundle to a stable user location and ad-hoc sign it:

```sh
mkdir -p "$HOME/Applications"
ditto UnityNeovimLauncher.app "$HOME/Applications/UnityNeovimLauncher.app"
codesign --force --deep --sign - "$HOME/Applications/UnityNeovimLauncher.app"
codesign --verify --deep --strict "$HOME/Applications/UnityNeovimLauncher.app"
```

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

### Verify

1. Double-click a `.cs` file in Unity.
2. Confirm Ghostty opens with Neovim at the selected file.
3. Double-click a Console error that includes a file and line.
4. Confirm the existing Neovim session is reused and the cursor moves to the reported location.

macOS might ask whether Unity, the launcher, or `osascript` can control Ghostty. Allow it under:

```text
System Settings → Privacy & Security → Automation
```

## How it works

```text
Unity
  └─ file + line + column
       └─ UnityNeovimLauncher.app
            └─ Ghostty AppleScript API
                 └─ one Neovim server per Unity project
```

Each canonical Unity project path maps to a stable socket:

```text
/tmp/unl-<32-hex-project-hash>.sock
```

On the first request, the launcher:

1. Creates a Ghostty window in the Unity project directory.
2. Starts Neovim with `--listen`.
3. Waits up to two seconds for the server socket.
4. Opens the requested file and positions the cursor through Neovim RPC.

On later requests, it:

1. Detects the existing project-specific Neovim server.
2. Opens the new file in that server.
3. Moves the cursor to Unity's line and column.
4. Focuses the matching Ghostty terminal when possible.

## Moving to another Mac

Copy or clone these files:

```text
UnityNeovimLauncher/
├── README.md
├── test-launcher.sh
└── UnityNeovimLauncher.app/
    └── Contents/
        ├── Info.plist
        └── MacOS/
            └── UnityNeovimLauncher
```

Then:

1. Install Ghostty 1.3+ and Neovim.
2. Run the staging tests:

   ```sh
   ./test-launcher.sh
   ```

3. Copy and sign the `.app` using the installation commands above.
4. Select the launcher in each Unity installation's **External Tools** preferences.
5. Enter the exact Unity argument template.
6. Approve the macOS Automation permission if prompted.
7. Test both a script double-click and a Console error double-click.

Unity's editor selection is a machine-level preference. Copying a Unity project does not automatically configure the launcher on another Mac.

## C# completion and diagnostics

This launcher only handles opening and navigation. IDE features require a separate C# setup:

- Generated Unity `.sln` and `.csproj` files
- A C# language server such as Roslyn
- Neovim LSP configuration
- Optionally, a Unity-compatible debug adapter

If completion becomes stale after adding or moving scripts, regenerate Unity's project files before debugging the Neovim LSP configuration.

## Limitations

- Ghostty 1.3+ is required because the launcher uses its AppleScript surface API.
- Project and file paths containing newline or carriage-return characters are rejected before any terminal or RPC action.
- Spaces, apostrophes, semicolons, dollar signs, and ordinary shell metacharacters are supported.
- Unity messages without a source file and location cannot navigate to a specific line in any editor.
- The launcher waits up to two seconds for a newly created Neovim server.

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

- Ghostty is installed in `/Applications/Ghostty.app`.
- Ghostty AppleScript support is enabled.
- macOS Automation permission was granted.
- Neovim is installed in one of the supported locations.

### A new window opens for every click

Check whether the project socket exists and responds:

```sh
ls /tmp/unl-*.sock
nvim --server /tmp/unl-<project-hash>.sock --remote-expr '1'
```

A stale socket can remain after an abnormal Neovim exit. Remove only the socket confirmed to belong to the closed project session.

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
