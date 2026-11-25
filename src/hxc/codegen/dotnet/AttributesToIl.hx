package hxc.codegen.dotnet;

import haxe.Int64;
import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Type.FlagTClass;
import hxc.core.Type.ModuleType;
import hxc.core.Type.TClass;
import hxc.core.Type.TClassField;
import hxc.core.Type.TEnum;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.GenerateDotnet.DotnetCtx;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta;
import hxc.codegen.dotnet.TclassToIl;

// What an attribute goes on, as C#'s AttributeUsage names the declaration: TType is a class, TClrEnum a
// @:nativeGen enum. Callers write AttrTarget.TType, as hxc.core.Type's T has a TType too.
enum AttrTarget {
	TType;
	TStruct;
	TInterface;
	TClrEnum;
	TField;
	TMethod;
	TCtor;
	TProperty;
	TParam;
	TAssembly;
}

// The type of an attribute's constructor parameter, field or property, as ECMA-335 II.23.3 encodes it:
// bool, char, the integer types, float32, float64, string, System.Type, object, an enum (`under` is its
// underlying type) and a one-dimensional array of those.
enum AttrType {
	ATBool;
	ATChar;
	ATI1;
	ATU1;
	ATI2;
	ATU2;
	ATI4;
	ATU4;
	ATI8;
	ATU8;
	ATR4;
	ATR8;
	ATString;
	ATType;
	ATObject;
	ATEnum(path:IlPath, under:AttrType);
	ATArray(elem:AttrType);
}

// An argument's value: an integer of type `type` (an enum's underlying type for AEnum), a float of type
// ATR4 or ATR8, a string or a Type's serialized name (null: null), an enum value with the enum's serialized
// name, an array of elements of type `type` (null: null), and a value given to an object parameter, which
// the blob writes with its type first.
enum AttrValue {
	ABool(v:Bool);
	AInt(type:AttrType, v:Int64);
	AFloat(type:AttrType, v:Float);
	AString(s:Null<String>);
	AType(name:Null<String>);
	AEnum(enumName:String, type:AttrType, v:Int64);
	AArray(type:AttrType, values:Null<Array<AttrValue>>);
	ABoxed(v:AttrValue);
}

// An attribute's constructor: its MethodDef or MemberRef token and its parameter types.
typedef AttrCtor = {token:Int, params:Array<AttrType>};

// A named argument: a field (FIELD 0x53) or property (PROPERTY 0x54) of the attribute class.
typedef AttrNamed = {isProperty:Bool, name:String, type:AttrType, value:AttrValue};

// Where forMember's attributes are, for its messages and C#'s name lookup: the member's Haxe name and the
// namespace of the type that holds it, whose enclosing namespaces C# looks the attribute's name up in.
typedef AttrSite = {name:String, ns:Array<String>};

// What a member's pseudo-attributes give it (AttributesToIl.pseudo): its TypeDef or Field flags, a
// StructLayout's Pack and Size (null without a StructLayout; a ClassLayout row when either is not 0) and a
// FieldOffset's offset (a FieldLayout row).
typedef PseudoAttrs = {typeFlags:Int, fieldFlags:Int, layout:Null<{pack:Int, size:Int}>, offset:Null<Int>};

// A type an attribute names: an assembly's (`net`), or the program's class (`c`) or @:nativeGen enum (`e`).
private typedef AttrClass = {path:IlPath, name:String, ?net:IlClass, ?c:TClass, ?e:TEnum};

// A constant argument, before its parameter's type is known: an integer literal with its C# type, a
// float (double) literal, a string, a bool, null, typeof (the type's serialized name), an enum value and
// an array, `new[] {...}` in gencs's C#.
private enum Const {
	KInt(v:Int64, type:AttrType);
	KFloat(v:Float);
	KString(s:String);
	KBool(b:Bool);
	KNull;
	KType(name:String);
	KEnum(type:AttrType, v:Int64);
	KArray(values:Array<Const>);
}

// A constructor overload resolution can choose: its parameters' signatures, and the token, made once it
// is chosen.
private typedef Candidate = {sigs:Array<IlSigNorm>, params:Array<AttrType>, token:() -> Int};

// A refusal, positioned at the attribute expression or the part of it at fault.
private class AttrError {
	public final msg:String;
	public final pos:Position;

	public function new(msg:String, pos:Position) {
		this.msg = msg;
		this.pos = pos;
	}
}

// CustomAttribute rows (attrs notes §1): the `@:meta(e)` entries of a member, `e` an attribute written as
// C# would (StrictMeta has rewritten `@:strict` into that form), each a row on the member gencs's C# puts it
// on, in Haxe meta order, as Roslyn writes them in source order. The attribute's type is found by C#'s
// rules (the name, then the name + `Attribute`, from the member's namespace outward, among the referenced
// assemblies' types and the program's), and its constructor from the constant arguments by C#'s literal
// conversions and betterness (ruling 4). The blob is ECMA-335 II.23.3's, with Type and enum names
// assembly-qualified as Roslyn writes them. C#'s compile errors (CS0579, CS0592, CS0246, CS0616, CS1503,
// CS0182, CS0121) are `dotnet:` errors that name them. The attributes the backend writes on its own
// (CompilerGenerated, DefaultMember, ...) come from System.Runtime (runtimeAttr), never from another
// assembly that defines its own copy. The pseudo-attributes (StructLayout, FieldOffset, Serializable,
// NonSerialized) are flags and tables, not rows: pseudo gives them when the member is planned, and forMember
// leaves them out. Roslyn's other pseudo-attributes are refused.
class AttributesToIl {
	static final systemNs = ["System"];
	static final attributePath:IlPath = {ns: ["System"], nested: [], name: "Attribute"};
	static final usagePath:IlPath = {ns: ["System"], nested: [], name: "AttributeUsageAttribute"};
	static final typePath:IlPath = {ns: ["System"], nested: [], name: "Type"};
	static final editorBrowsablePath:IlPath = {ns: ["System", "ComponentModel"], nested: [], name: "EditorBrowsableAttribute"};
	static final editorBrowsableStatePath:IlPath = {ns: ["System", "ComponentModel"], nested: [], name: "EditorBrowsableState"};
	static final debuggingModesPath:IlPath = {ns: ["System", "Diagnostics"], nested: ["DebuggableAttribute"], name: "DebuggingModes"};
	static final pseudoNames = [
		"System.Runtime.InteropServices.StructLayoutAttribute", "System.Runtime.InteropServices.FieldOffsetAttribute",
		"System.SerializableAttribute", "System.NonSerializedAttribute"
	];
	// Roslyn's other pseudo-attributes, flags or tables that hxc does not write (ruling 5).
	static final unsupportedPseudoNames = [
		"System.Runtime.InteropServices.DllImportAttribute", "System.Runtime.InteropServices.MarshalAsAttribute",
		"System.Runtime.InteropServices.ComImportAttribute", "System.Runtime.CompilerServices.MethodImplAttribute",
		"System.Runtime.InteropServices.PreserveSigAttribute", "System.Runtime.InteropServices.InAttribute",
		"System.Runtime.InteropServices.OutAttribute", "System.Runtime.InteropServices.OptionalAttribute",
		"System.Runtime.CompilerServices.SpecialNameAttribute"
	];
	// What the CLR reads from the method it starts.
	static final apartmentNames = ["System.STAThreadAttribute", "System.MTAThreadAttribute"];
	// C#'s names of AttributeTargets' bits, in bit order, as CS0592 lists them.
	static final targetNames = [
		"assembly", "module", "class", "struct", "enum", "constructor", "method", "property, indexer", "field", "event", "interface",
		"parameter", "delegate", "return", "type parameter"
	];
	// C#'s keywords for the System types typeof can name.
	static final aliases = [
		"bool" => "Boolean", "byte" => "Byte", "sbyte" => "SByte", "char" => "Char", "short" => "Int16", "ushort" => "UInt16",
		"int" => "Int32", "uint" => "UInt32", "long" => "Int64", "ulong" => "UInt64", "float" => "Single", "double" => "Double",
		"decimal" => "Decimal", "string" => "String", "object" => "Object"
	];

	final g:DotnetCtx;
	// lookupPath's answers, by IlPaths.key; a type that is not there is cached as null.
	final classes = new Map<String, Null<AttrClass>>();
	// The program's @:nativeGen enums, by IlPaths.key.
	var clrEnums:Null<Map<String, TEnum>> = null;
	var runtimeId:Null<ModuleBuilder.AssemblyIdentity> = null;
	// pseudo's answers, by the meta they read and then by the target and the site's namespace.
	final pseudoDone = new haxe.ds.ObjectMap<Metadata, Map<String, PseudoAttrs>>();
	// While a member is planned (pseudo), before any TypeDef row is written: lookupPath finds a program class
	// by g.classAt and keeps no answer.
	var planning = false;

	function new(g:DotnetCtx) {
		this.g = g;
	}

	static function of(g:DotnetCtx):AttributesToIl {
		if (g.attributes == null) g.attributes = new AttributesToIl(g);
		return g.attributes;
	}

	// The rows of `meta`'s @:meta entries on `owner`, a TypeDef, Field, MethodDef, Param or Property token.
	public static function forMember(g:DotnetCtx, owner:Int, meta:Metadata, target:AttrTarget, pos:Position, ?site:AttrSite):Void {
		of(g).member(owner, meta, target, pos, site == null ? {name: "", ns: []} : site);
	}

	// The entry point's rows: the apartment attributes of the Haxe `main`, as well as main's own. The CLR reads the
	// apartment from the method it starts, which is not `main` but the Main the backend writes to call it, so
	// without this the attribute does nothing. gencs leaves its Main bare (a deliberate divergence). An entry
	// that cannot be read says so on `main`, which has just been through member, and is skipped here.
	public static function forEntryPoint(g:DotnetCtx, owner:Int, main:TClassField, site:AttrSite):Void {
		var a = of(g);
		var seen = new Map<String, Bool>();
		for (m in main.meta) {
			if (m.name != ":meta") continue;
			try {
				if (apartmentNames.indexOf(a.parse(m, site).cls.name) >= 0) a.entry(owner, m, TMethod, site, seen);
			} catch (e:AttrError) {} catch (u:Unsupported) {}
		}
	}

	// A row for one of the backend's own attributes; a `first` one comes before its parent's other rows.
	public static function write(g:DotnetCtx, owner:Int, ctor:AttrCtor, fixed:Array<AttrValue>, named:Array<AttrNamed>, first = false):Void {
		if (fixed.length != ctor.params.length)
			throw "internal error: an attribute row with " + fixed.length + " arguments for a constructor of " + ctor.params.length;
		var a = of(g);
		var b = new IlBytes();
		b.u16(1);
		for (i in 0...fixed.length) a.fixedArg(b, ctor.params[i], fixed[i]);
		b.u16(named.length);
		for (n in named) {
			b.u8(n.isProperty ? 0x54 : 0x53);
			a.typeTag(b, n.type);
			b.serString(n.name);
			a.fixedArg(b, n.type, n.value);
		}
		g.mb.customAttribute(owner, ctor.token, b.getBytes(), first);
	}

	// A CompilerGenerated row on each of the Field and MethodDef `tokens`, as Roslyn marks an auto-property's
	// backing field and accessors and a field-like event's.
	public static function compilerGenerated(g:DotnetCtx, tokens:Array<Int>):Void {
		var ctor = runtimeAttr(g, "System.Runtime.CompilerServices", "CompilerGeneratedAttribute", []);
		for (token in tokens) write(g, token, ctor, [], []);
	}

	// The constructor of System.Runtime's attribute `ns`.`name` with parameters `sig`, on a TypeRef into
	// System.Runtime, as Roslyn references the attributes it writes itself.
	public static function runtimeAttr(g:DotnetCtx, ns:String, name:String, sig:Array<AttrType>):AttrCtor {
		var a = of(g);
		var id = a.runtimeIdentity();
		var parent = ModuleBuilder.typeDefOrRefToken(g.mb.typeTokenIn({ns: ns.split("."), nested: [], name: name}, id));
		// An enum in the signature is System.Runtime's too.
		function pin(t:AttrType) switch (t) {
			case ATEnum(p, _): g.mb.typeTokenIn(p, id);
			case ATArray(e): pin(e);
			case _:
		}
		for (t in sig) pin(t);
		return {token: g.mb.memberRef(parent, ".ctor", g.sigs.method(true, LVoid, [for (t in sig) sigOf(t)], 0)), params: sig};
	}

	// The parameter type `s` is as an attribute's, or null when an attribute cannot take it.
	public static function attrTypeOf(g:DotnetCtx, s:IlSigNorm):Null<AttrType> {
		return of(g).attrType(s);
	}

	// A type's name as an attribute's Type argument serializes it: `Ns.Outer+Inner`n[[Arg, Assembly...]]`,
	// with the assembly's display name unless the assembly being written defines it.
	public static function serializedName(g:DotnetCtx, s:IlSigNorm):String {
		return of(g).qualified(s);
	}

	function runtimeIdentity():ModuleBuilder.AssemblyIdentity {
		if (runtimeId == null) {
			// Without the reference pack (or a System.Runtime.dll reference), name the identity the pack's
			// System.Runtime would have: the target's major version and Microsoft's framework key.
			var lib = NetRefs.of(g.ctx).runtimeLibrary();
			runtimeId = lib != null ? lib.identity() : {
				name: "System.Runtime",
				version: [NetSetup.dotnetVersion(g.ctx), 0, 0, 0],
				culture: "",
				publicKeyToken: haxe.io.Bytes.ofHex("b03f5f7f11d50a3a")
			};
		}
		return runtimeId;
	}

	function member(owner:Int, meta:Metadata, target:AttrTarget, pos:Position, site:AttrSite):Void {
		// The attribute types already on the member, by IlPaths.key.
		var seen = new Map<String, Bool>();
		entries(owner, meta, ":meta", target, site, seen, pos);
		// gencs's gen_nocompletion: EditorBrowsable(EditorBrowsableState.Never) after the @:meta attributes, on a
		// @:noCompletion field, property, method or constructor (ruling 6).
		if (target.match(TField | TProperty | TMethod | TCtor) && TypeFunctions.hasMeta(":noCompletion", meta)) {
			if (seen.exists(IlPaths.key(editorBrowsablePath))) {
				var m = TypeFunctions.getMetaOpt(":noCompletion", meta);
				g.error("@:noCompletion writes EditorBrowsable on " + site.name + ", which already has one (C# error CS0579)", m.pos);
				return;
			}
			var ctor = runtimeAttr(g, "System.ComponentModel", "EditorBrowsableAttribute", [ATEnum(editorBrowsableStatePath, ATI4)]);
			write(g, owner, ctor, [AEnum(dottedName(editorBrowsableStatePath), ATI4, Int64.ofInt(1))], []);
		}
	}

	// The rows of `meta`'s entries named `name` on `owner`, each type recorded in `seen`.
	function entries(owner:Int, meta:Metadata, name:String, target:AttrTarget, site:AttrSite, seen:Map<String, Bool>, pos:Position):Void {
		for (m in meta) {
			if (m.name != name) continue;
			try {
				entry(owner, m, target, site, seen);
			} catch (e:AttrError) {
				g.error(e.msg, e.pos == null ? pos : e.pos);
			} catch (u:Unsupported) {
				if (u.pos == null) u.pos = m.params.length > 0 ? m.params[0].pos : m.pos;
				g.report(u);
			}
		}
	}

	// The assembly's rows (ruling 6): each class's @:cs.assemblyMeta entries (StrictMeta has rewritten
	// @:cs.assemblyStrict into them), in the order the classes are written, then the SDK's
	// TargetFramework(".NETCoreApp,Version=v<net>.0", FrameworkDisplayName = ".NET <net>.0"). gencs writes
	// `[assembly: ...]` before the namespace of the first class of a module, where C# looks the names up
	// from the global namespace, and refuses them on another class or on a class it writes in no namespace
	// (gencs.ml:2612, change_ns: after @:native, and haxe.root under -D no-root).
	public static function forAssembly(g:DotnetCtx, classes:Array<TClass>, version:Int):Void {
		var a = of(g);
		var owner = (TableIdx.IAssembly << 24) | 1;
		var seen = new Map<String, Bool>();
		var site:AttrSite = {name: "the assembly", ns: []};
		// The class whose entries first named each attribute type, by IlPaths.key.
		var firstAt = new Map<String, Position>();
		for (c in classes) {
			var m = TypeFunctions.getMetaOpt(":cs.assemblyMeta", c.meta);
			if (m == null) continue;
			if (DotnetNames.typePath(TClassDecl(c)).ns.length == 0) {
				g.error("@:cs.assemblyMeta cannot be used on top level modules", c.pos);
				continue;
			}
			if (firstType(g, c) != c) {
				g.error("@:cs.assemblyMeta can only be used on the first class of a module", c.pos);
				continue;
			}
			a.entries(owner, c.meta, ":cs.assemblyMeta", TAssembly, site, seen, c.pos);
			for (k in seen.keys()) if (!firstAt.exists(k)) firstAt.set(k, c.pos);
		}
		var framework:IlPath = {ns: ["System", "Runtime", "Versioning"], nested: [], name: "TargetFrameworkAttribute"};
		if (seen.exists(IlPaths.key(framework))) {
			g.error("TargetFrameworkAttribute is on the assembly already: hxc writes it on every assembly, as the .NET SDK does (C# error CS0579)", firstAt.get(IlPaths.key(framework)));
			return;
		}
		var ctor = runtimeAttr(g, "System.Runtime.Versioning", "TargetFrameworkAttribute", [ATString]);
		var v = version + ".0";
		write(g, owner, ctor, [AString(".NETCoreApp,Version=v" + v)], [
			{isProperty: true, name: "FrameworkDisplayName", type: ATString, value: AString(".NET " + v)}
		]);
		// -D dotnet-debug-jit: DebuggableAttribute(Default | IgnoreSymbolStoreSequencePoints | DisableOptimizations,
		// 0x103), so the JIT keeps the locals and statement boundaries .hx stepping needs (as a Debug build of C# does).
		if (g.ctx.defines.rawDefined("dotnet_debug_jit")) {
			var debuggable = runtimeAttr(g, "System.Diagnostics", "DebuggableAttribute", [ATEnum(debuggingModesPath, ATI4)]);
			write(g, owner, debuggable, [AEnum(dottedName(debuggingModesPath), ATI4, Int64.ofInt(0x103))], []);
		}
	}

	// The first type of `c`'s module that gencs writes: a class that is not extern, or an enum, that the
	// compile keeps.
	static function firstType(g:DotnetCtx, c:TClass):Null<TClass> {
		var kept = new haxe.ds.ObjectMap<{}, Bool>();
		for (mt in g.ctx.types) switch (mt) {
			case TClassDecl(k) if (k.module == c.module): kept.set(k, true);
			case TEnumDecl(e) if (e.module == c.module): kept.set(e, true);
			case _:
		}
		for (mt in c.module.types) switch (mt) {
			case TClassDecl(k) if (kept.exists(k) && !TypeFunctions.hasClassFlag(k, CExtern)): return k;
			case TEnumDecl(e) if (kept.exists(e) && !e.isExtern): return null;
			case _:
		}
		return null;
	}

	function entry(owner:Int, m:MetadataEntry, target:AttrTarget, site:AttrSite, seen:Map<String, Bool>):Void {
		var a = parse(m, site);
		var cls = a.cls, e = a.e;
		if (unsupportedPseudoNames.indexOf(cls.name) >= 0)
			throw new AttrError(cls.name + " is a pseudo-attribute (a flag, not an attribute row) and is not supported", e.pos);
		if (cls.c != null && cls.c.params.length > 0)
			throw new AttrError(cls.name + " is generic, and @:meta cannot give an attribute class type arguments (C# error CS0305)", e.pos);
		var usage = usageOf(cls);
		var bit = targetBit(target);
		if (usage.validOn & bit == 0)
			throw new AttrError(cls.name + " is not valid on " + targetNoun(target) + "; its AttributeUsage allows " + targetList(usage.validOn) + " (C# error CS0592)", e.pos);
		var key = IlPaths.key(cls.path);
		if (seen.exists(key) && !usage.multiple)
			throw new AttrError(cls.name + " is already on " + site.name + ", and its AttributeUsage does not allow it more than once (C# error CS0579)", e.pos);
		seen.set(key, true);
		// A pseudo-attribute is a flag or a table, never a row: pseudo() read it when the member was planned.
		if (pseudoNames.indexOf(cls.name) >= 0) return;
		var args = arguments(cls, a.args, site.ns, e.pos);
		write(g, owner, {token: args.ctor.token(), params: args.ctor.params}, args.fixed, args.named);
	}

	// The attribute a @:meta entry names, and its argument expressions.
	function parse(m:MetadataEntry, site:AttrSite):{e:Expr, cls:AttrClass, args:Array<Expr>} {
		// gencs drops a @:meta of several parameters without a word.
		if (m.params.length != 1) throw new AttrError("@:meta takes one attribute; write one @:meta per attribute", m.params.length > 0 ? m.params[0].pos : m.pos);
		var e = m.params[0];
		switch (e.expr) {
			case EConst(CString(s, _)):
				throw new AttrError("@:meta with C# text is not supported; write the attribute as an expression, like @:meta(" + s + ")", e.pos);
			case _:
		}
		var call = e;
		while (call.expr.match(EParenthesis(_))) switch (call.expr) {
			case EParenthesis(x): call = x;
			case _:
		}
		var parts:Null<Array<String>>, args:Array<Expr>;
		switch (call.expr) {
			case ECall(f, el):
				parts = dotted(f);
				args = el;
			case _:
				parts = dotted(call);
				args = [];
		}
		if (parts == null)
			throw new AttrError("@:meta's attribute must be a type, or a call of one, like @:meta(System.ObsoleteAttribute(\"why\"))", e.pos);
		return {e: e, cls: resolveAttribute(parts, site.ns, e.pos), args: args};
	}

	// The constructor C# calls for an attribute's arguments, and their values.
	function arguments(cls:AttrClass, args:Array<Expr>, ns:Array<String>, pos:Position):{ctor:Candidate, fixed:Array<AttrValue>, named:Array<AttrNamed>} {
		var positional:Array<Const> = [];
		var named:Array<AttrNamed> = [];
		for (a in args) switch (a.expr) {
			case EBinop(OpAssign, {expr: EConst(CIdent(name))}, v):
				var mem = memberOf(cls, name);
				if (mem != null && mem.writeOnly)
					throw new AttrError(name + " is not a valid named argument: a property must have a public getter and setter (C# error CS0617)", a.pos);
				if (mem == null) throw new AttrError(cls.name + " has no public field or settable property " + name + " (C# error CS0246)", a.pos);
				var k = constant(v, ns);
				if (!converts(k, mem.type))
					throw new AttrError("the value given to " + name + " does not convert to " + mem.label + " (C# error CS0029)", v.pos);
				named.push({isProperty: mem.isProperty, name: name, type: mem.type, value: valueOf(k, mem.type)});
			case _:
				if (named.length > 0) throw new AttrError("an attribute's named arguments must come after its positional ones (C# error CS1016)", a.pos);
				positional.push(constant(a, ns));
		}
		var ctor = chooseCtor(cls, positional, pos);
		return {ctor: ctor, fixed: [for (i in 0...positional.length) valueOf(positional[i], ctor.params[i])], named: named};
	}

	// ---- pseudo-attributes

	// The flags and layout `meta`'s pseudo-attributes give a member being planned (ruling 5): Serializable a
	// type's 0x2000, NonSerialized a field's 0x80, StructLayout a type's layout (Sequential 0x8, Explicit 0x10,
	// Auto 0) and CharSet (Ansi 0, Unicode 0x10000, Auto 0x20000), with its Pack and Size for a ClassLayout
	// row, and FieldOffset a field's FieldLayout row. `layout` is null without a StructLayout, and `offset`
	// without a FieldOffset. An entry that is not valid on the target, or is there twice, gives its error when
	// the member's rows are written (forMember), as any attribute does; an argument C# would refuse gives it
	// here. Each meta is read once per target and namespace, as a leave-out round plans the classes again.
	public static function pseudo(g:DotnetCtx, meta:Metadata, target:AttrTarget, pos:Position, ?site:AttrSite):PseudoAttrs {
		var a = of(g);
		if (site == null) site = {name: "", ns: []};
		var byUse = a.pseudoDone.get(meta);
		if (byUse == null) {
			byUse = new Map();
			a.pseudoDone.set(meta, byUse);
		}
		var key = Std.string(target) + " " + site.ns.join(".");
		var r = byUse.get(key);
		if (r == null) {
			r = a.pseudoOf(meta, target, pos, site);
			byUse.set(key, r);
		}
		return r;
	}

	// `f`'s result, with lookupPath in planning mode while it runs: the types are not declared yet, so it
	// finds the program's classes by their paths and keeps none of its answers. The mode is restored however
	// `f` ends.
	function planned<R>(f:() -> R):R {
		var was = planning;
		planning = true;
		try {
			var r = f();
			planning = was;
			return r;
		} catch (e:Dynamic) {
			planning = was;
			throw e;
		}
	}

	function pseudoOf(meta:Metadata, target:AttrTarget, pos:Position, site:AttrSite):PseudoAttrs {
		var r:PseudoAttrs = {typeFlags: 0, fieldFlags: 0, layout: null, offset: null};
		for (m in meta) {
			if (m.name != ":meta" || m.params.length != 1 || !maybePseudo(m.params[0])) continue;
			var a = try planned(() -> parse(m, site)) catch (_:AttrError) null;
			if (a == null || pseudoNames.indexOf(a.cls.name) < 0 || usageOf(a.cls).validOn & targetBit(target) == 0) continue;
			try {
				var args = planned(() -> arguments(a.cls, a.args, site.ns, a.e.pos));
				function int(v:AttrValue):Int return switch (v) {
					case AInt(_, i) | AEnum(_, _, i): i.low;
					case _: throw "internal error: a pseudo-attribute argument that is not an integer";
				}
				switch (a.cls.path.name) {
					case "SerializableAttribute":
						r.typeFlags |= 0x2000;
					case "NonSerializedAttribute":
						r.fieldFlags |= 0x80;
					case "FieldOffsetAttribute":
						var offset = int(args.fixed[0]);
						// A refused offset still marks the field as having one, so that it is not also missing one.
						r.offset = offset < 0 ? 0 : offset;
						if (offset < 0) throw new AttrError("a field's offset cannot be negative (C# error CS0591)", a.args[0].pos);
					case "StructLayoutAttribute":
						r.typeFlags &= ~0x30018;
						// Roslyn takes a value LayoutKind does not name, StructLayout(1) or (5), for Sequential.
						r.typeFlags |= switch (int(args.fixed[0])) {
							case 2: 0x10;
							case 3: 0;
							case _: 0x8;
						}
						// Kept when a named argument is refused, so the type's fields are checked against its layout.
						var layout = {pack: 0, size: 0};
						r.layout = layout;
						for (i in 0...args.named.length) {
							var n = args.named[i], v = int(args.named[i].value);
							var at = a.args[a.args.length - args.named.length + i].pos;
							inline function invalid() return new AttrError("the value given to " + n.name + " is not valid (C# error CS0599)", at);
							switch (n.name) {
								case "Pack":
									if (v != 0 && (v < 0 || v > 128 || v & (v - 1) != 0)) throw invalid();
									layout.pack = v;
								case "Size":
									if (v < 0) throw invalid();
									layout.size = v;
								case "CharSet":
									r.typeFlags |= switch (v) {
										case 1 | 2: 0;
										case 3: 0x10000;
										case 4: 0x20000;
										case _: throw invalid();
									}
								case _:
							}
						}
				}
			} catch (e:AttrError) {
				g.error(e.msg, e.pos == null ? pos : e.pos);
			} catch (u:Unsupported) {
				if (u.pos == null) u.pos = m.params[0].pos;
				g.report(u);
			}
		}
		return r;
	}

	// Whether the attribute expression's last name is a supported pseudo-attribute's, which is all pseudoOf
	// needs to look at.
	static function maybePseudo(e:Expr):Bool {
		var parts = dotted(switch (e.expr) {
			case ECall(f, _): f;
			case _: e;
		});
		if (parts == null) return false;
		var last = parts[parts.length - 1];
		for (n in pseudoNames) {
			var short = n.substr(n.lastIndexOf(".") + 1);
			if (last == short || last + "Attribute" == short) return true;
		}
		return false;
	}

	// The parts of a dotted name, or null.
	static function dotted(e:Expr):Null<Array<String>> {
		return switch (e.expr) {
			case EConst(CIdent(s)): [s];
			case EField(e1, f, _):
				var l = dotted(e1);
				l == null ? null : l.concat([f]);
			case EParenthesis(e1): dotted(e1);
			case _: null;
		}
	}

	static function dottedName(p:IlPath):String {
		return p.ns.concat(p.nested).concat([p.name]).join(".");
	}

	// ---- types

	// The program's or a referenced assembly's type at `path`, or null.
	function lookupPath(path:IlPath):Null<AttrClass> {
		var key = IlPaths.key(path);
		if (planning) {
			var c = g.classAt(path);
			if (c != null && !TypeFunctions.hasClassFlag(c, CExtern)) return {path: path, name: dottedName(path), c: c};
		} else if (classes.exists(key)) {
			return classes.get(key);
		}
		var r:Null<AttrClass> = null;
		if (!planning && g.mb.definesType(path)) {
			var c = g.classAt(path);
			if (c != null && !TypeFunctions.hasClassFlag(c, CExtern)) {
				r = {path: path, name: dottedName(path), c: c};
			} else {
				if (clrEnums == null) {
					clrEnums = new Map();
					for (mt in g.ctx.types) switch (mt) {
						case TEnumDecl(e) if (HxGen.isClrEnum(e)): clrEnums.set(IlPaths.key(DotnetNames.typePath(mt)), e);
						case _:
					}
				}
				var e = clrEnums.get(key);
				// Another type of the program (an hxgen enum's class, a companion) is none an attribute can name.
				r = e != null ? {path: path, name: dottedName(path), e: e} : {path: path, name: dottedName(path)};
			}
		} else {
			// The reference pack's class first: Roslyn compiles gencs's C# against it, so its constructors
			// (DefaultValueAttribute's (uint) and (ulong), which net-20's lacks) are the ones C# chooses from.
			var refs = NetRefs.of(g.ctx);
			var lib = refs.packDefiner(path);
			if (lib == null) lib = refs.definer(path);
			var raw = lib == null ? null : lib.rawClass(path);
			if (raw != null) r = {path: path, name: dottedName(path), net: raw};
		}
		if (!planning) classes.set(key, r);
		return r;
	}

	// The paths a dotted name can be, the longest namespace first: `A.B.C` is A.B's C, A's B+C or B+C nested
	// in A.
	static function splits(parts:Array<String>):Array<IlPath> {
		var r:Array<IlPath> = [];
		var k = parts.length - 1;
		while (k >= 0) {
			var ns = parts.slice(0, k);
			var rest = parts.slice(k);
			r.push({ns: ns, nested: rest.slice(0, rest.length - 1), name: rest[rest.length - 1]});
			k--;
		}
		return r;
	}

	// C#'s lookup of a dotted type name from the namespace `ns`: in `ns`, then in each enclosing namespace.
	function lookup(parts:Array<String>, ns:Array<String>):Null<AttrClass> {
		var i = ns.length;
		while (i >= 0) {
			for (p in splits(ns.slice(0, i).concat(parts))) {
				var r = lookupPath(p);
				if (r != null) return r;
			}
			i--;
		}
		return null;
	}

	// The attribute class a name gives: the name or the name + `Attribute`, whichever is an attribute class.
	function resolveAttribute(parts:Array<String>, ns:Array<String>, pos:Position):AttrClass {
		var plain = lookup(parts, ns);
		var suffixed = lookup(parts.slice(0, parts.length - 1).concat([parts[parts.length - 1] + "Attribute"]), ns);
		var plainIs = plain != null && isAttribute(plain), suffixedIs = suffixed != null && isAttribute(suffixed);
		if (plainIs && suffixedIs)
			throw new AttrError(parts.join(".") + " is ambiguous between the attribute classes " + plain.name + " and " + suffixed.name
				+ "; write the one meant in full (C# error CS1614)", pos);
		if (plainIs) return plain;
		if (suffixedIs) return suffixed;
		var found = plain != null ? plain : suffixed;
		if (found != null) throw new AttrError(found.name + " is not an attribute class (C# error CS0616)", pos);
		var name = parts.join(".");
		throw new AttrError("the attribute type " + name + " is not found, nor " + name + "Attribute (C# error CS0246)", pos);
	}

	// The type a typeof or an enum value's type names, C#'s keywords included.
	function lookupType(parts:Array<String>, ns:Array<String>):Null<AttrClass> {
		if (parts.length == 1 && aliases.exists(parts[0])) return lookupPath({ns: systemNs, nested: [], name: aliases.get(parts[0])});
		return lookup(parts, ns);
	}

	// The base type of a class, or null.
	function superOf(cls:AttrClass):Null<AttrClass> {
		if (cls.net != null) {
			return switch (cls.net.csuper == null ? null : cls.net.csuper.snorm) {
				case LClass(p, _): lookupPath(p);
				case _: null;
			}
		}
		if (cls.c != null && cls.c.superClass != null) {
			var sc = cls.c.superClass.c;
			var p = TypeFunctions.hasClassFlag(sc, CExtern) ? (try g.types.externPath(sc) catch (_:Unsupported) null) : DotnetNames.typePath(TClassDecl(sc));
			return p == null ? null : lookupPath(p);
		}
		return null;
	}

	function isAttribute(cls:AttrClass):Bool {
		var cur = cls, depth = 0;
		while (cur != null && depth++ < 64) {
			if (IlPaths.equals(cur.path, attributePath)) return true;
			cur = superOf(cur);
		}
		return false;
	}

	// The class's AttributeUsage, from the class or its bases: AttributeTargets.All and AllowMultiple=false
	// when none says.
	function usageOf(cls:AttrClass):{validOn:Int, multiple:Bool} {
		var cur = cls, depth = 0;
		while (cur != null && depth++ < 64) {
			if (cur.net != null) {
				for (a in cur.net.cattrs) {
					var t = IlMetaTools.attrType(a);
					if (t == null || t.name != usagePath.name || !IlPaths.strsEq(t.ns, usagePath.ns) || a.value == null) continue;
					var validOn = switch (a.value.fixed[0]) {
						case InstEnum(i) | InstConstant(IInt(i)): i;
						case _: 0x7FFF;
					}
					var multiple = false;
					for (n in a.value.named) if (n.name == "AllowMultiple") switch (n.inst) {
						case InstConstant(IBool(b)): multiple = b;
						case _:
					}
					return {validOn: validOn, multiple: multiple};
				}
			} else if (cur.c != null) {
				for (m in cur.c.meta) {
					if (m.name != ":meta" || m.params.length != 1) continue;
					var r = try programUsage(m.params[0], DotnetNames.typePath(TClassDecl(cur.c)).ns) catch (_:AttrError) null;
					if (r != null) return r;
				}
			}
			cur = superOf(cur);
		}
		return {validOn: 0x7FFF, multiple: false};
	}

	// A program class's `@:meta(System.AttributeUsage(targets, AllowMultiple = b))`, or null for another
	// attribute.
	function programUsage(e:Expr, ns:Array<String>):Null<{validOn:Int, multiple:Bool}> {
		var parts = null, args = [];
		switch (e.expr) {
			case ECall(f, el):
				parts = dotted(f);
				args = el;
			case _:
				parts = dotted(e);
		}
		if (parts == null) return null;
		var cls = resolveAttribute(parts, ns, e.pos);
		if (!IlPaths.equals(cls.path, usagePath)) return null;
		var r = {validOn: 0x7FFF, multiple: false};
		for (a in args) switch (a.expr) {
			case EBinop(OpAssign, {expr: EConst(CIdent("AllowMultiple"))}, v):
				switch (constant(v, ns)) {
					case KBool(b): r.multiple = b;
					case _:
				}
			case EBinop(OpAssign, _, _):
			case _:
				switch (constant(a, ns)) {
					case KEnum(_, v) | KInt(v, _): r.validOn = v.low;
					case _:
				}
		}
		return r;
	}

	static function targetBit(t:AttrTarget):Int {
		return switch (t) {
			case TAssembly: 0x1;
			case TType: 0x4;
			case TStruct: 0x8;
			case TClrEnum: 0x10;
			case TCtor: 0x20;
			case TMethod: 0x40;
			case TProperty: 0x80;
			case TField: 0x100;
			case TInterface: 0x400;
			case TParam: 0x800;
		}
	}

	static function targetNoun(t:AttrTarget):String {
		return switch (t) {
			case TAssembly: "an assembly";
			case TType: "a class";
			case TStruct: "a struct";
			case TClrEnum: "an enum";
			case TCtor: "a constructor";
			case TMethod: "a method";
			case TProperty: "a property";
			case TField: "a field";
			case TInterface: "an interface";
			case TParam: "a parameter";
		}
	}

	static function targetList(validOn:Int):String {
		return [for (i in 0...targetNames.length) if (validOn & (1 << i) != 0) targetNames[i]].join(", ");
	}

	// ---- parameter types

	function attrType(s:IlSigNorm):Null<AttrType> {
		return switch (s) {
			case LBool: ATBool;
			case LChar: ATChar;
			case LInt8: ATI1;
			case LUInt8: ATU1;
			case LInt16: ATI2;
			case LUInt16: ATU2;
			case LInt32: ATI4;
			case LUInt32: ATU4;
			case LInt64: ATI8;
			case LUInt64: ATU8;
			case LFloat32: ATR4;
			case LFloat64: ATR8;
			case LString: ATString;
			case LObject: ATObject;
			case LClass(p, []) if (IlPaths.equals(p, typePath)): ATType;
			case LClass(p, []) | LValueType(p, []) if (DotnetTypes.primitive(p) != null): attrType(DotnetTypes.primitive(p));
			case LValueType(p, []):
				var under = enumUnder(p);
				under == null ? null : ATEnum(p, under);
			case LVector(e):
				var t = e.match(LVector(_)) ? null : attrType(e);
				t == null ? null : ATArray(t);
			case _: null;
		}
	}

	// The underlying type of the enum at `p`, or null when `p` is no enum.
	function enumUnder(p:IlPath):Null<AttrType> {
		var cls = lookupPath(p);
		if (cls == null) return null;
		if (cls.e != null) return ATI4;
		if (cls.net == null) return null;
		switch (cls.net.csuper == null ? null : cls.net.csuper.snorm) {
			case LClass(sp, _) if (DotnetTypes.isSystemEnum(sp)):
			case _: return null;
		}
		for (f in cls.net.cfields) if (f.fflags.contract.indexOf(CStatic) < 0) {
			var t = attrType(f.fsig.snorm);
			if (t != null) return t;
		}
		return ATI4;
	}

	static function sigOf(t:AttrType):IlSigNorm {
		return switch (t) {
			case ATBool: LBool;
			case ATChar: LChar;
			case ATI1: LInt8;
			case ATU1: LUInt8;
			case ATI2: LInt16;
			case ATU2: LUInt16;
			case ATI4: LInt32;
			case ATU4: LUInt32;
			case ATI8: LInt64;
			case ATU8: LUInt64;
			case ATR4: LFloat32;
			case ATR8: LFloat64;
			case ATString: LString;
			case ATType: LClass(typePath, []);
			case ATObject: LObject;
			case ATEnum(p, _): LValueType(p, []);
			case ATArray(e): LVector(sigOf(e));
		}
	}

	static function typeEq(a:AttrType, b:AttrType):Bool {
		return switch [a, b] {
			case [ATEnum(p1, _), ATEnum(p2, _)]: IlPaths.equals(p1, p2);
			case [ATArray(e1), ATArray(e2)]: typeEq(e1, e2);
			case [ATEnum(_, _) | ATArray(_), _] | [_, ATEnum(_, _) | ATArray(_)]: false;
			case _: Type.enumIndex(a) == Type.enumIndex(b);
		}
	}

	// The Haxe type a parameter's signature is, for messages.
	function haxeName(s:IlSigNorm):String {
		return switch (s) {
			case LBool: "Bool";
			case LChar: "cs.Char16";
			case LInt8: "cs.Int8";
			case LUInt8: "cs.UInt8";
			case LInt16: "cs.Int16";
			case LUInt16: "cs.UInt16";
			case LInt32: "Int";
			case LUInt32: "UInt";
			case LInt64: "haxe.Int64";
			case LUInt64: "cs.UInt64";
			case LFloat32: "Single";
			case LFloat64: "Float";
			case LString: "String";
			case LObject: "Dynamic";
			case LVector(e): "cs.NativeArray<" + haxeName(e) + ">";
			case LClass(p, _) | LValueType(p, _):
				var cls = lookupPath(p);
				if (cls != null && cls.c != null) DotnetTypes.haxePath(TClassDecl(cls.c));
				else if (cls != null && cls.e != null) DotnetTypes.haxePath(TEnumDecl(cls.e));
				else Globals.sTypePath(NetConverter.netpathToHx(true, p));
			case _: Std.string(s);
		}
	}

	// ---- constants

	// The constant an argument expression is, by C#'s rules for attribute arguments.
	function constant(e:Expr, ns:Array<String>):Const {
		return switch (e.expr) {
			case EParenthesis(x): constant(x, ns);
			case EConst(CInt(s, suffix)): intLiteral(s, suffix, false, e.pos);
			case EConst(CFloat(s, suffix)):
				if (suffix != null && suffix != "f64") throw new AttrError(suffix + " is not a valid float suffix", e.pos);
				KFloat(Std.parseFloat(StringTools.replace(s, "_", "")));
			case EConst(CString(s, _)): KString(s);
			case EConst(CIdent("true")): KBool(true);
			case EConst(CIdent("false")): KBool(false);
			case EConst(CIdent("null")): KNull;
			case EUnop(Neg, Prefix, x):
				var lit = x;
				while (true) switch (lit.expr) {
					case EParenthesis(y): lit = y;
					case _: break;
				}
				switch (lit.expr) {
					case EConst(CInt(s, suffix)): intLiteral(s, suffix, true, e.pos);
					case _:
						switch (constant(x, ns)) {
							// C#'s unary minus: a uint becomes a long, and a ulong has none.
							case KInt(_, ATU8): throw negUlong(e.pos);
							case KInt(v, ATU4): KInt(Int64.neg(v), ATI8);
							case KInt(v, t): KInt(Int64.neg(v), t);
							case KFloat(v): KFloat(-v);
							case _: throw notConstant(e.pos);
						}
				}
			case ECall({expr: EConst(CIdent("typeof"))}, [t]):
				var parts = dotted(t);
				var cls = parts == null ? null : lookupType(parts, ns);
				if (cls == null) throw new AttrError("the type " + (parts == null ? "in typeof" : parts.join(".")) + " is not found (C# error CS0246)", t.pos);
				KType(qualified(LClass(cls.path, [])));
			case EArrayDecl(values): KArray([for (v in values) constant(v, ns)]);
			case EField(_, _, _):
				var parts = dotted(e);
				if (parts == null) throw notConstant(e.pos);
				var field = parts.pop();
				var cls = lookupType(parts, ns);
				var k = cls == null ? null : literalField(cls, field);
				if (k == null) throw notConstant(e.pos);
				k;
			case _: throw notConstant(e.pos);
		}
	}

	static function notConstant(pos:Position):AttrError {
		return new AttrError("an attribute argument must be a constant, a typeof or an array of constants (C# error CS0182)", pos);
	}

	// An enum's value, or another literal field (a C# const) of a referenced type, or null.
	function literalField(cls:AttrClass, name:String):Null<Const> {
		if (cls.e != null) {
			var ef = cls.e.constrs.get(name);
			return ef == null ? null : KEnum(ATEnum(cls.path, ATI4), Int64.ofInt(ef.index));
		}
		if (cls.net == null) return null;
		for (f in cls.net.cfields) if (f.fname == name && f.fflags.contract.indexOf(CLiteral) >= 0 && f.fconstant != null) {
			var under = enumUnder(cls.path);
			var v:Null<Int64> = switch (f.fconstant) {
				case IBool(b): Int64.ofInt(b ? 1 : 0);
				case IChar(i) | IByte(i) | IShort(i) | IInt(i): Int64.ofInt(i);
				case IInt64(_, i): i;
				case _: null;
			}
			if (under != null) return v == null ? null : KEnum(ATEnum(cls.path, under), v);
			return switch (f.fconstant) {
				case IBool(b): KBool(b);
				case IInt(i): KInt(Int64.ofInt(i), ATI4);
				case IInt64(_, i): KInt(i, ATI8);
				case IFloat64(x): KFloat(x);
				case _: null;
			}
		}
		return null;
	}

	static function negUlong(pos:Position):AttrError {
		return new AttrError("the operator - cannot be applied to a ulong (C# error CS0023)", pos);
	}

	// An integer literal, negated or not, as C# types it: unsuffixed, the first of int, uint, long and
	// ulong that holds it (a 0x literal of 2^63 or more is a ulong, its bits kept); with Haxe's suffix,
	// i32's int (a 0x literal's bits), u32's uint or i64's long (its bits).
	function intLiteral(s:String, suffix:Null<String>, neg:Bool, pos:Position):Const {
		var digits = StringTools.replace(s, "_", "");
		// The parser folds a minus into the literal.
		if (StringTools.startsWith(digits, "-")) {
			digits = digits.substr(1);
			neg = !neg;
		}
		var hex = StringTools.startsWith(digits, "0x") || StringTools.startsWith(digits, "0X");
		var v = parseInt(digits);
		if (v == null) throw new AttrError("the integer literal " + s + " is too large (C# error CS1021)", pos);
		inline function negated(t:AttrType) return KInt(neg ? Int64.neg(v) : v, t);
		return switch (suffix) {
			case null:
				if (Int64.compare(v, 0) < 0) {
					// C# makes the decimal -9223372036854775808 a long; another negated ulong is an error.
					if (!neg) KInt(v, ATU8) else if (!hex && Int64.eq(v, Int64.make(0x80000000, 0))) KInt(v, ATI8) else throw negUlong(pos);
				} else if (inRange(v, ATI4)) negated(ATI4);
				else if (inRange(v, ATU4))
					// C# makes the decimal -2147483648 an int; another negated uint is a long.
					neg && !hex && Int64.eq(v, Int64.make(0, 0x80000000)) ? KInt(Int64.neg(v), ATI4) : negated(neg ? ATI8 : ATU4);
				else negated(ATI8);
			case "i32":
				var i:Null<Int64> = !hex ? v : digits.length <= 10 ? Int64.ofInt(v.low) : null;
				if (i == null || !inRange(i, ATI4) || (neg && Int64.eq(i, Int64.make(-1, 0x80000000))))
					throw new AttrError("Cannot represent " + s + " with a 32 bit integer", pos);
				KInt(neg ? Int64.neg(i) : i, ATI4);
			case "u32":
				if (!inRange(v, ATU4)) throw new AttrError("Cannot represent " + s + " with a 32 bit unsigned integer", pos);
				negated(neg ? ATI8 : ATU4);
			case "i64": negated(ATI8);
			case other: throw new AttrError(other + " is not a valid integer suffix", pos);
		}
	}

	// A decimal or 0x literal's 64 bits, unsigned, or null when it needs more.
	static function parseInt(s:String):Null<Int64> {
		var v = Int64.ofInt(0);
		if (StringTools.startsWith(s, "0x") || StringTools.startsWith(s, "0X")) {
			var hex = s.substr(2);
			if (hex.length == 0 || hex.length > 16) return null;
			for (i in 0...hex.length) {
				var d = Std.parseInt("0x" + hex.charAt(i));
				if (d == null) return null;
				v = Int64.or(Int64.shl(v, 4), Int64.ofInt(d));
			}
			return v;
		}
		if (s.length == 0) return null;
		// 2^64 - 1 is 1844674407370955161 * 10 + 5.
		var tenth = Int64.make(0x19999999, 0x99999999);
		for (i in 0...s.length) {
			var d = s.charCodeAt(i) - "0".code;
			if (d < 0 || d > 9) return null;
			var c = Int64.ucompare(v, tenth);
			if (c > 0 || (c == 0 && d > 5)) return null;
			v = Int64.add(Int64.mul(v, 10), Int64.ofInt(d));
		}
		return v;
	}

	static function inRange(v:Int64, t:AttrType):Bool {
		inline function within(lo:Int64, hi:Int64) return Int64.compare(v, lo) >= 0 && Int64.compare(v, hi) <= 0;
		return switch (t) {
			case ATI1: within(-128, 127);
			case ATU1: within(0, 255);
			case ATI2: within(-32768, 32767);
			case ATU2: within(0, 65535);
			case ATI4: within(Int64.make(-1, 0x80000000), Int64.make(0, 0x7FFFFFFF));
			case ATU4: within(0, Int64.make(0, 0xFFFFFFFF));
			case ATI8: true;
			case ATU8: Int64.compare(v, 0) >= 0;
			case _: false;
		}
	}

	static function isIntegral(t:AttrType):Bool {
		return t.match(ATI1 | ATU1 | ATI2 | ATU2 | ATI4 | ATU4 | ATI8 | ATU8);
	}

	// C#'s implicit numeric conversions.
	static function numericTo(from:AttrType):Array<AttrType> {
		return switch (from) {
			case ATI1: [ATI2, ATI4, ATI8, ATR4, ATR8];
			case ATU1: [ATI2, ATU2, ATI4, ATU4, ATI8, ATU8, ATR4, ATR8];
			case ATI2: [ATI4, ATI8, ATR4, ATR8];
			case ATU2: [ATI4, ATU4, ATI8, ATU8, ATR4, ATR8];
			case ATI4: [ATI8, ATR4, ATR8];
			case ATU4: [ATI8, ATU8, ATR4, ATR8];
			case ATI8 | ATU8: [ATR4, ATR8];
			case ATChar: [ATU2, ATI4, ATU4, ATI8, ATU8, ATR4, ATR8];
			case ATR4: [ATR8];
			case _: [];
		}
	}

	static function isReference(t:AttrType):Bool {
		return t.match(ATString | ATType | ATObject | ATArray(_));
	}

	// Whether C# converts a value of type `a` to `b` implicitly.
	static function implicitType(a:AttrType, b:AttrType):Bool {
		if (typeEq(a, b) || b.match(ATObject)) return true;
		for (t in numericTo(a)) if (typeEq(t, b)) return true;
		return switch [a, b] {
			case [ATArray(e1), ATArray(e2)]: isReference(e1) && isReference(e2) && implicitType(e1, e2);
			case _: false;
		}
	}

	// The type of a constant itself, or null for null and an array with no common element type.
	static function naturalType(k:Const):Null<AttrType> {
		return switch (k) {
			case KInt(_, t): t;
			case KFloat(_): ATR8;
			case KString(_): ATString;
			case KBool(_): ATBool;
			case KNull: null;
			case KType(_): ATType;
			case KEnum(t, _): t;
			case KArray(values): {
					// `new[] {...}`: the one element type every element converts to.
					var best:Null<AttrType> = null;
					for (v in values) {
						var t = naturalType(v);
						if (t == null) continue;
						if (best == null || implicitType(best, t)) best = t;
					}
					if (best == null) return null;
					for (v in values) if (!converts(v, best)) return null;
					ATArray(best);
				}
		}
	}

	// Whether the constant converts to an attribute parameter of type `t` (C# 10.2's implicit conversions,
	// the constant ones included).
	static function converts(k:Const, t:AttrType):Bool {
		var nat = naturalType(k);
		if (t.match(ATObject)) return nat != null || k.match(KNull);
		return switch [k, t] {
			case [KInt(v, lt), _] if (isIntegral(t)):
				typeEq(lt, t) || (lt.match(ATI4) && inRange(v, t)) || (lt.match(ATI8) && t.match(ATU8) && inRange(v, ATU8)) || implicitType(lt, t);
			case [KInt(_, _), ATR4 | ATR8]: true;
			case [KInt(v, _), ATEnum(_, _)]: Int64.isZero(v);
			case [KFloat(_), ATR8]: true;
			case [KString(_), ATString] | [KBool(_), ATBool] | [KType(_), ATType]: true;
			case [KNull, ATString | ATType | ATArray(_)]: true;
			case [KEnum(et, _), ATEnum(_, _)]: typeEq(et, t);
			// C#'s `new[] {...}` needs an element type every element converts to.
			case [KArray(_), ATArray(_)]: nat != null && implicitType(nat, t);
			case _: false;
		}
	}

	// Whether converting `k` to `t1` is better than to `t2` (C# 12.6.4.5): an exact match, else the better
	// conversion target.
	static function better(k:Const, t1:AttrType, t2:AttrType):Bool {
		if (typeEq(t1, t2)) return false;
		var nat = naturalType(k);
		var e1 = nat != null && typeEq(nat, t1), e2 = nat != null && typeEq(nat, t2);
		if (e1 != e2) return e1;
		if (implicitType(t1, t2) && !implicitType(t2, t1)) return true;
		// A signed integral type is better than an unsigned one.
		return switch [t1, t2] {
			case [ATI1, ATU1 | ATU2 | ATU4 | ATU8] | [ATI2, ATU2 | ATU4 | ATU8] | [ATI4, ATU4 | ATU8] | [ATI8, ATU8]: true;
			case _: false;
		}
	}

	// The value a constant gives a parameter of type `t`, which it converts to.
	function valueOf(k:Const, t:AttrType):AttrValue {
		return switch [t, k] {
			case [ATObject, KNull]: ABoxed(AString(null));
			case [ATObject, _]: ABoxed(valueOf(k, naturalType(k)));
			case [ATBool, KBool(b)]: ABool(b);
			case [ATR4 | ATR8, KInt(v, lt)]:
				var high:Float = lt.match(ATU8) && v.high < 0 ? v.high + 4294967296.0 : v.high;
				AFloat(t, high * 4294967296.0 + (v.low < 0 ? v.low + 4294967296.0 : v.low));
			case [ATR4 | ATR8, KFloat(v)]: AFloat(t, v);
			case [_, KInt(v, _)] if (isIntegral(t) || t.match(ATChar)): AInt(t, v);
			case [ATEnum(p, under), KInt(v, _) | KEnum(_, v)]: AEnum(qualified(LValueType(p, [])), under, v);
			case [ATString, KString(s)]: AString(s);
			case [ATString, KNull]: AString(null);
			case [ATType, KType(name)]: AType(name);
			case [ATType, KNull]: AType(null);
			case [ATArray(e), KNull]: AArray(e, null);
			case [ATArray(e), KArray(values)]: AArray(e, [for (v in values) valueOf(v, e)]);
			case _: throw "internal error: an attribute argument that does not convert";
		}
	}

	// A constant's type, for messages.
	function constLabel(k:Const):String {
		return switch (k) {
			case KInt(_, t): haxeName(sigOf(t));
			case KFloat(_): "Float";
			case KString(_): "String";
			case KBool(_): "Bool";
			case KNull: "null";
			case KType(_): "cs.system.Type";
			case KEnum(t, _): haxeName(sigOf(t));
			case KArray(_):
				var t = naturalType(k);
				t == null ? "Array" : haxeName(sigOf(t));
		}
	}

	// ---- constructors and members

	// The constructors of the attribute class that an attribute can call, in declaration order.
	function candidates(cls:AttrClass):Array<Candidate> {
		var r:Array<Candidate> = [];
		if (cls.net != null) {
			for (m in cls.net.cmethods) {
				if (m.mname != ".ctor" || m.mflags.access != FAPublic || m.mflags.contract.indexOf(CMStatic) >= 0) continue;
				var sigs = [for (a in m.margs) a.sig.snorm];
				var params = [for (s in sigs) attrType(s)];
				if (params.indexOf(null) >= 0) continue;
				var owner = LClass(cls.path, []);
				r.push({sigs: sigs, params: params, token: () -> g.mb.memberRef(g.typeTokenOf(owner), ".ctor", g.sigs.method(true, LVoid, sigs, 0))});
			}
		} else if (cls.c != null) {
			var plan = g.planOf.get(cls.c);
			if (plan == null) {
				var why = g.types.leftOut.get(DotnetTypes.haxePath(TClassDecl(cls.c)));
				throw Unsupported.error("the attribute class " + cls.name + " is not in the assembly" + (why == null ? "" : " (left out: " + why + ")"));
			}
			var ctors = [];
			for (m in plan.methods) {
				if (m.name != ".ctor" || !m.hasThis || m.flags & 7 != MethodAttrs.PUBLIC || m.kind.match(MEmptyCtor)) continue;
				var params = [for (s in m.args) attrType(s)];
				if (params.indexOf(null) >= 0) continue;
				ctors.push(m);
			}
			// The plan lists overloads in its own order; messages list them as the source declares them.
			haxe.ds.ArraySort.sort(ctors, (a, b) -> a.pos.min - b.pos.min);
			for (m in ctors) {
				var token = m.token;
				r.push({sigs: m.args, params: [for (s in m.args) attrType(s)], token: () -> token});
			}
		}
		return r;
	}

	// The constructor C#'s overload resolution chooses for the constants.
	function chooseCtor(cls:AttrClass, args:Array<Const>, pos:Position):Candidate {
		var applicable = [];
		for (c in candidates(cls)) {
			if (c.params.length != args.length) continue;
			var ok = true;
			for (i in 0...args.length) if (!converts(args[i], c.params[i])) ok = false;
			if (ok) applicable.push(c);
		}
		if (applicable.length == 0)
			throw new AttrError("no constructor of " + cls.name + " takes (" + [for (a in args) constLabel(a)].join(", ") + ") (C# error CS1503)", pos);
		function betterThan(a:Candidate, b:Candidate):Bool {
			var some = false;
			for (i in 0...args.length) {
				if (better(args[i], b.params[i], a.params[i])) return false;
				if (better(args[i], a.params[i], b.params[i])) some = true;
			}
			return some;
		}
		for (a in applicable) {
			var best = true;
			for (b in applicable) if (b != a && !betterThan(a, b)) best = false;
			if (best) return a;
		}
		var pair = null;
		for (i in 0...applicable.length) for (j in i + 1...applicable.length)
			if (pair == null && !betterThan(applicable[i], applicable[j]) && !betterThan(applicable[j], applicable[i])) pair = [applicable[i], applicable[j]];
		if (pair == null) pair = [applicable[0], applicable[1]];
		inline function label(c:Candidate) return cls.name + "(" + [for (s in c.sigs) haxeName(s)].join(", ") + ")";
		throw new AttrError("the call to " + cls.name + "'s constructor is ambiguous between " + label(pair[0]) + " and " + label(pair[1]) + " (C# error CS0121)", pos);
	}

	// The public instance field or settable property `name` of the class or its bases; writeOnly when the
	// property has no public getter, which C# needs too.
	function memberOf(cls:AttrClass, name:String):Null<{isProperty:Bool, type:AttrType, label:String, writeOnly:Bool}> {
		var cur = cls, depth = 0;
		while (cur != null && depth++ < 64) {
			var found:Null<{isProperty:Bool, sig:IlSigNorm, writeOnly:Bool}> = null;
			if (cur.net != null) {
				for (f in cur.net.cfields)
					if (f.fname == name && f.fflags.access == FAPublic && f.fflags.contract.indexOf(CStatic) < 0
						&& f.fflags.contract.indexOf(CInitOnly) < 0 && f.fflags.contract.indexOf(CLiteral) < 0)
						found = {isProperty: false, sig: f.fsig.snorm, writeOnly: false};
				for (p in cur.net.cprops)
					if (found == null && p.pname == name && p.pset != null && p.pset.flags.access == FAPublic && p.pset.flags.contract.indexOf(CMStatic) < 0)
						found = {isProperty: true, sig: p.psig.snorm, writeOnly: p.pget == null || p.pget.flags.access != FAPublic};
			} else if (cur.c != null) {
				var plan = g.planOf.get(cur.c);
				if (plan != null) {
					for (f in plan.fields)
						if (f.name == name && f.property == null && f.flags & 7 == FieldAttrs.PUBLIC && f.flags & (FieldAttrs.STATIC | FieldAttrs.INIT_ONLY | FieldAttrs.LITERAL) == 0)
							found = {isProperty: false, sig: f.sig, writeOnly: false};
					for (p in plan.properties)
						if (found == null && p.name == name && p.index.length == 0 && p.isStatic != true && p.setter != null && p.setter.flags & 7 == MethodAttrs.PUBLIC)
							found = {isProperty: true, sig: p.sig, writeOnly: p.getter == null || p.getter.flags & 7 != MethodAttrs.PUBLIC};
				}
			}
			if (found != null) {
				// A property's signature is its type; a field's is the field's.
				var sig = switch (found.sig) {
					case LMethod(_, ret, _): ret;
					case s: s;
				}
				var t = attrType(sig);
				return t == null ? null : {isProperty: found.isProperty, type: t, label: haxeName(sig), writeOnly: found.writeOnly};
			}
			cur = superOf(cur);
		}
		return null;
	}

	// ---- names and the blob

	// A type's display name as a serialized Type names it, without its assembly.
	function bareName(s:IlSigNorm):String {
		return switch (s) {
			case LVector(e): bareName(e) + "[]";
			case LClass(p, args) | LValueType(p, args):
				var base = (p.ns.length > 0 ? p.ns.join(".") + "." : "") + p.nested.concat([p.name]).join("+");
				if (args.length > 0)
					base += "[" + [for (a in args) isLocal(a) ? bareName(a) : "[" + qualified(a) + "]"].join(",") + "]";
				base;
			case _:
				var p = DotnetTypes.primitivePath(s);
				if (p == null) throw "internal error: a Type argument naming " + Std.string(s);
				bareName(LClass(p, []));
		}
	}

	function pathOf(s:IlSigNorm):Null<IlPath> {
		return switch (s) {
			case LVector(e): pathOf(e);
			case LClass(p, _) | LValueType(p, _): p;
			case _: DotnetTypes.primitivePath(s);
		}
	}

	function isLocal(s:IlSigNorm):Bool {
		var p = pathOf(s);
		return p != null && g.mb.definesType(p);
	}

	// The name, assembly-qualified when another assembly defines the type, as Roslyn writes it: Roslyn names the
	// reference pack's assembly (System.Runtime, not the mscorlib of hxcs's net-20 externs that the TypeRefs
	// name), and a --net-lib's own types that library.
	function qualified(s:IlSigNorm):String {
		if (isLocal(s)) return bareName(s);
		var p = pathOf(s);
		var lib = NetRefs.of(g.ctx).packDefiner(p);
		var id = lib != null ? lib.identity() : g.mb.externScope(p);
		var token = id.publicKeyToken == null ? "null" : id.publicKeyToken.toHex();
		return bareName(s) + ", " + id.name + ", Version=" + id.version.join(".") + ", Culture=" + (id.culture == "" ? "neutral" : id.culture)
			+ ", PublicKeyToken=" + token;
	}

	static function typeCode(t:AttrType):Int {
		return switch (t) {
			case ATBool: 0x02;
			case ATChar: 0x03;
			case ATI1: 0x04;
			case ATU1: 0x05;
			case ATI2: 0x06;
			case ATU2: 0x07;
			case ATI4: 0x08;
			case ATU4: 0x09;
			case ATI8: 0x0A;
			case ATU8: 0x0B;
			case ATR4: 0x0C;
			case ATR8: 0x0D;
			case ATString: 0x0E;
			case ATType: 0x50;
			case ATObject: 0x51;
			case ATEnum(_, _): 0x55;
			case ATArray(_): 0x1D;
		}
	}

	// A FieldOrPropType: the type code, an enum's name, an array's element type.
	function typeTag(b:IlBytes, t:AttrType):Void {
		b.u8(typeCode(t));
		switch (t) {
			case ATEnum(p, _): b.serString(qualified(LValueType(p, [])));
			case ATArray(e): typeTag(b, e);
			case _:
		}
	}

	// A boxed value's type, which comes before it.
	function valueTag(b:IlBytes, v:AttrValue):Void {
		switch (v) {
			case ABool(_): b.u8(0x02);
			case AInt(t, _) | AFloat(t, _): b.u8(typeCode(t));
			case AString(_): b.u8(0x0E);
			case AType(_): b.u8(0x50);
			case AEnum(name, _, _):
				b.u8(0x55);
				b.serString(name);
			case AArray(t, _):
				b.u8(0x1D);
				typeTag(b, t);
			case ABoxed(_): b.u8(0x51);
		}
	}

	function intOf(b:IlBytes, t:AttrType, v:Int64):Void {
		switch (t) {
			case ATBool | ATI1 | ATU1: b.u8(v.low & 0xFF);
			case ATChar | ATI2 | ATU2: b.u16(v.low & 0xFFFF);
			case ATI4 | ATU4: b.u32(v.low);
			case ATI8 | ATU8: b.i64(v);
			case ATEnum(_, under): intOf(b, under, v);
			case _: throw "internal error: an integer attribute argument of type " + Std.string(t);
		}
	}

	// A value as a parameter of type `t` takes it: an object parameter's with its type first.
	function fixedArg(b:IlBytes, t:AttrType, v:AttrValue):Void {
		switch (t) {
			case ATObject:
				var inner = switch (v) {
					case ABoxed(x): x;
					case _: v;
				}
				valueTag(b, inner);
				bare(b, inner);
			case _:
				bare(b, v);
		}
	}

	function bare(b:IlBytes, v:AttrValue):Void {
		switch (v) {
			case ABool(x): b.u8(x ? 1 : 0);
			case AInt(t, x): intOf(b, t, x);
			case AFloat(ATR4, x): b.f32(x);
			case AFloat(_, x): b.f64(x);
			case AString(s) | AType(s): b.serString(s);
			case AEnum(_, t, x): intOf(b, t, x);
			case AArray(_, null): b.u32(-1);
			case AArray(t, l):
				b.u32(l.length);
				for (x in l) fixedArg(b, t, x);
			case ABoxed(x):
				valueTag(b, x);
				bare(b, x);
		}
	}
}
