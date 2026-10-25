# Silent Hill cabinet patches

Local Xenia patches for media `625FCB0C`, base version `00000005`.
They are gated by the exact executable module hash, rather than title ID alone.
No game data is included.

The SH2 and SH3 FPS patches change the game's D3D presentation interval from
two display refreshes to one. At 60 Hz this removes the presentation's 30 FPS
ceiling. Actual frame rate and gameplay/cutscene timing require an interactive
test; this does not guarantee that every scene can run at 60 FPS.

SH2's launcher normally passes a single byte to select its voice track.
The direct-start patches set the equivalent internal flag explicitly:
zero selects the original XMA files, one appends `.new` to voice filenames.
Install each SH2 variant in a separate `storage_root/patches` directory.
Pass that storage root on Xenia's command line: it is chosen before loading
the config. Both configs can use the same explicit `content_root` and
`cache_root`, retaining the user's profile, saves and cache.

Start the shared collection ISO with `--launch_module=sh2_360.xex` or
`--launch_module=sh3_360.xex`. The ISO is still required for game resources.

Regenerate the TOML files with Python 3.11+: `python generate.py`.
Disable only the `60 FPS presentation interval` block to compare at 30 FPS;
leave the voice-selection block enabled for deterministic direct starts.

## Homecoming

The separate Homecoming patch targets PAL media `7F02C49C`, base version
`00000003`, executable hash `3DB72D7712F6ECD9`. Its engine constructor sets
both `fpsLimit` and `maxFPSLimit` to 30 with one `li r10,30` instruction.
The patch changes this instruction to `li r10,60`, retaining both field stores.
An independent `SysUpdate_Render` wait uses a fixed `1000/30 - 0.01` millisecond
interval at `0x82050710`. Raising the engine defaults alone leaves this wait
active. The patch also changes that single-use constant to `1000/60 - 0.01`.
It does not change the simulation clock. Use a 60 FPS emulator limit and
`time_scalar = 1`. Test gameplay speed, cutscenes and QTEs interactively;
raising these limits does not guarantee 60 FPS in every scene.

Validate all patch preimages against decoded virtual PE images with:
`python validate.py /path/to/hd/images --homecoming-image /path/to/default.xex.pe`.
Keep all original game images outside this repository.

The optional `diagnostics/Homecoming-Live-Lesen.cmd` starts a Windows PowerShell
memory reader for exactly one running Homecoming Xenia process. It only opens
the process for query/read access, validates its identity, and processes atomic
JSON range requests in `diagnostics/Homecoming-Live`. Close it with Ctrl+C.
Runtime output contains private memory and must stay outside this repository.
