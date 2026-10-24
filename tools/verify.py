#!/usr/bin/env python3
"""Offline load check of a patched .tipa against an iOS dyld_shared_cache.

usage: verify.py <app.tipa> <dyld_shared_cache> <dyldex> <workdir>
  env: TARGET_IOS (the cache's iOS version, default 14.3)

For every Mach-O in the bundle: minos, chain pointer formats, every non-weak dylib
load resolvable (cache, or bundle via @rpath/@loader_path), and every non-weak
import (chained or classic binds) exported by the image its ordinal names. No
weak-lookup-only imports (chained ordinal -3, classic weak-bind without a regular
bind): 14.3 dyld2 leaves those null. LINKEDIT layout as 14.3 dyld checks it.
Exit 1 on any hard failure.
"""
import os
import plistlib
import shutil
import struct
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from machotool import (MachO, Resolver, classic_binds, weak_lookup_only, linkedit_layout_errors,
                       LC_BUILD_VERSION, LC_LOAD_WEAK_DYLIB, LC_DYLD_CHAINED_FIXUPS)


def main():
    tipa, cache, dyldex, work = sys.argv[1:5]
    t = os.environ.get('TARGET_IOS', '14.3').split('.') + ['0']
    TARGET = (int(t[0]) << 16) | (int(t[1]) << 8)
    stage = os.path.join(work, 'verify')
    shutil.rmtree(stage, ignore_errors=True)
    zipfile.ZipFile(tipa).extractall(stage)
    app = os.path.join(stage, 'Payload', os.listdir(os.path.join(stage, 'Payload'))[0])
    res = Resolver(dyldex, cache, os.path.join(work, 'dsc'))

    images = []
    for root, _, files in os.walk(app):
        for f in files:
            p = os.path.join(root, f)
            with open(p, 'rb') as fh:
                if fh.read(4) == b'\xcf\xfa\xed\xfe':
                    images.append(p)
    # @rpath candidates: the image's own rpaths, then those of every executable that
    # could load it (app and app extensions)
    exe_rpaths = []
    for img in images:
        m = MachO(open(img, 'rb').read())
        if m.filetype == 2:
            exe_rpaths += [rp.replace('@executable_path', os.path.dirname(img)) for rp in m.rpaths()]

    def locate(path, loader):
        """-> ('file', abs) | ('cache', installname) | None"""
        cands = []
        if path.startswith('@rpath/'):
            rel = path[len('@rpath/'):]
            for rp in MachO(open(loader, 'rb').read()).rpaths() + exe_rpaths:
                rp = rp.replace('@loader_path', os.path.dirname(loader))
                if '@executable_path' in rp:
                    continue
                cands.append(os.path.normpath(os.path.join(rp, rel)))
        else:
            cands.append(path.replace('@loader_path', os.path.dirname(loader)))
        for c in cands:
            if c.startswith(app):
                if os.path.exists(c):
                    return ('file', c)
            elif res.exports(c) is not None:
                return ('cache', c)
        return None

    def exports(loc):
        return res.exports(loc[1], file=loc[1]) if loc[0] == 'file' else res.exports(loc[1])

    bad = 0
    for img in sorted(images):
        m = MachO(open(img, 'rb').read())
        rel = os.path.relpath(img, app)
        minos = next((struct.unpack_from('<I', b, 12)[0] for c, b in m.cmds if c == LC_BUILD_VERSION), None)
        fmts = m.chain_formats() if m.linkedit(LC_DYLD_CHAINED_FIXUPS) else {'classic'}
        line = f'{rel}: minos {minos >> 16 if minos else "?"}.{(minos >> 8) & 0xFF if minos else ""} chains {sorted(fmts, key=str)}'
        errs, weak_missing = [], 0
        if minos and minos > TARGET:
            errs.append(f'minos {minos >> 16}.{(minos >> 8) & 0xFF} > target')
        if fmts - {2, 'classic'}:
            errs.append(f'pointer formats {fmts}')
        locs = {}
        for o, cmd, p in m.dylibs():
            loc = locate(p, img)
            locs[o] = loc
            if loc is None and cmd != LC_LOAD_WEAK_DYLIB:
                errs.append(f'missing dylib {p}')
        if m.linkedit(LC_DYLD_CHAINED_FIXUPS):
            imps = [(o, w, n) for _, _, o, w, n in m.chained_imports()]
            own = m.exports()
            wl = sorted({n for o, _, n in imps if o == 0xFD and n not in own})
        else:
            imps = classic_binds(m)
            wl = sorted({n for _, _, n in weak_lookup_only(m)})
        if wl:
            errs.append(f'weak-lookup only (null on target): {" ".join(wl)}')
        errs += [f'LINKEDIT: {e}' for e in linkedit_layout_errors(m)]
        n_checked = 0
        for o, w, n in imps:
            if o <= 0 or o >= 0xF0 or n is None:
                continue
            n_checked += 1
            loc = locs.get(o)
            ok = loc is not None and n in (exports(loc) or ())
            if not ok:
                if w:
                    weak_missing += 1
                else:
                    errs.append(f'unresolved {m.dylibs()[o - 1][2]} {n}')
        line += f', {n_checked} imports, {weak_missing} weak-missing'
        print(('FAIL ' if errs else 'ok   ') + line)
        for e in errs:
            print('     ' + e)
        bad += bool(errs)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
