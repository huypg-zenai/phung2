#!/usr/bin/env bash
# install_sws.sh LIB - put the sws-llvm libvk_swiftshader.so (build_sws.sh) into every puppeteer Chrome under
# $PUPPETEER_CACHE_DIR (default /opt/puppeteer-cache), only if that Chrome is the one it was verified against:
# Chrome 147.0.7727.56 whose bundled lib has sha256 a2c809468d66c236... (R1 box, 22/10). Anything else -> leave Chrome
# untouched and say so (exit 0, so an image build never breaks; grep the build log for "sws-llvm").
# The bundled lib is kept as libvk_swiftshader.so.bundled; to undo: cp it back over libvk_swiftshader.so.
# SWS_THREADS=N (default 4; 0 = leave SwiftShader's default 16) also writes [Processor] ThreadCount=N into SwiftShader.ini
# next to the lib (SwiftShader reads it from the LIBRARY's directory, not the cwd).
set -u
LIB=${1:?LIB}; C=${PUPPETEER_CACHE_DIR:-/opt/puppeteer-cache}; WANT=a2c809468d66c236
n=0
for d in "$C"/chrome/*/chrome-linux64; do
  [ -f "$d/libvk_swiftshader.so" ] || continue
  cur=$(sha256sum "$d/libvk_swiftshader.so.bundled" 2>/dev/null || sha256sum "$d/libvk_swiftshader.so"); cur=${cur:0:16}
  if [ "$cur" != "$WANT" ]; then echo "sws-llvm: NOT installed in $d (bundled lib sha $cur != $WANT: other Chrome build)"; continue; fi
  [ -f "$d/libvk_swiftshader.so.bundled" ] || cp "$d/libvk_swiftshader.so" "$d/libvk_swiftshader.so.bundled"
  cp "$LIB" "$d/libvk_swiftshader.so" && n=$((n + 1)) && echo "sws-llvm: installed in $d ($(sha256sum "$LIB" | cut -c1-16))"
  th=${SWS_THREADS:-4}; if [ "$th" != 0 ]; then printf '[Processor]\nThreadCount=%s\n' "$th" > "$d/SwiftShader.ini"; echo "sws-llvm: ThreadCount=$th"; fi
done
[ $n -gt 0 ] || echo "sws-llvm: installed nowhere"
