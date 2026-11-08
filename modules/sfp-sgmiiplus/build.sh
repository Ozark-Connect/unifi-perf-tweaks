#!/bin/bash
# Build the port-specific SGMII+ modules from their shared implementation.
# Run in the pinned container, with the repository read-only and /out writable:
#   docker run --rm -v "$PWD":/repo:ro -v /path/to/build:/out \
#     debian@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308 \
#     bash /repo/modules/sfp-sgmiiplus/build.sh /out/config both
# Port-specific build.sh wrappers retain their existing entry points.
set -euo pipefail

CONFIG="${1:?usage: build.sh CONFIG [eth6|eth5|both]}"
TARGET="${2:-both}"
case "$TARGET" in
    eth6) MODS="force_uniphy1_sgmiiplus" ;;
    eth5) MODS="force_uniphy2_sgmiiplus" ;;
    both) MODS="force_uniphy1_sgmiiplus force_uniphy2_sgmiiplus" ;;
    *) echo "ERROR: target must be eth6, eth5 or both" >&2; exit 1 ;;
esac
RESULT_DIR="$(cd "$(dirname "$CONFIG")" && pwd)"
QSDK_REPO="https://github.com/CodeLinaro-mirror/qsdk_oss_kernel_linux-ipq-5.4.git"
QSDK_COMMIT="8a567f8188c2174fec2ec9a2993fe30e5b50c61c"   # NHSS.QSDK.12.4.r1
EXPECTED_GCC="14.2.0-19"
EXPECTED_VERMAGIC="5.4.213-ui-ipq9574 SMP preempt mod_unload aarch64"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="/work"   # inside the container; fixed so debug paths and the hash stay the same
SRC="$WORK/qsdk-5.4"
OUT="$WORK/out"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    git make gcc libc6-dev gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    bc bison flex libssl-dev libelf-dev python3 kmod ca-certificates >/dev/null

gcc_pkg=$(dpkg-query -W -f='${Version}' gcc-14-aarch64-linux-gnu 2>/dev/null || true)
echo "cross gcc package: ${gcc_pkg:-unknown} (vendor kernel: ${EXPECTED_GCC})"
case "$gcc_pkg" in
    "$EXPECTED_GCC"*) ;;
    *) echo "WARNING: compiler differs from the vendor build; the module may still work but will not be byte-identical." ;;
esac

if [ ! -d "$SRC/.git" ]; then
    git init -q "$SRC"
    git -C "$SRC" remote add origin "$QSDK_REPO"
fi
git -C "$SRC" fetch -q --depth 1 origin "$QSDK_COMMIT"
git -C "$SRC" checkout -q --force FETCH_HEAD
git -C "$SRC" clean -qfdx

cd "$SRC"
cp "$CONFIG" .config
: > .scmversion                       # no "+" suffix in the kernel release
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-ui-ipq9574"/' .config
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make -s olddefconfig
make -s -j"$(nproc)" modules_prepare
echo "kernel release: $(make -s kernelrelease)"

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$HERE/sfp_sgmiiplus.h" "$OUT/"
: > "$OUT/Makefile"
for MOD in $MODS; do
    case "$MOD" in
        force_uniphy1_sgmiiplus) PORT_DIR="$HERE/../force-uniphy1-sgmiiplus" ;;
        force_uniphy2_sgmiiplus) PORT_DIR="$HERE/../force-uniphy2-sgmiiplus" ;;
    esac
    cp "$PORT_DIR/$MOD.c" "$OUT/"
    printf 'obj-m += %s.o\n' "$MOD" >> "$OUT/Makefile"
done
make -s -C "$SRC" M="$OUT" KCFLAGS="-ffile-prefix-map=$WORK=." modules
for MOD in $MODS; do
    vermagic=$(modinfo -F vermagic "$OUT/$MOD.ko")
    echo "$MOD vermagic: $vermagic"
    if [ "${vermagic% }" != "$EXPECTED_VERMAGIC" ]; then
        echo "ERROR: vermagic does not match the vendor kernel ($EXPECTED_VERMAGIC)" >&2
        exit 1
    fi
    cp "$OUT/$MOD.ko" "$RESULT_DIR/$MOD.ko"
    (cd "$RESULT_DIR" && sha256sum "$MOD.ko" | tee "$MOD.ko.sha256")
    echo "$MOD undefined symbols (must exist in the target kernel):"
    aarch64-linux-gnu-nm -u "$OUT/$MOD.ko" | awk '{print "  " $2}'
done
