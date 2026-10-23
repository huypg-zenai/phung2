#!/usr/bin/env bash
# sws_mode.sh - RUN-TIME switch for kernel-optim's sws-llvm SwiftShader (installed at image build by install_sws.sh).
# Called by run.sh before anything starts Chrome; a box A/B needs no rebuild:
#   PGH_SWS=1 (image default)  sws-llvm lib active (only where install_sws.sh installed it, i.e. Chrome 147.0.7727.56
#                              whose bundled lib sha256 = a2c809468d66c236...; it kept libvk_swiftshader.so.bundled)
#   PGH_SWS=0                  Chrome's bundled lib put back + SwiftShader.ini removed = exactly pgh17's renderer
#   PGH_SWS_THREADS=N          (with PGH_SWS=1; image default 4) [Processor] ThreadCount=N in SwiftShader.ini NEXT TO the
#                              lib (SwiftShader reads it from the library's dir); 0 = no ini (SwiftShader default 16)
#   PGH_SWS_LIB=llvm|cid|cl4   [pgh17d] (with PGH_SWS=1; image default llvm) which sws lib: llvm = /opt/sws/libvk_swiftshader.so
#                              (bb3e6767..., the gated one) | cid = /opt/sws/cid/libvk_swiftshader.so (sws-llvm-cid
#                              3b393179..., kernel-optim R3c: content-keyed JIT cache ids, same pixels, ~-20% GPU main
#                              thread; NOT gated on the pod CPU yet). cid is used only if its sha256 matches AND ldd finds
#                              every library/symbol version it needs here; else '!!' + llvm. Anything else -> '!!' + llvm.
#                              [cycle1] cl4 = /opt/sws/cl4/libvk_swiftshader.so (sws-llvm-cl4 688cab9f..., kernel-optim R8:
#                              the llvm lib + Renderer.hpp MaxClusterCount 16->4, MaxBatchSize 128->1024; pixel-identical,
#                              render busy CPU -27% (-39% heavy drafts), Chrome peak RSS +8%): exactly the same sha256 + ldd
#                              checks and '!!' + llvm fallback as cid.
# PGH_SWS=1 with PGH_RENDER_PIN=0 -> '!!' + mode 0 (kernel-optim gate 22/10 on AVX-512 Zen 4: the lib WITHOUT the
#                              program pin was slower than Chrome's lib, 1.76 vs 2.08 drafts/s); PGH_SWS_NOPIN_OK=1 forces it.
#                              The guard is the same for both libs (it runs before the lib choice).
# Anything else for PGH_SWS -> '!!' line + treated as 1. Never fails the container start (always exit 0); every outcome
# is one "[sws]" line naming the lib used (grep the pod log for it). Dirs without .bundled (= install refused) are left untouched.
# Test hooks: PUPPETEER_CACHE_DIR (default /opt/puppeteer-cache), SWS_LIB (default /opt/sws/libvk_swiftshader.so),
# SWS_SHA (expected sha256 of SWS_LIB, default the tested file bb3e6767...), SWS_CID_LIB (default
# /opt/sws/cid/libvk_swiftshader.so), SWS_CID_SHA (default 3b393179...), SWS_CL4_LIB (default
# /opt/sws/cl4/libvk_swiftshader.so), SWS_CL4_SHA (default 688cab9f...), SWS_LDD (default ldd).
set -u
C=${PUPPETEER_CACHE_DIR:-/opt/puppeteer-cache}
LIB=${SWS_LIB:-/opt/sws/libvk_swiftshader.so}
WANT=${SWS_SHA:-bb3e676767c277fc787856547a85a1561782c97b798f1741fecfb396859f5ffa}
CLIB=${SWS_CID_LIB:-/opt/sws/cid/libvk_swiftshader.so}
CWANT=${SWS_CID_SHA:-3b3931790b3ee0419a45be45270c314a68dc4f39cf1e2e7a85598196f74ff0d1}
KLIB=${SWS_CL4_LIB:-/opt/sws/cl4/libvk_swiftshader.so}
KWANT=${SWS_CL4_SHA:-688cab9fe3fbf71cef7dbee09b4d0886b44f3660ef52ce58861dfac44ad61ca1}
mode=${PGH_SWS:-1}; th=${PGH_SWS_THREADS:-4}; sel=${PGH_SWS_LIB:-llvm}
case "$mode" in 0|1) ;; *) echo "[sws] !! PGH_SWS='$mode' is not 0/1 -> 1"; mode=1;; esac
case "$th" in ''|*[!0-9]*) echo "[sws] !! PGH_SWS_THREADS='$th' is not a number -> 4"; th=4;; esac
[ "$th" -gt 64 ] && { echo "[sws] !! PGH_SWS_THREADS=$th > 64 -> 4"; th=4; }
case "$sel" in llvm|cid|cl4) ;; *) echo "[sws] !! PGH_SWS_LIB='$sel' is not llvm/cid/cl4 -> llvm"; sel=llvm;; esac
# the optional (non-default) lib picked by PGH_SWS_LIB: cid and cl4 go through the very same checks and copy below
case "$sel" in cid) ALIB=$CLIB; AWANT=$CWANT; ANAME=sws-llvm-cid;; cl4) ALIB=$KLIB; AWANT=$KWANT; ANAME=sws-llvm-cl4;; esac
if [ "$mode" = 1 ] && [ "${PGH_RENDER_PIN:-1}" = 0 ] && [ "${PGH_SWS_NOPIN_OK:-0}" != 1 ]; then
  echo "[sws] !! PGH_SWS=1 with PGH_RENDER_PIN=0: sws-llvm without the pin is slower than Chrome's lib -> mode 0 (PGH_SWS_NOPIN_OK=1 forces 1)"
  mode=0
fi
# [pgh17d] cid (and [cycle1] cl4): check the shipped file once (sha, then loadability: a lib that needs a newer glibc than this image's would
# make Chrome lose WebGL), before any Chrome dir is touched; on any doubt use llvm
if [ "$mode" = 1 ] && [ "$sel" != llvm ]; then
  got=$(sha256sum "$ALIB" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" != "$AWANT" ]; then
    echo "[sws] !! PGH_SWS_LIB=$sel: $ALIB sha256 ${got:0:16} != ${AWANT:0:16} -> llvm"; sel=llvm
  else
    lo=$(${SWS_LDD:-ldd} "$ALIB" 2>&1); lrc=$?
    if [ $lrc != 0 ] || grep -q 'not found' <<< "$lo"; then
      echo "[sws] !! PGH_SWS_LIB=$sel: $ALIB does not load here (ldd rc $lrc: $(grep -m1 'not found' <<< "$lo" | tr -s ' \t' ' ' | cut -c1-300)) -> llvm"; sel=llvm
    fi
  fi
fi
ini_() { if [ "$th" = 0 ]; then rm -f "$ini"; else printf '[Processor]\nThreadCount=%s\n' "$th" > "$ini"; fi; }
tc_() { [ "$th" = 0 ] && echo 'default (no ini)' || echo "$th"; }
n=0
for d in "$C"/chrome/*/chrome-linux64; do
  [ -f "$d/libvk_swiftshader.so.bundled" ] || continue
  n=$((n + 1)); cur="$d/libvk_swiftshader.so"; ini="$d/SwiftShader.ini"
  if [ "$mode" = 0 ]; then
    if cmp -s "$d/libvk_swiftshader.so.bundled" "$cur" || cp "$d/libvk_swiftshader.so.bundled" "$cur"; then
      rm -f "$ini" && echo "[sws] mode 0: Chrome's bundled lib in $d ($(sha256sum "$cur" | cut -c1-16)), no SwiftShader.ini" \
        || echo "[sws] !! mode 0: bundled lib in $d but SwiftShader.ini could not be removed"
    else
      echo "[sws] !! mode 0: could not restore the bundled lib in $d (read-only?) -> state unchanged: $(sha256sum "$cur" | cut -c1-16)"
    fi
    continue
  fi
  if [ "$sel" != llvm ]; then
    # copied file verified after the copy; any failure -> fall through to the llvm path below (never a half state)
    if { cmp -s "$ALIB" "$cur" || cp "$ALIB" "$cur"; } 2>/dev/null && [ "$(sha256sum "$cur" | cut -d' ' -f1)" = "$AWANT" ]; then
      ini_; echo "[sws] mode 1: $ANAME in $d ($(sha256sum "$cur" | cut -c1-16)), ThreadCount $(tc_)"; continue
    fi
    echo "[sws] !! PGH_SWS_LIB=$sel: could not put $ANAME into $d -> llvm"
  fi
  got=$(sha256sum "$LIB" 2>/dev/null | cut -d' ' -f1)
  if [ "$got" != "$WANT" ]; then
    echo "[sws] !! mode 1: $LIB sha256 ${got:0:16} != ${WANT:0:16} -> state unchanged in $d: $(sha256sum "$cur" | cut -c1-16)"
    continue
  fi
  if ! { cmp -s "$LIB" "$cur" || cp "$LIB" "$cur"; }; then
    echo "[sws] !! mode 1: could not copy sws-llvm into $d -> state unchanged: $(sha256sum "$cur" | cut -c1-16)"; continue
  fi
  ini_
  echo "[sws] mode 1: sws-llvm in $d ($(sha256sum "$cur" | cut -c1-16)), ThreadCount $(tc_)"
done
[ $n -gt 0 ] || echo "[sws] sws-llvm not installed in this image (no libvk_swiftshader.so.bundled under $C/chrome): Chrome's own lib, PGH_SWS ignored"
exit 0
