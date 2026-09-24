# Unity Herdr-first launcher

Objective: Open Unity scripts in one dedicated Herdr workspace per canonical Unity project when a compatible Herdr server is running; retain direct Ghostty fallback when Herdr is unavailable.

Problem: Ghostty AppleScript returns an empty terminal working directory for live Neovim, causing silent failure to focus a reused session. The user prefers their existing Herdr client and authorizes closing the old Prototype 2 Neovim session (closed after PID/socket validation).

Scope: launcher host selection, safe per-project workspace reuse, tests, setup/troubleshooting docs. Do not modify Unity projects or Herdr configuration. Never run a command in an unrelated existing pane. Preserve a live Neovim socket as the session identity and avoid duplicate launches on ambiguous Herdr failures.

TDD mode: unknown (no configured mode found); ordinary functional checks. Runner: `./test-launcher.sh`; structural: `sh -n UnityNeovimLauncher.app/Contents/MacOS/UnityNeovimLauncher`, `plutil -lint UnityNeovimLauncher.app/Contents/Info.plist`.

Delivery: ask-on-risk, forecast ~250 authored lines; single feature branch `feat/unity-herdr-first`. User explicitly requested commit and push.

## Tasks

- [x] T0 [inline] Preserve and discard cancelled partial implementation. Evidence: `/tmp/unity-herdr-partial.XXXXXX.patch` (~37 KB); `git restore` only the two tracked source/test files.
- [x] T1 [inline live probe] Validate Herdr CLI using temporary workspace `wQ`, root pane `wQ:p1`, `pane run` of harmless printf and cleanly close `wQ`. Evidence: `herdr status --json` compatible running 0.9.1, create returned workspace/root_pane JSON, printf visible, close returned ok. No existing pane used.
- [x] T2 [delegated writer: multi-file write] Herdr-first host routing and 12 stub scenarios; strict Python JSON extraction, duplicate-label rejection, fresh workspace/tab pane only, visible failure on ambiguous run; Ghostty fallback when unavailable. Evidence: worker `./test-launcher.sh` PASS and `sh -n` PASS; independent live isolated CLI `tab create` confirmed `result.root_pane.pane_id`; test isolation incident diagnosed and transient test workspace closed. No commit requested.
- [x] T3 [delegated writer or inline documentation] Documentation and 12-scenario suite done; independent verifier found two coverage/wording gaps, corrected and rechecked (`./test-launcher.sh`, `sh -n`, `plutil -lint`, `git diff --check` PASS). Signed user app installed at `~/Applications/UnityNeovimLauncher.app`; previous copies backed up under `~/Library/Application Support/UnityNeovimLauncher/backups/`. `codesign --verify --deep --strict`, `cmp` against source, installed dry-run on Prototype 2 and Unity external editor preference all passed. User reported actual Unity double-click now opens Herdr in their existing Ghostty session.

Review note: native lineage `review-80df0e416bfc0341` is still reviewing, with no reviewer artifacts admitted because the host relay failed upstream. User explicitly allowed skipping the review to test the installed app; do not claim it closed or approved. The installed app deployment is for user testing, not review approval.

Live feedback: Unity's GUI launched the installed app into direct Ghostty even while Herdr was running. Reproduced with GUI-like PATH: dry-run reports `herdr=-` because Herdr discovery only checks PATH, unlike Neovim's Homebrew absolute path. User closed the resulting Prototype 2 Neovim session and authorized the correction.

- [x] T4 [delegated writer: multi-file write] Added `/opt/homebrew/bin/herdr` and `/usr/local/bin/herdr` discovery with explicit override precedence and PATH fallback. GUI-like PATH dry-run returns `herdr=/opt/homebrew/bin/herdr`, absent override returns `herdr=-`; writer and independent verifier report `./test-launcher.sh`, both `sh -n`, `plutil -lint`, `git diff --check` PASS, no new test leaks. Installed signed copy and verified `codesign --verify --deep --strict` plus `cmp`; prior version backed up at `~/Library/Application Support/UnityNeovimLauncher/backups/UnityNeovimLauncher-pre-gui-path-20260923-200651.app`. Installed minimal-PATH dry-run detects Homebrew Herdr. User retest remains under T3.

Next: implementation and user testing complete. Native review lineage `review-80df0e416bfc0341` remains open and was explicitly skipped for the user test; this is not review approval. Legacy leaked headless Neovim processes from earlier test runs remain untouched. Commit and push requested by user.
