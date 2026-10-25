# Hitman HD Trilogy FPS patches

Module-specific Xenia patches for the HD Trilogy executables. Each changes the
initial D3D presentation interval from two guest vblanks to one, without changing
the emulated clock. The exact module hash prevents applying a patch to another
executable, including the other game on disc 1.

Copy the Silent Assassin and Contracts TOMLs to the ordinary Xenia Edge `patches`
folder. Copy the Blood Money TOML to Xenia Canary's `patches` folder. Keep
`apply_patches = true`, `time_scalar = 1`, and `framerate_limit = 60` in the loaded
game configs. Keep Edge's `guest_display_refresh_cap = true` and Canary's
`vsync = true`. The ROM/ISO files are not modified.

This removes the identified 30-FPS presentation interval. Actual FPS and camera,
gameplay and cutscene timing must be checked in play; sufficient hardware
performance is still required. Disable the patch's `is_enabled` option to revert
the presentation interval.

## Validate against your executable

Use Python 3.11 or newer and install `requirements.txt`. Supply the original XEX
and its decompressed **virtual memory image**, for example `xex2ool basefile`
output. A conventional PE disk-layout image is not interchangeable.

```sh
python validate.py SilentAssassin /path/to/default.xex /path/to/default.pe
python validate.py Contracts /path/to/default.xex /path/to/default.pe
python validate.py BloodMoney /path/to/default.xex /path/to/default.pe
```

The validator reconstructs Xenia's function-import thunks before hashing code
pages and checks the original instruction and the generated patch. Games,
decrypted executables, logs and cabinet databases must not be added to this repo.
