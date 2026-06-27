# PGCL #143 + RFC — Resumption / Handoff (2026-06-27)

Durable handoff so this can be resumed later, even with **radically reduced
hardware/software** (worst case: just `git` + a text editor). This repo
(`pgcl-testscripts`) is mirrored to github / disroot / sourcehut / framagit, so
this file survives loss of the local box. The blow-by-blow hunt log lives in the
author's local memory `pgcl143-rmap-underflow-hunt.md` (not mirrored).

---

## 1. RFC — the deadline deliverable — DONE, needs only sending
**Deadline: end of Tue 30 Jun 2026 (00:00 MESZ Wed 1 Jul).**
- Cover letter (canonical prose): `PGCL-COVER-LETTER.md`.
- Assembled mbox: `rfc-v1/0000-cover-letter.patch` + `rfc-v1/0001..0028-*.patch` (28 patches).
- Recipients: `rfc-v1/recipients.txt` (full `get_maintainer` dump — **curate**, don't send to all 521). Plan: To: linux-mm + akpm; Cc: core mm reviewers + linux-arch + lkml + corbet (linux-doc) + Shutemov / Xu Lu / Roberts-Jain (parallel upstream efforts).
- Code: `github.com/NadiaYvette/linux` branch **`pgcl-rfc-v1`** (= the exact posted series; also sourcehut `linux-pgcl`). Full dev tree: branch `nadia.chambers/page-clustering-001`.
- Send: `git send-email` (Infomaniak SMTP; device password in keyring). This is the surest deadline goal — independent of #143.

## 2. #143 — what the bug is
PGCL keeps **one `struct page` per "cluster"** = `PAGE_MMUCOUNT` (16 at pgcl4) hardware
MMU sub-PTEs; a cluster has a per-cluster **refcount** and per-sub-PTE **`_mapcount`**
(Option A; `pte_pfn` returns the cluster pfn; PVMW yields `nr_mmupages` PTEs/yield).
The bug: a file/anon cluster is **FREED (refcount→0) while a sub-PTE still maps it**
→ kernel `bad_page` at munmap ("present PTE in vma → freed pfn, `mapcount:-1`") → the
pfn is reused → init reads garbage, jumps to NULL → "Attempted to kill init" panic.
A **cross-CPU race** (needs ≥2 CPUs, or an `-smp1` fault-vs-kswapd scheduling
interleave). Bisected to the **MMUPAGE-unit rmap conversion** commits.

## 3. Reproduction assets (in `rmap-ab/`)
- **`run-smp8-live.sh`** — the A/B **fix oracle**: KVM `-smp8` + `bzImage-vandangle` +
  `abl-initramfs/`; crashes ~12–200 s guest, **~100%**. Load-independent (guest-internal
  2 G pressure + 8 vCPUs). Use this to A/B any candidate fix: corruption 4/4 → 0/N = fixed.
- **`rrcrash-4-KEEP.bin`** (+`.log`) — a deterministic **icount-rr recording** of the
  kill-init, captured under host memory pressure. Reverse-debuggable in principle (see §5).
- **`memhog.sh`** — on-demand host memory pressure (recreates the "frankenstein"/cbmc load
  that lets `rr-record` land the racy `-smp1` schedule for a fresh capture).

## 4. Ruled out / narrowed (the durable conceptual state)
- **It IS:** freed-with-live-PTE, `mapcount:-1`, in the conversion's per-sub-PTE machinery;
  needs concurrency.
- **RULED OUT:** fork-dup (#143a probe 0); `do_wp_page` COW-reuse (powered A/B); compaction
  (`COMPACTION=n` still corrupts); **reclaim-freeze-while-mapped** (a `__remove_mapping`
  post-`folio_ref_freeze` `folio_mapped()` tripwire fired **0/4** while corruption was 4/4);
  simple refcount/mapcount **unit mismatch** (finish_fault / fault-around / zap all balance
  in MMUPAGE units on careful read).
- **LEADING hypothesis:** PVMW drops the PTL at a pte-table boundary, and a concurrent
  PTL-only zap (munmap/exit) on a **SHARED cluster** (forked `sd-parse-elf` children share
  pages) removes one mapper's rmap+ref but leaves its PTE → folio refcount hits 0 with a
  live PTE. (Agent A in §6 is auditing this to a precise interleaving + fix.)

## 5. Reverse-debug: the wall, and the fix for next time
- **Wall:** gdb-attached TCG icount replay is catastrophically slow (gdb disables TB
  chaining; 4 h did NOT reach the guest-445 s crash). QEMU also does **not** reproduce
  serial console on replay, so progress is invisible without gdb.
- **The fix (untried; QEMU 10.1.4 has the primitives):** `replay_break <icount>` fast-forwards
  the replay **gdb-free at full speed** to just before the crash; `savevm` there; then gdb
  `loadvm` + replay only the last stretch + `reverse-continue`. `info replay` (HMP/QMP) gives
  a real progress bar. **Validate `savevm`/`loadvm` determinism under `rr=replay` first**
  (use HMP `savevm`, not the finicky `rrsnapshot=` CLI). Rebuild the debug kernel with
  `CONFIG_DEBUG_INFO` for line-numbered backtraces (current build has symtab only, no DWARF).
- **gdb scripts:** `rev-orphan.gdb` (orphan-PTE walk + `chkmap` + reverse `hunt`),
  `rev-fwd.gdb` (forward-only victim ID), `revrun.sh` (PTY runner). Harness lessons baked in:
  invoke via `bash`; `pkill` bracket-trick to avoid self-kill; `loadbases` AFTER the run-to-crash;
  `set non-stop off` + a PTY (`script -c`) to make `continue` block non-interactively;
  `-iex 'set debuginfod enabled off'` to suppress the startup prompt.

## 6. In flight (2026-06-27)
- **Agent A** (static audit) → the exact cross-context interleaving (file:line) + a candidate patch.
- **Agent B** (formal) → a minimal concurrent C model of the cluster protocol checked with
  **CBMC** (installed) / genMC → a violating interleaving; output `rmap-ab/formal/FINDINGS.md`;
  plus a plan to dovetail into **Tessera** (`~/src/tessera`, Lean4: `Kau`/`Sharing`/`MapAtomic`
  + `.litmus`).
- **TODO:** snapshot-near-crash de-risk (§5); a gdb-Python driver (heartbeat progress +
  incremental findings-to-file + a command-file query channel) for an observable, resumable spin.

## 7. How to resume with reduced capability
- **git + editor only:** review Agent A's candidate fix + §4 narrowing; the fix is a small `mm/`
  change, reviewable anywhere.
- **build, no QEMU-rr:** A/B the candidate fix against `run-smp8-live.sh` (the oracle).
- **full capability:** snapshot-near-crash reverse-debug (§5) for the authoritative trace; or
  re-capture with `rr-record.sh` under `memhog.sh` pressure.
