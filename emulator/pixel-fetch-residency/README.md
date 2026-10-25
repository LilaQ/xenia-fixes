# Xenia Edge pixel-shader vfetch residency

The source patch includes vertex-fetch ranges used by the active pixel shader in the D3D12 residency/upload loop. The existing fetch validation and upload path remain in use; shared VS/PS slots are deduplicated.

`build_fix.py` builds an equivalent, version-pinned continuation for an owner-supplied Windows Edge executable. It rejects a different input hash or call-site layout and emits a separate executable. No game executable, cache, capture, profile or save is distributed. Apply the source patch when rebuilding a different Edge version.

```sh
python build_fix.py --exe /path/to/original/xenia_edge.exe --out xenia_edge_rise.exe
python test_binary.py --original /path/to/original/xenia_edge.exe --fixed xenia_edge_rise.exe
clang++ -std=c++17 -DORIGINAL test_residency.cpp -o test_before
./test_before
clang++ -std=c++17 test_residency.cpp -o test_after
./test_after
```

The binary execution test needs an x86-64 host or a compatible x86-64 Python environment; NASM is required by the builder. `prepare_launchbox.py` prepares a Rise-only emulator association with the existing controls and Keys2Pad lifecycle. It writes only to the supplied staging directory. Applying prepared XML requires LaunchBox and Big Box to be closed and the interactive game comparison to have succeeded.

The optional `capture-window` diagnostic uses RenderDoc's in-application API
to collect one measured wall-time window and save one capture at the end. It
does not implement emulator lockstep or guarantee 60 simulation frames. The
Windows wrapper accesses only the explicitly selected Xenia process and aborts
if the recorder or RenderDoc binary has an unexpected identity.

Build its freestanding x64 DLL with `python capture-window/build.py --clang
/path/to/clang --linker /path/to/lld-link`. Generated binaries stay in the ignored
`capture-window/build` directory. The build emits a wrapper with the matching DLL
hash. The Windows API calls and abort paths can be exercised by
`capture-window/test_win_binary.py <built-dll>` using an x64 Unicorn runtime;
`test_capture.c` is the platform-independent timing/API fixture.

The optional `host-fence` continuation extends the existing guest fence waits to
all draws using the imported host-memory buffer, including consumers that do
not themselves export data. This prevents an execution fence or interrupt from
being reported complete while the GPU still reads CPU-backed draw inputs. It
keeps device-buffer draws and ring-buffer parse-progress writeback unchanged.
The continuation is pinned to the output of `build_fix.py`; the source patch is
for the matching D3D12 source layout, not a patch for arbitrary Edge revisions.

```sh
python host-fence/build.py --exe xenia_edge_rise.exe --out /path/to/build/xenia_edge_rise_fence.exe
python host-fence/test_binary.py --original xenia_edge_rise.exe --fixed /path/to/build/xenia_edge_rise_fence.exe
```

The host-fence execution test checks both the continuation and the original
PM4 interrupt wait-dispatch instructions. Native GPU wait calls are stubbed;
this verifies ABI and wait selection, not GPU performance or game rendering.

`canary-port` applies the pixel-vfetch residency correction to the pinned
Canary cc4981a Windows binary. It does not apply the Edge host-buffer fence
continuation: this Canary path uses a device-local shared-memory buffer and
has no corresponding imported-host-buffer routing. The source patch covers
D3D12. Readback policy and game compatibility must be checked separately.

```sh
python canary-port/build.py --exe /path/to/xenia_canary.exe --out /path/to/build/xenia_canary_rise.exe
python canary-port/test_binary.py --original /path/to/xenia_canary.exe --fixed /path/to/build/xenia_canary_rise.exe
python canary-port/test_queue.py --original /path/to/xenia_canary.exe --fixed /path/to/build/xenia_canary_rise.exe
```

`test_queue.py` executes the full original and corrected fetch-queue loops,
including fetch validation and address/size decoding. It verifies that
pixel-only slots missing from the original queue appear after the correction,
that shared slots appear once, and that a null pixel shader preserves the
vertex-only behavior. It does not run guest shaders or the game.
