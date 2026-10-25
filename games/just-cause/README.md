# Just Cause cabinet fixes

## Just Cause 2: module-specific FPS patch

The TOMLs target the game's presentation pacing and, for TU1, its separate
main-loop frame budget. They match only title `534307E7`, media `57290BAA`,
base version 1. Use the file matching the installed update:

- TU0: module hash `12134BD1769BFB2B`, instruction at `82895D6C`.
- TU1: module hash `6CDA2880AB433BFF`, instruction at `82BD9004`.

The TU1 location was checked by applying the original, matching official delta
update locally and reproducing Xenia's import rewrites. The reconstructed code
hash matches the loaded module. TU0 changes `li r30,2` to `li r30,1`
before storing the value in the presentation parameters. TU1 retains that
variant for comparison, with the engine-timer variant enabled by default.

TU1 also changes the runtime interval selection at `82BE52B0` from
`lwzx r4,r9,r8` to `li r4,1`. The original instruction indexes the interval
table at `832645A8` (`0x80000000`, `1`, `2`, `4`, `8`) before calling
`821CEA30`, which stores the selected value at D3D device offset `0x35EC`.
That is the same field initialized from presentation parameters offset `0x34`;
changing only the creation parameters leaves this runtime update unpatched.
The engine function containing this update was present in the gameplay JIT
snapshot. Whether this additional change achieves 60 FPS without timing issues
still requires gameplay testing.

TU1 also includes a mutually exclusive immediate-presentation comparison.
It selects `0x80000000`, the existing mode selected by the game's own branch
at `82BD901C` and the first entry in its interval table. Device creation and
runtime selection both receive that value. In the D3D command path at
`821CAC50`, interval one becomes a one-refresh scheduling request, whereas
immediate becomes zero. The test retains Edge's host limit of 60 FPS and
`time_scalar = 1`; it does not speed up the emulated clock. The interval-one
variant is disabled during this comparison.

The enabled TU1 variant also changes `ori r8,r9,33333` at `82214400` to
`ori r8,r9,16667`. The existing code converts that microsecond budget to
timebase ticks and stores it at `832958F8`; the next update sleeps for the
remaining budget at `822143C8`. This limiter is independent of presentation
intervals and Edge's host FPS limit. The two presentation-only variants must
remain disabled when the combined timer/presentation variant is enabled.

Copy it into the launched Xenia variant's `patches` folder. Enable `apply_patches`,
keep the guest vblank rate capped at 60 Hz, set `framerate_limit = 60`, and retain
`time_scalar = 1` in the loaded game config. Original game files and emulator
binaries stay unchanged.
Actual FPS and gameplay/cutscene timing require interactive testing. Set
`is_enabled = false` to undo the game-code change.

The official [compatibility report](https://github.com/xenia-canary/game-compatibility/issues/989)
includes a subsequently unreproduced report that launching extracted `default.xex`
avoided an ISO-loading hang. Extracting all game files and updating only the
LaunchBox ApplicationPath is a separate diagnostic step. Preserve the ISO until
successful play testing; preserve the existing config, profile and save paths.

## Just Cause 1: motion blur

The upstream [patch](https://github.com/xenia-canary/game-patches/blob/main/patches/534307D5%20-%20Just%20Cause.patch.toml)
provides `Disable Motion Blur`. Enable it only for its matching module hash
`A0E5289AF35E88F2`. This is a test for blur caused by the game's postprocessing;
it does not establish the cause of every blurry render.

Do not commit games, decrypted executables, private cabinet XMLs or logs.

## Windows CPU/GPU diagnosis

Copy the files from `diagnostics` into the launched Edge installation's
`diagnostics` folder. With exactly one Just Cause 2 instance running at the
place where the issue occurs, run `JC2-Diagnose.cmd`, accept the Windows elevation
prompt and press Enter. The Windows CPU recorder captures 15 seconds; the
helper also reads the JIT function map and records per-thread and GPU-engine
counters. For low-FPS diagnosis, move the camera in the affected gameplay scene
during the capture instead of recording a loading screen. It
does not change game files, settings, saves or the emulator process. The
live log is opened with read/write sharing to avoid a file-lock failure.

Capture folders contain private runtime data and must not be committed.
Keep the game open until the resulting addresses have been resolved.

If an existing capture needs a larger JIT snapshot, run `JC2-JIT-Nachlesen.cmd`
while the same emulator instance remains open. It verifies the recorded PID and
process start time, then replaces only the map and code snapshot in that capture.
The original CPU trace is retained. The reader covers Edge's full JIT address
range, with a 256-MB code-copy limit that fails explicitly rather than silently
truncating the snapshot.

## Edge scheduler comparison

`configs/jc2-edge-scheduler-test.toml` contains a narrow diagnostic override.
CPU sampling located a repeated status poll in guest function `8233CFA0`,
through `826E8BE8` and `827A1788`, on guest CPU 4. Scheduler logging also showed
that thread at priority 11 with a ready priority-10 worker on the same CPU.
This does not by itself prove that the poll causes the loading hang.

Merge the template's three keys into the existing game config while Xenia is
closed. Edge's `guest_scheduler_spin_quanta` permits a waiting lower-priority
thread to run after 20 unyielded slices. This deliberately relaxes priority
ordering, rather than bypassing any game loading check. Keep the FPS patch
disabled for this comparison. Check whether the initial loading screen completes
and whether the log records a `guest_scheduler_spin_quanta broke priority order`
message. Set the value back to `0` to restore normal scheduling. The workaround's
effect on gameplay has not been verified.

## Live thread-state capture

Run `JC2-Threadzustand.cmd` while the extracted TU0 or TU1 game is running in Edge.
It identifies the six guest CPU dispatch threads and briefly suspends each
individually to read its integer registers and stack, always resuming it in a `finally`
block before writing any files. It verifies the game's code at the logged
memory base and rejects contexts with unrelated stack, link-register or memory
base values. The capture includes bounded guest stack/object slices and the
JIT map for that same process. Stack bytes are copied before resuming their thread,
including readable prefixes at guard pages. A bounded main-loop manager snapshot
is saved separately under `game-state`; object fields shared with other threads
can still change during capture. It does not change guest memory or settings.
It requires permission to query the process and suspend/read its threads.

Private output lives under `diagnostics/JC2-Zustand-*`, excluded from Git.
`tests/Test-ThreadReader.ps1` checks the context filter and byte order without
calling Windows APIs. Actual Windows capture still requires an interactive run.

For additional bounded reads from the same running instance, `JC2-Live-Lesen.cmd`
accepts GUID-named JSON requests under `diagnostics/JC2-Live`. Each request supplies
hexadecimal guest addresses and byte counts, limited to 128 ranges, 64 KiB per
range and 4 MiB total. The process is opened only for query/read access and the
TU0 or TU1 code signature is rechecked for every request. The helper stops when that
process exits or the user closes it; it does not start a persistent service.
Request results and the readiness marker are private runtime data excluded from
Git. Use repeated reads to check fields modified concurrently by other threads.
An optional `{"capture_threads":true}` request captures the six guest CPU
threads through the same helper. This briefly pauses individual CPU threads,
then resumes them before file I/O; it does not write guest memory. Both TU0 and
TU1 contexts are validated against their code signatures. TU0-specific manager
layouts are never followed for TU1.
