#!/bin/bash
set -e

LTP_SRC="$HOME/src/ltp"
SYSROOT="$HOME/src/pgcl/userspace/sysroot/hppa64"
OUTDIR="$HOME/src/pgcl/userspace/build/ltp-hppa64"
LIBTMP="/tmp/ltp-lib-hppa64"
CC="hppa64-linux-gnu-gcc"
LD="$HOME/src/pgcl/tmp/hppa64-toolchain/bin/hppa64-linux-gnu-ld"
STRIP="hppa64-linux-gnu-strip"
LIBGCC=$(hppa64-linux-gnu-gcc -print-file-name=libgcc.a)
STUBS_SRC="$HOME/src/pgcl/userspace/hppa64-glibc-stubs.c"
STUBS="/tmp/hppa64-glibc-stubs.o"

# CRT files from glibc sysroot (provides _start with proper dp initialization)
CRT1="$SYSROOT/lib/crt1.o"
CRTI="$SYSROOT/lib/crti.o"
CRTN="$SYSROOT/lib/crtn.o"

# Build stubs if missing or source changed
if [ ! -f "$STUBS" ] || [ "$STUBS_SRC" -nt "$STUBS" ]; then
    echo "Building glibc stubs..."
    $CC -c -O2 -w "$STUBS_SRC" -o "$STUBS"
fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

built=0
failed=0
fail_list=""

compile_and_link() {
    local src="$1"
    local name="$(basename "${src%.c}")"
    local obj="/tmp/ltp-hppa64-$name.o"

    # Try default, then gnu89 fallback
    if ! $CC -c -O2 -w -D_GNU_SOURCE \
        -Wno-incompatible-pointer-types -Wno-int-conversion \
        -isystem "$SYSROOT/include" --sysroot="$SYSROOT" \
        -I"$LTP_SRC/include" -I"$LTP_SRC/include/old" \
        -o "$obj" "$src" 2>/dev/null; then
        if ! $CC -c -O2 -w -D_GNU_SOURCE -std=gnu89 \
            -Wno-incompatible-pointer-types -Wno-int-conversion \
            -isystem "$SYSROOT/include" --sysroot="$SYSROOT" \
            -I"$LTP_SRC/include" -I"$LTP_SRC/include/old" \
            -o "$obj" "$src" 2>/dev/null; then
            failed=$((failed+1))
            fail_list="$fail_list $name"
            rm -f "$obj"
            return 1
        fi
    fi

    # Link with crt1.o (provides _start + dp init) and define $global$=__gp
    if ! $LD -static --allow-multiple-definition \
        -e _start \
        --defsym '$global$=__gp' \
        -o "$OUTDIR/$name" \
        "$CRT1" "$CRTI" \
        "$STUBS" "$obj" "$LIBTMP/libltp.a" \
        -L"$SYSROOT/lib" -lc -lpthread -lc "$LIBGCC" -lc \
        "$CRTN" 2>/dev/null ||
       [ ! -f "$OUTDIR/$name" ]; then
        failed=$((failed+1))
        fail_list="$fail_list $name"
        rm -f "$obj"
        return 1
    fi

    built=$((built+1))
    rm -f "$obj"
    return 0
}

for dir in brk fork madvise mlock mlock2 mlockall munlock munlockall mmap mremap mprotect msync munmap sbrk shmat mincore; do
    srcdir="$LTP_SRC/testcases/kernel/syscalls/$dir"
    [ -d "$srcdir" ] || continue
    for src in "$srcdir"/*.c; do
        [ -f "$src" ] || continue
        compile_and_link "$src" || true
    done
done

for dir in mmapstress vma; do
    srcdir="$LTP_SRC/testcases/kernel/mem/$dir"
    [ -d "$srcdir" ] || continue
    for src in "$srcdir"/*.c; do
        [ -f "$src" ] || continue
        compile_and_link "$src" || true
    done
done

# Strip PT_INTERP (hppa64 glibc always adds it even for static) and debug symbols
for f in "$OUTDIR"/*; do
    python3 /tmp/strip-interp.py "$f" 2>/dev/null
done
$STRIP "$OUTDIR"/* 2>/dev/null || true

echo ""
echo "=== Results ==="
echo "  Built: $built"
echo "  Failed: $failed"
if [ -n "$fail_list" ]; then
    echo "  Failed:$fail_list"
fi
count=$(ls "$OUTDIR" 2>/dev/null | wc -l)
size=$(du -sh "$OUTDIR" 2>/dev/null | cut -f1)
echo "  Total: $count binaries ($size)"
echo "  Output: $OUTDIR"
