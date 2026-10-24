#!/usr/bin/env python3
"""List iOS 14.4-15.1 ObjC methods the app may call unguarded on iOS 14 (target 14.3).

usage: scan_objc.py <Payload/X.app> [new.sdk] [old.sdk]
  default SDKs: $THEOS/sdks/iPhoneOS16.5.sdk (annotations), iPhoneOS14.5.sdk (baseline)

A min-15.1 build drops @available checks for APIs <= 15.1, so any such selector the
app references may be sent on 14. Candidates = selectors in the app's __objc_methname
that the new SDK declares on some class/protocol as introduced in iOS 15.0 or 15.1,
minus (class, selector) pairs the old SDK already declares (catches name collisions
like scrollEdgeAppearance: iOS 13 on UINavigationBar, 15 on UIToolbar).
14.4/14.5 APIs are in the 14.5 SDK, so for those the baseline is iPhoneOS13.7.sdk
(the target is 14.3, so anything introduced after it is missing).
Output: '<intro> <+|-> <Class|<Protocol>> <selector>' sorted, one per line.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from machotool import MachO

THEOS = os.environ.get('THEOS', os.path.expanduser('~/theos'))

AVAIL = re.compile(r'(?:API_AVAILABLE|NS_AVAILABLE_IOS|API_DEPRECATED[^(]*|UIKIT_AVAILABLE)?\(([^()]*(?:\([^()]*\)[^()]*)*)\)')
IOS = re.compile(r'\bios\((\d+)\.(\d+)')
BLOCK = re.compile(r'@(interface|protocol)\s+(\w+)\s*(?:<[^>]*>)?\s*(?::\s*\w+)?\s*(\(\s*\w*\s*\))?')


def app_selectors(app):
    sels = set()
    for root, _, files in os.walk(app):
        if '/Extensions/' in root + '/':
            continue
        for f in files:
            p = os.path.join(root, f)
            with open(p, 'rb') as fh:
                if fh.read(4) != b'\xcf\xfa\xed\xfe':
                    continue
            m = MachO(open(p, 'rb').read())
            for seg in m.segments():
                for sname, addr, size, offset, flags in seg[5]:
                    if sname == '__objc_methname':
                        sels |= {s.decode() for s in bytes(m.d[offset:offset + size]).split(b'\0') if s}
    return sels


def strip_comments(t):
    t = re.sub(r'/\*.*?\*/', ' ', t, flags=re.S)
    return re.sub(r'//[^\n]*', ' ', t)


def ios_intro(text):
    """Introduced iOS version from an availability annotation string, or None."""
    for m in re.finditer(r'(API_AVAILABLE|API_DEPRECATED(?:_WITH_REPLACEMENT)?|NS_AVAILABLE_IOS|NS_CLASS_AVAILABLE_IOS)\s*\(', text):
        depth, i = 1, m.end()
        while depth and i < len(text):
            depth += {'(': 1, ')': -1}.get(text[i], 0)
            i += 1
        args = text[m.end():i - 1]
        if m.group(1).startswith('NS_'):
            v = re.match(r'\s*(\d+)_(\d+)', args)
            if v:
                return int(v.group(1)), int(v.group(2))
        v = IOS.search(args)
        if v:
            return int(v.group(1)), int(v.group(2))
    return None


def selector_of(decl):
    """ObjC method declaration ('- (T)a:(T)x b:(T)y ...') -> 'a:b:'."""
    body = re.sub(r'^[-+]\s*\([^)]*(?:\([^)]*\)[^)]*)*\)\s*', '', decl.strip())
    parts = re.findall(r'(\w+)\s*:', re.sub(r'\([^)]*(?:\([^)]*\)[^)]*)*\)', ' ', body))
    if parts:
        return ''.join(p + ':' for p in parts)
    m = re.match(r'(\w+)', body)
    return m.group(1) if m else None


def property_sels(decl):
    attrs = re.match(r'@property\s*(\(([^)]*)\))?', decl)
    a = attrs.group(2) or '' if attrs else ''
    rest = decl[attrs.end():] if attrs else decl
    rest = re.sub(r'\b(API_\w+|NS_\w+|UI_\w+|__\w+)\s*\([^;]*$', '', rest)
    rest = re.sub(r'(\s+[A-Z][A-Z0-9]*_[A-Z0-9_]+)+\s*$', '', rest)   # bare macros (UI_APPEARANCE_SELECTOR)
    names = re.findall(r'[\s*](\w+)\s*$', ' ' + rest.strip())
    if not names:
        return []
    name = names[0]
    g = re.search(r'getter\s*=\s*(\w+)', a)
    s = re.search(r'setter\s*=\s*(\w+:)', a)
    out = [g.group(1) if g else name]
    if 'readonly' not in a:
        out.append(s.group(1) if s else 'set' + name[0].upper() + name[1:] + ':')
    return out


def sdk_decls(sdk):
    """{(owner, sel): (kind, intro)}; owner 'Class' or '<Proto>'; intro None if unannotated."""
    out = {}
    fw = os.path.join(sdk, 'System/Library/Frameworks')
    for f in sorted(os.listdir(fw)):
        hd = os.path.join(fw, f, 'Headers')
        if not os.path.isdir(hd):
            continue
        for h in sorted(os.listdir(hd)):
            if not h.endswith('.h'):
                continue
            t = strip_comments(open(os.path.join(hd, h), errors='replace').read())
            for blk in re.finditer(r'(@(?:interface|protocol)\b(?!\s*\w+(?:\s*,\s*\w+)*\s*;).*?)@end', t, flags=re.S):
                b = blk.group(1)
                head_end = b.find('\n')
                bm = BLOCK.match(b)
                if not bm:
                    continue
                owner = bm.group(2) if bm.group(1) == 'interface' else f'<{bm.group(2)}>'
                # block availability: annotation right before @interface, or on the header line
                pre = t[max(0, blk.start() - 300):blk.start()]
                pre = pre[pre.rfind(';') + 1:]
                bintro = ios_intro(pre + b[:head_end])
                for d in re.split(r';', b[head_end:]):
                    d = ' '.join(d.split())
                    if d.startswith(('-', '+')):
                        sels = [selector_of(d)]
                        kind = d[0]
                    elif d.startswith('@property'):
                        sels = property_sels(d)
                        kind = '+' if re.match(r'@property\s*\([^)]*\bclass\b', d) else '-'
                    else:
                        continue
                    intro = ios_intro(d) or bintro
                    for s in sels:
                        if s:
                            out.setdefault((owner, s), (kind, intro))
    return out


def main():
    app = sys.argv[1]
    new = sys.argv[2] if len(sys.argv) > 2 else os.path.join(THEOS, 'sdks/iPhoneOS16.5.sdk')
    old = sys.argv[3] if len(sys.argv) > 3 else os.path.join(THEOS, 'sdks/iPhoneOS14.5.sdk')
    sels = app_selectors(app)
    nd, od = sdk_decls(new), sdk_decls(old)
    od14 = sdk_decls(os.path.join(THEOS, 'sdks/iPhoneOS13.7.sdk'))
    rows = []
    for (owner, s), (kind, intro) in nd.items():
        if not (s in sels and intro):
            continue
        if ((15, 0) <= intro <= (15, 1) and (owner, s) not in od or
                (14, 4) <= intro <= (14, 5) and (owner, s) not in od14):
            rows.append(f'{intro[0]}.{intro[1]} {kind} {owner} {s}')
    print('\n'.join(sorted(rows, key=lambda r: r.split()[2:])))


if __name__ == '__main__':
    main()
