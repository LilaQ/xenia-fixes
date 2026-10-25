# Xenia Patch Manager

Small Windows PowerShell 5.1 / WinForms interface for the official Xenia Canary game patches. Place `PatchManager.ps1` and `PatchManager.Core.psm1` in `Xenia Canary/PatchManager/` and start the script with Windows PowerShell in STA mode.

The cabinet installation supplies a local `library.json` mapping installed LaunchBox games to verified Xbox title IDs. This private inventory is not part of the repository. `upstream.json` records the installed upstream revision, and `settings.json` tracks original configuration values for restoration.

The manager updates from `xenia-canary/game-patches` at startup without running downloaded code. Existing option choices are preserved; new options start disabled. Original upstream title IDs, module hashes and writes are preserved. Saving rejects conflicting writes for the same title and module hash. Enabled framerate options receive a title-specific 60 FPS limit. Patch files and affected configuration files are backed up before changes. Restart Xenia to load changes.

All patches are version-specific. A checked option is not proof that Xenia applied it to a particular executable. Xenia's log and `[Patches Applied]` window title are the runtime confirmation. Some patches require a specific title update or have gameplay side effects described in the interface.

Run `pwsh -NoProfile -File tests.ps1` for portable parser, conflict, option preservation and configuration restoration tests. The WinForms interface itself requires Windows.

Optimized game settings can be merged from a local checkout of `xenia-manager/optimized-settings` using `apply-optimized-settings.py`. Preparation takes `--launchbox`, `--plan`, `--library` (a verified Title-ID inventory), `--settings` (the upstream settings directory), and `--database` (x360db games.json). Review the prepared changes before applying with `--launchbox`, `--plan`, and `--apply`; close Xenia, LaunchBox and Big Box first. The importer backs up changed files, preserves disc routes and controls, and updates the patch manager to retain imported presentation limits. Newly imported options still need cabinet playtesting.
