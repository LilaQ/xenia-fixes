# XXL RuntimeHost patch for Xenia Edge

Experimental CPU optimizations for title `58411249`, limited to RuntimeHost
module hash `0F8C087D6FEA1BD4` and its loaded address `0x82210000`.

The memory-copy replacement copies exactly the requested range, preserves
the original destination as the return value, and leaves nonvolatile
registers intact. It uses unaligned scalar 64-bit accesses supported by
Xenia's CPU backend. It is **not suitable for original Xbox 360 hardware**.

The cache-flush replacement resolves and calls Edge's existing
`KeSweepIcacheRange` kernel export, ordinal `0xAB`, instead of the inactive
`dcbf`/`icbi` traversal. It caches that export in unreachable original memcpy
code and retains the existing `sync`/`isync` barriers. Export lookup failure
returns with the barriers intact. The memcpy and cache replacements share
one patch switch because the cache routine occupies code made unreachable
by the memcpy replacement. Enable `[CPU] writable_code_segments = true`
in this game's configuration so the cached pointer can be written.

The installed Edge `669b4266f` implements this kernel export and invalidates
both address-space aliases. The observed dynamic syscall sites matched their
compiled code; stale translation at those sites was not demonstrated. This
patch tests whether honoring RuntimeHost's broader code-cache flush requests
helps. It does not establish that cache invalidation causes the slowdown.

No game content, profiles, logs, or captured code are included. The patch
changes loaded guest memory only; it does not modify the original package.

## Build and test

Use Python 3.11 or newer:

```sh
python -m pip install -r requirements.txt
python test_patch.py
python test_flush.py
python build_patch.py
```

The execution tests use Unicorn's default PPC64 CPU and virtual TLB.
They check copy results, byte-access ranges, page boundaries, ABI register
preservation, export lookup and reuse, failure handling, and the emitted TOML
encoding. A successful test does not
establish in-game performance or compatibility.

## Install or remove

With Xenia closed, place `58411249 - XXL RuntimeHost.patch.toml` in Edge's
`patches` directory. Enable `[General] apply_patches = true` and
`[CPU] writable_code_segments = true` in the XXL game configuration.
The next launch's log should name `RuntimeHost copy and JIT cache repair`
when the matching RuntimeHost module loads.

To undo the test, close Xenia and remove this patch file, or set its
`is_enabled` field to `false`, then restore the previous game configuration.
No LaunchBox entry changes are needed.

## Inspect runtime call stubs

`tools/XXL-Codecheck.cmd` runs a bounded, read-only snapshot of a single
running Windows Edge instance of this title. Place it and the matching
PowerShell file in the existing diagnostics directory, start XXL normally,
and run the command file once the menu is visible. No WPR recording or
configuration change is performed.

The tool checks the expected patched RuntimeHost instruction and fixed
memory base before reading 32 instruction bytes at each compiled guest
entry in `0x82000000..0x84FFFFFF`. It also captures the compiled JIT code
and address table so the runtime instructions can be compared with their
translations. Unreadable entries remain explicitly empty. Keep the output
private: captured guest code must not be committed or redistributed.

Dynamically generated CLR code outside the fixed indirection table is
captured separately in `dynamic-sites.csv`. The reader identifies the
x64 syscall resume-address sequence in compiled code, then reads the
corresponding guest instruction through the logged user page table.
The descriptor and memory base must match the expected XXL build. It
records missing mappings explicitly and limits the scan to 256 code sites.

Run `pwsh -File tests/Test-Codecheck.ps1` to verify 4 KB, 64 KB, and 16 MB
page translation, kernel virtual frames, and missing descriptor handling
against an in-memory fixture using the production C# implementation.
