#!/bin/bash
# Build all 16 architecture kernels with PAGE_MMUSHIFT=4
set -u
D=/home/nyc/src/pgcl
LOGDIR="$D/build-logs-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"

PASS=0
FAIL=0
SKIP=0

build() {
    local name="$1"; shift
    local log="$LOGDIR/$name.log"
    echo -n "[$name] Building... "
    if "$D/do-build.sh" "$@" > "$log" 2>&1; then
        echo "OK"
        PASS=$((PASS+1))
    else
        echo "FAIL"
        tail -5 "$log"
        FAIL=$((FAIL+1))
    fi
}

echo "=== Building all 16 arch kernels — $(date) ==="
echo ""

build x86_64      x86_64      x86       ""                        x86_64_defconfig
build aarch64     aarch64     arm64     aarch64-linux-gnu-        defconfig
build riscv64     riscv64     riscv     riscv64-linux-gnu-        defconfig
build s390x       s390x       s390      s390x-linux-gnu-          defconfig
build powerpc64   powerpc64   powerpc   powerpc64le-linux-gnu-    ppc64_defconfig
build sparc64     sparc64     sparc     sparc64-linux-gnu-        sparc64_defconfig
build alpha       alpha       alpha     alpha-linux-gnu-          defconfig
build loongarch64 loongarch64 loongarch loongarch64-linux-gnu-    defconfig
build riscv32     riscv32     riscv     riscv32-linux-gnu-        rv32_defconfig
build m68k        m68k        m68k      m68k-linux-gnu-           multi_defconfig
build hppa        hppa        parisc    hppa-linux-gnu-           generic-32bit_defconfig
build mips64      mips64      mips      mips64-linux-gnu-         malta_defconfig
build arm         arm         arm       arm-linux-gnu-            multi_v7_defconfig
build arm-lpae    arm-lpae    arm       arm-linux-gnu-            vexpress_defconfig
build hppa64      hppa64      parisc    hppa64-linux-gnu-         generic-64bit_defconfig
build microblaze  microblaze  microblaze microblaze-linux-gnu-    defconfig

echo ""
echo "=== Build Summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
echo "Logs in: $LOGDIR"
