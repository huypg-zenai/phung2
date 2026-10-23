# sws-llvm: SwiftShader for Chrome 147, LLVM JIT backend (render speed, same pixels)

`libvk_swiftshader.so` is a build of **SwiftShader** (https://swiftshader.googlesource.com/SwiftShader, Apache License 2.0;
a copy of the licence is in `LICENSE-SwiftShader-Apache-2.0.txt`). It is the revision that Chromium 147.0.7727.56 pins in
its DEPS (`313545f85af72f954820e54f4110cda591a6cf7b`), built with the LLVM JIT backend (`REACTOR_BACKEND=LLVM`, the LLVM
copy that ships inside SwiftShader's `third_party/`: Apache 2.0 with LLVM exception). Chrome for Testing ships
the same revision built with the Subzero backend.

`build_sws.sh` is the exact recipe. It needs Ubuntu 22.04, git, cmake, ninja-build, build-essential and python3, and takes
about 3-10 min. Compared with SwiftShader's stock CMake build it has two changes:
1. Chromium's GN defines that the CMake build leaves out: `SWIFTSHADER_LEGACY_PRECISION=true`,
   `SWIFTSHADER_HIGH_PRECISION_FILTERING`, `SWIFTSHADER_ZERO_INITIALIZE_DEVICE_MEMORY`.
2. In `src/Reactor/LLVMReactor.cpp`, `MulAdd()` for Float4 and SIMD::Float is emitted as `x * y + z`, as Subzero does.
   Stock LLVM emits `llvm.fmuladd`, which becomes a fused multiply-add on AVX2 CPUs and rounds differently.

The shipped file has sha256 `bb3e676767c277fc787856547a85a1561782c97b798f1741fecfb396859f5ffa` (also in `SWS_SHA256`).
It is the exact file kernel-optim measured. Builds are not byte-reproducible because they embed build paths. A rebuild with
`build_sws.sh` was measured too and gave identical pixels.

The file is built with Ubuntu 22.04's gcc 11.4.0 and links the system `libstdc++.so.6` dynamically.

| Item | Value |
|---|---|
| NEEDED libraries | `libstdc++.so.6`, `libm.so.6`, `libgcc_s.so.1`, `libc.so.6`, `ld-linux-x86-64.so.2` |
| Newest symbol versions it needs | `GLIBC_2.34`, `GLIBCXX_3.4.30`, `CXXABI_1.3.13` |

Ubuntu 22.04 is the base of `pytorch/pytorch:2.8.0-cuda12.8-cudnn9-devel` and provides all of these.

| File | What it does |
|---|---|
| `install_sws.sh LIB` | Runs at image build. It copies the lib into `$PUPPETEER_CACHE_DIR/chrome/*/chrome-linux64/` only when that Chrome's bundled lib has sha256 `a2c809468d66c236...`. It keeps the bundled lib as `libvk_swiftshader.so.bundled` and writes `SwiftShader.ini` (`[Processor] ThreadCount=4`) next to the lib. For any other Chrome build it changes nothing and prints `sws-llvm: NOT installed`. |
| `sws_mode.sh` | Runs at container start, called by run.sh. `PGH_SWS=0` restores the bundled lib and removes the ini. `PGH_SWS=1` (the default) uses sws-llvm with `PGH_SWS_THREADS` threads (default 4; 0 means no ini, so SwiftShader uses its default of 16). `PGH_SWS_LIB` picks the lib for mode 1: `llvm` (the default, this file), `cid` (`cid/libvk_swiftshader.so`, below) or `cl4` (`cl4/libvk_swiftshader.so`, below); an invalid value or an unusable cid/cl4 lib gives one `!!` line and `llvm`. |
| `build_sws.sh OUT_DIR` | The build recipe above. It is kept for provenance and is not run in the image. `SWS_CID=1` adds `cid_patch.py` (below); the default 0 is the bb3e6767 recipe. |
| `cid/libvk_swiftshader.so` | Optional **sws-llvm-cid** lib (kernel-optim R3c), sha256 `3b3931790b3ee0419a45be45270c314a68dc4f39cf1e2e7a85598196f74ff0d1` (also in `cid/SWS_SHA256`). Same source, same 4 changes, plus `cid_patch.py`: SwiftShader's JIT routine caches are keyed by content ids instead of per-object serial ids, so an identical shader in a new pipeline/page is not JIT-compiled again. Not installed at build time; `PGH_SWS_LIB=cid` (with `PGH_SWS=1`) makes `sws_mode.sh` copy it in at container start, only if its sha256 matches and `ldd` finds every library and symbol version it needs; otherwise one `!!` line and the default lib. |
| `cl4/libvk_swiftshader.so` | Optional **sws-llvm-cl4** lib (kernel-optim R8, `results/r8/ship/cl4+bs1024.libvk_swiftshader.so`), sha256 `688cab9fe3fbf71cef7dbee09b4d0886b44f3660ef52ce58861dfac44ad61ca1` (also in `cl4/SWS_SHA256`). It is this sws-llvm (rev `313545f8` + the lmul `MulAdd` patch) with `src/Device/Renderer.hpp` `MaxClusterCount` 16->4 and `MaxBatchSize` 128->1024. Pixel-identical; render busy CPU -27% overall and -39% on heavy drafts; Chrome peak RSS +8%. Built with Ubuntu 22.04's gcc 11.4.0, newest symbol versions `GLIBC_2.34`, `GLIBCXX_3.4.30`, `CXXABI_1.3.13` (same NEEDED list as above), so it loads on the image. Handled exactly like cid: not installed at build time; `PGH_SWS_LIB=cl4` (with `PGH_SWS=1`) makes `sws_mode.sh` copy it in at container start only if its sha256 matches and `ldd` finds everything; otherwise one `!!` line and the default lib. Like the other libs it is committed in the repo (no .gitignore rule covers it), so it reaches the Docker build context with the checkout. |
| `cid_patch.py SWS_SRC` | The cid source patch (verbatim from kernel-optim `render/ship/`), called by `build_sws.sh` when `SWS_CID=1`. |

**cid build note:** the shipped `cid/libvk_swiftshader.so` was built with Ubuntu 24.04's gcc 13.3 and needs `GLIBC_2.38`
(`__isoc23_strtol*`, `fmod`, `fmodf`), newer than Ubuntu 22.04's 2.35. In this image (glibc 2.35) it will not load, so
`PGH_SWS_LIB=cid` falls back to the default lib (`ldd` guard in `sws_mode.sh`). To use cid in the image, rebuild it with
`SWS_CID=1 build_sws.sh OUT` on Ubuntu 22.04, as the recipe says, and pin the new sha256.
