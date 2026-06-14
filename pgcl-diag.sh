#!/bin/sh
# PGCL emergency-boot diagnostic.
# Run from an emergency.target shell on a stuck pgcl kernel:
#     mount /boot && sh /boot/pgcl-diag.sh
# Writes results to /boot/pgcl-diag-out.txt (ext4, survives reboot — no camera needed).
set +e
mount -o remount,rw / 2>/dev/null
mount /boot 2>/dev/null            # ext4 on nvme0n1p5, separate from the hung btrfs p6
OUT=/boot/pgcl-diag-out.txt
{
  echo "==== PGCL emergency diag: $(uname -r)  ===="
  uptime 2>&1

  echo "---- [DISCRIMINATOR] direct NVMe write test to /boot ext4 (timeout 15s) ----"
  echo "   completes fast => NVMe I/O is alive, stall is btrfs-readiness-specific"
  echo "   hangs/timeout  => controller-wide I/O black hole (NVMe/IRQ)"
  timeout 15 dd if=/dev/zero of=/boot/pgcl-iotest bs=1M count=20 oflag=direct 2>&1
  echo "dd rc=$?"; rm -f /boot/pgcl-iotest 2>/dev/null

  echo "---- D-state (uninterruptible-I/O) processes ----"
  ps -eo stat,pid,comm 2>/dev/null | awk 'NR==1 || $1 ~ /^D/'

  echo "---- btrfs device ready (direct ioctl, no udevd needed) ----"
  btrfs device ready /dev/nvme0n1p6 2>&1; echo "btrfs-ready rc=$?  (rc!=0 => kernel says NOT all devices present)"

  echo "---- btrfs filesystem show ----"
  btrfs filesystem show 2>&1

  echo "---- try to bring up udevd + query device tag ----"
  systemctl start systemd-udevd 2>/dev/null || /usr/lib/systemd/systemd-udevd --daemon 2>/dev/null
  udevadm trigger --settle --action=add /dev/nvme0n1p6 2>/dev/null
  sleep 2
  udevadm info /dev/nvme0n1p6 2>&1 | grep -iE 'SYSTEMD_READY|ID_BTRFS_READY|ID_FS_TYPE|ID_FS_UUID'

  echo "---- systemd stuck jobs ----"
  systemctl list-jobs --no-pager 2>&1 | head -40

  echo "---- /proc/mounts (what actually mounted) ----"
  grep -iE 'btrfs| / |/home|/boot|nvme' /proc/mounts 2>&1

  echo "---- dmesg: nvme/btrfs/timeout/hung/error ----"
  dmesg 2>&1 | grep -iE 'nvme|btrfs|timeout|hung task|blocked for|I/O error|call trace|MISSING' | tail -70

  echo "==== END ===="
} > "$OUT" 2>&1
sync
echo
echo ">>> wrote $OUT"
echo ">>> now: reboot   (pick the good 6.18 kernel)"
