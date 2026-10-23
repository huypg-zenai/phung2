#!/usr/bin/env bash
# build_sws.sh OUT_DIR - kernel-optim "sws-llvm": Chrome 147's SwiftShader rebuilt with the LLVM JIT backend, pixel-identical
# to Chrome's bundled libvk_swiftshader.so (Subzero) and ~1/3 less render CPU (R1, projects/kernel-optim/PROGRESS.md).
# Needs Ubuntu 22.04 (same glibc as the contest image), git, cmake, ninja-build, build-essential, python3; ~3 min on 32 cores.
# What differs from SwiftShader's stock CMake build, and why each one is needed for identical pixels:
#   1. revision 313545f85af72f954820e54f4110cda591a6cf7b = the one Chromium 147.0.7727.56 DEPS pins
#   2. Chromium's GN defines that CMake leaves out: SWIFTSHADER_LEGACY_PRECISION=true, SWIFTSHADER_HIGH_PRECISION_FILTERING,
#      SWIFTSHADER_ZERO_INITIALIZE_DEVICE_MEMORY (without them 0.8% of edge pixels differ, with Subzero too)
#   3. REACTOR_BACKEND=LLVM (the speed-up: the JIT'd raster code runs ~2x faster)
#   4. MulAdd() emitted as x * y + z like SubzeroReactor.cpp, not llvm.fmuladd (LLVM turns that into a hardware FMA on
#      AVX2 CPUs = different rounding: 77% of views had some differing pixels). FMA() itself is unchanged.
# Links libstdc++ dynamically: needs GLIBCXX_3.4.30 / glibc 2.34 = Ubuntu 22.04's (the image base). A -static-libstdc++
# build CRASHED Chrome right after prewarm (R1 box 22/10), so do not link it statically.
# Prints the sha256 of OUT_DIR/libvk_swiftshader.so.
set -euo pipefail
OUT=${1:?OUT_DIR}; REV=313545f85af72f954820e54f4110cda591a6cf7b; T=${SWS_BUILD_DIR:-/tmp/sws-build}
mkdir -p "$OUT" "$T"
[ -d "$T/src/.git" ] || git clone -q --filter=blob:none https://swiftshader.googlesource.com/SwiftShader "$T/src"
git -C "$T/src" checkout -q -f $REV
python3 - "$T/src/src/Reactor/LLVMReactor.cpp" <<'PY'
import re, sys
p = sys.argv[1]; t = open(p).read()
if "kopt: no fmuladd" not in t:
    pat = re.compile(r"(RValue<(Float4|SIMD::Float)> MulAdd\(RValue<\2> x, RValue<\2> y, RValue<\2> z\)\n\{\n).*?\n\}", re.S)
    t, n = pat.subn(lambda m: m.group(1) + "\treturn x * y + z;  // kopt: no fmuladd, round like Subzero\n}", t)
    assert n == 2, f"MulAdd anchors found {n}, expected 2"
    open(p, "w").write(t)
PY
# 5. SWS_CID=1 (R3c, 22/10): content-keyed JIT routine cache ids (cid_patch.py next to this script) -> the same shader is
#    no longer re-JIT'd for every new pipeline/page: -20% GPU-main-thread time, same pixels. Default 0 = the bb3e6767 recipe.
[ "${SWS_CID:-0}" = 1 ] && python3 "$(dirname "$0")/cid_patch.py" "$T/src"
D="-DSWIFTSHADER_LEGACY_PRECISION=true -DSWIFTSHADER_HIGH_PRECISION_FILTERING -DSWIFTSHADER_ZERO_INITIALIZE_DEVICE_MEMORY"
cmake -S "$T/src" -B "$T/b2" -G Ninja -DCMAKE_BUILD_TYPE=Release -DREACTOR_BACKEND=LLVM \
  -DSWIFTSHADER_BUILD_TESTS=OFF -DSWIFTSHADER_BUILD_BENCHMARKS=OFF -DSWIFTSHADER_WARNINGS_AS_ERRORS=OFF \
  -DCMAKE_C_FLAGS="$D" -DCMAKE_CXX_FLAGS="$D" > "$T/cmake.log"
ninja -C "$T/b2" vk_swiftshader > "$T/ninja.log"
cp "$(find "$T/b2" -name libvk_swiftshader.so -type f | head -1)" "$OUT/libvk_swiftshader.so"
sha256sum "$OUT/libvk_swiftshader.so"
