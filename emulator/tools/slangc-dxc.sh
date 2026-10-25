#!/bin/sh
set -eu
# GAT_SLANGC may be the local tools/slang-host.cc driver, which can load
# the locally built DXC library alongside the upstream Slang compiler library.
: "${GAT_SLANGC:?Set GAT_SLANGC to the native slangc executable}"
: "${GAT_DXC_LIBRARY:?Set GAT_DXC_LIBRARY to the native DXC library}"
exec "$GAT_SLANGC" -dxc-path "$GAT_DXC_LIBRARY" "$@"
