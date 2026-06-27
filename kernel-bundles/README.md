# PGCL kernel branches — thin git bundle (non-US-mirror durability)

Framagit and Disroot can't host a full Linux kernel repository, so the kernel
branches are preserved here as a **thin git bundle** instead. This file lives in
`pgcl-testscripts`, which is mirrored to all four hosts (Disroot/NL, Framagit/FR,
SourceHut, GitHub) — so the kernel work survives even if the GitHub/SourceHut
*git* mirrors (the only two that can hold the full tree) are lost.

The full git remotes for the kernel tree remain:
- SourceHut — https://git.sr.ht/~nadiayvette/linux-pgcl
- GitHub — https://github.com/NadiaYvette/linux

## What's in `pgcl-branches.bundle`

A *thin* bundle: only the objects introduced by the PGCL branches, **not** the
mainline base. It carries three refs:

- `nadia.chambers/page-clustering-001` — full development tree
- `nadia.chambers/pgcl-mmupage-mapcount` — rmap/mapcount working branch
  (includes the #146 + anon-exclusive-WARN-guard byproduct fixes)
- `pgcl-rfc-v1` — the posted RFC series

**Base required to unbundle:** Linux **v7.1** (commit `8cd9520d35a6`). The bundle
is useless without it — that's what makes it ~900 K instead of gigabytes.

## Restore

```sh
# 1. Get a mainline tree at v7.1:
git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git fetch --tags origin            # ensures v7.1 (8cd9520d35a6) is present

# 2. Verify and pull the PGCL branches out of the bundle:
git bundle verify /path/to/pgcl-branches.bundle
git fetch /path/to/pgcl-branches.bundle 'refs/heads/*:refs/heads/*'
# -> branches nadia.chambers/page-clustering-001,
#    nadia.chambers/pgcl-mmupage-mapcount, pgcl-rfc-v1 are now local.
```

If kernel.org no longer serves v7.1, any archive of commit `8cd9520d35a6`
(its tree is byte-identical to the v7.1 release) suffices as the base.

## Regenerate (to refresh after new commits)

```sh
cd <linux-pgcl-worktree>
git bundle create pgcl-branches.bundle ^v7.1 \
    nadia.chambers/page-clustering-001 \
    nadia.chambers/pgcl-mmupage-mapcount \
    pgcl-rfc-v1
```

Then replace this directory's copy and commit. The human-readable patch-series
form of the posted series is also kept, in `../rfc-v1/`.
