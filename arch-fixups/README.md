# Per-arch fixups for matrix-driver-all.sh

Each `<arch>/apply.sh` is sourced by the matrix driver after `make defconfig`
and before `make olddefconfig`/`make`.  Inside, you have access to the driver's
shell variables:

- `$KBUILD`     — out-of-tree build directory (`scripts/config --file "$KBUILD/.config" ...`)
- `$ARCH`       — matrix arch name (`x86_64`, `aarch64`, `ppc64`, `arm-lpae`, ...)
- `$LA`         — kernel ARCH= value (`x86`, `arm64`, `powerpc`, `arm`, ...)
- `$CC`         — `CROSS_COMPILE=` prefix (may be empty for native)
- `$INITRAMFS`  — initramfs directory (`/home/nyc/src/pgcl/userspace/initramfs`)
- `$CONFIG`     — PGCL config (`mainline`, `0`, `2`, `4`, `6`)

The fixup may set the following variables consumed by the driver:

- `TIMEOUT`             — QEMU wall-clock timeout in seconds (overrides default 300)
- `INITRD_ARG`          — replaces the default `-initrd $INITRAMFS/initramfs-$ARCH.cpio.gz`
- `EXTRA_QEMU`          — additional QEMU args (e.g. `-dtb ...`)
- `EMBEDDED_INITRD`     — set to `1` to skip the `-initrd` path (microblaze, loongarch64)
- `BOOT_STYLE`          — `default` (bzImage/Image + -initrd) or `esp` (FAT32 disk + EFI)
- `EXTRA_CC_PATH`       — prepended to `PATH` (for pinned cross-toolchains, e.g. hppa64
                          binutils ≤ 2.44 to dodge the 2.45 reloc-range regression)

The fixup runs after a generic `--enable BLK_DEV_INITRD` is applied to every
arch, so individual fixups don't need to repeat that.

## Adding a new fixup

1. `mkdir arch-fixups/<arch>`
2. `cp arch-fixups/_template/apply.sh arch-fixups/<arch>/apply.sh`
3. Edit and commit.

## Pinned toolchains

Larger artifacts (e.g. a hand-built `hppa64-binutils-2.44`) live outside the
git repo at `~/.local/cross-toolchains/<name>/bin/`.  The build recipe and
provenance for each pinned toolchain belong in `TOOLCHAINS.md` at the repo
root so a fresh machine can reconstruct them.

## Why this lives in the repo

These fixes have been re-derived multiple times across sessions (alpha
defconfig missing BLK_DEV_INITRD, s390x boot timeout under PAR=2 contention,
arm-lpae DTB build path, hppa64 binutils 2.45 reloc range, m68k QEMU 10.1.4
silent boot, microblaze QEMU silent boot).  Capturing the resolved cases as
versioned scripts makes them survive across sessions, machines, and clones.
