# mapcount & refcount in the folio VM — a working reference, with the PGCL overlay

Grounded in the v7.1 tree in `/home/nyc/src/linux`. Goal: make the diffs legible by
nailing what mainline *means*, then layering PGCL on top. Read §1–§5 for mainline;
§6 is the PGCL overlay and where #143 lives.

────────────────────────────────────────────────────────────────────────
## 0. The two counters, one sentence each

- **refcount** (`folio->_refcount`, via `folio_ref_count()`): *how many holders keep this
  folio alive right now.* When it hits 0, the folio is freed.
- **mapcount** (`folio_mapcount()`): *how many user page-table entries currently point into
  this folio.* It is **not** a liveness counter — it's a "is this mapped, and how widely"
  counter. A folio can have mapcount 0 and refcount > 0 (e.g. in the page cache, unmapped).

The bridge between them is the Prime Invariant (§2).

────────────────────────────────────────────────────────────────────────
## 1. The objects

```
              folio (the unit of management)
              ┌───────────────────────────────────────────────┐
   order-0:   │ struct page  ── one 4K page                    │
              └───────────────────────────────────────────────┘
              ┌───────────────────────────────────────────────┐
   order-N:   │ head page │ tail │ tail │ ... │ tail (2^N pages)│
              │  ^counters live here                           │
              └───────────────────────────────────────────────┘
```

Counters by folio size (v7.1, `struct page`/`struct folio` in `mm_types.h`):

| field | small (order-0) | large (order≥1) | meaning |
|---|---|---|---|
| `_refcount` | yes | yes (head) | liveness; `folio_ref_count()` |
| `_mapcount` | **the** mapcount | per-*page* (tail), only if `CONFIG_PAGE_MAPCOUNT` | PTEs referencing *this page* |
| `_large_mapcount` | — | yes (head) | **total** PT entries mapping the folio |
| `_entire_mapcount` | — | yes (head) | PMD/PUD ("entire") mappings only |
| `_nr_pages_mapped` | — | yes (head) | #pages with ≥1 PTE, + `ENTIRELY_MAPPED` sentinel |

`folio_mapcount()`:  small → `_mapcount + 1`;  large → `_large_mapcount + 1`.
`folio_entire_mapcount()` (large only) → `_entire_mapcount + 1`.

**The −1 bias.** Every mapcount is stored as `(true count) − 1`, so a fresh/unmapped
descriptor reads −1. This exists so the two *edges that matter generically* are detectable
atomically:
  - first map:   `atomic_inc_and_test(&_mapcount)`  is true on −1 → 0
  - last unmap:  `atomic_add_negative(-1,&_mapcount)` is true on 0 → −1
Intermediate counts (0↔1↔2…, fork/alias) are just `atomic_add`/`sub`.

────────────────────────────────────────────────────────────────────────
## 2. The Prime Invariant (memorize this one)

From `mm.h` `folio_mapcount()` kerneldoc:

> "the number of present user page table entries that reference any part of a folio.
>  **Each such present user page table entry must be paired with exactly one folio
>  reference.** … each user page table entry (PTE/PMD/PUD) counts exactly once."

So:  **every present user PT entry ⇒ +1 mapcount AND +1 refcount. Establish them together,
tear them down together.** Get this pairing wrong by one and you get the `refcount:-`/
`Bad page map` class.

The full refcount is mapcount plus the *non-mapping* holders (`folio_expected_ref_count()`):

```
expected_refcount(folio) =
      (folio_test_swapcache ? nr_pages : 0)     // 1 swapcache ref per page
    + (anon ? 0 : (folio->mapping ? nr_pages:0)) // 1 pagecache ref per page (file)
    + (anon ? 0 : folio_test_private)            // +1 for PG_private (buffers/subpage)
    + folio_mapcount(folio);                     // the Prime Invariant term
```
Migration/reclaim *freeze* the folio by checking `folio_ref_count() == expected+1` and
then `folio_ref_freeze()`; a mismatch means "someone holds a ref we didn't expect" → bail.
This is why a stray ref (or a stray mapping that wasn't counted) shows up as a migration
failure *or*, if the bookkeeping is the other way, a premature free.

────────────────────────────────────────────────────────────────────────
## 3. `_nr_pages_mapped` and `ENTIRELY_MAPPED` (the large-folio bit that confuses everyone)

`mm/internal.h`:  `ENTIRELY_MAPPED = 0x800000`,  `FOLIO_PAGES_MAPPED = 0x7fffff`.

`_nr_pages_mapped` packs two things into one atomic:
  - **low bits** (`& FOLIO_PAGES_MAPPED`): how many distinct pages of the folio have ≥1 PTE.
  - **`+ ENTIRELY_MAPPED`**: added once when the folio is mapped by an *entire* (PMD/PUD) entry.

It answers "is this folio fully mapped, partially mapped, or entire-mapped?" which drives the
`NR_*_MAPPED` vmstats and deferred-split. It is **not** the mapcount; it's the *shape* of the
mapping. (`rmap.c __folio_add_rmap`: PTE adds bump the low bits via `atomic_inc_and_test`
per page; PMD adds add `ENTIRELY_MAPPED`.)

────────────────────────────────────────────────────────────────────────
## 4. Scenarios (the part to check your intuition against)

Notation:  `R=` refcount, `M=` folio_mapcount, `E=` entire_mapcount, `npm=`_nr_pages_mapped.
Assume anon unless noted; ignore transient/GUP refs.

### (a) order-0, faulted once in one mm
```
   VMA ──PTE──▶ [4K page]            R=1   M=1
```
One PTE, one ref. `_mapcount=0` (=M−1). Exclusive (PageAnonExclusive set).

### (b) order-0, after fork() — same page in two mms
```
   mmA ──PTE──▶ [4K page] ◀──PTE── mmB     R=2   M=2
```
mapcount counts PTEs, *not* mms. Two PTEs → M=2, R=2. PageAnonExclusive cleared (shared) →
a write now goes to COW, not reuse.

### (c) order-0, aliased twice in ONE mm (double mmap / old remap_file_pages)
```
   VMA1 ─PTE─▶ [4K page] ◀─PTE─ VMA2   (same mm)   R=2   M=2
```
**Identical accounting to (b).** mapcount is mm-agnostic; repeated references in one mm are
counted exactly like references from different mms. The rmap walk (`i_mmap`/`anon_vma` tree)
visits *both* PTEs, so add/remove balance. This is the "repeated mappings" case your framing
leans on — and for the *counters* it is exactly right.

### (d) large folio (order-9, 2M), PMD-mapped in one mm
```
   VMA ══PMD══▶ [ 2M folio (512×4K) ]      R = 512(cache, if file) + 1(the PMD)
                                            M=1   E=1   npm=ENTIRELY_MAPPED
```
ONE PMD entry ⇒ M=1 (one PT entry), E=1. The PMD references the *whole* folio but counts once.

### (e) large folio, fully PTE-mapped (512 PTEs)
```
   VMA ─PTE×512─▶ [ 2M folio ]              M=512   E=0   npm=512
```
512 PTEs ⇒ M=512. Not entire (E=0). npm=512 (all pages have a PTE).

### (f) large folio, PARTIALLY PTE-mapped (e.g. 10 of 512 pages)
```
   VMA ─PTE×10─▶ [ 2M folio, 10 pages live ]   M=10   E=0   npm=10
```
M=10, npm=10. "partially mapped" → eligible for deferred split.

### (g) large folio, VARYING VIEWS — PMD in mmA, PTEs in mmB (your "different sizes" case)
```
   mmA ════PMD═══▶ [ 2M folio ] ◀─PTE×10─ mmB
                                  M = 1(PMD) + 10(PTEs) = 11
                                  E = 1            npm = ENTIRELY_MAPPED + 10
```
**Explicitly legal and common** (a THP split in one process, an unaligned mmap in another).
`folio_mapcount()=11` sums everything; `folio_entire_mapcount()=1` isolates the PMD;
`_nr_pages_mapped` says "entire, plus 10 individually." Every entry still pairs 1:1 with a ref.

### (h) the COW / exclusivity decision (where state, not counts, rules)
```
   do_wp_page: reuse iff  PageAnonExclusive(page)               // per-PAGE flag
                          OR wp_can_reuse_anon_folio()          // small: folio_ref_count()==1
```
Note it's a *flag* + a *refcount==1* test, i.e. "am I the only holder, and is this byte-range
exclusively mine?" — a question about **identity of the bytes**, not just a count.

### (i) reclaim / migration freeze
```
   try_to_unmap(folio): walk rmap, drop every PTE → M→0, R→(non-map holders)
   then __remove_mapping / __folio_migrate_mapping:
        if folio_ref_count() != expected → ABORT (someone still holds it)
        else folio_ref_freeze(0) → safe to reclaim/move
```
The freeze is the moment the Prime Invariant is *cashed in*: if every mapping was correctly
paired with a ref and all were removed, the refcount lands exactly on `expected`.

────────────────────────────────────────────────────────────────────────
## 5. Lifecycle — who touches the counters

| event | mapcount | refcount | notes |
|---|---|---|---|
| fault-in | `folio_add_*_rmap` +1/entry | +1/entry | establish together, under PTL |
| fork dup | `folio_dup_*_rmap` +1/entry (child) | +1/entry | child shares; src write-protected |
| zap/munmap | `folio_remove_rmap` −1/entry | −1/entry (tlb) | PTL held across both |
| COW reuse | unchanged | unchanged | only if exclusive/refcount==1 |
| COW copy | old −1, new +1 (new folio) | old −1, new +1 | |
| reclaim | try_to_unmap → 0, then freeze→free | → expected → 0 | folio lock held |
| migration | remove → restore (1:1) | freeze→transfer | PVMW_SYNC |
| split | redistribute to sub-folios | unchanged total | `__folio_split` |

────────────────────────────────────────────────────────────────────────
## 6. The PGCL overlay  ← the part that matters for #143

PGCL inserts a granularity **below** what mainline calls "a PTE":

```
   mainline ladder:        PTE (one 4K page)  <  PMD (512×4K)  <  PUD …
   PGCL ladder:    sub-PTE (one 4K MMUPAGE) < cluster (PAGE_SIZE = N×MMUPAGE,
                                              ONE struct page) < PMD < …
```

At pgcl4: `MMUPAGE=4K`, `PAGE=cluster=64K`, `PAGE_MMUCOUNT=16`. **One struct page per 64K
cluster.** `pte_page(any sub-PTE of the cluster)` resolves to that one struct page (because
`pte_pfn` returns the cluster pfn — see `pgcl-pte-pfn-coordinate-model`).

### 6.1 Your framing, made precise

A cluster mapped by all 16 sub-PTEs:
```
   VMA ─subPTE0─▶ [MMUPAGE 0] ┐
   VMA ─subPTE1─▶ [MMUPAGE 1] │  all 16 sub-PTEs resolve to the SAME struct page
       …                      ├▶ ┌──────── cluster struct page ────────┐
   VMA ─subPTE15▶ [MMUPAGE15] ┘   │  _mapcount, _refcount live here     │
                                  └─────────────────────────────────────┘
                                  M = 16   R = 16(+cache/private for file)
```

- **For the counters:** identical to "the same struct page referenced 16 times" — i.e.
  scenario (c)'s repeated-references, just with disjoint byte ranges. Each sub-PTE is one
  PT entry, paired with one ref. The Prime Invariant holds verbatim. **This is why the
  conversion's per-sub-PTE counting is correct** — and why every count value I audited
  checks out.

- **For state:** the analogy **breaks**. Scenario (c)'s aliases share bytes, so the single
  per-page `PG_dirty`/`PG_young`/`PageAnonExclusive` is *the truth*. PGCL's 16 sub-PTEs map
  **disjoint** bytes, so one flag for 16 sub-pages is **lossy**:

```
   cluster struct page:  [ PG_dirty? PageAnonExclusive? ]  ← ONE bit each
   reality:              sub0 dirty, sub1 clean, sub2 dirty, … (16 independent truths)
```

### 6.2 The fault line (where #143 and its siblings live)

The dangerous question is any decision that reads a **per-cluster flag or a count** to infer
something about a **single sub-page's identity**:

- `PageAnonExclusive(cluster)` used to decide "is *this sub-page* exclusively mine, reuse on
  write?" — but the bit is cluster-wide. A cluster that's exclusive w.r.t. sub-page 0 but
  shared w.r.t. sub-page 5 has only one bit to say it. (This is the #146 / wp_can_reuse area.)
- `folio_mapcount()==1` meaning "singly mapped" — under PGCL a singly-*process*-mapped cluster
  has M=16, never 1, so that inference silently never fires (perf), and the inverse — treating
  M as "one logical mapping" — is wrong.
- A sub-PTE made exclusive/COW'd independently of its 15 neighbours leaves the cluster flag
  unable to represent the mix → a later reuse/free decision on a *different* sub-page can act
  on stale cluster state.

### 6.3 The new entry types PGCL must keep 1:1 with refs

```
   sub-PTE      (MMUPAGE)         → +1 mapcount, +1 ref   (the common case)
   cluster PTE-batch              → +N over the cluster   (folio_add/remove_rmap_subptes)
   PMD over a large (multi-cluster) folio → entire        (Contract-A, _entire_mapcount)
```
The bug surface is the *seams* between these when a folio is mapped at **varying views/
alignments** (`vsub != psub` after mremap; a cluster straddling a pte-table; a large folio
PMD-here / sub-PTE-there). That's where one CPU's notion of "how many sub-PTEs does this
cluster contribute" can disagree with another's, and the 1:1 entry↔ref pairing slips.

### 6.4 Reading guide for the diffs (preconv ↔ conv ↔ HEAD worktrees)

When you read a hunk, ask:
1. **Counting:** does every sub-PTE established/removed change mapcount AND refcount by
   exactly 1 (or +N/−N consistently for a batch)? (Almost always yes — that half is sound.)
2. **State:** does it read a *per-cluster* flag (`PageAnonExclusive`, dirty, the
   `folio_ref_count()==1`/`mapcount==1` exclusivity tests) to decide something about *one
   sub-page*? (That's the lossy half — the real risk.)
3. **Edges:** does it assume the cluster is mapped as a unit (all-16 or none), when a
   varying-view/straddle/partial-COW could leave it mixed?

The counters are mainline-faithful; the **state collapse onto one struct page** is the part
the conversion had to invent, and it's the part to scrutinize.
