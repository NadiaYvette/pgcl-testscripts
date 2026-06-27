// SPDX-License-Identifier: GPL-2.0
/*
 * mm/pgcl143_ptescan.c -- DEBUG (uncommitted): structural orphan-PTE scanner.
 *
 * #143 is an *orphan PTE*: a present sub-PTE whose rmap entry and refcount were
 * already removed, so the cluster is freed (refcount 0) while a live PTE still
 * maps it.  Counting detectors cannot see this -- the leftover PTE is uncounted
 * (its rmap is gone) and the freed cluster's refcount reached 0 normally.  So we
 * detect it *structurally*: a kthread periodically walks every user mm's page
 * tables and flags any PRESENT pte whose cluster struct page is already freed
 * (refcount 0 or back in the buddy allocator).  On the first hit it dumps the
 * owning mm/vma/addr, dump_page(), and dump_page_owner() -- whose FREE stack
 * names the path that freed the cluster while this PTE was live: the #143
 * CREATOR.  Detection happens in the walk callback (locks held); the heavy dump
 * runs after the walk returns (locks dropped).  PGCL-only; empty at PGCL==0.
 *
 * Tunable: pgcl143_ptescan.scan_ms=<ms> on the kernel command line.
 */
#include <linux/mm.h>
#include <linux/pagewalk.h>
#include <linux/sched.h>
#include <linux/sched/mm.h>
#include <linux/sched/task.h>
#include <linux/sched/signal.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/page_owner.h>
#include <linux/page-flags.h>
#include <linux/nmi.h>

#if PAGE_MMUSHIFT

static unsigned int scan_ms = 300;	/* scan interval; edit + rebuild to tune */

static bool pgcl143_fired;

struct orphan_hit {
	struct page	*pg;
	unsigned long	addr;
	unsigned long	vm_flags;
	bool		is_file;
	bool		buddy;
	bool		found;
};

static int pgcl143_pte(pte_t *pte, unsigned long addr, unsigned long next,
		       struct mm_walk *walk)
{
	struct orphan_hit *h = walk->private;
	pte_t e = ptep_get(pte);
	unsigned long pfn;
	struct page *pg;

	if (h->found || READ_ONCE(pgcl143_fired))
		return 1;
	if (!pte_present(e))
		return 0;
	pfn = pte_pfn(e);			/* cluster pfn under PGCL */
	if (!pfn_valid(pfn))
		return 0;
	pg = pfn_to_page(pfn);
	/* orphan: a live sub-PTE mapping an already-freed cluster */
	if (page_count(pg) == 0 || PageBuddy(pg)) {
		h->pg		= pg;
		h->addr		= addr;
		h->vm_flags	= walk->vma ? walk->vma->vm_flags : 0;
		h->is_file	= walk->vma && walk->vma->vm_file;
		h->buddy	= PageBuddy(pg);
		h->found	= true;
		return 1;			/* stop walk; dump outside locks */
	}
	return 0;
}

static const struct mm_walk_ops pgcl143_ops = {
	.pte_entry = pgcl143_pte,
};

static void pgcl143_scan_mm(struct task_struct *p)
{
	struct orphan_hit h = {};
	struct mm_struct *mm;

	mm = get_task_mm(p);
	if (!mm)
		return;
	if (mmap_read_trylock(mm)) {
		walk_page_range(mm, 0, TASK_SIZE, &pgcl143_ops, &h);
		mmap_read_unlock(mm);
	}
	mmput(mm);

	if (!h.found)
		return;
	if (cmpxchg(&pgcl143_fired, false, true))
		return;				/* someone else fired first */

	pr_emerg("=============== PGCL143-ORPHAN ===============\n");
	pr_emerg("present sub-PTE -> ALREADY-FREED cluster (the #143 orphan)\n");
	pr_emerg("  pid=%d comm=%s addr=%lx vm_flags=%lx (%s)%s\n",
		 task_pid_nr(p), p->comm, h.addr, h.vm_flags,
		 h.is_file ? "file" : "anon", h.buddy ? " [in buddy]" : "");
	dump_page(h.pg, "pgcl143 orphan cluster");
	/*
	 * The page_owner FREE stack below is the path that freed this cluster
	 * while the PTE above stayed present -- the #143 creator.
	 */
	dump_page_owner(h.pg);
	trigger_all_cpu_backtrace();
	pr_emerg("==============================================\n");
}

static int pgcl143_scan_fn(void *unused)
{
	pr_info("pgcl143 orphan-PTE scanner active (scan_ms=%u)\n", scan_ms);
	while (!kthread_should_stop()) {
		struct task_struct *p;

		rcu_read_lock();
		for_each_process(p) {
			if (READ_ONCE(pgcl143_fired))
				break;
			if (p->flags & PF_KTHREAD)
				continue;
			get_task_struct(p);
			rcu_read_unlock();
			pgcl143_scan_mm(p);
			rcu_read_lock();
			put_task_struct(p);
		}
		rcu_read_unlock();

		/* once fired, idle long so the dump stays readable on the console */
		msleep(READ_ONCE(pgcl143_fired) ? 60000 : scan_ms);
	}
	return 0;
}

static int __init pgcl143_ptescan_init(void)
{
	struct task_struct *t;

	t = kthread_run(pgcl143_scan_fn, NULL, "pgcl143_scan");
	if (IS_ERR(t))
		pr_err("pgcl143 scanner failed to start: %ld\n", PTR_ERR(t));
	return 0;
}
late_initcall(pgcl143_ptescan_init);

#endif /* PAGE_MMUSHIFT */
