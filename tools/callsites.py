#!/usr/bin/env python3
"""Approximate call-site counts per chained import: adjacent ADRP+LDR (64-bit, unsigned
offset) pairs in __text that load a GOT slot bound to that import. Analysis aid only.

usage: callsites.py <image> [filter-substring]   -> '<count> <dylib> <symbol>'
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from machotool import MachO, slot_imports


def main():
    m = MachO(open(sys.argv[1], 'rb').read())
    flt = sys.argv[2] if len(sys.argv) > 2 else None
    imps = m.chained_imports()
    dyl = {o: p for o, _, p in m.dylibs()}
    slots = slot_imports(m)
    text = next(s for seg in m.segments() for s in seg[5] if s[0] == '__text')
    _, addr, size, off, _ = text
    w = np.frombuffer(bytes(m.d[off:off + size]), dtype='<u4')
    pc = addr + 4 * np.arange(len(w), dtype=np.int64)
    a, l = w[:-1], w[1:]
    is_adrp = (a & 0x9F000000) == 0x90000000
    is_ldr = (l & 0xFFC00000) == 0xF9400000
    same = (a & 0x1F) == ((l >> 5) & 0x1F)
    sel = np.nonzero(is_adrp & is_ldr & same)[0]
    a, l, p = a[sel].astype(np.int64), l[sel].astype(np.int64), pc[sel]
    imm = ((a >> 29) & 3) | (((a >> 5) & 0x7FFFF) << 2)
    imm = np.where(imm & (1 << 20), imm - (1 << 21), imm)
    tgt = (p & ~0xFFF) + (imm << 12) + ((l >> 10) & 0xFFF) * 8
    counts = {}
    for t, c in zip(*np.unique(tgt, return_counts=True)):
        i = slots.get(int(t))
        if i is not None:
            counts[i] = counts.get(i, 0) + int(c)
    for i, eo, o, weak, name in imps:
        if flt and flt not in name and flt not in dyl.get(o, ''):
            continue
        print(counts.get(i, 0), dyl.get(o, o), name)


if __name__ == '__main__':
    main()
