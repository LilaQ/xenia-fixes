#!/usr/bin/env bash
set -euo pipefail

# Use the pinned checkout with edge-644ba68-tfu2-trace.patch and the
# dependency compatibility patch and edge-644ba68-cartel-consecutive-trace.patch
# applied, in that order, followed by edge-644ba68-host-read-execution-fence.patch.
# Also apply edge-644ba68-trace-host-export-snapshot.patch and
# edge-644ba68-skip-no-effect-draws.patch and
# edge-644ba68-cartel-replay-stage-timing.patch, then
# edge-644ba68-host-geometry-snapshots.patch and
# edge-644ba68-trace-host-export-routing.patch. Build products stay outside this repo.
: "${XENIA_SOURCE:?Set the prepared Edge source directory}"
: "${XENIA_BUILD:?Set the external build directory}"
: "${XENIA_WIN_TOOLCHAIN:?Set the llvm-mingw CMake toolchain file}"
: "${XENIA_HOST_SHADER_CC:?Set the native shader compiler executable}"
: "${XE_MESON_EXECUTABLE:?Set the Windows cross-build Meson wrapper}"
: "${SLANGC_PATH:?Set the native Slang compiler wrapper}"

expected=644ba68febd06c4e0affa2c6ea146d0eb7fbfc73
test "$(git -C "$XENIA_SOURCE" rev-parse HEAD)" = "$expected"
patch_dir="$(cd "$(dirname "$0")/../patches" && pwd)"
# Later patches refine the same hunks. Validate the complete series in reverse
# on temporary copies, leaving the prepared checkout untouched.
python3 - "$XENIA_SOURCE" "$patch_dir" "$XENIA_BUILD" <<'PYVERIFY'
import pathlib, shutil, subprocess, sys, tempfile
source, patches, build = map(pathlib.Path, sys.argv[1:])
series = [
    'edge-644ba68-cartel-consecutive-trace.patch',
    'edge-644ba68-host-read-execution-fence.patch',
    'edge-644ba68-trace-host-export-snapshot.patch',
    'edge-644ba68-skip-no-effect-draws.patch',
    'edge-644ba68-cartel-replay-stage-timing.patch',
    'edge-644ba68-host-geometry-snapshots.patch',
    'edge-644ba68-trace-host-export-routing.patch',
]
build.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='cartel-patch-check.', dir=build) as tmp:
    scratch = pathlib.Path(tmp)
    names = set()
    for name in series:
        for line in (patches / name).read_text().splitlines():
            if line.startswith('+++ b/'):
                names.add(line[6:])
    for name in names:
        relative = pathlib.PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise RuntimeError('Unsafe patch path')
        target = scratch / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, target)
    for name in reversed(series):
        subprocess.run(['git', 'apply', '--reverse', '--ignore-whitespace',
                        str(patches / name)], cwd=scratch, check=True)
print('Verified complete Cartel patch series on temporary source copies.')
PYVERIFY
# The pinned generated DirectX header uses CRLF; the portable diff uses LF.
git -C "$XENIA_SOURCE" apply --check --reverse --ignore-whitespace \
  "$patch_dir/edge-644ba68-mingw-dependencies.patch"

mkdir -p "$XENIA_BUILD"
cat > "$XENIA_BUILD/version.h" <<EOF
#ifndef GENERATED_VERSION_H_
#define GENERATED_VERSION_H_
#define XE_BUILD_BRANCH "edge-tfu2-trace"
#define XE_BUILD_COMMIT "$expected"
#define XE_BUILD_COMMIT_SHORT "${expected:0:7}"
#define XE_BUILD_DATE __DATE__
#endif
EOF

cmake -S "$XENIA_SOURCE" -B "$XENIA_BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$XENIA_WIN_TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE=Release \
  '-DCMAKE_C_FLAGS=-DUNICODE -D_UNICODE -fms-extensions' \
  '-DCMAKE_CXX_FLAGS=-DUNICODE -D_UNICODE -fms-extensions' \
  -DXENIA_ENABLE_GPU_TRACE=ON -DXENIA_ENABLE_LTO=OFF \
  -DXENIA_ENABLE_PROFILER=OFF -DXENIA_BUILD_MISC=ON \
  -DXENIA_BUILD_TESTS=OFF \
  -DXENIA_HOST_SHADER_CC="$XENIA_HOST_SHADER_CC" \
  -DXE_MESON_EXECUTABLE="$XE_MESON_EXECUTABLE" \
  -DXENIA_MESA_SOURCE_DIR="$XENIA_SOURCE/third_party/mesa"
cmake --build "$XENIA_BUILD" \
  --target xenia-app xenia-gpu-d3d12-trace-dump -j "${XENIA_JOBS:-8}"
