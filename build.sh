#!/bin/sh
# Patch WhatsApp 26.41.74 for iOS 14 (TrollStore .tipa): shim + patch -> offline load check.
#   usage: ./build.sh <decrypted.ipa> <dyld_shared_cache_arm64e> [out.tipa]
#   env:   WORK (default ./work), THEOS (default ~/theos), DYLDEX, CONCURRENCY, SDK,
#          TARGET_IOS (minos written, default 14.0), CACHE_IOS (cache's version, default 14.3),
#          PROFILE, WAPORT_LOG=1 (diagnostic build: full Documents/waport.log)
set -e
[ $# -ge 2 ] || { sed -n '3,6p' "$0"; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
IPA="$1"
CACHE="$2"
OUT="${3:-$(basename "${IPA%.ipa}")-ios${TARGET_IOS:-14}.tipa}"
W="${WORK:-$HERE/work}"
mkdir -p "$W"
DYLDEX="${DYLDEX:-$W/venv/bin/dyldex}"
if [ ! -x "$DYLDEX" ]; then
    python3 -m venv "$W/venv"
    # setuptools<81: capstone (dyldextractor dep) still imports pkg_resources
    "$W/venv/bin/pip" install -q dyldextractor 'setuptools<81'
fi
python3 "$HERE/tools/patch.py" "$IPA" "$OUT" "$CACHE" "$DYLDEX" "$W"
TARGET_IOS="${CACHE_IOS:-14.3}" python3 "$HERE/tools/verify.py" "$OUT" "$CACHE" "$DYLDEX" "$W"
