# Changelog

## 1.0

First release of **Assistente IA** in the Codex CLI & Claude Code Workspace repository.

### Build 3 (1.0 Professional)

The public version stays 1.0. See [AUDITORIA-1.0-PROFESSIONAL.md](AUDITORIA-1.0-PROFESSIONAL.md) (Portuguese) for the confirmed problems, test results and measurements.

- **Security.** On Windows, agents start without going through `cmd.exe`, so `&`, `|`, `%` and quotes in a prompt stay text. Terminal and Windows ZIP backups now skip credentials, Git data and dependencies by default; a full copy is a separate choice. Desktop backups no longer follow a file that turns into a link after the preview. The credential and cache rules cover more files (`.npmrc`, `.netrc`, `.aws`, `.ssh`, keystores, Terraform state and others).
- **Fixes.** File modes and modification times are read correctly on Linux. Saved reasoning efforts are checked per agent, and Claude Code's `ultracode` is available. ZIPs made by the macOS app restore on Linux and Windows. The macOS app can save a backup over an existing file after you confirm.
- **Agent handoff.** Checkpoints record decisions and open issues. **Save and request review** opens one read-only review session with the other agent; nothing loops automatically.
- **Context audit.** Finds possible credentials (location only), oversized context files, `AGENTS.md` over Codex's 32 KiB default, missing references and `@` imports, imports deeper than four levels, repeated lines and too many checkpoints. The size estimate is labeled bytes ÷ 4, not a measurement. Reports can be saved without your home folder or token-like values.
- **Checkpoint compaction.** After you confirm, older checkpoints move to a new file in the archive folder and the last three stay. No text is deleted.
- **Prompt library.** 21 ready-made prompts in Portuguese, English and Spanish, from full audits to reviews by the other agent. Search, preview, copy to the project or start a session from the panel, or choose option 7 in the terminal.
- **Quick actions.** `Ctrl+K` opens a searchable list of panel actions.
- **Detected commands.** **Checks** suggests test, build and lint commands from the project's manifest files for review. Nothing is installed or run automatically.
- **Worktrees.** Clean up records of worktree folders removed outside the app after a preview. Files and branches are kept.
- **CI.** Tests run on every push and pull request with a read-only token. Windows failures are no longer hidden by a later success. Release builds attach the build file used by the update check, never change a published release, and can be rerun for a tag when no macOS runner is available.

### Builds 1 and 2

- Build 2 adds update detection within version 1.0, worktree management, project profiles, favorites and project search.
- Run configurable test and build commands in the terminal and carry their results to checkpoint review.
- Preview desktop ZIP backups, skip common credentials and generated files, and restore archives into a new folder.
- Native macOS app with a default project folder, recent projects, and quick actions.
- Graphical launchers for Linux and Windows using Python and Tkinter.
- English, Brazilian Portuguese, and Spanish, plus automatic language selection. New projects use localized folder names and templates. Existing project paths stay valid.
- Choose between agent folders or creating directly in the selected folder. Either layout lets you choose Codex or Claude for each session.
- Check tool versions, agent sign-in, RTK hooks and Token Optimizer settings from the panel.
- Review a checkpoint when switching agents and run parallel terminal sessions in separate Git worktrees.
- Save progress and continue from notes directly in the Windows terminal menu.
- Copy Codex, Claude Code, Git, npm and RTK commands from the panel.
- One workspace with `AGENTS.md`, `CLAUDE.md`, shared instructions, reusable prompts, and project progress notes.
- New, resume, and history actions for the official Codex and Claude Code terminal sessions.
- Agent account controls, Git status, local npm server, ZIP backups, and keyboard shortcuts.
- Protection against duplicate terminal compression when RTK and Token Optimizer are used together.
- Optional verified app updates on macOS and release notifications on Linux and Windows.
- Existing macOS, Linux, and Windows terminal menus included.

See the [download and setup guide](README.md#download-and-install), the [Portuguese guide](README.pt-BR.md), or the [Spanish guide](README.es.md).
