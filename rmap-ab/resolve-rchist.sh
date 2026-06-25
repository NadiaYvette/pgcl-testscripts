#!/bin/bash
# resolve-rchist.sh — turn the PGCL143rchist write-history dump into named call
# sites.  Extracts every full kernel RIP (@ffffffff8xxxxxxx) from the log, batch-
# resolves them in ONE addr2line call against the DEBUG_INFO vmlinux (per-address
# is far too slow on the 81MB DWARF), and prints a rip->func:line table plus the
# annotated histories.  Guards the empty-address case (addr2line with no args
# reads stdin and hangs).
set -eu
LOG="${1:-rch-p4a.log}"
VM="${2:-/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-dbginfo/vmlinux}"
SCR=/tmp/claude-1000/-home-nyc-src-pgcl/443a8d37-2901-482f-b7cd-76625947368f/scratchpad

[ -r "$LOG" ] || { echo "no log: $LOG" >&2; exit 1; }
[ -r "$VM" ]  || { echo "no vmlinux: $VM" >&2; exit 1; }

grep -ao '@ffffffff8[0-9a-f]\{6,\}' "$LOG" | sed 's/@//' | sort -u > "$SCR/rips.txt"
n=$(wc -l < "$SCR/rips.txt")
echo "distinct full RIPs: $n"
[ "$n" -gt 0 ] || { echo "(no full RIPs — still truncated/page-offset only)"; exit 0; }

# batched resolve: addr2line -f -i (inline frames) -> pair func/loc lines
addr2line -f -e "$VM" $(cat "$SCR/rips.txt") | paste -d'\t' - - > "$SCR/rips.res"
paste "$SCR/rips.txt" "$SCR/rips.res" | sed 's#/home/nyc/src/linux/##' | sort -t$'\t' -k2
