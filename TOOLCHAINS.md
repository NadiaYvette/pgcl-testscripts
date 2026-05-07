# Cross-toolchains used by the matrix

Default toolchains come from Fedora's `gcc-${arch}-linux-gnu` /
`binutils-${arch}-linux-gnu` packages.  Pinned toolchains for arches where the
distro version is broken or unavailable live under
`~/.local/cross-toolchains/<name>/bin/` and are picked up by the corresponding
`arch-fixups/<arch>/apply.sh` via `EXTRA_CC_PATH`.

| Pinned toolchain | Why | Build recipe |
|---|---|---|
| `hppa64-binutils-2.44` | Upstream binutils 2.45 has a PA-RISC reloc-handling regression that breaks `kernel/ptrace.o` ("Field out of range [0..31] (68)").  binutils ≤ 2.44 builds clean. | See below |

## hppa64-binutils-2.44 build

```sh
cd /tmp
wget https://ftp.gnu.org/gnu/binutils/binutils-2.44.tar.xz
tar xf binutils-2.44.tar.xz
cd binutils-2.44
mkdir build && cd build
../configure --target=hppa64-linux-gnu \
             --prefix=$HOME/.local/cross-toolchains/hppa64-binutils-2.44 \
             --disable-nls --disable-werror
make -j$(nproc)
make install
```

After install, verify the matrix picks it up:
```sh
$ ls $HOME/.local/cross-toolchains/hppa64-binutils-2.44/bin/hppa64-linux-gnu-as
$ ARCH=hppa64 CONFIG=4 ./matrix-driver-all.sh /home/nyc/src/linux hppa64 4 /tmp/test
```
The `arch-fixups/hppa64/apply.sh` block will prepend that path automatically.

## Provenance

Why not just track binutils HEAD?  Each pinned toolchain in this file freezes
a known-good combination tested against our kernel tree.  A tarball URL +
configure flags is enough for any reviewer (or future-us) to reproduce the
exact toolchain we built and tested with, without having to hunt for the
right git revision.

When upstream Fedora ships a version of the affected package that builds the
kernel cleanly again, the pinned entry can be removed and the corresponding
`apply.sh` block deleted.
