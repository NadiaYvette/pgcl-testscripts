#!/usr/bin/env python3
"""
kmsg-vocab.py - extract a closed-set vocabulary of kernel log format strings,
tagged with source file:line and boot stage, for matching noisy OCR reads of a
frozen console (see framestack.py) back to the exact emitting source line.

It scans the given files/dirs for printk-family / decompressor / EFI-stub call
sites, pulls the (C-adjacent-concatenated) string-literal format argument, folds
in the file's pr_fmt() prefix for pr_* calls, normalizes whitespace/escapes, and
writes a TSV:  stage <TAB> file:line <TAB> format-string

Heuristic, deliberately over-inclusive: extra candidates are harmless to a
fuzzy matcher, a missing one is not.  Use with kmsg-match.py.
"""
import argparse
import glob
import os
import re
import sys

CALL = re.compile(
    r'\b('
    r'printk(?:_deferred|_once|_ratelimited)?|'
    r'pr_(?:emerg|alert|crit|err|warn|warning|notice|info|cont|debug)|'
    r'panic|BUG|WARN(?:_ON(?:_ONCE)?|_ONCE)?|'
    r'early_printk|earlyprintk|'
    r'efi_(?:printk|info|err|warn|puts)|'
    r'debug_putstr|__putstr|putstr|puts|error|warn'
    r')\s*\(')
STR = re.compile(r'"((?:\\.|[^"\\])*)"')
PRFMT = re.compile(r'#\s*define\s+pr_fmt\s*\([^)]*\)\s+(.*)')


def match_paren(s, i):
    """i indexes '('; return index just past the matching ')'."""
    depth = 0
    while i < len(s):
        c = s[i]
        if c == '"':
            i += 1
            while i < len(s) and s[i] != '"':
                i += 2 if s[i] == '\\' else 1
        elif c == "'":
            i += 1
            while i < len(s) and s[i] != "'":
                i += 2 if s[i] == '\\' else 1
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(s)


def norm(fmt):
    fmt = (fmt.replace('\\n', ' ').replace('\\t', ' ')
              .replace('\\"', '"').replace('\\\\', '\\'))
    return re.sub(r'\s+', ' ', fmt).strip()


def alnum_len(s):
    return sum(c.isalnum() for c in s)


def stage_of(path):
    if 'boot/compressed' in path:
        return 'decompress'
    if 'libstub' in path:
        return 'efistub'
    if '/arch/x86/boot/' in path:
        return 'realmode'
    if path.endswith('init/main.c'):
        return 'start_kernel'
    if '/mm/' in path or '/arch/x86/mm/' in path:
        return 'early-mm'
    return 'early-kernel'


def scan(path):
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return []
    prefix = ''
    m = PRFMT.search(txt)
    if m:
        lits = STR.findall(m.group(1))
        if lits and '%' not in lits[0]:
            prefix = lits[0]
    out = []
    stage = stage_of(path)
    rel = path
    for cm in CALL.finditer(txt):
        fn = cm.group(1)
        op = txt.find('(', cm.end() - 1)
        if op < 0:
            continue
        end = match_paren(txt, op)
        arg = txt[op + 1:end]
        # first argument only (up to top-level comma) is enough for the fmt
        lits = STR.findall(arg)
        if not lits:
            continue
        fmt = norm(''.join(lits))
        if fn.startswith('pr_') and prefix:
            fmt = norm(prefix) + fmt
        if alnum_len(fmt) < 3:
            continue
        line = txt.count('\n', 0, cm.start()) + 1
        out.append((stage, f'{rel}:{line}', fmt))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('paths', nargs='+', help='source files or directories')
    ap.add_argument('-r', '--root', default='', help='strip this prefix from paths')
    ap.add_argument('-o', '--out', help='output TSV (default stdout)')
    args = ap.parse_args()

    files = []
    for p in args.paths:
        if os.path.isdir(p):
            for ext in ('*.c', '*.h', '*.S'):
                files += glob.glob(os.path.join(p, '**', ext), recursive=True)
        else:
            files.append(p)

    seen = set()
    rows = []
    for f in sorted(set(files)):
        for stage, loc, fmt in scan(f):
            if args.root and loc.startswith(args.root):
                loc = loc[len(args.root):].lstrip('/')
            key = (loc, fmt)
            if key in seen:
                continue
            seen.add(key)
            rows.append((stage, loc, fmt))

    fh = open(args.out, 'w') if args.out else sys.stdout
    for r in rows:
        fh.write('\t'.join(r) + '\n')
    if args.out:
        fh.close()
    sys.stderr.write(f'{len(rows)} format strings from {len(files)} files\n')
    from collections import Counter
    for s, n in Counter(r[0] for r in rows).most_common():
        sys.stderr.write(f'  {s:14} {n}\n')


if __name__ == '__main__':
    main()
