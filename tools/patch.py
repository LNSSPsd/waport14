#!/usr/bin/env python3
"""Patch an iOS app built for a newer minimum iOS so it loads on an older one
(tested: iOS 14.3, TrollStore). See ../NOTES.md.

usage: patch.py <in.ipa> <out.tipa> <dyld_shared_cache> <dyldex> <workdir>
  env: THEOS, THEOS_BIN (ldid dir), CONCURRENCY (back-deploy libswift_Concurrency.dylib),
       TARGET_IOS (default 14.0), PROFILE (default profiles/<bundle id> if it exists),
       WAPORT_LOG=1 (diagnostic shim)

Every Mach-O in the bundle (app, app extensions, frameworks incl. dlopen'd ones):
  * LC_BUILD_VERSION minos -> TARGET_IOS; chained pointer format 6 -> 2
  * load commands for dylibs the target lacks: bundled replacement (libswift_Concurrency
    -> back-deploy copy via @rpath) or weak load
  * each chained import the target doesn't export, in order:
      exported by the shim (hand-written)     -> shim
      RETARGETS (symbol moved between dylibs) -> that dylib
      already weak                            -> unchanged (guarded by the app)
      callable (function / async fn pointer)  -> generated logging trap in the shim
      Swift resilient enum case tag           -> generated zero constant in the shim
      otherwise (data)                        -> weak (null)
  * weak-lookup imports (ordinal -3) -> the dylib that exports them
  * executables: + LC_LOAD_DYLIB of the shim (its constructors install the ObjC fallbacks)
Classic-bind images: weak-bind-only symbols get explicit binds (14 dyld2 leaves them null).
ExtensionKit extensions (Extensions/, iOS 16+) are removed. Info.plists: MinimumOSVersion,
UISupportedDevices. Re-sign with ldid keeping each image's own entitlements, zip as .tipa.
"""
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from machotool import (MachO, Resolver, dylib_cmd, rpath_cmd, weak_lookup_only, stub_imports,
                       append_binds, LC_BUILD_VERSION, LC_LOAD_WEAK_DYLIB, LC_LOAD_DYLIB,
                       LC_DYLD_CHAINED_FIXUPS)
import traps

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
THEOS = os.environ.get('THEOS', os.path.expanduser('~/theos'))
THEOS_BIN = os.environ.get('THEOS_BIN', os.path.join(THEOS, 'toolchain/linux/iphone/bin'))
# Swift 5.5 back-deployment runtime (iOS 13-14), shipped with theos' swift-5.8 toolchain
CONCURRENCY = os.environ.get('CONCURRENCY', os.path.join(
    THEOS, 'toolchain/swift-5.8/linux/iphone/lib/swift-5.5/iphoneos/libswift_Concurrency.dylib'))
TARGET = os.environ.get('TARGET_IOS', '14.0')
MINOS = (int(TARGET.split('.')[0]) << 16) | (int((TARGET.split('.') + ['0'])[1]) << 8)

FOUNDATION = '/System/Library/Frameworks/Foundation.framework/Foundation'
AVFAUDIO = '/System/Library/Frameworks/AVFAudio.framework/AVFAudio'
SHIM_NAME = '@rpath/libwaport.dylib'
# missing system dylib -> bundled replacement (file copied into Frameworks/)
BUNDLED = {'/usr/lib/swift/libswift_Concurrency.dylib': ('@rpath/libswift_Concurrency.dylib', CONCURRENCY)}
# symbols that lived in another dylib on older iOS
RETARGETS = {
    FOUNDATION: ['/usr/lib/swift/libswiftFoundation.dylib'],   # Swift overlay, until iOS 15
    AVFAUDIO: ['/System/Library/Frameworks/AVFoundation.framework/AVFoundation'],  # split in 14.5
}
# resolvable imports still sent to the shim when it exports them: Swift type-by-name
# lookups (mangle.m); diagnostic builds also C++ exception hooks (compat_cxx.mm),
# signal-handler wrapping and Mach exception-port blocking (log.m)
HOOKS = {'___cxa_throw', '__ZSt13set_terminatePFvvE', '_sigaction', '_signal',
         '_task_set_exception_ports', '_task_swap_exception_ports',
         '_swift_getTypeByMangledNameInContext', '_swift_getTypeByMangledNameInContextInMetadataState',
         '_swift_getTypeByMangledNameInEnvironment', '_swift_getTypeByMangledNameInEnvironmentInMetadataState'}
MH_EXECUTE = 2


def log(*a):
    print(*a, flush=True)


class Ctx:
    def __init__(self, res, app, shim):
        self.res, self.app, self.fw = res, app, os.path.join(app, 'Frameworks')
        self.shim = shim
        self.memo = {}

    def exports(self, path):
        """Exports of a load-command path as seen from the app on the target (None = absent)."""
        if path not in self.memo:
            if path in BUNDLED:
                self.memo[path] = self.res.exports(BUNDLED[path][0], file=BUNDLED[path][1])
            elif path.startswith('@rpath/'):
                rel = path[len('@rpath/'):]
                f = os.path.join(self.fw, rel)
                if rel == 'libwaport.dylib':
                    f = self.shim
                if os.path.exists(f):
                    self.memo[path] = self.res.exports(path, file=f)
                else:
                    self.memo[path] = self.res.exports('/usr/lib/swift/' + rel)   # LC_RPATH /usr/lib/swift
            else:
                self.memo[path] = self.res.exports(path)
        return self.memo[path]

    def reset_shim(self, shim):
        self.shim = shim
        self.memo.pop(SHIM_NAME, None)
        self.res.memo.pop(shim, None)


def exporting_ordinal(m, sym, ctx):
    """First non-weak dylib ordinal of m whose exports (on target) contain sym, or None."""
    for o, cmd, p in m.dylibs():
        if cmd != LC_LOAD_WEAK_DYLIB and sym in (ctx.exports(p) or ()):
            return o
    return None


def plan_image(m, ctx):
    """[(entry_offset, action, target, sym, from_path)] for chained imports to change.
    action: 'to' (bind to target dylib), 'shim', 'trap' (shim, generated), 'weak'."""
    ords = {o: p for o, _, p in m.dylibs()}
    shim_ex = ctx.exports(SHIM_NAME)
    plan = []
    for i, eo, o, weak, sym in m.chained_imports():
        if o in (0, 0xFD, 0xFE, 0xFF):       # self / weak-lookup / flat / main
            continue
        p = ords[o]
        if p == SHIM_NAME:
            continue
        if sym in HOOKS and sym in shim_ex:
            plan.append((eo, 'shim', SHIM_NAME, sym, p))
            continue
        ex = ctx.exports(p)
        if ex is not None and sym in ex:
            continue
        if sym in shim_ex:
            plan.append((eo, 'shim', SHIM_NAME, sym, p))
            continue
        alt = next((t for t in RETARGETS.get(p, ()) if sym in (ctx.exports(t) or ())), None)
        if alt:
            plan.append((eo, 'to', alt, sym, p))
        elif not weak:   # already-weak imports are guarded (availability / null checks): leave null
            plan.append((eo, 'trap?', None, sym, p))
    return plan


def patch_chained(path, m, plan, kinds, ctx, report):
    name = os.path.relpath(path, ctx.app)
    for c in m.cmds:
        if c[0] == LC_BUILD_VERSION and struct.unpack_from('<I', c[1], 12)[0] > MINOS:
            b = bytearray(c[1])
            struct.pack_into('<I', b, 12, MINOS)
            c[1] = bytes(b)
    if m.chain_formats() != {2}:
        r, b = m.convert_chains_6_to_2()
        report.append(f'{name}: chains 6->2, {r} rebases, {b} binds')

    fix_load_commands(m, name, ctx, report)
    need = set()
    final = []
    for eo, act, target, sym, frm in plan:
        if act == 'trap?':
            k = kinds[sym][0]
            act, target = ('trap', SHIM_NAME) if k in ('func', 'async', 'enumcase') else ('weak', None)
        final.append((eo, act, target, sym, frm))
        if target:
            need.add(target)
    if m.filetype == MH_EXECUTE:
        need.add(SHIM_NAME)
    by_path = {p: o for o, _, p in m.dylibs()}
    for target in sorted(need - set(by_path)):
        m.cmds.append(dylib_cmd(LC_LOAD_DYLIB, target))
        report.append(f'{name}: + LC_LOAD_DYLIB {target}')
    m.write_cmds()
    by_path = {p: o for o, _, p in m.dylibs()}

    counts = {}
    for eo, act, target, sym, frm in final:
        if target:
            m.set_import(eo, ordinal=by_path[target])
        else:
            m.set_import(eo, weak=True)
        key = f'{act} {os.path.basename(frm)}' + (f' -> {os.path.basename(target)}' if act == 'to' else '')
        counts[key] = counts.get(key, 0) + 1
    for k, v in sorted(counts.items()):
        report.append(f'{name}: {v:5d} {k}')

    # weak-lookup (-3) imports not defined here -> concrete ordinal
    own = m.exports()
    wl, unres = [], []
    for i, eo, o, weak, sym in m.chained_imports():
        if o == 0xFD and sym not in own:
            t = exporting_ordinal(m, sym, ctx)
            if t:
                m.set_import(eo, ordinal=t)
                wl.append(sym)
            else:
                unres.append(sym)
    if wl:
        report.append(f'{name}: {len(wl):5d} weak-lookup -> explicit')
    for s in unres:
        report.append(f'{name}: WARNING weak-lookup {s} exported by no dependency (stays null on 14)')
    open(path, 'wb').write(m.d)


def fix_load_commands(m, name, ctx, report):
    """Dylibs absent on the target: bundled replacement, else weak load."""
    need_swift_rpath = False
    for c in m.cmds:
        if c[0] not in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            continue
        no = struct.unpack_from('<I', c[1], 8)[0]
        p = c[1][no:].split(b'\0')[0].decode()
        if p in BUNDLED:
            cur, compat = struct.unpack_from('<II', c[1], 16)
            c[:] = dylib_cmd(c[0], BUNDLED[p][0], cur, compat)
            need_swift_rpath = True
            report.append(f'{name}: {p} -> {BUNDLED[p][0]} (bundled)')
        elif c[0] == LC_LOAD_DYLIB and ctx.exports(p) is None:
            b = bytearray(c[1])
            struct.pack_into('<I', b, 0, LC_LOAD_WEAK_DYLIB)
            c[:] = [LC_LOAD_WEAK_DYLIB, bytes(b)]
            report.append(f'{name}: {p} absent -> weak load')
    if need_swift_rpath and '/usr/lib/swift' not in m.rpaths():
        m.cmds.append(rpath_cmd('/usr/lib/swift'))
        report.append(f'{name}: + LC_RPATH /usr/lib/swift')


def patch_classic(path, m, ctx, report):
    """minos, plus explicit binds for weak-bind-only symbols (machotool.weak_lookup_only)."""
    name = os.path.relpath(path, ctx.app)
    for c in m.cmds:
        if c[0] == LC_BUILD_VERSION and struct.unpack_from('<I', c[1], 12)[0] > MINOS:
            b = bytearray(c[1])
            struct.pack_into('<I', b, 12, MINOS)
            c[1] = bytes(b)
    binds = []
    for seg, so, sym in weak_lookup_only(m):
        o = exporting_ordinal(m, sym, ctx)
        assert o, f'{name}: no dylib exports weak-lookup {sym}'
        binds.append((seg, so, o, sym))
    if binds:
        append_binds(m, binds)
        report.append(f'{name}: {len(binds)} weak-bind-only -> explicit bind: '
                      + ' '.join(sorted({s for *_, s in binds})))
    else:
        m.write_cmds()
    open(path, 'wb').write(m.d)


def set_min_os(plist_path):
    """MinimumOSVersion -> TARGET if higher; drop App Store thinning's UISupportedDevices."""
    raw = open(plist_path, 'rb').read()
    pl = plistlib.loads(raw)
    fmt = plistlib.FMT_BINARY if raw[:6] == b'bplist' else plistlib.FMT_XML
    old = pl.get('MinimumOSVersion')
    changed = []
    if old and tuple(map(int, old.split('.'))) > tuple(map(int, TARGET.split('.'))):
        pl['MinimumOSVersion'] = TARGET
        changed.append(f'MinimumOSVersion {old} -> {TARGET}')
    if pl.pop('UISupportedDevices', None):
        changed.append('UISupportedDevices removed')
    if changed:
        with open(plist_path, 'wb') as f:
            plistlib.dump(pl, f, fmt=fmt)
    return changed


def ldid(*args):
    r = subprocess.run([os.path.join(THEOS_BIN, 'ldid'), *args], capture_output=True)
    if r.returncode:
        raise SystemExit(f'ldid {args}: {r.stderr.decode()}')
    return r.stdout


def build_shim(work, traps_s=None, extra=()):
    out = os.path.join(work, 'shim')
    args = [os.path.join(HERE, 'src/build-shim.sh'), out]
    if traps_s or extra:
        args.append(traps_s or '')
    subprocess.run(args + list(extra), check=True, stdout=subprocess.DEVNULL)
    return os.path.join(out, 'libwaport.dylib')


def macho_files(app):
    out = []
    for root, dirs, files in os.walk(app):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            with open(p, 'rb') as fh:
                magic = fh.read(4)
            if magic == b'\xcf\xfa\xed\xfe':
                out.append(p)
            elif magic in (b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
                raise SystemExit(f'{p}: fat Mach-O, thin it to arm64 first')
    return out


def main():
    ipa, out, cache, dyldex, work = sys.argv[1:6]
    for f, what in ((CONCURRENCY, 'libswift_Concurrency (set CONCURRENCY)'),
                    (os.path.join(THEOS_BIN, 'ldid'), 'ldid (set THEOS or THEOS_BIN)'),
                    (traps.DEMANGLE, 'swift-demangle (set SWIFT_DEMANGLE)')):
        if not os.path.exists(f):
            raise SystemExit(f'missing {what}: {f}')
    stage = os.path.join(work, 'stage')
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    with zipfile.ZipFile(ipa) as z:
        z.extractall(stage)
        for zi in z.infolist():   # zipfile drops modes; restore exec bits
            mode = zi.external_attr >> 16
            if mode:
                os.chmod(os.path.join(stage, zi.filename), mode & 0o7777)

    app = os.path.join(stage, 'Payload', os.listdir(os.path.join(stage, 'Payload'))[0])
    info = plistlib.load(open(os.path.join(app, 'Info.plist'), 'rb'))
    bid, ver = info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString')
    log(f'{bid} {ver} (MinimumOSVersion {info.get("MinimumOSVersion")}) -> iOS {TARGET}')
    profile = os.environ.get('PROFILE', os.path.join(HERE, 'profiles', bid))
    extra = []
    if os.path.isdir(profile):
        pj = os.path.join(profile, 'profile.json')
        prof = json.load(open(pj)) if os.path.exists(pj) else {}
        if ver not in prof.get("tested_versions", []):
            log(f'WARNING: {ver} not on-device tested (profile: {prof.get("tested_versions") or "none yet"})')
        extra = sorted(os.path.join(profile, f) for f in os.listdir(profile) if f.endswith(('.m', '.mm', '.S', '.c')))
        log(f'profile {profile}: {len(extra)} source(s)')
    report = []

    ext = os.path.join(app, 'Extensions')
    if os.path.isdir(ext):
        shutil.rmtree(ext)
        report.append('Extensions/ (ExtensionKit, iOS 16+) removed')

    images = macho_files(app)
    ents = {}
    for p in images:
        e = ldid('-e', p)
        if e.strip():
            ents[p] = os.path.join(work, 'ents', os.path.relpath(p, app).replace('/', '__') + '.plist')
            os.makedirs(os.path.dirname(ents[p]), exist_ok=True)
            open(ents[p], 'wb').write(e)

    # pass 1: plan against the hand-written shim, collect what needs generated traps
    res = Resolver(dyldex, cache, os.path.join(work, 'dsc'))
    ctx = Ctx(res, app, build_shim(work, None, extra))
    machos = {p: MachO(open(p, 'rb').read()) for p in images}
    plans = {p: plan_image(m, ctx) for p, m in machos.items() if m.linkedit(LC_DYLD_CHAINED_FIXUPS)}
    missing = sorted({sym for pl in plans.values() for _, a, _, sym, _ in pl if a == 'trap?'})
    called = set()
    for p in plans:
        imps = machos[p].chained_imports()
        called |= {imps[i][4] for i in stub_imports(machos[p])}
    kinds = traps.classify(missing, called)
    gen = {s: k for s, (k, _) in kinds.items() if k != 'data'}
    traps_s = os.path.join(work, 'traps.S')
    open(traps_s, 'w').write(traps.gen_asm(gen))
    with open(os.path.join(work, 'missing.txt'), 'w') as f:
        for s in missing:
            f.write(f'{kinds[s][0]:8s} {s[1:]}\t{kinds[s][1]}\n')
    by_kind = {}
    for k, _ in kinds.values():
        by_kind[k] = by_kind.get(k, 0) + 1
    report.append(f'missing on target: {len(missing)} symbols {by_kind} (list: {work}/missing.txt)')

    # pass 2: shim with traps, then patch
    shim = build_shim(work, traps_s, extra)
    ctx.reset_shim(shim)
    fw = os.path.join(app, 'Frameworks')
    os.makedirs(fw, exist_ok=True)
    shutil.copy2(shim, fw)
    shutil.copy2(CONCURRENCY, fw)
    for p, m in machos.items():
        if p in plans:
            patch_chained(p, m, plans[p], kinds, ctx, report)
        else:
            patch_classic(p, m, ctx, report)

    for root, dirs, files in os.walk(app):
        if 'Info.plist' in files and root.endswith(('.app', '.appex', '.framework')):
            pl = os.path.join(root, 'Info.plist')
            for ch in set_min_os(pl):
                report.append(f'{os.path.relpath(pl, app)}: {ch}')

    if os.environ.get('WAPORT_LOG') == '1':   # waport.log reachable in Files -> On My iPhone
        pl = os.path.join(app, 'Info.plist')
        raw = open(pl, 'rb').read()
        d = plistlib.loads(raw)
        d['UIFileSharingEnabled'] = True
        plistlib.dump(d, open(pl, 'wb'), fmt=plistlib.FMT_BINARY if raw[:6] == b'bplist' else plistlib.FMT_XML)
        report.append('Info.plist: UIFileSharingEnabled (diagnostic build)')

    # app extensions may raise their jetsam limit (src/memlimit.m): 14's dyld dirties every
    # bound data page at load, so extensions linking an app's big frameworks start near it
    for p in images:
        if os.path.dirname(p).endswith('.appex') and os.path.basename(p) == \
                os.path.splitext(os.path.basename(os.path.dirname(p)))[0]:
            if p not in ents:
                ents[p] = os.path.join(work, 'ents', os.path.relpath(p, app).replace('/', '__') + '.plist')
                os.makedirs(os.path.dirname(ents[p]), exist_ok=True)
                plistlib.dump({}, open(ents[p], 'wb'))
            d = plistlib.loads(open(ents[p], 'rb').read())
            if not d.get('com.apple.private.memorystatus'):
                d['com.apple.private.memorystatus'] = True
                plistlib.dump(d, open(ents[p], 'wb'))
                report.append(f'{os.path.relpath(p, app)}: + com.apple.private.memorystatus')
    for p in images + [os.path.join(fw, 'libwaport.dylib'), os.path.join(fw, 'libswift_Concurrency.dylib')]:
        ldid('-S' + ents[p] if p in ents else '-S', p)
    report.append(f're-signed {len(images) + 2} images (ldid), {len(ents)} with their original entitlements')

    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(os.path.join(stage, 'Payload')):
            dirs.sort()
            for f in sorted(files):
                full = os.path.join(root, f)
                zi = zipfile.ZipInfo.from_file(full, os.path.relpath(full, stage))
                zi.compress_type = zipfile.ZIP_DEFLATED
                with open(full, 'rb') as fh:
                    z.writestr(zi, fh.read())
    report.append(f'wrote {out}')
    log('\n'.join(report))


if __name__ == '__main__':
    main()
