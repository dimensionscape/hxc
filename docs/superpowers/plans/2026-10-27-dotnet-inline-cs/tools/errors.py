#!/usr/bin/env python3
# errors.py <root> <log>...: each `dotnet:` error of an hxc log with its kind and source text.
# <root> resolves relative file names (the directory hxc ran in).
import re, sys
root = sys.argv[1].rstrip('/') + '/'
ERR = re.compile(r'^(.*?\.hx):(\d+): (characters (\d+)-(\d+)|lines (\d+)-(\d+)) : dotnet: (.*)$')
def src(f, a, b):
    p = f if re.match(r'^[A-Za-z]:', f) else root + f
    try: lines = open(p, encoding='utf-8', errors='replace').read().split('\n')
    except OSError: return ['<unreadable>']
    return [l.rstrip() for l in lines[a-1:b]]
def kind(msg, text):
    t = ' '.join(text)
    if 'left out' in msg: return 'left-out class'
    if '@:classCode' in msg: return '@:classCode'
    if '@:functionCode' in msg: return '@:functionCode'
    if 'embedded resources' in msg: return 'resources'
    if 'cs.Syntax' in msg: return 'cs.Syntax.code' if 'Syntax.code' in t else 'cs.Syntax (other)'
    if msg.startswith('untyped code'): return '__cs__' if '__cs__' in t else 'untyped (other)'
    return 'other'
for log in sys.argv[2:]:
    print('#', log)
    for l in open(log, encoding='utf-8', errors='replace'):
        l = l.rstrip('\n')
        if 'dotnet: ' not in l: continue
        m = ERR.match(l)
        if not m:
            print('[%s] %s' % (kind(l.split('dotnet: ',1)[1], []), l)); continue
        f, ln = m.group(1), int(m.group(2))
        if m.group(6): text = src(f, int(m.group(6)), int(m.group(7)))
        else: text = src(f, ln, ln)
        msg = m.group(8)
        print('[%s] %s:%d: %s' % (kind(msg, text), f, ln, msg))
        for t in text[:20]: print('    | ' + t)
