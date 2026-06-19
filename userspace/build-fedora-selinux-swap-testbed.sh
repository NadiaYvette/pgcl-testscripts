#!/bin/bash
# build-fedora-selinux-swap-testbed.sh  — RUN AS ROOT (sudo).
#
# Builds a Fedora-43 ext4 *disk image* + a swap disk to reproduce the laptop
# pgcl4 userspace class in QEMU (fast iteration, no laptop reboots):
#   #138 selinuxfs status-page mmap EIO  (SELinux enabled -> dbus mmaps it)
#   #139 swap-space signature mismatch   (mkswap MMUPAGE header vs kernel PAGE)
#
# The pgcl4 kernel has VIRTIO_BLK + EXT4_FS(+SECURITY) built in, so the image
# boots with no initramfs/modules.  SELinux runs permissive (the status-page
# mmap fires regardless of enforcing/labels; permissive avoids unlabeled-fs
# breakage).  Swap is a plain /dev/vdb the guest mkswaps (zram is a module;
# the signature bug is device-agnostic).
#
# Output (chowned to nyc so QEMU runs non-root):
#   /home/nyc/src/pgcl/pgcl4-testbed/{rootfs.ext4,swap.raw}
set -eu

OUT=/home/nyc/src/pgcl/pgcl4-testbed
ROOTFS=$OUT/rootfs-dir   # on disk, not /tmp (tmpfs size); stays root-owned for mkfs -d
IMG=$OUT/rootfs.ext4
SWAP=$OUT/swap.raw
REL=43
OWNER=nyc
mkdir -p "$OUT"

# ---- 1) rootfs via dnf (the expensive, network step) ----
if [ ! -x "$ROOTFS/usr/bin/systemctl" ]; then
    echo "=== dnf --installroot $ROOTFS (Fedora $REL) ==="
    dnf --installroot="$ROOTFS" --releasever="$REL" --use-host-config \
        --setopt=install_weak_deps=False --assumeyes \
        --exclude=kernel --exclude=kernel-core \
        --exclude=kernel-modules --exclude=kernel-modules-core --exclude=kernel-modules-extra \
        install \
        @core selinux-policy-targeted policycoreutils libselinux-utils \
        dbus-broker util-linux procps-ng strace less vim-minimal gcc
else
    echo "=== rootfs already present at $ROOTFS (skip dnf) ==="
fi

# ---- 2) configure ----
echo "=== configure rootfs ==="
echo pgcl-sel > "$ROOTFS/etc/hostname"
sed -i 's|^root:[^:]*:|root::|' "$ROOTFS/etc/shadow" 2>/dev/null || true
# serial console autologin
d="$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d"; mkdir -p "$d"
printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin root --noclear %%I 115200 linux\n' \
    > "$d/override.conf"
ln -sf /usr/lib/systemd/system/multi-user.target "$ROOTFS/etc/systemd/system/default.target"
# SELinux enabled but permissive
[ -f "$ROOTFS/etc/selinux/config" ] && sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$ROOTFS/etc/selinux/config"

# swap test: mkswap + swapon /dev/vdb at boot (reproduces #139)
cat > "$ROOTFS/etc/systemd/system/pgcl-swaptest.service" <<'EOF'
[Unit]
Description=PGCL swap test (mkswap+swapon /dev/vdb)
DefaultDependencies=no
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'mkswap /dev/vdb; echo PGCL-SWAP-mkswap=$?; swapon /dev/vdb; echo PGCL-SWAP-swapon=$?'
[Install]
WantedBy=multi-user.target
EOF
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sf ../pgcl-swaptest.service "$ROOTFS/etc/systemd/system/multi-user.target.wants/pgcl-swaptest.service"

# autotest: on autologin, run the selinux-status-page mmap probe + swap report,
# dump the relevant journal, then power off so QEMU exits with the transcript.
cat > "$ROOTFS/root/.bash_profile" <<'EOF'
echo "===== PGCL TESTBED: login reached ====="
echo "kernel=$(uname -r) page=$(getconf PAGESIZE) selinux=$(getenforce 2>/dev/null)"
cat > /tmp/sst.c <<'CEOF'
#include <stdio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
int main(void){
    int fd=open("/sys/fs/selinux/status",O_RDONLY);
    if(fd<0){perror("open status");return 1;}
    void*p=mmap(0,sysconf(_SC_PAGESIZE),PROT_READ,MAP_SHARED,fd,0);
    if(p==MAP_FAILED){perror("mmap status");return 2;}
    printf("STATUS-PAGE-MMAP-OK seq=%u\n",*(volatile unsigned*)p);
    return 0;
}
CEOF
gcc -o /tmp/sst /tmp/sst.c 2>/tmp/sst.err && /tmp/sst; echo "sst-rc=$?"; cat /tmp/sst.err 2>/dev/null
echo "--- swap ---"; swapon --show 2>/dev/null; cat /proc/swaps
echo "--- journal: selinux/dbus/swap ---"
journalctl -b --no-pager 2>/dev/null | grep -iE 'selinux status|status page|dbus-broker.*(selinux|fatal)|Unable to find swap|swap-space|zram' | head -20
echo "===== PGCL TESTBED: done, powering off ====="
sync; systemctl poweroff -i
EOF

# ---- 3) build ext4 image from the dir (no mount; root preserves owners) ----
echo "=== build $IMG ==="
SZ=$(du -sm "$ROOTFS" | cut -f1); SZ=$((SZ*2 + 1024))   # MB: 2x + 1G slack
rm -f "$IMG"; truncate -s "${SZ}M" "$IMG"
mkfs.ext4 -F -q -L pgclroot -b 4096 -d "$ROOTFS" "$IMG"

# ---- 4) swap disk (unformatted; guest mkswaps it) ----
rm -f "$SWAP"; truncate -s 1G "$SWAP"

# ---- 5) hand image+swap to nyc so QEMU runs without sudo ----
# (NOT the rootfs-dir: it must stay root-owned so a re-run's mkfs -d keeps
#  correct guest ownership)
chown "$OWNER":"$OWNER" "$IMG" "$SWAP"
echo "=== TESTBED READY ==="
echo "  image: $IMG ($(du -h "$IMG"|cut -f1))   swap: $SWAP (1G)"
echo "  boot (non-root):"
echo "    qemu-system-x86_64 -enable-kvm -m 4G -smp 4 -nographic -no-reboot \\"
echo "      -kernel /home/nyc/src/pgcl/kernel-rpm-build/pgcl4-debug/arch/x86/boot/bzImage \\"
echo "      -drive file=$IMG,format=raw,if=virtio -drive file=$SWAP,format=raw,if=virtio \\"
echo "      -append 'root=/dev/vda rw rootfstype=ext4 console=ttyS0 nokaslr selinux=1 enforcing=0'"
