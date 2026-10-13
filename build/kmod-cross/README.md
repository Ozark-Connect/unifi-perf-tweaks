# kmod-cross

Docker-based cross-compilation environment for
[`modules/force-uniphy1-sgmiiplus`](../../modules/force-uniphy1-sgmiiplus) and
[`modules/force-uniphy2-sgmiiplus`](../../modules/force-uniphy2-sgmiiplus).

Builds against a real Linux 5.4.213 source tree (matching UniFi OS's
`5.4.213-ui-ipq9574`) pulled from Qualcomm's public QSDK kernel repo on
CodeLinaro, rather than the prebuilt `.ko` files checked into this repo.

Kernel source: https://git.codelinaro.org/clo/qsdk/oss/kernel/linux-ipq-5.4
(tag `NHSS.QSDK.12.2.r7`, verified `VERSION=5 PATCHLEVEL=4 SUBLEVEL=213`).

## 1. Get the router's kernel config

```bash
ssh root@<gateway-ip> "zcat /proc/config.gz" > router.config
```

If `/proc/config.gz` isn't available on your firmware, this won't work -
there's no other supported way to get an exact `.config` short of asking
Ubiquiti (see [docs/sfp-sgmiiplus.md](../../docs/sfp-sgmiiplus.md) cross-compiling notes).

## 2. Build the image

```bash
docker build -t sgmiiplus-kbuild build/kmod-cross
```

This clones the kernel tree during the image build. The `.config`-dependent
`modules_prepare` step happens later, at `docker run` time in step 3, since
it depends on your `router.config`.

## 3. Build the modules

```bash
mkdir -p out
docker run --rm \
    -v "$(pwd)/router.config:/work/router.config:ro" \
    -v "$(pwd)/modules:/work/modules:ro" \
    -v "$(pwd)/out:/work/out" \
    sgmiiplus-kbuild
```

Output `.ko` files land in `./out/`. Compare against the checked-in
`modules/force-uniphy*/*.ko` if you want to sanity-check the prebuilt
binaries (they won't be byte-identical - build timestamps/paths differ even
with a deterministic source - but `modinfo` output, especially `vermagic`
and the exported/kallsyms symbol references, should match).

## Notes / caveats

- **`vermagic` comes from your `router.config`**, not this Dockerfile - as
  long as the config's `CONFIG_LOCALVERSION` matches what's baked into
  `uname -r` on the gateway (`-ui-ipq9574`), the built module's vermagic
  will match automatically.
- The kernel tree checked out here does **not** include IPQ9574-specific SoC
  drivers (clock/pinctrl/ESS switch/uniphy PHY) or a matching device tree -
  that's expected and fine. The modules never compile against those; they
  resolve everything at runtime via `kallsyms_lookup_name()` and a couple of
  exported `qca-ssdk.ko` symbols. `modules_prepare` only needs a
  correctly-versioned tree + your `.config` to generate `Module.symvers` and
  `include/generated/*` - it doesn't need to produce a bootable kernel.
- If your router's config has `CONFIG_MODVERSIONS=y`, the two exported
  symbols the module calls directly (`ssdk_mac_sw_sync_work_stop`,
  `ssdk_mac_sw_sync_work_start`) need CRCs matching the actual `qca-ssdk.ko`
  on your gateway. This tree can't provide that - the CRCs it generates are
  synthesized from function signatures in this tree, not from Ubiquiti's
  actual `qca-ssdk.ko` build. If `insmod` rejects the module with a
  "disagrees about version of symbol" error, this is why; you'd need
  `qca-ssdk`'s real `Module.symvers` from the gateway to fix it, which isn't
  available anywhere. Everything else in the module resolves symbol
  addresses manually via `kallsyms_lookup_name()` and is unaffected.
- Rebuild with a different tag by overriding the build arg, e.g.
  `docker build --build-arg KERNEL_REF=<tag> -t sgmiiplus-kbuild build/kmod-cross`.
