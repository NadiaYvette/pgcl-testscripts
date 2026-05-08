#!/bin/bash
# matrix-watch.sh: stream FAIL events and per-config milestone events from a
# matrix-dispatch-all.sh run.  Each emitted stdout line becomes one Monitor
# notification.
#
# Usage: matrix-watch.sh OUTDIR DISPATCHER_PID

set -u

OUTDIR=${1:?usage: matrix-watch.sh OUTDIR DISPATCHER_PID}
DPID=${2:?}

ARCHES="x86_64 aarch64 riscv64 ppc64 s390x sparc64 loongarch64 alpha riscv32 m68k hppa mips64 arm arm-lpae hppa64 microblaze"
CONFIGS="mainline 0 2 4 6"

STATE="$OUTDIR/.watch-state"
touch "$STATE"

reported() { grep -qxF "$1" "$STATE"; }
mark()     { echo "$1" >> "$STATE"; }

# Classify a completed cell.  Emits one short status line on real failures.
# Successes (including those whose LTP subtotals were lost to console buffering
# but completed cleanly per "Autotest mode: powering off") are silent —
# milestones cover them.
classify() {
    local log=$1 cell=$2
    local rc ltp anom poweroff cow stress build_fail
    rc=$(grep "QEMU exited rc=" "$log" | tail -1 | sed 's/.*rc=//')
    ltp=$(grep "LTP subtotals:" "$log" | tail -1 | sed 's/.*LTP subtotals: //')
    # poweroff: any of several end-of-run markers (the init script's
    # "Autotest mode" echo, the sysrq-trigger output, or the architectural
    # reboot/poweroff line).  Heavy console buffering can drop the
    # "Autotest mode" line, so accept any of these as evidence the kernel
    # reached the test-finished state cleanly.
    poweroff=$(grep -cE "Autotest mode: powering off|sysrq: Power Off|reboot: Power down|reboot: machine restart" "$log" 2>/dev/null)
    cow=$(grep "cow: PASS\|cow: FAIL" "$log" 2>/dev/null | head -1)
    # PGCL stress "Results: 12 passed" (or whatever count) appears before LTP;
    # its presence is a strong signal the test loop got past selftests.
    stress=$(grep -c "PGCL stress\|--- Running LTP" "$log" 2>/dev/null)
    build_fail=$(grep -c "BUILD FAIL\|DEFCONFIG FAIL" "$log" 2>/dev/null)
    # Anomaly scan: kernel BUG/Oops/Bad page state/WARNING/Call Trace,
    # excluding the pre-existing x86_64 W+X notice, the cmdline echo, and
    # benign userspace cgroup/cfg80211 warnings.
    anom=$(grep -nE "\bBUG[: ]|\bOops|\bpanic[^=]|Bad page state|\bWARNING:|Call Trace|negative.*refcount|negative.*_mapcount" "$log" \
           | grep -vE "Kernel command line|panic=|W\+X mappings|cgroup: Unknown|cfg80211" \
           | head -1)

    local ltpfail=0
    if [ -n "$ltp" ]; then
        ltpfail=$(echo "$ltp" | grep -oE "[0-9]+ failed" | head -1)
        ltpfail=${ltpfail%% *}
        ltpfail=${ltpfail:-0}
    fi

    # Real-fail predicates, in order of severity:
    if [ "$build_fail" -gt 0 ]; then
        printf 'FAIL %s build\n' "$cell"
    elif [ -n "$anom" ]; then
        printf 'FAIL %s anomaly: %s\n' "$cell" "$anom"
    elif [ -n "$ltp" ] && [ "$ltpfail" != "0" ]; then
        printf 'FAIL %s ltp=%s\n' "$cell" "$ltp"
    elif [ "$poweroff" = "0" ] && [ "$build_fail" = "0" ]; then
        # No autotest poweroff line — the kernel hung mid-test or QEMU was killed.
        # (Build failures are caught above; this is a runtime hang.)
        printf 'FAIL %s no_poweroff rc=%s\n' "$cell" "${rc:-?}"
    fi
    # Else: cleanly powered off, no anomalies, LTP either reported 0 failed
    # or its summary was lost to console buffering — treat as PASS, stay silent.
}

# Check whether all 16 arches of a config have completed.  If so, emit milestone.
check_milestone() {
    local cfg=$1
    reported "MILESTONE_$cfg" && return 0
    local done=0 anom=0 a log cell
    for a in $ARCHES; do
        log="$OUTDIR/${a}_${cfg}.log"
        cell="${a}_${cfg}"
        if [ -f "$log" ] && grep -q "cleanup done\|BUILD FAIL" "$log" 2>/dev/null; then
            done=$((done+1))
            grep -qE "\bBUG[: ]|\bOops|Bad page state|\bWARNING:|Call Trace" "$log" 2>/dev/null \
                && grep -qvE "Kernel command line|W\+X mappings" "$log" \
                && anom=$((anom+1))
        fi
    done
    if [ "$done" = 16 ]; then
        mark "MILESTONE_$cfg"
        # Tally: count cells with LTP subtotals showing 0 failures
        local pass=0
        for a in $ARCHES; do
            log="$OUTDIR/${a}_${cfg}.log"
            grep -q "LTP subtotals: .* 0 failed" "$log" 2>/dev/null && pass=$((pass+1))
        done
        printf 'MILESTONE config=%s done=16/16 ltp_clean=%d/16 anomalous_cells=%d\n' \
            "$cfg" "$pass" "$anom"
    fi
}

# Main loop
while true; do
    for cfg in $CONFIGS; do
        for a in $ARCHES; do
            cell="${a}_${cfg}"
            log="$OUTDIR/${cell}.log"
            reported "$cell" && continue
            [ -f "$log" ] || continue
            # A cell is "done" when our driver writes "cleanup done" or a hard build fail
            if grep -q "cleanup done\|BUILD FAIL" "$log" 2>/dev/null; then
                classify "$log" "$cell"
                mark "$cell"
            fi
        done
        check_milestone "$cfg"
    done

    if ! kill -0 "$DPID" 2>/dev/null; then
        # Dispatcher exited — give a final pass for stragglers
        sleep 5
        for cfg in $CONFIGS; do
            for a in $ARCHES; do
                cell="${a}_${cfg}"
                log="$OUTDIR/${cell}.log"
                reported "$cell" && continue
                if [ -f "$log" ]; then
                    classify "$log" "$cell"
                    mark "$cell"
                else
                    printf 'FAIL %s no_log\n' "$cell"
                    mark "$cell"
                fi
            done
            check_milestone "$cfg"
        done
        # Final summary
        local_total=$(wc -l < "$STATE" | tr -d ' ')
        printf 'DISPATCHER_DONE state_lines=%s\n' "$local_total"
        exit 0
    fi
    sleep 30
done
