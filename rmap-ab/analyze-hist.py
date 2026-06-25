#!/usr/bin/env python3
"""
analyze-hist.py - offline analysis of the QEMU #143 deep-history ring dump.

The QEMU side (PGCL_HISTGB=N) logs EVERY struct-page refcount/mapcount write
(both counts before the op + exact guest RIP + cpu) and every free/alloc event
into a big RAM ring, dumped to pgcl-hist.bin at exit.  This rewinds the symptom
(a premature free / corruption) to the causal operation OFFLINE -- no perturbing
online walk.

Entry (32 bytes, little-endian): seq(Q) rip(Q) frame(I) a(i) b(i) kind(B) cpu(B)
off(B) pad(B).  kind: 0=rc write 1=mc write 2=free 3=alloc 4=nonatomic.
For writes  a=refcount-before, b=mapcount-before.  For free/alloc a=4K count.

Usage:
  analyze-hist.py <pgcl-hist.bin> [vmlinux] [--cpfn 0xNNN] [--limit N]
Default: scan all frees for FREED-WHILE-MAPPED (last observed mapcount >= 0
before the free) and USE-AFTER-FREE (a write after a free with no alloc), then
print the offending clusters' full histories with resolved call sites.
"""
import sys, struct, bisect, subprocess

EREC = struct.Struct("<QQIiiBBBB")
KIND = {0: "rc", 1: "mc", 2: "FREE", 3: "alloc", 4: "nonatomic"}
MMUSHIFT = 4

def load(path, want=None):
    with open(path, "rb") as f:
        magic, head, n, esz = struct.unpack("<QQQQ", f.read(32))
        assert magic == 0x504743484953544c, "bad magic"
        assert esz == EREC.size, f"entry size {esz} != {EREC.size}"
        buf = f.read(n * esz)
    evs = []
    lo = max(1, head - n)        # valid seq window (seq 0 == unused slot)
    for i in range(n):
        seq, rip, frame, a, b, kind, cpu, off, _ = EREC.unpack_from(buf, i * esz)
        if seq == 0 or seq < lo or seq >= head:
            continue
        if want is not None:        # filter on read (memory-safe for huge dumps)
            if kind in (0, 1, 5):
                if frame != want:
                    continue
            elif kind in (2, 3):
                if not (frame <= want < frame + max(1, a >> MMUSHIFT)):
                    continue
        evs.append((seq, rip, frame, a, b, kind, cpu, off))
    evs.sort()
    return evs, head, n

def load_syms(vmlinux):
    if not vmlinux:
        return None, None
    out = subprocess.run(["nm", "-n", vmlinux], capture_output=True, text=True).stdout
    addrs, names = [], []
    for ln in out.splitlines():
        p = ln.split()
        if len(p) >= 3 and p[1] in "tT":
            try:
                addrs.append(int(p[0], 16)); names.append(p[2])
            except ValueError:
                pass
    return addrs, names

def sym(addrs, names, rip):
    if not addrs or not rip:
        return ""
    i = bisect.bisect_right(addrs, rip) - 1
    return names[i] if i >= 0 else "?"

def main():
    if len(sys.argv) < 2:
        print(__doc__); return
    path = sys.argv[1]
    vmlinux = None
    want_cpfn = None
    limit = 40
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == "--cpfn":
            want_cpfn = int(args[i + 1], 0); i += 2
        elif args[i] == "--limit":
            limit = int(args[i + 1]); i += 2
        else:
            vmlinux = args[i]; i += 1
    evs, head, n = load(path, want_cpfn)
    addrs, names = load_syms(vmlinux)
    print(f"loaded {len(evs)} valid events (head={head} ring={n}); "
          f"{'FULL run' if head <= n else f'last {n} of {head}'}"
          f"{f' [filtered cpfn=0x{want_cpfn:x}]' if want_cpfn is not None else ''}")

    # per-cpfn event index (kinds 0,1 writes; 2,3 free/alloc; 5 mapping snapshot)
    bycpfn = {}
    for e in evs:
        seq, rip, frame, a, b, kind, cpu, off = e
        if kind in (0, 1, 5):
            bycpfn.setdefault(frame, []).append(e)
        elif kind in (2, 3):       # free/alloc may span clusters
            ncl = max(1, a >> MMUSHIFT)
            for cf in range(frame, frame + ncl):
                bycpfn.setdefault(cf, []).append(e)

    def show(cpfn, lst, tag):
        print(f"\n=== cpfn=0x{cpfn:x}  {tag}  ({len(lst)} events) ===")
        for e in lst[-limit:] if limit else lst:
            seq, rip, frame, a, b, kind, cpu, off = e
            if kind in (0, 1):
                print(f"  seq={seq:<10} {KIND[kind]:9} rc={a:<4} mc={b:<4} "
                      f"cpu{cpu} @{rip:016x} {sym(addrs,names,rip)}")
            elif kind == 5:
                print(f"  seq={seq:<10} map       cr3=0x{a:x}000 va=0x{rip:x} "
                      f"sub={off} gen={b} cpu{cpu}")
            else:
                print(f"  seq={seq:<10} {KIND[kind]:9} count={a}")

    def orphans_for(cpfn, lst):
        frees = sorted(e[0] for e in lst if e[5] == 2)
        maps = {}
        for e in lst:
            if e[5] == 5:
                maps.setdefault((e[2], e[1]), []).append(e[0])
        out = []
        for (cr3, va), seqs in maps.items():
            seqs.sort()
            fb = bisect.bisect_left(frees, seqs[0])
            fe = bisect.bisect_right(frees, seqs[-1])
            for fs in frees[fb:fe]:
                if any(s < fs for s in seqs) and any(s > fs for s in seqs):
                    out.append((cr3, va, seqs[0], fs, seqs[-1], len(seqs)))
                    break
        return out

    if want_cpfn is not None:
        lst = bycpfn.get(want_cpfn, [])
        orph = orphans_for(want_cpfn, lst)
        print(f"\n*** ORPHAN/DANGLING PTEs on cpfn=0x{want_cpfn:x}: {len(orph)} "
              f"(mapping survives a FREE of the cpfn) ***")
        for cr3, va, s0, fs, s1, nobs in sorted(orph, key=lambda x: -x[5]):
            print(f"  cr3=0x{cr3:x}000 va=0x{va:x}: mapped seq{s0}..{s1} "
                  f"({nobs} obs) ACROSS free seq{fs}")
        show(want_cpfn, lst, "requested")
        return

    # scan: FREED-WHILE-MAPPED + USE-AFTER-FREE
    fwm, uaf = [], []
    for cpfn, lst in bycpfn.items():
        last_write = None
        freed_seq = None
        for e in lst:
            seq, rip, frame, a, b, kind, cpu, off = e
            if kind in (0, 1):
                # write after a free with no intervening alloc = use-after-free
                if freed_seq is not None:
                    uaf.append((cpfn, freed_seq, seq)); freed_seq = None
                last_write = e
            elif kind == 2:       # FREE
                # last observed mapcount before this free still mapped (>=0)?
                if last_write is not None and last_write[4] >= 0:
                    fwm.append((cpfn, last_write, seq))
                freed_seq = seq
            elif kind == 3:       # alloc clears the freed state
                freed_seq = None
                last_write = None

    # ORPHAN/DANGLING PTE: a (cr3,va)->cpfn mapping snapshot (kind 5) that is
    # observed both BEFORE and AFTER a FREE of that cpfn = a PTE the unmap left
    # behind (counts went to zero but the PTE survived) -> the #143 root cause.
    orphan = []
    for cpfn, lst in bycpfn.items():
        frees = sorted(e[0] for e in lst if e[5] == 2)
        if not frees:
            continue
        maps = {}                       # (cr3,va) -> sorted [seqs observed]
        for e in lst:
            if e[5] == 5:
                maps.setdefault((e[2], e[1]), []).append(e[0])
        for (cr3, va), seqs in maps.items():
            seqs.sort()
            # any free strictly between the first and last observation of this map?
            lo, hi = seqs[0], seqs[-1]
            fb = bisect.bisect_left(frees, lo)
            fe = bisect.bisect_right(frees, hi)
            if fe > fb and len(seqs) >= 2:
                # confirm an observation on BOTH sides of some free in (lo,hi)
                for fs in frees[fb:fe]:
                    if seqs[0] < fs < seqs[-1] and any(s < fs for s in seqs) \
                       and any(s > fs for s in seqs):
                        orphan.append((cpfn, cr3, va, seqs[0], fs, seqs[-1],
                                       len(seqs)))
                        break
    print(f"\n*** ORPHAN/DANGLING PTE candidates: {len(orphan)} "
          f"((cr3,va)->cpfn mapping survives a FREE of cpfn) ***")
    for cpfn, cr3, va, s0, fs, s1, nobs in sorted(orphan, key=lambda x: -x[6])[:30]:
        print(f"  cpfn=0x{cpfn:x} cr3=0x{cr3:x}000 va=0x{va:x}: mapped seq{s0}.."
              f"{s1} ({nobs} obs) ACROSS free seq{fs}")

    print(f"\n*** FREED-WHILE-MAPPED candidates: {len(fwm)} "
          f"(last logged mapcount >= 0 immediately before a free) ***")
    for cpfn, lw, fseq in sorted(fwm, key=lambda x: -x[1][0])[:20]:
        print(f"  cpfn=0x{cpfn:x}: last write seq={lw[0]} rc={lw[3]} mc={lw[4]} "
              f"@{lw[1]:016x} {sym(addrs,names,lw[1])}  -> FREE seq={fseq}")
    print(f"\n*** USE-AFTER-FREE candidates: {len(uaf)} "
          f"(rc/mc write after a free, no alloc) ***")
    for cpfn, fseq, wseq in sorted(uaf, key=lambda x: -x[2])[:20]:
        print(f"  cpfn=0x{cpfn:x}: FREE seq={fseq} then write seq={wseq}")

    # print full history of the most recent FWM cluster (the rewind)
    if fwm:
        c = sorted(fwm, key=lambda x: -x[1][0])[0][0]
        show(c, bycpfn[c], "TOP FREED-WHILE-MAPPED (full rewind)")

if __name__ == "__main__":
    main()
