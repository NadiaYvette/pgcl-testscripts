#!/bin/sh
# Reproduce the PGCL #143 PAGE-CACHE-REF-LIFECYCLE (surf-pagecache) model-check
# results.  Surface: xarray / page-cache ref lifecycle for a FILE folio and its
# interaction with reclaim (__remove_mapping) + truncate (truncate_cleanup_folio,
# __filemap_remove_folio) under PGCL cluster vs MMUPAGE indexing.
#
# CBMC 6.8.0 ships inside Kani at ~/.kani/kani-0.67.0/bin.
set -e
export PATH="$HOME/.kani/kani-0.67.0/bin:$PATH"
echo "## cbmc: $(cbmc --version)"
echo

# NSTEPS/unwind are tuned per model so the nondeterministic cooperative scheduler
# is fully explored AND completion is reachable (coverage probes below confirm the
# __CPROVER_assume(all done) is satisfiable -> results are non-vacuous).

echo "===== 1. PAGE-CACHE REMOVE GATE vs FAULT/RECLAIM/TRUNCATE interleave ====="
echo "      pc_remove_gate.c — folio-lock-serialized droppers vs a faulting task"
echo "      INVARIANT: pc ref never dropped (folio removed/freed) while a sub-PTE maps it"
for s in 1 2 3; do
  printf '   SCENARIO=%s (expect SUCCESSFUL): ' "$s"
  cbmc pc_remove_gate.c -DSCENARIO=$s --unwind 22 --unwinding-assertions 2>&1 | grep -E 'VERIFICATION'
done
printf '   SCENARIO=4 all-three (NSTEPS=14, expect SUCCESSFUL): '
cbmc pc_remove_gate.c -DSCENARIO=4 -DNSTEPS=14 --unwind 16 --unwinding-assertions 2>&1 | grep -E 'VERIFICATION'
echo
echo "   -- negative control: truncate ignores the folio lock (expect FAILED) --"
perl -0pe 's/(case 0: \/\* find_lock_entries.*?\n)\t\tif \(folio_lock\) return 0;[^\n]*\n/$1\t\t\/* BUG: no lock *\/\n/s' \
  pc_remove_gate.c > _neg.c
printf '   broken-serialization SCENARIO=2 (expect FAILED): '
cbmc _neg.c -DSCENARIO=2 -DNSTEPS=14 --unwind 16 2>&1 | grep -E 'VERIFICATION'
rm -f _neg.c
echo

echo "===== 2. TRUNCATE PAGE-vs-MMUPAGE UNIT ARITHMETIC (race #3) ====="
echo "      pc_truncate_units.c — sweep a sub-cluster truncate offset; check no folio"
echo "      is removed (pc ref dropped) while a sub-PTE outside the truncated sub-range maps it"
printf '   MODE=0 faithful cluster-rounded arithmetic (expect SUCCESSFUL): '
cbmc pc_truncate_units.c -DMODE=0 --unwind 32 --unwinding-assertions 2>&1 | grep -E 'VERIFICATION'
printf '   MODE=1 injected unit bug: remove boundary cluster w/o unmap (expect FAILED): '
cbmc pc_truncate_units.c -DMODE=1 --unwind 32 --unwinding-assertions 2>&1 | grep -E 'VERIFICATION'
printf '   MODE=2 injected under-unmap on removed cluster (expect FAILED): '
cbmc pc_truncate_units.c -DMODE=2 --unwind 32 --unwinding-assertions 2>&1 | grep -E 'VERIFICATION'
echo
echo "   -- SECONDARY (data/SIGBUS, NOT free-while-mapped): a sub-cluster ftruncate"
echo "      leaves the partial folio's sub-PTEs in [newsize, round_up(newsize,PAGE))"
echo "      mapped (and zeroed). folio is RETAINED so pc ref is safe; same at PGCL=0."
printf '   MODE=0 with CHECK_SIGBUS (expect FAILED = the benign lingering tail): '
cbmc pc_truncate_units.c -DMODE=0 -DCHECK_SIGBUS=1 --unwind 32 --unwinding-assertions 2>&1 | grep -E 'VERIFICATION'
echo

echo "===== 3. ORPHAN vs the PAGE-CACHE GATE (race #1, pc side) ====="
echo "      pc_orphan_gate.c — can a faithful teardown/install create an orphan that"
echo "      fools __remove_mapping / filemap_unaccount_folio's folio_mapped() gate?"
printf '   SCENARIO=1 straddle+fault+dropper (NSTEPS=13, expect SUCCESSFUL): '
cbmc pc_orphan_gate.c -DSCENARIO=1 -DNSTEPS=13 --unwind 15 --unwinding-assertions 2>&1 | grep -E 'VERIFICATION'
printf '   SCENARIO=2 deferred-zap window vs dropper (NSTEPS=10, expect SUCCESSFUL): '
cbmc pc_orphan_gate.c -DSCENARIO=2 -DNSTEPS=10 --unwind 12 --unwinding-assertions 2>&1 | grep -E 'VERIFICATION'
printf '   SCENARIO=3 straddle+zap+dropper (NSTEPS=13, expect SUCCESSFUL): '
cbmc pc_orphan_gate.c -DSCENARIO=3 -DNSTEPS=13 --unwind 15 --unwinding-assertions 2>&1 | grep -E 'VERIFICATION'
echo
echo "   -- sanity: an orphan present AT the gate is caught (expect FAILED) --"
cat > _san.c <<'EOF'
#include <assert.h>
#define NSUB 4
int pte[NSUB], rmap[NSUB], refcount, xslot, freed;
static int mapcount(void){ int i,c=0; for(i=0;i<NSUB;i++) c+=rmap[i]; return c; }
static int any_pte(void){ int i; for(i=0;i<NSUB;i++) if(pte[i]) return 1; return 0; }
int main(void){
  int i; xslot=1; freed=0;
  for(i=0;i<NSUB;i++){ pte[i]=1; rmap[i]=1; }
  refcount = 1 + NSUB;
  for(i=0;i<NSUB;i++) rmap[i]=0;
  pte[0]=0; pte[1]=0; pte[2]=0;          /* pte[3] stays present: the orphan */
  refcount -= 3;
  if(mapcount() == 0){ assert(!any_pte()); xslot=0; refcount-=1; }  /* MUST FAIL */
  return 0;
}
EOF
printf '   orphan-at-gate sanity (expect FAILED): '
cbmc _san.c --unwind 8 2>&1 | grep -E 'VERIFICATION'
rm -f _san.c
echo
echo "## done."
