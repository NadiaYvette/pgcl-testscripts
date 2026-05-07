#!/bin/bash
# hppa64 — generic-64bit_defconfig.  Build currently fails with upstream
# binutils 2.45 due to "Field out of range [0..31] (68)" in kernel/ptrace.o
# (regression in binutils 2.45's PA-RISC reloc handling, not PGCL-specific).
#
# Workaround: pin binutils 2.44 (or a backport-fixed 2.45+) at
# ~/.local/cross-toolchains/hppa64-binutils-2.44/bin/ and prepend to PATH.
# See TOOLCHAINS.md for the build recipe.
if [ -d "$HOME/.local/cross-toolchains/hppa64-binutils-2.44/bin" ]; then
    EXTRA_CC_PATH="$HOME/.local/cross-toolchains/hppa64-binutils-2.44/bin"
fi

TIMEOUT=900
