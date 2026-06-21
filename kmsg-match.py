#!/usr/bin/env python3
"""
kmsg-match.py - snap a noisy OCR read of a kernel console line to the most
likely source format string (and its file:line) from a vocabulary built by
kmsg-vocab.py.

The closed-set half of the framestack.py workflow: stacking cleans the image,
this resolves the residual glyph ambiguity against the finite set of strings the
kernel can actually print.  printf specifiers in candidates are stripped before
comparison (the screen shows substituted values, not "%lu"), and partial reads
(the camera caught only part of a line) are scored by best-substring overlap.

Usage:
  kmsg-match.py -v vocab.tsv "Decmpressing Linx..."      # query on argv
  echo "BUG unabl to handl page faul" | kmsg-match.py -v vocab.tsv
"""
import argparse
import difflib
import re
import sys

SPEC = re.compile(r'%[-#0 +]*[0-9.*]*(?:[hljztL]|hh|ll)*[diouxXeEfFgGaAcspn%]')


def norm(s):
    s = SPEC.sub('', s)
    s = s.lower()
    s = re.sub(r'[^a-z0-9]+', ' ', s)
    return re.sub(r'\s+', ' ', s).strip()


def score(q, cand):
    if not q or not cand:
        return 0.0
    full = difflib.SequenceMatcher(None, q, cand, autojunk=False).ratio()
    # partial reads: best match of the query against a same-length window of the
    # candidate, so a faithful fragment scores high but tokens merely scattered
    # across a long line do not.
    best = full
    if len(cand) > len(q):
        w = len(q)
        step = max(1, w // 8)
        for i in range(0, len(cand) - w + 1, step):
            r = difflib.SequenceMatcher(None, q, cand[i:i + w],
                                        autojunk=False).ratio()
            if r > best:
                best = r
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-v', '--vocab', required=True, help='vocab TSV from kmsg-vocab.py')
    ap.add_argument('-k', '--top', type=int, default=8, help='results to show')
    ap.add_argument('query', nargs='*', help='OCR text (else read stdin)')
    args = ap.parse_args()

    rows = []
    for ln in open(args.vocab, encoding='utf-8'):
        p = ln.rstrip('\n').split('\t')
        if len(p) == 3:
            rows.append((p[0], p[1], p[2], norm(p[2])))

    q = ' '.join(args.query) if args.query else sys.stdin.read()
    qn = norm(q)
    if not qn:
        sys.exit('empty query')

    ranked = sorted(rows, key=lambda r: score(qn, r[3]), reverse=True)
    print(f'query: {q.strip()!r}\n')
    for stage, loc, fmt, cn in ranked[:args.top]:
        print(f'{score(qn, cn):.2f}  {stage:12}  {loc}')
        print(f'        {fmt}')


if __name__ == '__main__':
    main()
