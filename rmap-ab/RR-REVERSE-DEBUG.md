# QEMU record/replay + reverse debugging for #143 (and any whole-kernel MM bug)

A deterministic "rewind the clock" workflow for a hard, intermittent kernel
memory-management bug, built while hunting PGCL #143 (pgcl4: a cluster is freed
while a sub-PTE still maps it → the page is reused/zeroed → userspace returns to
`RIP=0` → "Attempted to kill init").

This complements the forward, non-perturbing instrumentation in
`tree-backup/QEMU-143-DEBUG-README.md` and `../RMAP-DEBUG-TOOLKIT.md`. Forward
logging tells you *what* the counts did; this lets you run *backward* from the
symptom to the exact instruction that caused it.

## The key finding that makes this possible

`#143` **reproduces at `-smp 1`** (~2 of 3 runs under icount). So it is a
**single-CPU, scheduling-sensitive interleaving** (the faulting task vs
kswapd/reclaim across *context switches*), **not a parallel cross-CPU race**.

This matters for two reasons:

1. It explains why every parallel-refcount-race audit (do_swap_page,
   try_to_unmap_one/reclaim, do_wp_page reuse, zap, copy_present_ptes fork) came
   back clean — there is no two-CPU race to find.
2. **QEMU record/replay supports `-smp 1` only** ("Record/replay is not
   supported with multiple CPUs"). A genuinely parallel race could not be
   captured this way; a single-CPU interleaving can, and replays bit-for-bit.

(For the record: the bug also fires under `thread=single -smp 8` round-robin
~1/4, and reliably under `thread=multi`; `-smp 1` is simply the mode that is
both reproducing *and* recordable.)

## Why record/replay instead of just logging

Storage was never the constraint. A full record/replay log is small (~50 MB for
a ~160 s run) because it records only the *nondeterministic inputs* (interrupt
timing, block-I/O completion order, RDRAND, …) and reconstructs everything else
by re-execution. The constraint on a *parallel* race is the observer effect:
serialization changes timing. Because #143 survives serialization, we get the
whole sci-fi for free: a deterministic recording you can replay and step
**backward** through with `reverse-continue` / `reverse-stepi`.

## Prerequisites

* A QEMU built with reverse-exec support — check:
  `strings qemu-system-x86_64 | grep ReverseContinue` → `;ReverseStep+;ReverseContinue+`.
* A **not-stripped** `vmlinux` whose `bzImage` is byte-identical to the one being
  recorded: `kernel-rpm-build/pgcl4-debug/vmlinux`
  (`cmp pgcl4-debug/arch/x86/boot/bzImage rmap-ab/bzImage-vandangle`).
  Function symbols are enough for `bt`/`info symbol`; for source lines/types
  rebuild with `CONFIG_DEBUG_INFO_DWARF` (see `build-dbginfo-vmlinux.sh`).
* The read-only base images: `rmap-ab/btrfs.img`, `pgcl4-testbed/swap.raw`.

## The scripts

| script | purpose |
|---|---|
| `rr-record.sh [N] [tmo]` | record up to N icount runs; keep the rrfile of any run that kills init |
| `rr-verify.sh <rrfile> [reclog]` | replay a recording; prove it is bit-exact vs the record log |
| `replay-rr.sh <rrfile> [port]` | replay under a **frozen gdbstub** (`-S -gdb tcp::port`) for reverse debugging |
| `rev-debug.gdb` | gdb macros + recipe (`vmemmap`, `pg`, `watchrc`, `gpa2cpfn`) |

## End-to-end

```sh
cd rmap-ab
./rr-record.sh 6                 # -> ">>> CRASH CAUGHT: rrcrash-3.bin"
./rr-verify.sh rrcrash-3.bin     # optional: confirm bit-exact replay
# terminal 1:
./replay-rr.sh rrcrash-3.bin 1234
# terminal 2:
O=../kernel-rpm-build/pgcl4-debug
gdb $O/vmlinux -x rev-debug.gdb
```

Then follow the recipe printed by `rev-debug.gdb`:

1. `vmemmap`
2. `continue` — replay forward to the fatal fault (`RIP=0`).
3. `reverse-stepi` — step back to the bad `ret`/indirect branch; the `0` came
   from `[rsp]` (the popped return slot). `info registers rsp rip`.
4. `monitor gva2gpa <stackVA>` then `gpa2cpfn <gpa>` → the **victim cluster pfn**
   (the stale pfn the dangling sub-PTE still points at).
5. `pg <cpfn>` — confirm `refcount==0` (already freed) while init still maps it.
6. `watchrc <cpfn>` — hardware watchpoint on that cluster's `_refcount` via its
   **vmemmap (kernel-linear) address**, which stays mapped across context
   switches (a userspace VA would not).
7. `reverse-continue` — stops *at* the write that drove the refcount to 0.
8. `bt` — the buggy unref path. Root cause, deterministically, with a stack.

## Gotchas (each cost real time)

* **`-smp >1` is rejected** by record/replay. Use `-smp 1`.
* **No `rrsnapshot`.** It wrote *duplicate* `rrinit` snapshots into the qcow2 and
  replay reverted to the empty one → zero console output / divergence. Instead
  use a **fresh qcow2 overlay** over the read-only base for *both* record and
  replay: identical start state, no snapshot machinery. (`qemu-img create -f
  qcow2 -b base -F raw overlay.qcow2`.)
* **Block I/O must be wrapped in `blkreplay`** (`driver=blkreplay,image=…`) or the
  completion order is nondeterministic and replay diverges.
* **Never point two live QEMU at the same RAW image** — `Failed to get "write"
  lock`. Overlays open the base read-only, so concurrent runs are fine.
* **Watch kernel-linear addresses, not userspace VAs**, so the watchpoint
  survives context switches during `reverse-continue`.
* `reverse-continue` re-executes from periodic internal snapshots, so it is
  slower than forward — but bounded and exact.

## PGCL coordinate reminder (pgcl4)

`PAGE_SHIFT=16` (64 KiB), `MMUPAGE_SHIFT=12` (4 KiB), `PAGE_MMUCOUNT=16`. One
`struct page` per **cluster**; refcount/mapcount are summed over the 16
sub-MMUPAGEs. `page_to_pfn()` is the cluster pfn = `phys >> 16`. `struct page`
is 64 B; in this build `_mapcount` is at `+48`, `_refcount` at `+52`.
