#!/bin/bash
# Collect #143 evidence from a pgcl4 laptop boot. Read-only; safe to run on the
# pgcl4 kernel after it's up, OR on the stock kernel after a crash (reads the
# previous boot's journal + pstore). Bundles everything into a tarball + prints
# a verdict summary.
set -u
OUT=/home/nyc/src/pgcl/pgcl143-laptop-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
SIG='PGCL143wp|BUG: Bad page map|BUG: Bad page state|bad-rss-counter|Bad rss-counter|Attempted to kill init|general protection|mapcount|refcount|page_owner'

echo "=== collecting into $OUT ==="
# Kernel log: current boot and previous boot (the crashed one, if any).
journalctl -k -b  0 > "$OUT/kmsg-b0.txt"       2>/dev/null
journalctl -k -b -1 > "$OUT/kmsg-bprev.txt"    2>/dev/null
dmesg > "$OUT/dmesg.txt" 2>/dev/null
# pstore: panic / oops captured across reboot (efi-pstore or ramoops).
cp -a /sys/fs/pstore/* "$OUT/" 2>/dev/null
# Which kernel + cmdline this was.
uname -a > "$OUT/uname.txt" 2>/dev/null
cat /proc/cmdline > "$OUT/cmdline.txt" 2>/dev/null
free -g > "$OUT/free.txt" 2>/dev/null

echo "============ #143 VERDICT ============"
for f in "$OUT/kmsg-b0.txt" "$OUT/kmsg-bprev.txt" "$OUT"/dmesg-* "$OUT"/*-[0-9]*; do
  [ -f "$f" ] || continue
  wp=$(grep -acE 'PGCL143wp' "$f" 2>/dev/null)
  wpmax=$(grep -aoE 'PGCL143wp #[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
  badmap=$(grep -acE 'BUG: Bad page map' "$f" 2>/dev/null)
  badpage=$(grep -acE 'BUG: Bad page state' "$f" 2>/dev/null)
  rss=$(grep -acE 'Bad rss-counter|bad-rss-counter' "$f" 2>/dev/null)
  ki=$(grep -acE 'Attempted to kill init' "$f" 2>/dev/null)
  [ $((wp+badmap+badpage+rss+ki)) -eq 0 ] && continue
  echo "$(basename "$f"): wp=$wp (max #${wpmax:-0}) badmap=$badmap badpage=$badpage rss=$rss killinit=$ki"
done
echo "  reached graphical/login this boot? $(systemctl is-active graphical.target multi-user.target 2>/dev/null | paste -sd, )"
echo
echo "=== first PGCL143wp / Bad page map detail (if any) ==="
grep -ahA20 -m1 'PGCL143wp #1\|BUG: Bad page map' "$OUT/kmsg-b0.txt" "$OUT/kmsg-bprev.txt" 2>/dev/null | head -40
echo
tar czf "$OUT.tar.gz" -C "$(dirname "$OUT")" "$(basename "$OUT")" 2>/dev/null
echo "=== bundled: $OUT.tar.gz  (send this) ==="
echo "Quick read: wp=0 + badmap=0 + reached graphical => pgcl4 USABLE on the laptop."
echo "            wp>0 with no panic => hitting the underflow but surviving (near-miss; #N = count)."
echo "            killinit / pstore panic => reproduced #143; the dump_page + dump_stack name it."
