# Unity C# assistance in Neovim

The launcher and the C# language server solve different problems:

- **UnityNeovimLauncher** opens a Unity-selected file at its line and column in a project-specific Neovim server.
- **OmniSharp LSP** provides C# completion, diagnostics, hover documentation, definitions, and references *inside* Neovim.

This repository contains the portable launcher only. It does not contain a user's machine-specific Neovim configuration or generated Unity project files.

## Requirements

- macOS
- Homebrew and the .NET 8 SDK
- Neovim with LazyVim and Mason
- Mason OmniSharp 1.39 or newer
- Treesitter's `c_sharp` parser
- A Unity project with the Unity IDE package installed and C# project generation enabled

The shell commands discover the Homebrew prefix automatically. The LazyVim example uses the Apple Silicon prefix; on Intel, replace `/opt/homebrew` with `/usr/local`.

## Install

Install .NET 8 and make it available to the shell that starts Neovim:

```sh
brew install dotnet@8
export DOTNET_ROOT="$(brew --prefix dotnet@8)/libexec"
export PATH="$(brew --prefix dotnet@8)/bin:$(brew --prefix dotnet@8)/libexec:$PATH"
dotnet --info
```

In Neovim, install the required tools:

```vim
:MasonInstall omnisharp
:TSInstall c_sharp
```

Confirm OmniSharp is version 1.39 or newer in `:Mason`. Mason installs tools under Neovim's data directory (typically `~/.local/share/nvim/mason`), not in this launcher repository.

## LazyVim configuration

Create this machine-local file:

```text
~/.config/nvim/lua/plugins/csharp.lua
```

Use this complete configuration. It sets the Homebrew .NET environment before OmniSharp starts, installs OmniSharp through Mason, and ensures the C# parser is installed.

```lua
local mason_bin = vim.fn.stdpath("data") .. "/mason/bin"
local dotnet_root = "/opt/homebrew/opt/dotnet@8/libexec"

return {
  {
    "mason-org/mason.nvim",
    opts = {
      ensure_installed = { "omnisharp" },
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        omnisharp = {
          cmd = {
            mason_bin .. "/omnisharp",
            "-z",
            "--hostPID",
            tostring(vim.fn.getpid()),
            "DotNet:enablePackageRestore=false",
            "--encoding",
            "utf-8",
            "--languageserver",
          },
          cmd_env = {
            DOTNET_ROOT = dotnet_root,
            PATH = table.concat({ dotnet_root, mason_bin, vim.env.PATH or "" }, ":"),
          },
          single_file_support = false,
          settings = {
            FormattingOptions = {
              EnableEditorConfigSupport = true,
              OrganizeImports = true,
            },
            MsBuild = {
              LoadProjectsOnDemand = false,
            },
            RoslynExtensionsOptions = {
              EnableAnalyzersSupport = true,
              EnableImportCompletion = true,
              AnalyzeOpenDocumentsOnly = false,
            },
            Sdk = {
              IncludePrereleases = false,
            },
          },
        },
      },
    },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      if type(opts.ensure_installed) == "table"
        and not vim.tbl_contains(opts.ensure_installed, "c_sharp")
      then
        table.insert(opts.ensure_installed, "c_sharp")
      end
    end,
  },
}
```

Restart Neovim after saving the file, then run `:Lazy sync` if LazyVim has not yet installed the declared plugins/tools.

## Generate Unity project files

In Unity, open **Unity → Settings → External Tools**, make sure a Unity IDE integration package is installed, and use **Regenerate project files**. That control may appear only when Unity recognizes an IDE integration. If selecting the custom launcher hides it, temporarily select an installed Visual Studio, Rider, or VS Code integration, regenerate the files, then restore the launcher. Do not manually edit generated project files. This generates files such as:

```text
MyProject.sln
Assembly-CSharp.csproj
Assembly-CSharp-Editor.csproj
```

Open Neovim from the Unity project root so OmniSharp can find the `.sln`. These files are generated from the project and Unity/editor/package state; they can contain absolute paths and differ between machines. Regenerate them after adding, moving, or changing scripts/packages rather than copying them between Macs.

## Configure Unity to use the launcher

The launcher remains Unity's external editor. In **Unity → Settings → External Tools**, set:

```text
External Script Editor: ~/Applications/UnityNeovimLauncher.app
External Script Editor Args: "$(ProjectPath)" "$(File)" $(Line) $(Column)
```

The argument template passes the project, file, line, and column to the launcher. It does not start or configure OmniSharp; Neovim loads OmniSharp when it opens C# files in a generated Unity project.

## Verify

From a Unity project root, verify .NET and start Neovim:

```sh
dotnet --info
nvim "Assets/Scripts/Example.cs"
```

Inside Neovim, run:

```vim
:checkhealth vim.lsp
:Mason
:lua print(vim.inspect(vim.lsp.get_clients({ name = "omnisharp" })))
```

Use the path of an existing C# file in the `nvim` command above. A non-empty client list confirms attachment. Then verify LSP behavior:

- `K` shows hover information over a C# symbol.
- `gd` jumps to a definition.
- `gr` lists references.
- Completion and diagnostics appear while editing.

Also double-click a Unity script and a Console error to verify launcher navigation separately.

## Troubleshooting

### OmniSharp does not attach

- Confirm the generated `.sln` and `.csproj` files exist at the Unity project root; regenerate them in Unity if they do not.
- Open Neovim from that root, not from an unrelated directory.
- Check `:Mason` for OmniSharp 1.39+ and run `:checkhealth vim.lsp`.
- In Neovim, run `:echo $DOTNET_ROOT` and `:echo $PATH`; they must include the .NET 8 paths configured above.
- Run `dotnet --info` in the terminal that launches Neovim.
- Restart Neovim after regenerating project files or changing `csharp.lua`.

### C# syntax highlighting is missing

Run `:TSInstall c_sharp`, restart Neovim, and check that `:InspectTree` recognizes C# nodes in a `.cs` buffer.

### Unity opens a file but completion is unavailable

Launcher navigation succeeded; diagnose the LSP separately with the verification commands above. The launcher does not bundle OmniSharp, .NET, Mason, or a Neovim configuration.

### macOS does not open or focus Ghostty

Allow the requested Automation permission under **System Settings → Privacy & Security → Automation** for Unity, the launcher, or `osascript` as applicable. This permission is separate from LSP setup.

## Portability and Git

Apple Silicon Homebrew normally uses `/opt/homebrew`; Intel Homebrew normally uses `/usr/local`. Adjust `dotnet_root` in `csharp.lua` to match the target Mac. Each user should keep that file in their own `~/.config/nvim`, install their own Mason tools, approve their own macOS Automation prompts, and regenerate Unity files locally.

Commit portable launcher sources and this guide. Do **not** commit machine-specific Neovim configuration, Mason data, generated Unity `.sln`/`.csproj` files, `.DS_Store`, Automation permissions, or Unity generated directories such as `Library/`, `Temp/`, `Logs/`, and `Obj/`.
