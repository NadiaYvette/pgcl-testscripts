#!/bin/bash
# setup-cpu-partitions.sh — exclusive CPU partitioning for pgcl(#143) vs Telix.
#
# Install setuid root so each unprivileged worker can (re)establish the partitions
# and move its own tasks in without a root shell:
#     sudo chown root setup-cpu-partitions.sh && sudo chmod u+s setup-cpu-partitions.sh
# NOTE: many kernels ignore the setuid bit on script files. If so, either add a
# NOPASSWD sudoers entry for this exact path, or drop in a 3-line setuid-root C
# wrapper that exec()s this script.
#
# TOPOLOGY (this box, Raptor Lake-P):
#   6 P-cores w/ HT  -> CPUs 0-11   (P0=0,1 P1=2,3 P2=4,5 P3=6,7 P4=8,9 P5=10,11)
#   8 E-cores        -> CPUs 12-19, sharing L2 in clusters of 4:
#                       cluster-0 = 12-15, cluster-1 = 16-19
#
# PARTITION LAYOUT (edit CPUS[] below to re-cut):
#   pgcl  : 12-19   all 8 E-cores; -smp 8 maps 1:1 (no oversubscription) and pgcl
#                   owns BOTH E-clusters, so no L2 sharing with Telix.
#   telix : 0-9,11  11 P-core threads (fast cores for CPU-heavy Telix).
#   system/interaction : CPU 10 (one P-core thread) stays in the root partition.
#
# Usage:
#   setup-cpu-partitions.sh setup                  create/refresh the partitions
#   setup-cpu-partitions.sh join pgcl|telix [PID]  move PID (default: caller) in
#   setup-cpu-partitions.sh status
#   setup-cpu-partitions.sh teardown
set -u
CG=/sys/fs/cgroup
OWNER_UID=1000
declare -A CPUS=( [pgcl]="12-19" [telix]="0-9,11" )

need_root() { [ "$(id -u)" = 0 ] || { echo "must be root (setuid/sudo)"; exit 1; }; }

do_setup() {
	need_root
	grep -qw cpuset "$CG/cgroup.controllers" || { echo "no cpuset controller"; exit 1; }
	grep -qw cpuset "$CG/cgroup.subtree_control" 2>/dev/null \
		|| echo +cpuset > "$CG/cgroup.subtree_control"
	for part in pgcl telix; do
		d="$CG/$part"
		mkdir -p "$d"
		echo "${CPUS[$part]}" > "$d/cpuset.cpus"
		# claim the cpus exclusively, then make it an ISOLATED partition
		# (isolated => removed from the general scheduler's load balancing, so
		# nothing else is scheduled there: true exclusion, not just affinity).
		echo "${CPUS[$part]}" > "$d/cpuset.cpus.exclusive" 2>/dev/null || true
		if ! echo isolated > "$d/cpuset.cpus.partition" 2>/dev/null; then
			echo root > "$d/cpuset.cpus.partition" 2>/dev/null \
				|| echo "WARN: $part is cpus-confined but not a partition"
		fi
		# let the owner move its own tasks in/out without root afterwards
		chown "$OWNER_UID" "$d/cgroup.procs" "$d/cgroup.threads" 2>/dev/null || true
		echo "$part: cpus=$(cat "$d/cpuset.cpus") partition=$(cat "$d/cpuset.cpus.partition" 2>/dev/null)"
	done
}

do_join() {
	need_root
	part="${2:?part}"; pid="${3:-$PPID}"
	[ -d "$CG/$part" ] || { echo "partition $part not set up"; exit 1; }
	echo "$pid" > "$CG/$part/cgroup.procs" && echo "moved pid $pid -> $part"
}

do_status() {
	for part in pgcl telix; do
		d="$CG/$part"
		[ -d "$d" ] || { echo "$part: (absent)"; continue; }
		echo "$part: cpus=$(cat "$d/cpuset.cpus" 2>/dev/null) partition=$(cat "$d/cpuset.cpus.partition" 2>/dev/null) procs=$(wc -l < "$d/cgroup.procs" 2>/dev/null)"
	done
	echo "effective root cpus: $(cat "$CG/cpuset.cpus.effective" 2>/dev/null)"
}

do_teardown() {
	need_root
	for part in pgcl telix; do
		d="$CG/$part"
		[ -d "$d" ] || continue
		echo member > "$d/cpuset.cpus.partition" 2>/dev/null || true
		while read -r p; do echo "$p" > "$CG/cgroup.procs" 2>/dev/null || true; done \
			< "$d/cgroup.procs" 2>/dev/null
		rmdir "$d" 2>/dev/null || echo "WARN: $part not removed (still populated)"
	done
}

case "${1:-status}" in
	setup)    do_setup ;;
	join)     do_join "$@" ;;
	status)   do_status ;;
	teardown) do_teardown ;;
	*) echo "usage: $0 {setup | join pgcl|telix [PID] | status | teardown}"; exit 1 ;;
esac
