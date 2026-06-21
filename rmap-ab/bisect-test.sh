#!/bin/bash
# git-bisect-run test for #143 pgcl4 order-0 rmap-underflow race.
# Operates on whatever commit is checked out in /home/nyc/src/linux.
# exit 0 = GOOD (booted clean N times), 1 = BAD (corruption), 125 = SKIP (no build / no boot).
# Builds + boots isolated on cores 14-19 (pgcl.slice). -snapshot => ephemeral disk writes
# (no rootfs/btrfs degradation across runs). Native DEBUG_VM signal => no probe needed.
set -u
LX=/home/nyc/src/linux
D=/home/nyc/src/pgcl
OBJ="$D/kernel-rpm-build/pgcl4-debug"
N="${BISECT_N:-4}"
cd "$LX" || exit 125
H=$(git rev-parse --short HEAD)

# Force pgcl4 + KCSAN off at every checkout (old commits may lack/添 options).
scripts/config --file "$OBJ/.config" --set-val PAGE_MMUSHIFT 4 -d KCSAN -d KCSAN_EARLY_ENABLE >/dev/null 2>&1
bash "$D/rmap-ab/iso" make O="$OBJ" olddefconfig >/tmp/bisect-cfg.log 2>&1

if ! bash "$D/rmap-ab/iso" make O="$OBJ" -j10 bzImage >/tmp/bisect-build.log 2>&1; then
	echo "SKIP(build) $H"; exit 125
fi
cp "$OBJ/arch/x86/boot/bzImage" /tmp/bisect-bz 2>/dev/null || { echo "SKIP(nobz) $H"; exit 125; }

booted=0; bad=0; sig=""
for r in $(seq 1 "$N"); do
	L=/tmp/bisect-run-$r.log
	bash "$D/rmap-ab/iso" timeout 165 qemu-system-x86_64 -enable-kvm -cpu host -smp 8 -m 3G \
		-kernel /tmp/bisect-bz \
		-append "root=/dev/vda rw rootfstype=ext4 console=ttyS0 nokaslr selinux=1 enforcing=0" \
		-snapshot \
		-drive file="$D/pgcl4-testbed/rootfs.ext4",format=raw,if=virtio \
		-drive file="$D/pgcl4-testbed/swap.raw",format=raw,if=virtio \
		-drive file="$D/rmap-ab/btrfs.img",format=raw,if=virtio \
		-nographic -no-reboot >"$L" 2>&1
	grep -aq 'login:' "$L" && booted=1
	if grep -aqE 'Bad page map|Bad rss-counter|refcount:-[0-9]|kernel BUG at|VM_BUG_ON_FOLIO' "$L"; then
		bad=1; sig=$(grep -aoE 'Bad page map|Bad rss-counter|refcount:-[0-9]|kernel BUG at[^!]*|VM_BUG_ON_FOLIO' "$L" | head -1); break
	fi
done

if [ "$booted" = 0 ]; then echo "SKIP(noboot) $H"; exit 125; fi
if [ "$bad" = 1 ]; then echo "BAD $H  [$sig]"; exit 1; fi
echo "GOOD $H (clean x$N)"; exit 0
