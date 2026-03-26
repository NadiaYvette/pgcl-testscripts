#!/bin/bash
#
# Create a minimal Fedora rootfs for PGCL kernel testing
#
# Usage: ./build-fedora-rootfs.sh [ROOTFS_DIR]
#   Default: /tmp/fedora-pgcl
#
# Requirements: dnf, qemu-system-x86_64
# Must run as root (for dnf --installroot)
#
set -e

ROOTFS="${1:-/tmp/fedora-pgcl}"
LINUX_SRC=/home/nyc/src/linux
RELEASEVER=43

log() { echo "=== $* ===" >&2; }
die() { echo "FATAL: $*" >&2; exit 1; }

# ---- Step 1: Create rootfs with dnf ----
create_rootfs() {
    if [ -f "$ROOTFS/bin/bash" ]; then
        log "Rootfs already exists at $ROOTFS"
        return 0
    fi

    log "Creating Fedora $RELEASEVER rootfs at $ROOTFS"
    mkdir -p "$ROOTFS"

    sudo dnf --installroot="$ROOTFS" \
        --releasever="$RELEASEVER" \
        --setopt=install_weak_deps=False \
        --assumeyes \
        install \
        @core \
        vim-minimal \
        less \
        strace \
        procps-ng \
        iproute \
        util-linux \
        gcc \
        make

    log "Rootfs created: $(du -sh "$ROOTFS" | cut -f1)"
}

# ---- Step 2: Configure rootfs ----
configure_rootfs() {
    log "Configuring rootfs"

    # Set hostname
    echo "pgcl-test" | sudo tee "$ROOTFS/etc/hostname" > /dev/null

    # Set root password to empty (for testing only)
    sudo sed -i 's|^root:[^:]*:|root::|' "$ROOTFS/etc/shadow" 2>/dev/null || true

    # Enable serial console
    sudo mkdir -p "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d"
    cat <<'EOF' | sudo tee "$ROOTFS/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf" > /dev/null
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
EOF

    # Set default target to multi-user (no GUI)
    sudo ln -sf /usr/lib/systemd/system/multi-user.target "$ROOTFS/etc/systemd/system/default.target" 2>/dev/null || true

    # Create a simple test script
    cat <<'TESTEOF' | sudo tee "$ROOTFS/root/pgcl-check.sh" > /dev/null
#!/bin/bash
echo "=== PGCL Kernel Check ==="
echo "Kernel:    $(uname -r)"
echo "Page size: $(getconf PAGESIZE)"
echo "Arch:      $(uname -m)"
echo "Memory:"
head -5 /proc/meminfo
echo ""
echo "=== Quick compile test ==="
cat > /tmp/hello.c << 'CEOF'
#include <stdio.h>
#include <unistd.h>
int main(void) {
    printf("Hello from PGCL kernel!\n");
    printf("Page size: %ld\n", sysconf(_SC_PAGESIZE));
    return 0;
}
CEOF
if gcc -o /tmp/hello /tmp/hello.c && /tmp/hello; then
    echo "Compile+run: PASS"
else
    echo "Compile+run: FAIL"
fi
TESTEOF
    sudo chmod +x "$ROOTFS/root/pgcl-check.sh"

    # fstab for 9p mount
    cat <<'EOF' | sudo tee "$ROOTFS/etc/fstab" > /dev/null
# PGCL test rootfs - 9p virtio mount
# (kernel passes root= on cmdline, this is for reference)
EOF

    log "Rootfs configured"
}

# ---- Step 3: Print boot command ----
print_boot_cmd() {
    local kernel="$LINUX_SRC/arch/x86/boot/bzImage"

    echo ""
    echo "========================================"
    echo "  Fedora PGCL Rootfs Ready"
    echo "========================================"
    echo ""
    echo "Rootfs: $ROOTFS"
    echo "Size:   $(du -sh "$ROOTFS" | cut -f1)"
    echo ""
    echo "Boot with:"
    echo ""
    echo "  sudo qemu-system-x86_64 \\"
    echo "    -kernel $kernel \\"
    echo "    -append \"root=fsRoot rootfstype=9p rootflags=trans=virtio,version=9p2000.L console=ttyS0 nokaslr nopti init=/lib/systemd/systemd\" \\"
    echo "    -fsdev local,id=fsRoot,path=$ROOTFS,security_model=passthrough \\"
    echo "    -device virtio-9p-pci,fsdev=fsRoot,mount_tag=fsRoot \\"
    echo "    -nographic -m 2G -smp 4 -no-reboot"
    echo ""
    echo "Then run: /root/pgcl-check.sh"
    echo ""
    echo "Quick boot (no systemd, just shell):"
    echo ""
    echo "  sudo qemu-system-x86_64 \\"
    echo "    -kernel $kernel \\"
    echo "    -append \"root=fsRoot rootfstype=9p rootflags=trans=virtio,version=9p2000.L console=ttyS0 nokaslr nopti init=/bin/bash\" \\"
    echo "    -fsdev local,id=fsRoot,path=$ROOTFS,security_model=passthrough \\"
    echo "    -device virtio-9p-pci,fsdev=fsRoot,mount_tag=fsRoot \\"
    echo "    -nographic -m 2G -smp 4 -no-reboot"
}

# ---- Main ----
main() {
    create_rootfs
    configure_rootfs
    print_boot_cmd
}

main
