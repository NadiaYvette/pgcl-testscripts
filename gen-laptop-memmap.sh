#!/bin/bash
# Emit a `memmap=exactmap ...` kernel cmdline that replays THIS laptop's real
# e820 (read live from /sys/firmware/memmap) so a QEMU guest sees the same
# fragmented memory map (holes + reserved interleaving + the lone 4KB RAM
# sliver) that trips the #106 corrupt-free-page bug. The clean QEMU map never
# reproduces it; this is the whole point.
#
# Usage:
#   gen-laptop-memmap.sh           # FULL faithful replay (needs QEMU -m >=64G)
#   gen-laptop-memmap.sh <HIGHGB>  # truncate the top System-RAM region to HIGHGB
#                                  # gigabytes (keeps ALL sub-4G geometry intact,
#                                  # so QEMU RAM = ~3G + HIGHGB). e.g. `2`.
#
# memmap= type letters: @=usable RAM, $=reserved, #=ACPI data. ACPI NVS and
# any other non-RAM type map to $ (all "not usable RAM", which is what the
# memmap-init/handover code keys on). e820 GAPS (addr ranges in no entry) are
# emitted as nothing -> the kernel treats them as true holes
# (init_unavailable_range), exactly as on the laptop.
set -u
MM=/sys/firmware/memmap
HIGHGB="${1:-0}"   # 0 = no truncation (full map)

out="memmap=exactmap"
# iterate entries in numeric order
for d in $(ls "$MM" | sort -n); do
  s=$(cat "$MM/$d/start"); e=$(cat "$MM/$d/end"); t=$(cat "$MM/$d/type")
  size=$(( e - s + 1 ))
  case "$t" in
    "System RAM")  letter='@' ;;
    "ACPI Tables") letter='#' ;;
    *)             letter='$' ;;   # Reserved, ACPI NVS, anything non-RAM
  esac
  # Truncate the big high RAM region (start >= 4G) if asked.
  if [ "$HIGHGB" != 0 ] && [ "$letter" = '@' ] && [ "$((s))" -ge "$((0x100000000))" ]; then
    size=$(( HIGHGB * 1024 * 1024 * 1024 ))
  fi
  out="$out memmap=$(printf '0x%x' "$size")$letter$(printf '0x%x' "$s")"
done
echo "$out"
