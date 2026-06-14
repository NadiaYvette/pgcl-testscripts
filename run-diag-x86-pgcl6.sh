#!/bin/bash
set -u
O=/home/nyc/src/pgcl/diag-x86-pgcl6-out; mkdir -p "$O"
echo "######## DIAG x86_64 PGCL=6 un-silenced + earlyprintk $(date +%H:%M:%S) ########"
BIGRAM_DEBUG=1 EXTRA_APPEND="page_owner=on earlyprintk=serial,ttyS0 ignore_loglevel" MATRIX_J=12 \
  bash /home/nyc/src/pgcl/diag-x86-pgcl6.sh /home/nyc/src/linux x86_64 6 "$O"
echo "######## DIAG verdict $(date +%H:%M:%S) ########"
L="$O/x86_64_6.log"
if grep -q 'Run /init as init process' "$L"; then echo "RESULT: BOOTED-OK (was transient)"; 
elif grep -qiE 'Bad page state|kernel BUG|free_page_is_bad|print_bad_pte' "$L"; then echo "RESULT: REAL-CORRUPTION-MARKER"; 
elif grep -q 'Booting from ROM' "$L" && ! grep -qiE 'Linux version|console \[' "$L"; then echo "RESULT: KERNEL-NEVER-CONSOLED (image/boot-path issue)"; 
else echo "RESULT: OTHER — inspect log"; fi
echo "--- last 25 log lines ---"; tail -25 "$L"
