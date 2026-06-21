#!/bin/bash
# #143 wp_page_copy attribution diagnostic.  Build on 12-19/-j8, QEMU on 16-19
# (via iso), oracle config (-smp 8).  Per-CPU publish of the wp_page_copy
# old_folio pfn (tag W); when an order-0 remove underflows we report whether a
# concurrent wp_page_copy on the SAME pfn was in flight on another CPU.
# CONCURRENT tag=W  => #2 (cross-mm wp_page_copy skew) CONFIRMED.
# no concurrent publisher => wp_page_copy not the concurrent party; expand to U/Z.
set -u
SRC=/home/nyc/src/linux
O=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug
D=/home/nyc/src/pgcl/rmap-ab
BZ=$D/bzImage-wpdiag

echo "=== BUILD start $(date +%H:%M:%S) ==="
taskset -c 12-19 make -C "$SRC" O="$O" -j8 bzImage 2>&1 | tail -3
rc=${PIPESTATUS[0]}
echo "BUILD-EXIT rc=$rc $(date +%H:%M:%S)"
[ "$rc" = 0 ] || { echo "BUILD FAILED"; exit 1; }
cp "$O/arch/x86/boot/bzImage" "$BZ"
echo "staged $(basename "$BZ") $(stat -c %s "$BZ")"

for r in 1 2 3 4 5 6 7 8; do
  bash "$D/run-rr.sh" "$BZ" "$D/wpdiag-$r.log" 220 8 >/dev/null 2>&1
  L=$D/wpdiag-$r.log
  uf=$(grep -ac 'PGCL#143wp: order-0 UNDERFLOW' "$L")
  cw=$(grep -ac 'PGCL#143wp:.*CONCURRENT tag=W' "$L")
  np=$(grep -ac 'PGCL#143wp:.*no concurrent publisher' "$L")
  echo "run$r: underflow=$uf CONCURRENT_W=$cw no_publisher=$np | login=$(grep -ac 'login:' "$L") panic=$(grep -ac 'Kernel panic' "$L") badpage=$(grep -ac 'Bad page' "$L")"
done
echo "=== wpdiag done $(date +%H:%M:%S) ==="
