# pgcl4 laptop test — #143 (reclaim-pressure-driven page-cache corruption)

## Hypothesis being tested
The QEMU dose-response shows #143 scales with **memory pressure**:
`-m 2G → 8/8 corrupt, 3G → 6/8, 12G → 1/8`. The dominant crash (PID1 segv →
kill init) is **reclaim-driven**. The laptop has far more RAM than the 3G
testbed, so reclaim — and thus #143 — should be **much rarer**. pgcl4 may be
usable on the real machine even though the testbed corrupts.

## The kernel
`kernel-*pgcl4*` RPM, built with a **light, non-perturbing capture detector**:
- `PGCL143wp #N: order-0 mapcount underflow pfn=... mc=... rc=... anon=... index=...`
  fires ONLY on the bug (the freed-while-mapped / dangling-PTE underflow), so it
  does not perturb the timing race. Dumps the first 8 with full `dump_page()` +
  one `dump_stack()`; the `#N` counter shows the total even if capped.
- Native always-on detectors (no DEBUG_VM needed): `BUG: Bad page map`
  (the testbed's dominant catch), `BUG: Bad page state`, bad rss-counter.
- `PAGE_OWNER=y` → the freed page's alloc/free history.
- No `WARN`/`BUG`/`panic_on_warn` from the detector → it can't panic the box.

## Install (HYGIENE — read first)
```
sudo rpm -i  ~/rpmbuild/RPMS/x86_64/kernel-<rel>.rpm      # -i, NEVER -U
# (rpm -U with the same kernelrelease runs the old postun and wipes the new
#  /boot files. Use -i. The stock kernel stays install-only-safe.)
sudo kernel-install add <rel> /lib/modules/<rel>/vmlinuz  # if needed
```
Keep a known-good stock kernel as the default boot entry to fall back to.

## Boot cmdline (NEVER `panic=1` on the laptop)
```
earlycon=efifb keep_bootcon ignore_loglevel nokaslr page_owner=on initcall_debug
```
Do NOT add `panic=1`/`panic_on_warn`. We want the box to stay up and log, and
panics captured via pstore — not an immediate reboot loop.

## Test 1 — usability (full RAM)
Boot pgcl4 normally. Expected if the pressure model holds: reaches login/desktop,
`PGCL143wp` count low or zero. After it's up:
```
bash /home/nyc/src/pgcl/collect-pgcl143.sh
```
- Reached a usable desktop + `wp=0`, `badmap=0` → **pgcl4 is usable on the laptop.**
- Boots but `wp>0` with no crash → it IS hitting the underflow but surviving
  (near-miss); the count tells us how close. Still a partial win + data.

## Test 2 — force-repro under pressure (confirm same bug on real HW)
Boot pgcl4 again, appending `mem=3G` to the cmdline (replicates the testbed's
pressure exactly). Expected: #143 reproduces (`PGCL143wp` / `Bad page map`, maybe
PID1 segv → kill-init panic). This confirms the laptop has the SAME bug and that
full-RAM is the mitigation. If it panics, reboot into the stock/known-good kernel,
then run the collect script (it reads the previous boot + pstore).

## After a crash
Boot the stock kernel, then:
```
bash /home/nyc/src/pgcl/collect-pgcl143.sh   # reads -b -1 + /sys/fs/pstore
```
