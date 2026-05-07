#!/bin/bash
# m68k — virt machine needs Goldfish RTC + TTY for console.
# Per MEMORY.md: QEMU 10.1.4 m68k -M virt produces zero kernel output regardless
# of -cpu (open infra issue, not yet resolved upstream).  Cell will time out
# silently; the longer timeout here is for any future fix.
scripts/config --file "$KBUILD/.config" --enable GOLDFISH --enable GOLDFISH_TTY
TIMEOUT=900
