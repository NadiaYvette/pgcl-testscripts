#!/bin/bash
# Build an instrumented x86_64 PGCL=0 kernel for the #106 laptop-e820 QEMU
# repro: same mm/ source as the laptop crasher, plus the page/mm corruption
# detectors un-silenced (DEBUG_VM + DEBUG_VM_PGFLAGS + PAGE_OWNER) so a bad
# free is CAUGHT AT THE SOURCE (free_page_is_bad / bad_page) with the freeing
# stack dumped by PAGE_OWNER (boot page_owner=on) — not just the downstream
# reserved-bit fault. PGCL=0 so it's the Newton-limit (must==mainline) case.
set -eu
SRC=/home/nyc/src/linux
KB=/home/nyc/src/pgcl/kernel-build-e820repro
LOG=/home/nyc/src/pgcl/e820repro-build.log
mkdir -p "$KB"
cd "$SRC"
{
  echo "### e820repro kernel build start $(date +%H:%M:%S) — HEAD $(git rev-parse --short HEAD)"
  make ARCH=x86 O="$KB" x86_64_defconfig
  scripts/config --file "$KB/.config" \
      --set-val PAGE_MMUSHIFT 0 \
      --enable DEBUG_VM --enable DEBUG_VM_PGFLAGS --enable PAGE_OWNER \
      --enable BLK_DEV_INITRD
  make ARCH=x86 O="$KB" olddefconfig
  make ARCH=x86 O="$KB" -j"${MJ:-10}"
  echo "### build rc=$? $(date +%H:%M:%S)"
  ls -la "$KB/arch/x86/boot/bzImage"
  grep -E 'CONFIG_PAGE_MMUSHIFT|CONFIG_DEBUG_VM=|CONFIG_PAGE_OWNER=' "$KB/.config"
} >"$LOG" 2>&1
echo "### DONE — see $LOG"
