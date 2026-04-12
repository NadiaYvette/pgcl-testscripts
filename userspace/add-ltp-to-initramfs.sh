#!/bin/bash
# Add LTP binaries to an existing initramfs
# Usage: ./add-ltp-to-initramfs.sh <arch> [ltp-arch]
# Example: ./add-ltp-to-initramfs.sh x86_64
#          ./add-ltp-to-initramfs.sh aarch64

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ARCH="${1:?Usage: $0 <arch> [ltp-arch]}"
LTP_ARCH="${2:-$ARCH}"

INITRAMFS="$SCRIPT_DIR/initramfs/initramfs-${ARCH}.cpio.gz"
LTP_DIR="$SCRIPT_DIR/build/ltp-${LTP_ARCH}"
INIT_SCRIPT="$SCRIPT_DIR/initramfs/init"
WORKDIR="/tmp/initramfs-${ARCH}-ltp"

if [ ! -f "$INITRAMFS" ]; then
    echo "ERROR: initramfs not found: $INITRAMFS"
    exit 1
fi

if [ ! -d "$LTP_DIR" ]; then
    echo "ERROR: LTP binaries not found: $LTP_DIR"
    echo "Run: ./build-ltp.sh $LTP_ARCH"
    exit 1
fi

echo "=== Adding LTP to $ARCH initramfs ==="
echo "  Source: $LTP_DIR ($(ls "$LTP_DIR" | wc -l) binaries)"

# Extract existing initramfs
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
zcat "$INITRAMFS" | cpio -idm 2>/dev/null

# Add LTP binaries
mkdir -p bin/ltp
cp "$LTP_DIR"/* bin/ltp/
echo "  Added $(ls bin/ltp/ | wc -l) LTP binaries"

# Add extra busybox symlinks needed by LTP
for cmd in sed id awk tr cut dd kill stat setsid nice nohup readlink \
           sort uniq tee touch rm cp mv mktemp seq expr env dirname \
           xargs yes chmod chown diff od hexdump; do
    [ ! -e bin/$cmd ] && [ -e bin/busybox ] && ln -s busybox bin/$cmd 2>/dev/null || true
done
mkdir -p sbin
for cmd in sysctl losetup; do
    [ ! -e sbin/$cmd ] && [ -e bin/busybox ] && ln -s ../bin/busybox sbin/$cmd 2>/dev/null || true
done

# Add passwd/group for uid checks
mkdir -p etc root tmp var/tmp
echo "root:x:0:0:root:/root:/bin/sh" > etc/passwd
echo "root:x:0:" > etc/group

# Update init script
cp "$INIT_SCRIPT" ./init

# Rebuild
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$INITRAMFS"
local_size=$(ls -lh "$INITRAMFS" | awk '{print $5}')
echo "  Rebuilt: $INITRAMFS ($local_size)"

# Cleanup
rm -rf "$WORKDIR"
echo "=== Done ==="
