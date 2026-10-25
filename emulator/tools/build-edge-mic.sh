#!/usr/bin/env bash
set -euo pipefail

: "${XENIA_SOURCE:?Set the pinned Xenia Edge source checkout}"
: "${XENIA_BUILD:?Set an external Windows build directory}"
: "${LLVM_MINGW_ROOT:?Set the llvm-mingw toolchain root}"
: "${XE_MESON_EXECUTABLE:?Set the Windows Meson wrapper}"
: "${SLANGC_PATH:?Set a native slangc executable}"
export SLANGC_PATH

expected=644ba68febd06c4e0affa2c6ea146d0eb7fbfc73
test "$(git -C "$XENIA_SOURCE" rev-parse HEAD)" = "$expected"
root="$(cd "$(dirname "$0")/.." && pwd)"
patches=(
  edge-644ba68-mingw-dependencies.patch
  edge-644ba68-tfu2-trace.patch
  edge-644ba68-xmic-host-capture.patch
  edge-644ba68-title-keys-aes.patch
  edge-644ba68-apc-object-pointer.patch
  edge-644ba68-xmic-async-data.patch
  edge-644ba68-xmic-multimic-low-latency.patch
  edge-644ba68-hid-dpad-priority.patch
  edge-644ba68-xmic-device-selection.patch
  edge-644ba68-xmic-auto-devices.patch
)
for name in "${patches[@]}"; do
  patch="$root/patches/$name"
  if git -C "$XENIA_SOURCE" apply --check --reverse "$patch"; then
    continue
  fi
  git -C "$XENIA_SOURCE" apply --check "$patch"
  git -C "$XENIA_SOURCE" apply "$patch"
done

mkdir -p "$XENIA_BUILD"
if [[ -n "${XENIA_MESA_PYTHON_BIN:-}" ]]; then
  export PATH="$XENIA_MESA_PYTHON_BIN:$PATH"
fi

# Xenia's third-party CMake expects the generated public header in the
# source checkout. Generate it with the native compiler before cross-building.
snappy="$XENIA_SOURCE/third_party/snappy"
if [[ ! -f "$snappy/snappy-stubs-public.h" ]]; then
  cmake -S "$snappy" -B "$XENIA_BUILD/snappy-native" -G Ninja \
    -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF
  cp "$XENIA_BUILD/snappy-native/snappy-stubs-public.h" "$snappy/"
fi

cat > "$XENIA_BUILD/version.h" <<EOF
#ifndef GENERATED_VERSION_H_
#define GENERATED_VERSION_H_
#define XE_BUILD_BRANCH "edge-mic"
#define XE_BUILD_COMMIT "$expected"
#define XE_BUILD_COMMIT_SHORT "${expected:0:7}"
#define XE_BUILD_DATE __DATE__
#endif
EOF

cmake -S "$XENIA_SOURCE" -B "$XENIA_BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$root/tools/windows-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  '-DCMAKE_C_FLAGS=-DUNICODE -D_UNICODE -fms-extensions' \
  '-DCMAKE_CXX_FLAGS=-DUNICODE -D_UNICODE -fms-extensions' \
  -DXENIA_ENABLE_GPU_TRACE=OFF -DXENIA_ENABLE_LTO=OFF \
  -DXENIA_ENABLE_PROFILER=OFF -DXENIA_BUILD_MISC=ON \
  -DXENIA_BUILD_TESTS=OFF \
  -DXE_MESON_EXECUTABLE="$XE_MESON_EXECUTABLE" \
  -DXENIA_MESA_SOURCE_DIR="$XENIA_SOURCE/third_party/mesa"

cmake --build "$XENIA_BUILD" --target xenia-app -j "${XENIA_JOBS:-8}"

output="${XENIA_OUTPUT:-$XENIA_BUILD/bin/Windows/xenia_edge_mic.exe}"
mkdir -p "$(dirname "$output")"
cp "$XENIA_BUILD/bin/Windows/xenia_edge.exe" "$output"
"$LLVM_MINGW_ROOT/bin/llvm-strip" --strip-all "$output"
printf 'Mic build: %s\n' "$output"
