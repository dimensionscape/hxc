package hxc.codegen.dotnet;

import hxc.core.Type;
import hxc.codegen.dotnet.CsSyntax;
import hxc.codegen.dotnet.CsToIl.CsValue;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlData;

// The type and namespace names of inline C# (csexpr §6.2), looked up as C# looks them up: keyword types,
// arrays, simple, dotted and `global::` names, generic type names. A type is a class of the program or a
// public type of an assembly NetRefs finds. CsToIl resolves the rest of a name (members) and lowers it.
class CsNames {
	final cs:CsToIl;
	final tl:TexprToIl;
	final g:DotnetCtx;

	public function new(cs:CsToIl) {
		this.cs = cs;
		tl = cs.tl;
		g = cs.g;
	}

	// The type or namespace `x` names, with nothing pushed, or null when it names neither (the head of a
	// member access names a type; what follows is a member). A name a namespace does not have is the
	// unknown-name error.
	public function typeOrNamespace(x:CsExpr):Null<CsValue> {
		switch (x.def) {
			case CKeywordType(name):
				return VType(CsToIl.keywordType(name));
			case CIdent(name):
				return simpleName(name, []);
			case CGlobal(name):
				return lookupIn(VNamespace([]), name, []);
			case CMember(e1, name):
				var head = typeOrNamespace(e1);
				return switch (head) {
					case VNamespace(path):
						var r = lookupIn(head, name, []);
						if (r == null) cs.unknownName(path.concat([name]).join("."), "CS0234");
						r;
					case VType(_): lookupIn(head, name, []);
					case _: null;
				}
			case _:
				return null;
		}
	}

	// The namespace of the class whose code the text is in, where C# starts looking a simple name up.
	function classNamespace():Array<String> {
		return tl.cls == null ? [] : DotnetNames.typePath(TClassDecl(tl.cls)).ns;
	}

	// A simple name, with the type arguments `args`, as C# looks it up: a type or namespace of that name in
	// the class's namespace, then in each enclosing one, then in the global namespace.
	function simpleName(name:String, args:Array<IlSigNorm>):Null<CsValue> {
		var ns = classNamespace();
		var k = ns.length;
		while (k >= 0) {
			var r = lookupIn(VNamespace(ns.slice(0, k)), name, args);
			if (r != null) return r;
			k--;
		}
		return null;
	}

	// The type (with the type arguments `args`) or, without type arguments, the namespace named `name` in the
	// namespace `scope`, or the type nested in the type `scope`; null when there is none.
	function lookupIn(scope:CsValue, name:String, args:Array<IlSigNorm>):Null<CsValue> {
		var clrName = args.length > 0 ? name + "`" + args.length : name;
		switch (scope) {
			case VNamespace(ns):
				var inner = ns.concat([name]);
				if (args.length == 0 && g.externs.namespaceExists(inner)) return VNamespace(inner);
				var t = typeAt({ns: ns, nested: [], name: clrName}, args);
				return t == null ? null : VType(t);
			case VType(LClass(p, outer) | LValueType(p, outer)) if (cs.programClass(LClass(p, outer)) == null):
				// A nested type takes the enclosing type's type arguments first.
				var t = typeAt({ns: p.ns, nested: p.nested.concat([p.name]), name: clrName}, outer.concat(args));
				return t == null ? null : VType(t);
			case _:
				return null;
		}
	}

	// The type whose CLR path is `path`, with the type arguments `args`: a class of the program, or a public
	// type of an assembly NetRefs finds (a loaded library, an assembly one references, the reference pack).
	function typeAt(path:IlPath, args:Array<IlSigNorm>):Null<IlSigNorm> {
		var c = path.nested.length == 0 ? g.externs.compiledClass(path) : null;
		if (c != null) {
			if (args.length > 0) throw new Unsupported("generic Haxe classes named in inline C#", true);
			return tl.sig(TInst(c, []));
		}
		var defined = try NetRefs.of(g.ctx).definer(path) != null catch (_:Unsupported) false;
		if (!defined || !g.externs.isVisibleType(path)) return null;
		return g.externs.csType(path, args);
	}

	// A type the C# text names, as a cast, `is` or `new` target.
	public function resolveType(t:CsType):IlSigNorm {
		switch (t) {
			case CTKeyword(name):
				return CsToIl.keywordType(name);
			case CTArray(t1):
				return LVector(resolveType(t1));
			case CTNamed(global, segments, targs):
				var args = [for (a in targs) resolveType(a)];
				var last = segments.length - 1;
				var headArgs = last == 0 ? args : [];
				var r = global ? lookupIn(VNamespace([]), segments[0], headArgs) : simpleName(segments[0], headArgs);
				if (r == null) cs.unknownName((global ? "global::" : "") + segments[0], global ? "CS0400" : "CS0246");
				for (i in 1...segments.length) {
					var next = lookupIn(r, segments[i], i == last ? args : []);
					if (next == null) cs.unknownName(segments.slice(0, i + 1).join("."), r.match(VNamespace(_)) ? "CS0234" : "CS0426");
					r = next;
				}
				return switch (r) {
					case VType(s): s;
					case _: cs.error("the inline C# name " + segments.join(".") + " is a namespace, not a type (C# error CS0118)");
				}
		}
	}
}
