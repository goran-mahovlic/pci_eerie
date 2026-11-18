#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-P-2.0
"""analiza_snimke.py <uart.txt> — dekodira snimku eerie_dbg_uart (redci 'Tt aaa LLdddddd'), TASK-6160.
Ispis: po riječi ltssm, rxvalid, pol, dva simbola (K-ime ili hex, /status), plus sažetak."""
import re, sys, collections
K = {0xBC: 'COM', 0xF7: 'PAD', 0x1C: 'SKP', 0xFB: 'STP', 0x5C: 'SDP', 0xFD: 'END', 0xFE: 'EDB', 0x7C: 'IDL', 0x3C: 'FTS'}
w = [int(m.group(1), 16) for m in re.finditer(r'^T[a-e] [0-9a-f]{3} ([0-9a-f]{8})$', open(sys.argv[1], errors='replace').read(), re.M)]
def sym(b):
    d, k, st = b & 0xFF, (b >> 8) & 1, (b >> 9) & 7
    t = K.get(d, 'K%02x' % d) if k else '%02x' % d
    return t + ('/%d' % st if st else '')
rows = []
for x in w:
    lt, rv, pol = x >> 26, (x >> 25) & 1, (x >> 24) & 1
    rows.append((lt, rv, pol, sym(x & 0xFFF), sym((x >> 12) & 0xFFF)))
print('riječi', len(rows), 'rxvalid=1:', sum(r[1] for r in rows), 'status!=0 simbola:', sum(('/' in r[3]) + ('/' in r[4]) for r in rows))
print('ltssm po riječima:', collections.Counter(r[0] for r in rows))
prev = None
for i, r in enumerate(rows):
    key = (r[0], r[1], r[2])
    if key != prev: print('\n[%03x] ltssm=%02x rxvalid=%d pol=%d :' % (i, *key), end=' ')
    print(r[3], r[4], end=' | ')
    prev = key
print()
