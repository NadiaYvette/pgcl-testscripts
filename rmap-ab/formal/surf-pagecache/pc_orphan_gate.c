/*
 * pc_orphan_gate.c  —  CBMC model of race #1 from the PAGE-CACHE side:
 * can a faithful interleave CREATE an orphan (a present sub-PTE whose rmap is
 * gone, so folio_mapped()==false) and then have a page-cache-ref DROPPER
 * (__remove_mapping reclaim, OR truncate's filemap_unaccount_folio) pass its
 * MAPCOUNT gate and free a still-PTE-present file folio?
 *
 *   cbmc pc_orphan_gate.c -DSCENARIO=n --unwind 24 --unwinding-assertions
 *
 * This is COMPLEMENTARY to pgcl_orphan_faithful.c (owned by another agent): that
 * model proves the rmap TEARDOWN paths (try_to_unmap_one / zap / fault install)
 * keep clear==rmap-drop==ref-drop balanced so no orphan is born there.  THIS
 * model takes the page-cache droppers as the observers and asks whether, given
 * the FAITHFUL teardown/install steps, the two pc-ref gates can ever fire on an
 * orphan.  If the teardown is balanced (no orphan ever exists), both gates are
 * safe by construction; we re-derive that here from the pc side and ALSO model
 * the one path unique to pc: truncate's unmap-then-remove (cleanup zaps, then
 * filemap_unaccount_folio asserts !mapped) — proving the zap fully clears the
 * folio's mapcount AND PTEs before the remove.
 *
 * ==========================================================================
 * The MAPCOUNT gate in BOTH droppers:
 *   reclaim: __remove_mapping is reached only after shrink_folio_list does
 *     if (folio_mapped()) try_to_unmap; if (folio_mapped()) keep;  (vmscan.c)
 *   truncate: truncate_cleanup_folio: if (folio_mapped()) unmap_mapping_folio;
 *     then filemap_unaccount_folio: VM_BUG_ON_FOLIO(folio_mapped()) (filemap.c:155)
 *   Both use folio_mapped() == folio_mapcount()>=1.  An ORPHAN (PTE present,
 *   rmap==0) has mapcount 0 -> passes both -> would free a mapped folio.
 *   So the safety hinges entirely on: NO ORPHAN EXISTS at the gate.
 *
 * We model the teardown actors FAITHFULLY (rmap and PTE cleared TOGETHER, same
 * nr) and the install FAITHFULLY (rmap before/with PTE under lock), then let a
 * pc-dropper observe at every interleaving point.  An orphan can only appear if
 * some step clears a PTE without clearing its rmap, or sets a PTE without its
 * rmap and then yields before fixing it.  We make those the ONLY way to fail and
 * check the faithful steps never do.
 * ==========================================================================
 */

#include <assert.h>

#define NMM   2
#define NSUB  4
#define BND   2          /* pte-table split for the straddle PVMW walk */

#ifndef SCENARIO
#define SCENARIO 1
#endif
#ifndef NSTEPS
#define NSTEPS 18
#endif

int pte_present[NMM][NSUB];
int rmap[NMM][NSUB];
int refcount;
int xslot;
int folio_lock;
int freed;

static int folio_mapcount(void){
	int m,i,c=0;
	for(m=0;m<NMM;m++) for(i=0;i<NSUB;i++) c+=rmap[m][i];
	return c;
}
#define folio_mapped() (folio_mapcount() >= 1)

static int any_pte_present(void){
	int m,i;
	for(m=0;m<NMM;m++) for(i=0;i<NSUB;i++) if(pte_present[m][i]) return 1;
	return 0;
}

/* ORPHAN: a present PTE whose rmap is not counted (mapcount blind to it). */
static int orphan_exists(void){
	int m,i;
	for(m=0;m<NMM;m++) for(i=0;i<NSUB;i++) if(pte_present[m][i] && !rmap[m][i]) return 1;
	return 0;
}

static void free_instant_check(void){
	if(refcount==0 && !freed){ freed=1; assert(!any_pte_present()); }
}

/* the two pc-ref droppers share this gate+drop.  The gate is MAPCOUNT; the
 * assertion we MUST uphold is the stronger PTE form: passing the mapcount gate
 * with a present PTE = the bug. */
static void pc_drop_if_unmapped(void){
	if(folio_mapped()) return;                 /* gate keeps it (mapcount>=1) */
	/* gate passed: kernel proceeds to drop the pc ref.  SAFETY: */
	assert(!any_pte_present());                 /* must be no orphan PTE */
	assert(!orphan_exists());                   /* equivalently: no orphan */
	xslot = 0;
	refcount -= 1;
	free_instant_check();
}

/* ---- Actor U: faithful try_to_unmap_one straddle PVMW (two PTLs) over mm Um.
 * clears nr PTEs + nr rmap + nr refs TOGETHER per yield (rmap.c:2310-2545). */
int U_pc, Um, U_table, U_start;
static int nr_run(int m,int table,int start){
	int n=0,i,hi=table?NSUB:BND;
	for(i=start;i<hi;i++){ if(!pte_present[m][i]) break; n++; }
	return n;
}
static int U_step(void){
	int nr,i;
	switch(U_pc){
	case 0: U_table=0; U_start=0; U_pc=1; return 0;
	case 1:
		if(U_start >= (U_table?NSUB:BND)){ U_pc=2; return 0; }
		nr=nr_run(Um,U_table,U_start);
		if(nr==0){ U_start++; return 0; }
		for(i=U_start;i<U_start+nr;i++){ pte_present[Um][i]=0; rmap[Um][i]=0; }
		refcount-=nr; free_instant_check();
		U_start+=nr; return 0;
	case 2: /* PTL drop at PMD boundary, move to next table */
		if(U_table==0){ U_table=1; U_start=BND; U_pc=1; return 0; }
		U_pc=3; return 0;
	default: return 1;
	}
}

/* ---- Actor Z: faithful zap with DEFERRED tlb over mm Zm: clear PTEs now (PTL),
 * drop rmap + ref later (no PTL).  The deferred window is the classic orphan
 * suspect: PTE cleared but rmap still up -> mapcount still counts -> NOT an
 * orphan (mapcount form), but is there a window where PTE present & rmap gone?
 * No: rmap is dropped AFTER the PTE is already cleared.  Model it and check. */
int Z_pc, Zm, Z_nr;
static int Z_step(void){
	int i;
	switch(Z_pc){
	case 0: /* PTL: clear PTEs */
		Z_nr=0;
		for(i=0;i<NSUB;i++) if(pte_present[Zm][i]){ pte_present[Zm][i]=0; Z_nr++; }
		Z_pc=1; return 0;
	case 1: /* deferred: drop rmap */
		for(i=0;i<NSUB;i++) rmap[Zm][i]=0;
		Z_pc=2; return 0;
	case 2: /* deferred: drop refs */
		refcount-=Z_nr; free_instant_check();
		Z_pc=3; return 0;
	default: return 1;
	}
}

/* ---- Actor F: faithful fault install into mm Fm under the FOLIO LOCK.
 * rmap before/with PTE (set_pte_range order) so no PTE-without-rmap is exposed.*/
int F_pc, Fm;
static int F_step(void){
	int i;
	switch(F_pc){
	case 0:
		if(!xslot){ F_pc=9; return 0; }
		refcount+=1;                 /* lookup try_get */
		F_pc=1; return 0;
	case 1:
		if(folio_lock) return 0;     /* wait for lock */
		if(!xslot){ refcount-=1; free_instant_check(); F_pc=9; return 0; }
		folio_lock=1+2; F_pc=2; return 0;
	case 2: /* rmap THEN pte (atomic under PTL within this step) */
		for(i=0;i<NSUB;i++) rmap[Fm][i]=1;
		for(i=0;i<NSUB;i++) pte_present[Fm][i]=1;
		refcount+=(NSUB-1);
		F_pc=3; return 0;
	case 3: folio_lock=0; F_pc=9; return 0;
	default: return 1;
	}
}

/* ---- Actor P: a page-cache dropper that interleaves freely and observes the
 * gate at any moment.  Models BOTH reclaim's post-unmap gate and truncate's
 * filemap_unaccount_folio gate — it just checks folio_mapped() and, if clear,
 * drops the pc ref.  It needs the folio lock (both droppers hold it). */
int P_pc;
static int P_step(void){
	switch(P_pc){
	case 0:
		if(folio_lock) return 0;
		if(!xslot){ P_pc=9; return 0; }
		folio_lock=1+5; P_pc=1; return 0;
	case 1: /* truncate-style: if mapped, unmap the whole folio first */
		if(folio_mapped()){
			int m,i,n=0;
			for(m=0;m<NMM;m++) for(i=0;i<NSUB;i++) if(pte_present[m][i]){
				pte_present[m][i]=0; rmap[m][i]=0; n++; }
			refcount-=n; free_instant_check();
		}
		P_pc=2; return 0;
	case 2: /* the gate + drop (filemap_unaccount_folio / __remove_mapping) */
		pc_drop_if_unmapped();
		if(!freed && !xslot && refcount>0){ refcount=0; free_instant_check(); }
		folio_lock=0; P_pc=9; return 0;
	default: return 1;
	}
}

static int U_done(void){ return U_pc>=3; }
static int Z_done(void){ return Z_pc>=3; }
static int F_done(void){ return F_pc>=9; }
static int P_done(void){ return P_pc>=9; }

static void post(void){
	/* the load-bearing invariant of this surface */
	if(!xslot){
		int m,i;
		for(m=0;m<NMM;m++) for(i=0;i<NSUB;i++)
			assert(!pte_present[m][i]);   /* pc removed while mapped */
	}
	if(freed) assert(!any_pte_present());
}

int main(void){
	int step, who;
	freed=0; xslot=1; folio_lock=0;
	U_pc=Z_pc=F_pc=P_pc=0; Um=Zm=Fm=0;

	for(int i=0;i<NSUB;i++){ pte_present[0][i]=1; rmap[0][i]=1; pte_present[1][i]=1; rmap[1][i]=1; }
	refcount = 1 + NMM*NSUB;

#if SCENARIO==1
	/* reclaim/truncate dropper P vs a straddle unmap U on mm1, fault F re-add mm... */
	for(int i=0;i<NSUB;i++){ pte_present[1][i]=0; rmap[1][i]=0; }
	refcount = 1 + NSUB;
	Um=0; Fm=1;
	#define LIVE_U 1
	#define LIVE_Z 0
	#define LIVE_F 1
	#define LIVE_P 1
#elif SCENARIO==2
	/* deferred zap Z on mm0 racing the pc dropper P (the deferred-window orphan
	 * suspect: P observes the gate while Z is between clear and rmap-drop). */
	Zm=0;
	#define LIVE_U 0
	#define LIVE_Z 1
	#define LIVE_F 0
	#define LIVE_P 1
#elif SCENARIO==3
	/* straddle U on mm0 + deferred zap Z on mm1, both racing P. */
	Um=0; Zm=1;
	#define LIVE_U 1
	#define LIVE_Z 1
	#define LIVE_F 0
	#define LIVE_P 1
#endif

	for(step=0; step<NSTEPS; step++){
		who=nondet_int();
		__CPROVER_assume(who>=0 && who<4);
		if(who==0 && LIVE_U && !U_done()) U_step();
		else if(who==1 && LIVE_Z && !Z_done()) Z_step();
		else if(who==2 && LIVE_F && !F_done()) F_step();
		else if(who==3 && LIVE_P && !P_done()) P_step();
		else continue;
		post();
	}
	__CPROVER_assume((!LIVE_U||U_done()) && (!LIVE_Z||Z_done()) &&
			 (!LIVE_F||F_done()) && (!LIVE_P||P_done()));
	if(!freed && refcount>0 && !xslot){ refcount=0; free_instant_check(); }
	post();
	assert(!(freed && any_pte_present()));
	return 0;
}
