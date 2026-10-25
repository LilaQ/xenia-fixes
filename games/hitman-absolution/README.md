# Hitman Absolution depth corrections for Xenia Edge

The current experimental mode (`--render-pass-bias`) applies a central,
shader-independent D3D12 rasterizer correction to this game's later HDR passes:
triangles, one RGBA16F target, D32F/S8 depth, single sample, enabled writable
`GREATER_EQUAL` depth, and no pre-existing constant/clamped/slope bias. It adds
512 units of floating-point primitive depth bias, clamped to 2**-16 normalized
depth. Shader bytecode is untouched. The captured sea pass belongs to this class;
other materials with the same state are included without collecting shader IDs.
G-buffer, depth-only, opposite comparison, multisample and already biased passes
are left unchanged. This is a bounded game-specific workaround, not an exact
Xenos depth-emulation implementation. Its wider visual coverage and occlusion
behaviour still require cabinet testing. It replaces the shader dispatch rather
than stacking two independent depth offsets.

```sh
python build_fix.py --exe /path/original-xenia_edge.exe --render-pass-bias \
  --output /path/new-hitman.exe
python test_render_pass.py /path/new-hitman.exe
```

`test_render_pass.py` executes the actual continuation for arbitrary shader
pointers and lengths, each failing state criterion, different image bases,
success/error HRESULTs, shadow-space use and nonvolatile registers. It also
checks the original unwind chain. `abi-offsets.cpp` independently checks the
field offsets and format enums against the Windows headers.

The following shader-specific mode remains the owner-verified fallback. The
installer accepts either pinned, execution-tested build, backs up the current
custom executable, and leaves stock Edge, LaunchBox and saves unchanged.

This tool builds a patch for the owner's exact Windows x64 Edge executable
(`669b4266f`, SHA-256 pinned in `build_fix.py`). It substitutes two verified
Hitman water pixel shaders while creating D3D12 graphics pipelines: the
puddle pass and the later sea/HDR pass. Other shaders, different binaries,
Vulkan and nonmatching depth-test states are not modified. There is no
per-frame hook, driver replacement or system DLL.

Both replacements retain the captured shaders' original colour calculations,
resource bindings and input signatures. They additionally export rasterized
depth with a positive 512-float32-ULP bias, suited to the captured reversed-depth
`GREATER_EQUAL` water passes. The captured puddle and sea stripe pixels failed
depth tests against slightly higher stored depth values. Replays with unchanged
shading and unbiased depth produced identical images; the biased original
shading restored the rejected water pixels. The owner confirmed that the
puddle-only patch corrected puddles but did not affect the sea. The combined
patch retains that puddle correction and adds the replay-validated sea pass.
Its coverage depends on these exact shaders and depth states: this is a
workaround for the two observed passes, not a general depth-precision repair
or a guarantee for every water effect in the game.

The executable patch redirects one complete call/store sequence into an
added readable, executable, nonwritable PE section containing the continuation
and validated DXIL. The original function's stack frame and nonvolatile
registers are preserved. A sorted exception table and chained unwind entry
retain its original unwind metadata and termination handler. Shader matching
checks each bytecode length, DXBC magic and all 128 digest bits, and requires
enabled `GREATER_EQUAL` depth testing. Pipeline descriptions are local to the
original function and are discarded on return.

The original executable, shaders, captures, logs and game files are private
inputs and are deliberately excluded from this repository.

The cabinet uses `xenia_edge_hitman.exe` beside the original `xenia_edge.exe`.
Only Hitman's separate LaunchBox emulator selects that binary; its Keys2Pad
startup and lifetime watchers use the same renamed process. Ordinary Edge
updates therefore do not overwrite the custom executable. Config, content,
cache and save paths remain shared exactly as before. The original stock
executable is restored from its verified backup, not from a patched input.

## Build and check

Install Python dependencies from `requirements.txt` and NASM. For the
shader-specific fallback, supply the exact owner-held original executable and both validated shader files from the
RenderDoc comparisons: puddle `wasser-plus-512ulp.dxil` and sea
`depth-plus-512.dxil`. The builder refuses all other input hashes and
never overwrites an input or an existing output file.

```sh
python build_fix.py --exe /path/xenia_edge.exe \
  --shader /path/wasser-plus-512ulp.dxil \
  --sea-shader /path/depth-plus-512.dxil --output /path/xenia_edge-hitman-water.exe
python test_fix.py /path/xenia_edge-hitman-water.exe
```

`test_fix.py` executes the emitted x64 code against a mock D3D12 method under
two image bases. It checks both dispatch paths, cross-length mismatches and
all 16 digest bytes for each shader,
HRESULT forwarding, argument preservation, shadow-space use, stack and
nonvolatile registers. It also validates PE exception-table ordering and the
chained unwind record. `abi-offsets.cpp` checks the Windows API layout with a
Windows-target C++ compiler. These checks do not replace an interactive
cabinet test or execute Windows' native unwinder. On Apple Silicon, the x64
Unicorn wheel under Rosetta may be required for x64 execution tests.

`isolate_build.py --launchbox /path/LaunchBox --original /path/original.exe`
prepares the one-time migration. Add `--apply` only with LaunchBox, Big Box
and Xenia closed. It backs up and verifies the executable and both XMLs,
preserves the game ID/count and command line, clones existing controller/exit
behaviour, and changes only Hitman's emulator reference. Afterwards,
`install_fix.py` installs verified outputs only as `xenia_edge_hitman.exe`
and protects the normal Edge executable from changes.

Only replace the custom EXE with Xenia closed, and first back up its original
bytes. Do not apply the builder to an updated stock Edge binary. A future build
requires reviewing its call site, ABI and unwind data again; the builder
intentionally fails instead of guessing.

`capture.ps1` and `trigger_capture.ps1` are installed as the existing
`Hitman-GPU-Aufnahme.ps1` and `Hitman-Jetzt-Aufnehmen.ps1` helpers. Both select
the isolated Hitman executable; the trigger requires exactly one matching
process. Capture settings are cloned, never saved over the game config.

`diagnose_capture.py` inspects a RenderDoc D3D12 capture without replacing
resources or changing game files. It exports native scene pipeline states
before PixelHistory instruments replay pipelines, plus captured shader bytes
and selected water-pixel histories. Run it through RenderDoc's embedded Python
with `HITMAN_ANALYSIS_ROOT` and `HITMAN_ANALYSIS_CAPTURE` set; the PowerShell/CMD
templates provide the cabinet launcher. Outputs remain private diagnostic
inputs and must not be committed. `test_diagnose.py` checks output structure,
replay ordering and cleanup using a mock replay; the native GPU run still
requires the Windows cabinet.

`inspect_inputs.py` follows a successful expanded capture inventory. It resolves
the sampled sea draws, exports their scene targets and constants, and reads the
actual per-stage bindless index buffers before resolving texture heap entries.
It also exports scene targets after their final draw, before clearing. Run it
with `HITMAN_ANALYSIS_SOURCE` pointing to the prior inventory and the capture/root
variables above; `inspect_inputs.ps1` and `.cmd` provide the cabinet launcher.
It does not change shaders or game data. `test_inputs.py` checks heap-index
resolution, resource-ID normalization, mismatched captures and failure cleanup.
Textures, buffer contents and diagnostic outputs must remain private inputs.

`compare_sea.py` measures black stripe pixels and adjacent intact pixels in the
inspected sea capture, then compares unchanged LLVM reassembly and explicit
depth-output variants in replay only. `depth_variant.py` resolves signature
metadata instead of assuming fixed node numbers and preserves existing colour
output instructions. `test_depth_variant.py` checks metadata sharing, output
preservation and rejection of unsupported signatures. Compilation, validation
and image comparison require the Windows replay; no live patch is installed.

References: [floating-point depth bias](https://learn.microsoft.com/en-us/windows/win32/direct3d11/d3d10-graphics-programming-guide-output-merger-stage-depth-bias),
[D3D12 pipeline description](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ns-d3d12-d3d12_graphics_pipeline_state_desc),
[Windows x64 unwind rules](https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64),
and [Edge's matching pipeline implementation](https://github.com/has207/xenia-edge/blob/669b4266f/src/xenia/gpu/d3d12/pipeline_cache.cc).
