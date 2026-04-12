#!/bin/bash
set -e

LTP_SRC="$HOME/src/ltp"
SYSROOT="$HOME/src/pgcl/userspace/sysroot/hppa64"
OUTDIR="$HOME/src/pgcl/userspace/build/ltp-hppa64"
LIBTMP="/tmp/ltp-lib-hppa64"
CC="hppa64-linux-gnu-gcc"
LD="/tmp/binutils-hppa64/bin/hppa64-linux-gnu-ld"
STRIP="hppa64-linux-gnu-strip"
LIBGCC=$(hppa64-linux-gnu-gcc -print-file-name=libgcc.a)
STUBS="/tmp/hppa64-glibc-stubs.o"

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

    if ! $LD -static --defsym '$global$=0' --allow-multiple-definition \
        -o "$OUTDIR/$name" \
        "$STUBS" "$obj" "$LIBTMP/libltp.a" \
        -L"$SYSROOT/lib" -lc -lpthread -lc "$LIBGCC" -lc 2>/dev/null; then
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
