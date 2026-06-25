#!/bin/bash
set -u
P=/home/nyc/src/pgcl; D=$P/rmap-ab; ST=$D/abl-initramfs/stage; A=$D/abl-initramfs
Q=$P/../qemu/build/qemu-system-x86_64; QB=/home/nyc/src/qemu/build
echo "=== rebuild qemu (dangle v3: pgd-set + full scan) $(date +%T) ==="
taskset -c 12-19 ninja -C "$QB" qemu-system-x86_64 > $P/qemu-danglev3-build.log 2>&1
rc=$?; if [ "$rc" != 0 ]; then echo "QEMU-BUILD-FAIL rc=$rc"; tail -25 $P/qemu-danglev3-build.log; exit 1; fi
echo "qemu built $(date +%T)"
echo "=== restore proven trigger (abl repro) into initramfs ==="
gcc -O2 -static -o "$ST/repro" "$P/userspace/file_reclaim_race_repro_abl.c" || exit 1
cp "$ST/repro" "$A/repro"
( cd "$ST" && find . | cpio -o -H newc 2>/dev/null | gzip > "$A/initramfs.cpio.gz" )
run() {  # $1=tag $2=bzImage
    local tag=$1
    local bz=$2
    local L=$D/dv3-$tag.log
    PGCL_DANGLE=1 bash "$D/iso" timeout 360 "$QB/qemu-system-x86_64" -accel tcg,thread=multi \
        -cpu max,la57=off -smp 8 -m 2G -kernel "$bz" \
        -initrd "$A/initramfs.cpio.gz" -append "console=ttyS0 nokaslr ignore_loglevel panic=1" \
        -drive file="$D/btrfs.img",format=raw,if=virtio \
        -drive file="$P/pgcl4-testbed/swap.raw",format=raw,if=virtio \
        -nographic -no-reboot > "$L" 2>&1
    echo "$tag: dangle=$(grep -ac 'FREE-WHILE-MAPPED' "$L") active=$(grep -ac 'dangling-PTE probe v2 ACTIVE' "$L") killinit=$(grep -ac 'kill init' "$L") npgd=$(grep -aoE 'npgd=[0-9]+' "$L" | tail -1)"
}
echo "=== pgcl4 (expect dangle hits if premature-free is real) ==="
for r in a b c d e f; do run p4$r "$D/bzImage-vandangle"; done
echo "=== pgcl0 control (expect 0 dangle) ==="
run p0a "$D/bzImage-pgcl0ctl"
echo "=== sample dangle hits (pgcl4) ==="
grep -ah 'FREE-WHILE-MAPPED' dv3-p4*.log 2>/dev/null | head -8
echo "=== danglepath (who frees the still-mapped page) resolved ==="
VM=/home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug/vmlinux
grep -ahA40 'PGCL143danglepath' dv3-p4*.log 2>/dev/null | grep -aoE 'ffffffff8[0-9a-f]{6,}' | sort -u | while read a; do printf "%s  " "$a"; addr2line -f -e "$VM" "$a" 2>/dev/null | tr "\n" " "; echo; done | grep -viE "\?\?:|lapic|hrtimer" | head -40
