#!/bin/bash
# Create a minimal initramfs for QEMU boot testing
set -e

INITDIR=/tmp/initramfs-pgcl
rm -rf "$INITDIR"
mkdir -p "$INITDIR"/{bin,sbin,proc,sys,dev,tmp,etc}

# Use busybox if available, otherwise create a minimal init
if command -v busybox &>/dev/null; then
    cp "$(command -v busybox)" "$INITDIR/bin/busybox"
    # Create essential symlinks
    for cmd in sh ash ls cat echo mount mkdir mknod grep sleep; do
        ln -sf busybox "$INITDIR/bin/$cmd"
    done
else
    echo "WARNING: busybox not found, creating minimal init only"
fi

# Create init script
cat > "$INITDIR/init" << 'INITEOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo "========================================"
echo " Page Clustering Boot Test"
echo "========================================"
echo ""

# Show page size info
if [ -f /proc/version ]; then
    echo "Kernel: $(cat /proc/version)"
fi
echo ""

# Show memory info
if [ -f /proc/meminfo ]; then
    echo "MemTotal:  $(grep MemTotal /proc/meminfo | awk '{print $2, $3}')"
    echo "MemFree:   $(grep MemFree /proc/meminfo | awk '{print $2, $3}')"
fi
echo ""

# Try to show page size via getconf
if command -v getconf >/dev/null 2>&1; then
    echo "getconf PAGESIZE: $(getconf PAGESIZE)"
fi
echo ""

echo "Boot successful!"
echo ""

# Drop to shell if available
if [ -x /bin/sh ]; then
    echo "Dropping to shell. Type 'poweroff -f' to exit."
    exec /bin/sh
else
    echo "No shell available. Halting."
    sleep 5
fi
INITEOF
chmod +x "$INITDIR/init"

# Create the cpio archive
cd "$INITDIR"
find . | cpio -o -H newc 2>/dev/null | gzip > /tmp/initramfs-pgcl.cpio.gz

echo "Created /tmp/initramfs-pgcl.cpio.gz ($(du -h /tmp/initramfs-pgcl.cpio.gz | cut -f1))"
