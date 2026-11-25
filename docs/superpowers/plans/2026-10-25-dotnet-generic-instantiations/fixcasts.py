"""fixcasts.py <g/src dir>: rewrites every gencs parent-cast body with the types notes' §4 rule.
P<a1..am> is the parent (interface, deep, or superclass) as the class declares it, after erasure. The body of
P_cast<P1_c..Pm_c>() becomes `return this.X_cast<b1..bn>();` with bk = Pj_c for the first j where aj == Tk, else Tk.
Prints one line per rewritten body."""
import os, re, sys
root = sys.argv[1]
files = {}
for dp, dn, fn in os.walk(root):
    for f in fn:
        if f.endswith('.cs'):
            p = os.path.join(dp, f); files[p] = open(p, encoding='utf-8').read()

def split_args(s):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch == '<': depth += 1
        elif ch == '>': depth -= 1
        if ch == ',' and depth == 0: out.append(cur.strip()); cur = ''
        else: cur += ch
    if cur.strip(): out.append(cur.strip())
    return out

decl_re = re.compile(r'public (?:sealed |abstract )?(?:class|interface) (\w+)(?:<([^>]*)>)?\s*:\s*([^{]*)\{')
ns_re = re.compile(r'namespace ([\w.]+)\s*\{')
decls = {}  # fullname -> (params, [(parentfull, args)])
for p, s in files.items():
    nss = [(m.start(), m.group(1)) for m in ns_re.finditer(s)]
    for d in decl_re.finditer(s):
        ns = ''
        for st, n in nss:
            if st < d.start(): ns = n
        name = d.group(1)
        full = (ns + '.' + name) if ns else name
        params = split_args(d.group(2)) if d.group(2) else []
        if not params: continue
        full = full + '`' + str(len(params))
        bases = []
        for b in split_args(d.group(3)):
            b = b.strip()
            mm = re.match(r'(?:global::)?([\w.]+)<(.*)>$', b)
            if mm:
                a = split_args(mm.group(2)); bases.append((mm.group(1) + '`' + str(len(a)), a))
        decls[full] = (params, bases)

def subst(arg, mapping):
    return re.sub(r'\b(\w+)\b', lambda m: mapping.get(m.group(1), m.group(1)), arg)

def ancestors(full, seen=None):
    """parent full name -> args in terms of full's own params"""
    res = {}
    if full not in decls: return res
    params, bases = decls[full]
    for pf, args in bases:
        if pf not in res: res[pf] = args
        if pf in decls:
            pparams = decls[pf][0]
            mapping = dict(zip(pparams, args))
            for af, aargs in ancestors(pf).items():
                if af not in res: res[af] = [subst(a, mapping) for a in aargs]
    return res

meth_re = re.compile(r'(public (?:virtual |override )?object (\w+)_cast<([^>]*)>\(\)\s*\{\s*(?:#line[^\n]*\n\s*)?return this\.(\w+)_cast<)([^>]*)(>\(\);)')
for p, s in list(files.items()):
    nss = [(m.start(), m.group(1)) for m in ns_re.finditer(s)]
    def nsat(pos):
        r = ''
        for st, n in nss:
            if st < pos: r = n
        return r
    decl_pos = [(d.start(), ((nsat(d.start()) + '.' + d.group(1)) if nsat(d.start()) else d.group(1)) + ('`' + str(len(split_args(d.group(2)))) if d.group(2) else '')) for d in decl_re.finditer(s)]
    def owner(pos):
        o = None
        for st, f in decl_pos:
            if st < pos: o = f
        return o
    out, last, changed = [], 0, False
    for mm in meth_re.finditer(s):
        cls = owner(mm.start())
        parent_prefix, pcs, own_prefix, own_args = mm.group(2), split_args(mm.group(3)), mm.group(4), split_args(mm.group(5))
        if cls is None or cls not in decls or cls.split('`')[0].replace('.', '_') != own_prefix: continue
        anc = ancestors(cls)
        pf = [f for f in anc if f.split('`')[0].replace('.', '_') == parent_prefix]
        if not pf: print('?? no parent', parent_prefix, 'for', cls); continue
        args = anc[pf[0]]
        params = decls[cls][0]
        new = []
        for t in params:
            js = [j for j, a in enumerate(args) if a == t]
            new.append(pcs[js[0]] if js else t)
        if new != own_args:
            print('%s.%s_cast: %s_cast<%s> -> <%s>' % (cls, parent_prefix, own_prefix, ', '.join(own_args), ', '.join(new)))
            out.append(s[last:mm.start(5)]); out.append(', '.join(new)); last = mm.end(5); changed = True
    if changed:
        out.append(s[last:])
        open(p, 'w', encoding='utf-8', newline='').write(''.join(out))
