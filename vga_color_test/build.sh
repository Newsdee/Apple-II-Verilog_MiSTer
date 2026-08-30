#!/usr/bin/env bash
set -euo pipefail

# Locate the MSYS2 ucrt64 toolchain (works from an MSYS2 shell where
# /ucrt64 is mapped, or from a shell that only sees /c/msys64).
if [ -d /ucrt64/bin ]; then
    UCRT=/ucrt64
elif [ -d /c/msys64/ucrt64 ]; then
    UCRT=/c/msys64/ucrt64
else
    echo "Error: MSYS2 ucrt64 toolchain not found." >&2
    exit 1
fi

export PATH="$UCRT/bin:/usr/bin:$PATH"
# Use the compiled Verilator binary directly; the Perl 'verilator' wrapper
# needs Pod::Usage, which is not always installed in ucrt64.
export V=verilator_bin
# MSYS2 ships make as mingw32-make; Verilator invokes $MAKE for the C++ build.
export MAKE="$UCRT/bin/mingw32-make.exe"
export VERILATOR_ROOT="$UCRT/share/verilator"
cd "$(dirname "$0")"
exec "$UCRT/bin/mingw32-make.exe" "$@"
