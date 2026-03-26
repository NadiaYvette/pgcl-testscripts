#!/bin/bash
# Cross-compile test for all architectures with PAGE_MMUSHIFT=0
# Verifies Phase 1 core definitions compile cleanly everywhere

LINUX=/home/nyc/src/linux
LOGDIR=/home/nyc/src/pgcl/build-logs
mkdir -p "$LOGDIR"

# arch:cross_compile:defconfig
TARGETS=(
    "x86:x86_64_defconfig"
    "x86:i386_defconfig"
    "arm64:aarch64-linux-gnu-:defconfig"
    "arm:arm-linux-gnu-:multi_v7_defconfig"
    "riscv:riscv64-linux-gnu-:defconfig"
    "powerpc:powerpc64-linux-gnu-:ppc64_defconfig"
    "s390:s390x-linux-gnu-:defconfig"
    "mips:mips64-linux-gnu-:malta_defconfig"
    "sparc:sparc64-linux-gnu-:sparc64_defconfig"
    "alpha:alpha-linux-gnu-:defconfig"
    "m68k:m68k-linux-gnu-:defconfig"
    "parisc:hppa-linux-gnu-:generic-64bit_defconfig"
    "loongarch:loongarch64-linux-gnu-:defconfig"
    "openrisc:openrisc-linux-gnu-:simple_smp_defconfig"
    "microblaze:microblaze-linux-gnu-:defconfig"
    "xtensa:xtensa-linux-gnu-:defconfig"
    "sh:sh4-linux-gnu-:defconfig"
)

PASS=0
FAIL=0
SKIP=0

for target in "${TARGETS[@]}"; do
    IFS=: read -r arch cross defcfg <<< "$target"
    log="$LOGDIR/${arch}${cross:+-$(echo $cross | cut -d- -f1)}.log"

    echo -n "Building $arch ($defcfg)... "

    # Check if cross compiler exists
    if [ -n "$cross" ]; then
        if ! command -v "${cross}gcc" &>/dev/null; then
            echo "SKIP (no ${cross}gcc)"
            SKIP=$((SKIP+1))
            continue
        fi
    fi

    (
        cd "$LINUX"
        make ARCH=$arch ${cross:+CROSS_COMPILE=$cross} $defcfg 2>&1
        # Add PAGE_MMUSHIFT=0 if not present
        grep -q CONFIG_PAGE_MMUSHIFT .config || echo "CONFIG_PAGE_MMUSHIFT=0" >> .config
        make ARCH=$arch ${cross:+CROSS_COMPILE=$cross} olddefconfig 2>&1
        make ARCH=$arch ${cross:+CROSS_COMPILE=$cross} -j$(nproc) 2>&1
    ) > "$log" 2>&1

    if [ $? -eq 0 ]; then
        echo "OK"
        PASS=$((PASS+1))
    else
        echo "FAIL (see $log)"
        tail -20 "$log"
        echo "---"
        FAIL=$((FAIL+1))
    fi
done

echo
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped out of ${#TARGETS[@]} targets"
