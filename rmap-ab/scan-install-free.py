#!/usr/bin/env python3
"""
scan-install-free.py <pgcl-hist.bin> [vmlinux] - the #143 smoking-gun detector.

Replays the deep-history ring's free(kind2)/alloc(kind3)/install(kind9) events as
a per-cluster state machine.  A present-USER-PTE install (set_ptes, leaf
0x51430006) that lands while the cluster is in the FREE state = a PTE pointing at
a free page = the dangling/wrong-page bug that causes #143.  Buckets the offending
installs by caller RIP (kind9 rip = _RET_IP_ of set_ptes = the install path) and
resolves them via `nm -n` so the dominant code path is named.
"""
import sys, struct, bisect, subprocess

E = struct.Struct("<QQIiiBBBB")
MMUSHIFT = 4

def main():
    if len(sys.argv) < 2:
        print(__doc__); return
    path = sys.argv[1]
    vmlinux = sys.argv[2] if len(sys.argv) > 2 else None
    addrs = names = None
    if vmlinux:
        out = subprocess.run(["nm", "-n", vmlinux], capture_output=True,
                             text=True).stdout
        addrs, names = [], []
        for ln in out.splitlines():
            p = ln.split()
            if len(p) >= 3 and p[1] in "tT":
                try:
                    addrs.append(int(p[0], 16)); names.append(p[2])
                except ValueError:
                    pass

    def sym(r):
        if not addrs:
            return ""
        i = bisect.bisect_right(addrs, r) - 1
        return names[i] if i >= 0 else "?"

    with open(path, "rb") as f:
        magic, head, n, esz = struct.unpack("<QQQQ", f.read(32))
        buf = f.read(n * esz)
    evs = [E.unpack_from(buf, i * esz) for i in range(n)]
    evs = [e for e in evs if e[0]]
    evs.sort()

    state = {}                  # cluster -> 'free'/'alloc'
    by_rip = {}                 # rip -> count of install-into-free
    by_rip_cl = {}              # rip -> set of clusters
    for seq, rip, frame, a, b, kind, cpu, off, _pad in evs:
        if kind == 2:
            for cf in range(frame, frame + max(1, a >> MMUSHIFT)):
                state[cf] = 'free'
        elif kind == 3:
            for cf in range(frame, frame + max(1, a >> MMUSHIFT)):
                state[cf] = 'alloc'
        elif kind == 9:
            if state.get(frame) == 'free':
                by_rip[rip] = by_rip.get(rip, 0) + 1
                by_rip_cl.setdefault(rip, set()).add(frame)

    total = sum(by_rip.values())
    print(f"INSTALL-INTO-FREE (present USER PTE -> free cluster): {total} events, "
          f"{len(by_rip)} distinct caller RIPs")
    for rip, c in sorted(by_rip.items(), key=lambda x: -x[1])[:15]:
        print(f"  {c:8}  {len(by_rip_cl[rip]):6} clusters  @{rip:016x}  {sym(rip)}")

if __name__ == "__main__":
    main()
