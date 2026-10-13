#!/bin/bash
# entrypoint.sh - prepare $KDIR with the router's .config, then build any
# out-of-tree module directories mounted at /work/modules.
#
# Expects (bind-mounted at `docker run` time):
#   /work/router.config   - the router's own kernel config
#                            (ssh root@<gw> "zcat /proc/config.gz" > router.config)
#   /work/modules          - this repo's modules/ directory (read-only is fine)
#   /work/out              - host directory to receive the built .ko files
set -euo pipefail

CONFIG=/work/router.config
MODULES_SRC=/work/modules
OUT=/work/out

if [ ! -f "${CONFIG}" ]; then
    echo "ERROR: router config not found at ${CONFIG}"
    echo "  Mount it with: -v \$(pwd)/router.config:/work/router.config:ro"
    echo "  Fetch it from the gateway with: ssh root@<gateway-ip> 'zcat /proc/config.gz' > router.config"
    exit 1
fi

echo "== Using router config: ${CONFIG} =="
cp "${CONFIG}" "${KDIR}/.config"

echo "== olddefconfig (accept router config, default any new symbols) =="
make -C "${KDIR}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" olddefconfig

echo "== modules_prepare =="
make -C "${KDIR}" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" modules_prepare

vermagic=$(grep -m1 UTS_RELEASE "${KDIR}/include/generated/utsrelease.h" 2>/dev/null || true)
echo "== Prepared kernel tree: ${vermagic:-<utsrelease.h not found>} =="

if [ ! -d "${MODULES_SRC}" ]; then
    echo "No ${MODULES_SRC} mounted - kernel tree is prepared at ${KDIR}."
    echo "Build manually with:"
    echo "  make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} KDIR=${KDIR} M=/path/to/module modules"
    exit 0
fi

mkdir -p "${OUT}"
built_any=0

for mod_dir in "${MODULES_SRC}"/*/; do
    [ -f "${mod_dir}/Makefile" ] || continue
    name=$(basename "${mod_dir}")
    echo "== Building ${name} =="

    # Module source dirs are read-only when bind-mounted from the host repo;
    # build objects need a writable copy.
    build_dir="/work/build/${name}"
    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"
    cp -a "${mod_dir}." "${build_dir}/"

    # cd (not `make -C`) so the module Makefile's $(PWD) - used as M=$(PWD)
    # in its `all:` recipe - actually resolves to this directory. `make -C`
    # alone leaves the inherited PWD env var pointing at the old cwd.
    (cd "${build_dir}" && make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" KDIR="${KDIR}")

    if compgen -G "${build_dir}"/*.ko > /dev/null; then
        cp "${build_dir}"/*.ko "${OUT}/"
        built_any=1
    else
        echo "WARNING: no .ko produced for ${name}"
    fi
done

if [ "${built_any}" -eq 1 ]; then
    echo "== Done. Built modules: =="
    ls -la "${OUT}"/*.ko
else
    echo "ERROR: no modules were built"
    exit 1
fi
