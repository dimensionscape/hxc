package hxc.codegen.dotnet;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.codegen.dotnet.IlMeta.TypeDefSemantics;
import hxc.codegen.dotnet.IlMeta.FieldAccess;
import hxc.codegen.dotnet.IlMeta.FieldContract;
import hxc.codegen.dotnet.IlMeta.MethodContract;
import hxc.codegen.dotnet.IlMeta.MethodImplFlag;
import hxc.codegen.dotnet.IlMeta.ParamIo;
import hxc.codegen.dotnet.IlMeta.IlConstant;
import hxc.codegen.dotnet.IlMeta.ClrMeta;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMetaTools.IlNotFound;

// .NET classes turned into the extern declarations the typer loads.

typedef NetLibCtx = {nstd:Bool, ncom:Context, nil:IlCtx};

// a member of any kind, with its declaring path, its name and whether it is static
private enum IlAnyField {
	AnyField(f:IlField);
	AnyMethod(m:IlMethod);
	AnyProp(p:IlProp);
}

private typedef AllField = {f:IlAnyField, path:IlPath, name:String, isStatic:Bool};

// A .NET enum's constructor and its value. A class, as the value is a 64-bit integer: a number in an
// anonymous structure is a double on the C# target, which keeps 53 bits of it.
@:structInit private class EnumValueOf {
	public var ec:EnumConstructor;
	public var v:haxe.Int64;
}

// the reference's Exit: the member is not converted.
enum NetExit {
	Exit;
}

class NetConverter {
	// see http://msdn.microsoft.com/en-us/library/2sk3x8a7(v=vs.71).aspx
	static function csBinop(op:Binop):String {
		return switch (op) {
			case OpAdd: "op_Addition";
			case OpSub: "op_Subtraction";
			case _: throw NotFound;
		}
	}

	public static function netnameToHx(name:String):String {
		return name.charAt(0).toUpperCase() + name.substr(1);
	}

	public static function isHaxeKeyword(s:String):Bool {
		return switch (s) {
			case "cast" | "extern" | "function" | "in" | "typedef" | "using" | "var" | "untyped" | "inline": true;
			case _: false;
		}
	}

	public static function hxpathToNet(com:Context, path:Path):IlPath {
		var p = com.netPathMap.get(Globals.sTypePath(path));
		return p != null ? p : {ns: [], nested: [], name: "Not_found"};
	}

	static function addCs(ns:Array<String>):Array<String> {
		if (ns.length > 0 && ns[0] == "system") return ["cs"].concat(ns);
		return ns;
	}

	// every byte that is not a letter, a digit or `_` becomes _x<code>_
	public static function escapeChars(s:String):String {
		var b = haxe.io.Bytes.ofString(s);
		var buf = new StringBuf();
		for (i in 0...b.length) {
			var c = b.get(i);
			if ((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code) || (c >= "0".code && c <= "9".code) || c == "_".code)
				buf.addChar(c);
			else
				buf.add("_x" + c + "_");
		}
		return buf.toString();
	}

	public static function netclToHx(cl:String):String {
		if (cl.length > 0) {
			var c = cl.charCodeAt(0);
			if (c >= "a".code && c <= "z".code) cl = String.fromCharCode(c - 32) + cl.substr(1);
		}
		var tick = cl.indexOf("`");
		if (tick < 0) return escapeChars(cl);
		return escapeChars(cl.substr(0, tick)) + "_" + cl.substr(tick + 1);
	}

	static function lowerNs(ns:Array<String>):Array<String> return [for (s in ns) escapeChars(s).toLowerCase()];

	public static function netpathToHx(std:Bool, p:IlPath):Path {
		if (p.nested.length == 0) {
			if (p.ns.length == 0) return new Path([], netclToHx(p.name));
			return new Path(addCs(lowerNs(p.ns)), netclToHx(p.name));
		}
		var nested = [for (n in p.nested) netclToHx(n)];
		var ns = lowerNs(p.ns).concat([p.nested[0]]);
		return new Path(addCs(ns), nested.join("_") + "_" + netclToHx(p.name));
	}

	// the first library added that defines the type
	public static function lookupIlclass(std:Bool, com:Context, ilpath:IlPath):Null<IlClass> {
		var path = netpathToHx(std, ilpath);
		for (lib in com.netLibs) {
			var r = lib.lookup(path);
			if (r != null) return r;
		}
		return null;
	}

	static inline function hint(ct:ComplexType):TypeHint return {ct: ct, pos: Position.nullPos};

	static inline function tpType(ct:ComplexType):TypeParamOrConst return TPType(hint(ct));

	static inline function ilp(ns:Array<String>, name:String):IlPath return {ns: ns, nested: [], name: name};

	public static function mkTypePath(ctx:NetLibCtx, path:IlPath, params:Array<TypeParamOrConst>):ComplexType {
		var sub:Null<String> = null;
		var name:String;
		if (path.nested.length == 0)
			name = netclToHx(path.name);
		else {
			var nested = [for (n in path.nested) netclToHx(n)];
			sub = nested.join("_") + "_" + netclToHx(path.name);
			name = netclToHx(path.nested[0]);
		}
		return CTPath({
			tpackage: netpathToHx(ctx.nstd, {ns: path.ns, nested: [], name: ""}).pack,
			tname: name,
			tparams: params,
			tsub: sub
		});
	}

	static function rawTypePath(pack:Array<String>, name:String, params:Array<TypeParamOrConst>):TypePath {
		return {tpackage: pack, tname: name, tparams: params, tsub: null};
	}

	public static function convertSignature(ctx:NetLibCtx, p:Position, s:IlSigNorm):ComplexType {
		return switch (s) {
			case LVoid: mkTypePath(ctx, ilp([], "Void"), []);
			case LBool: mkTypePath(ctx, ilp([], "Bool"), []);
			case LChar: mkTypePath(ctx, ilp(["cs", "types"], "Char16"), []);
			case LInt8: mkTypePath(ctx, ilp(["cs", "types"], "Int8"), []);
			case LUInt8: mkTypePath(ctx, ilp(["cs", "types"], "UInt8"), []);
			case LInt16: mkTypePath(ctx, ilp(["cs", "types"], "Int16"), []);
			case LUInt16: mkTypePath(ctx, ilp(["cs", "types"], "UInt16"), []);
			case LInt32: mkTypePath(ctx, ilp([], "Int"), []);
			case LUInt32: mkTypePath(ctx, ilp([], "UInt"), []);
			case LInt64: mkTypePath(ctx, ilp(["haxe"], "Int64"), []);
			case LUInt64: mkTypePath(ctx, ilp(["cs", "types"], "UInt64"), []);
			case LFloat32: mkTypePath(ctx, ilp([], "Single"), []);
			case LFloat64: mkTypePath(ctx, ilp([], "Float"), []);
			case LString: mkTypePath(ctx, ilp(["std"], "String"), []);
			case LObject: mkTypePath(ctx, ilp([], "Dynamic"), []);
			case LPointer(s) | LManagedPointer(s): mkTypePath(ctx, ilp(["cs"], "Pointer"), [tpType(convertSignature(ctx, p, s))]);
			case LTypedReference: mkTypePath(ctx, ilp(["cs", "system"], "TypedReference"), []);
			case LIntPtr: mkTypePath(ctx, ilp(["cs", "system"], "IntPtr"), []);
			case LUIntPtr: mkTypePath(ctx, ilp(["cs", "system"], "UIntPtr"), []);
			case LValueType(s, args) | LClass(s, args): mkTypePath(ctx, s, [for (a in args) tpType(convertSignature(ctx, p, a))]);
			case LTypeParam(i): mkTypePath(ctx, ilp([], "T" + i), []);
			case LMethodTypeParam(i): mkTypePath(ctx, ilp([], "M" + i), []);
			case LVector(s): mkTypePath(ctx, ilp(["cs"], "NativeArray"), [tpType(convertSignature(ctx, p, s))]);
			case LMethod(_, ret, args): CTFunction([for (a in args) hint(convertSignature(ctx, p, a))], hint(convertSignature(ctx, p, ret)));
			case _: mkTypePath(ctx, ilp([], "Dynamic"), []);
		}
	}

	public static function ilpathS(p:IlPath):String {
		if (p.nested.length == 0) return p.ns.length == 0 ? p.name : p.ns.join(".") + "." + p.name;
		if (p.ns.length == 0) return p.nested.join(".") + "." + p.name;
		return p.ns.join(".") + "." + p.nested.join(".") + "." + p.name;
	}

	static function hasAttr(expectedName:String, expectedNs:Array<String>, ilcls:IlClass):Bool {
		inline function check(name:String, ns:Array<String>) return name == expectedName && IlPaths.strsEq(ns, expectedNs);
		for (a in ilcls.cattrs) {
			var hit = switch (a.type) {
				case TypeRef(r): check(r.name, r.namespace);
				case TypeDef(d): check(d.name, d.namespace);
				case Method(m): m.declaring != null && check(m.declaring.name, m.declaring.namespace);
				case MemberRef(r): switch (r.cls) {
						case TypeRef(r): check(r.name, r.namespace);
						case TypeDef(d): check(d.name, d.namespace);
						case _: false;
					}
				case _: false;
			}
			if (hit) return true;
		}
		return false;
	}

	public static function enumIsFlag(ilcls:IlClass):Bool return hasAttr("FlagsAttribute", ["System"], ilcls);

	public static function isCompilerGenerated(ilcls:IlClass):Bool
		return hasAttr("CompilerGeneratedAttribute", ["System", "Runtime", "CompilerServices"], ilcls);

	static function mkMeta(name:String, p:Position, ?params:Array<Expr>):MetadataEntry
		return {name: name, params: params == null ? [] : params, pos: p};

	static function nativeMeta(s:String, p:Position):MetadataEntry
		return mkMeta(":native", p, [new Expr(EConst(CString(s, SDoubleQuotes)), p)]);

	static inline function acc(a:Access, ?p:Position):PlacedAccess return {access: a, pos: p == null ? Position.nullPos : p};

	static inline function placed(name:String):PlacedName return {name: name, pos: Position.nullPos};

	static inline function withFile(p:Position, name:String):Position return new Position(p.file + " (" + name + ")", p.min, p.max);

	static inline function debug(com:Context):Bool return com.defines.rawDefined("net_loader_debug");

	public static function convertIlEnum(ctx:NetLibCtx, p:Position, ilcls:IlClass, isFlag:Bool):TypeDecl {
		var meta = [nativeMeta(ilpathS(ilcls.cpath), p), mkMeta(":csNative", p)];
		var data:Array<EnumValueOf> = [];
		for (f in ilcls.cfields) {
			if (f.fname == "value__") continue;
			if (f.fflags.contract.indexOf(CStatic) < 0) continue;
			var fmeta:Metadata = [];
			var value:haxe.Int64 = 0;
			switch (f.fconstant) {
				case IChar(i) | IByte(i) | IShort(i):
					fmeta = [mkMeta(":csNative", p, [new Expr(EConst(CInt(Std.string(i))), p)])];
					value = i;
				case IInt(i):
					fmeta = [mkMeta(":csNative", p, [new Expr(EConst(CInt(Std.string(i))), p)])];
					value = i;
				case IFloat32(v) | IFloat64(v):
					value = floatToInt64(v);
				case IInt64(i, _):
					value = i;
				case _:
			}
			data.push({
				ec: {ecName: placed(f.fname), ecDoc: null, ecMeta: fmeta, ecArgs: [], ecPos: p, ecParams: [], ecType: null},
				v: value
			});
		}
		haxe.ds.ArraySort.sort(data, (a, b) -> haxe.Int64.compare(a.v, b.v));
		var name = netnameToHx(netpathToHx(ctx.nstd, ilcls.cpath).name);
		var d:Definition<EnumFlag, Array<EnumConstructor>> = {
			dName: placed(isFlag ? name + "_FlagsEnum" : name),
			dDoc: null,
			dParams: [], // enums never have type parameters
			dMeta: meta,
			dFlags: [EExtern],
			dData: [for (e in data) e.ec]
		};
		return {decl: EEnum(d), pos: p};
	}

	// OCaml's Int64.of_float: truncated toward zero
	static function floatToInt64(f:Float):haxe.Int64 {
		if (Math.isNaN(f) || !Math.isFinite(f)) return 0;
		f = f < 0 ? Math.fceil(f) : Math.ffloor(f);
		if (f >= 9.2233720368547758e18 || f < -9.2233720368547758e18) return 0;
		return haxe.Int64.fromFloat(f);
	}

	static function hasUnmanaged(s:IlSigNorm):Bool {
		return switch (s) {
			case LPointer(_): true;
			case LManagedPointer(s): hasUnmanaged(s);
			case LValueType(_, pl) | LClass(_, pl): Lambda.exists(pl, hasUnmanaged);
			case LVector(s): hasUnmanaged(s);
			case LArray(s, _): hasUnmanaged(s);
			case LMethod(_, r, args): hasUnmanaged(r) || Lambda.exists(args, hasUnmanaged);
			case _: false;
		}
	}

	static function fieldAccess(a:FieldAccess):PlacedAccess {
		return switch (a) {
			case FAFamily | FAFamOrAssem: acc(APrivate);
			case FAPublic: acc(APublic);
			// private instances aren't useful on externs
			case _: throw Exit;
		}
	}

	// a name starting with % is a renamed one: _name, with the original as its native name
	static function percentName(name:String, meta:Metadata, p:Position):{name:String, meta:Metadata} {
		if (name.charAt(0) != "%") return {name: name, meta: meta};
		var n = name.substr(1);
		return {name: "_" + n, meta: [nativeMeta(n, p)].concat(meta)};
	}

	static function hxPrefixed(name:String):Bool return name.length > 5 && name.substr(0, 5) == "__hx_";

	public static function convertIlfield(ctx:NetLibCtx, p:Position, field:IlField):ClassField {
		var com = ctx.ncom;
		if (!com.defines.rawDefined("unsafe") && hasUnmanaged(field.fsig.snorm)) throw Exit;
		p = withFile(p, field.fname);
		var cffName = field.fname;
		if (hxPrefixed(cffName)) throw Exit;
		var cffAccess = fieldAccess(field.fflags.access);
		var readonly = false;
		var access = [cffAccess];
		for (c in field.fflags.contract) switch (c) {
			case CStatic: access.unshift(acc(AStatic));
			case CInitOnly | CLiteral: readonly = true;
			case _:
		}
		if (debug(com))
			Sys.println("\t" + (Lambda.exists(access, a -> a.access == AStatic) ? "static " : "") + "field " + cffName + " : "
				+ IlMetaTools.ilsigS(field.fsig.ssig));
		var meta:Metadata = [];
		var kind = if (readonly) {
			meta.unshift(mkMeta(":readOnly", p));
			FProp(placed("default"), placed("never"), hint(convertSignature(ctx, p, field.fsig.snorm)), null);
		} else
			FVar(hint(convertSignature(ctx, p, field.fsig.snorm)), null);
		var n = percentName(cffName, meta, p);
		return new ClassField(placed(n.name), null, p, n.meta, access, kind);
	}

	public static function convertIlevent(ctx:NetLibCtx, p:Position, ev:IlEvent):ClassField {
		p = withFile(p, ev.ename);
		var name = ev.ename;
		var kind = FVar(hint(convertSignature(ctx, p, ev.esig.snorm)), null);
		var meta = [mkMeta(":event", p), mkMeta(":keep", p), mkMeta(":skipReflection", p)];
		var access = [acc(APrivate)];
		function addM(m:Null<IlAccessor>) {
			if (m != null && m.flags.contract.indexOf(CMStatic) >= 0) access.unshift(acc(AStatic));
		}
		if (debug(ctx.ncom)) Sys.println("\tevent " + name + " : " + IlMetaTools.ilsigS(ev.esig.ssig));
		addM(ev.eadd);
		addM(ev.eremove);
		addM(ev.eraise);
		return new ClassField(placed(name), null, p, meta, access, kind);
	}

	static function changeSig(s:IlSigNorm):IlSigNorm {
		return switch (s) {
			case LManagedPointer(s): LManagedPointer(changeSig(s));
			case LPointer(s): LPointer(changeSig(s));
			case LValueType(p, pl): LValueType(p, [for (s in pl) changeSig(s)]);
			case LClass(p, pl): LClass(p, [for (s in pl) changeSig(s)]);
			case LTypeParam(_): LObject;
			case LVector(s): LVector(changeSig(s));
			case LArray(s, a): LArray(changeSig(s), a);
			case LMethod(c, r, args): LMethod(c, changeSig(r), [for (s in args) changeSig(s)]);
			case p: p;
		}
	}

	public static function convertIlmethod(ctx:NetLibCtx, p:Position, isInterface:Bool, m:IlMethod, isExplicitImpl:Bool):ClassField {
		var com = ctx.ncom;
		if (!com.defines.rawDefined("unsafe") && hasUnmanaged(m.msig.snorm)) throw Exit;
		var forceCheck = com.defines.rawDefined("force_lib_check");
		p = withFile(p, m.mname);
		var cffName = switch (m.mname) {
			case ".ctor": "new";
			case ".cctor": throw Exit; // __init__ field
			case "Finalize": throw Exit; // destructor (~ClassName)
			case "Equals" | "GetHashCode": throw Exit;
			case name if (hxPrefixed(name)): throw Exit;
			case name: name;
		}
		var meta:Metadata = [];
		var access:Array<PlacedAccess> = switch (m.mflags.access) {
			case FAFamily | FAFamOrAssem:
				meta.unshift(mkMeta(":protected", p));
				[acc(APrivate)];
			case FAPublic:
				[acc(APublic)];
			case _:
				if (debug(com)) Sys.println("\tmethod " + cffName + " (skipped) : " + IlMetaTools.ilsigS(m.msig.ssig));
				throw Exit;
		}
		var isStatic = false;
		var isFinal:Null<Bool> = null;
		for (c in m.mflags.contract) switch (c) {
			case CMStatic if (cffName != "new"):
				isStatic = true;
				access.unshift(acc(AStatic));
			case CMVirtual if (isFinal == null):
				isFinal = false;
			case CMFinal:
				isFinal = true;
			case _:
		}
		access.unshift(acc(AOverload, p));
		if (debug(com)) Sys.println("\t" + (isStatic ? "static " : "") + "method " + cffName + " : " + IlMetaTools.ilsigS(m.msig.ssig));
		if ((isFinal == null || isFinal == true) && !forceCheck && !isStatic) access.unshift(acc(AFinal));
		if (isExplicitImpl) meta = [mkMeta(":noCompletion", p), mkMeta(":skipReflection", p)].concat(meta);

		var change = isStatic ? changeSig : (s -> s);
		var ret = m.mret.snorm;
		if (cffName.length > 4 && cffName.substr(0, 4) == "set_") switch [m.mret.snorm, m.margs] {
			case [LVoid, [a]]: ret = a.sig.snorm;
			case _:
		}
		var args:Array<FunctionArg> = [
			for (a in m.margs) {
				var t = switch (a.sig.snorm) {
					case LManagedPointer(s):
						var isOut = a.flags.io.indexOf(POut) >= 0 && a.flags.io.indexOf(PIn) < 0;
						mkTypePath(ctx, ilp(["cs"], isOut ? "Out" : "Ref"), [tpType(convertSignature(ctx, p, s))]);
					case _:
						convertSignature(ctx, p, change(a.sig.snorm));
				}
				{name: placed(a.name), opt: false, meta: [], type: hint(t), value: null};
			}
		];
		var retCt = convertSignature(ctx, p, change(ret));
		var types:Array<TypeParam> = [for (t in m.mtypes) typeParam("M" + t.tnumber)];
		var kind = FFun({fParams: types, fArgs: args, fType: hint(retCt), fExpr: null});
		var n = percentName(cffName, meta, p);
		if (m.moverride == null) {
			if (!isInterface && m.mflags.impl.indexOf(IAbstract) >= 0) access.unshift(acc(AAbstract));
		} else if (n.name != "new") {
			var ilcls = lookupIlclass(ctx.nstd, com, m.moverride.path);
			if (ilcls != null) {
				if (ilcls.cflags.semantics.indexOf(SInterface) < 0) access.unshift(acc(AOverride));
			} else
				com.log("(net-lib) A referenced assembly for path " + ilpathS(m.moverride.path) + " was not found");
		}
		return new ClassField(placed(n.name), null, p, n.meta, access, kind);
	}

	static function typeParam(name:String):TypeParam
		return {tpName: placed(name), tpParams: [], tpConstraints: null, tpDefault: null, tpMeta: []};

	public static function convertIlprop(ctx:NetLibCtx, p:Position, prop:IlProp, isExplicitImpl:Bool):ClassField {
		if (!ctx.ncom.defines.rawDefined("unsafe") && hasUnmanaged(prop.psig.snorm)) throw Exit;
		p = withFile(p, prop.pname);
		var pmflags = prop.pget != null ? prop.pget.flags : prop.pset != null ? prop.pset.flags : null;
		if (pmflags == null) throw Exit;
		var cffAccess = switch (pmflags.access) {
			case FAFamily | FAFamOrAssem: acc(APrivate);
			case FAPublic: acc(APublic);
			// non-public / protected fields don't interest us
			case _: throw Exit;
		}
		var access = pmflags.contract.indexOf(CMStatic) >= 0 ? [acc(AStatic), cffAccess] : [cffAccess];
		inline function accessorPrefixed(s:String, prefix:String) return s.length > 4 && s.substr(0, 4) == prefix;
		var get = if (prop.pget == null) "never"
			// special (?) getter; not used
			else if (!accessorPrefixed(prop.pget.name, "get_")) throw Exit
			else if (prop.pget.flags.access != FAPublic) switch (prop.pget.flags.access) {
				case FAFamily | FAFamOrAssem: "null";
				case _: "never";
			} else "get";
		var set = if (prop.pset == null) "never"
			else if (!accessorPrefixed(prop.pset.name, "set_")) throw Exit
			else if (prop.pset.flags.access != FAPublic) "never"
			else "set";
		if (debug(ctx.ncom)) Sys.println("\tproperty " + prop.pname + " (" + get + "," + set + ") : " + IlMetaTools.ilsigS(prop.psig.ssig));
		var ilsig = switch (prop.psig.snorm) {
			case LMethod(_, ret, []): ret;
			case _: throw Exit;
		}
		var meta = isExplicitImpl ? [mkMeta(":noCompletion", p), mkMeta(":skipReflection", p)] : [];
		var kind = FProp(placed(get), placed(set), hint(convertSignature(ctx, p, ilsig)), null);
		return new ClassField(placed(prop.pname), null, p, meta, access, kind);
	}

	static function getTypePath(ct:ComplexType):TypePath {
		return switch (ct) {
			case CTPath(p): p;
			case _: throw "Assertion failed: get_type_path";
		}
	}

	static function isExplicit(ilcls:IlClass, i:IlSigNorm):Bool {
		var s = switch (i) {
			case LClass(path, _) | LValueType(path, _): ilpathS(path);
			case _: throw "Assertion failed: is_explicit";
		}
		for (m in ilcls.cmethods) if (m.mname.length > s.length && m.mname.substr(0, s.length) == s) return true;
		return false;
	}

	static inline function e(d:ExprDef, p:Position):Expr return new Expr(d, p);

	static inline function ident(s:String, p:Position):Expr return e(EConst(CIdent(s)), p);

	static function mkSpecialCall(name:String, p:Position, args:Array<Expr>):Expr
		return e(ECast(e(EUntyped(e(ECall(ident(name, p), args), p)), p), null), p);

	static function mkAbstractFun(name:String, p:Position, kind:ClassFieldKind, metas:Array<String>, access:Array<PlacedAccess>):ClassField
		return new ClassField(placed(name), null, p, [for (m in metas) mkMeta(m, p)], access, kind);

	static function convertFunArg(ctx:NetLibCtx, p:Position, s:IlSigNorm):TypeHint {
		return switch (s) {
			case LManagedPointer(s): {ct: mkTypePath(ctx, ilp(["cs"], "Ref"), [tpType(convertSignature(ctx, p, s))]), pos: p};
			case s: {ct: convertSignature(ctx, p, s), pos: p};
		}
	}

	static function convertFun(ctx:NetLibCtx, p:Position, ret:IlSigNorm, args:Array<IlSigNorm>):ComplexType
		return CTFunction([for (a in args) convertFunArg(ctx, p, a)], hint(convertSignature(ctx, p, ret)));

	static function delegateName(path:IlPath):IlPath return {ns: path.ns, nested: path.nested, name: "Delegate_" + path.name};

	static function classParams(ctx:NetLibCtx, ilcls:IlClass):Array<TypeParamOrConst>
		return [for (t in ilcls.ctypes) tpType(mkTypePath(ctx, ilp([], "T" + t.tnumber), []))];

	public static function convertDelegate(ctx:NetLibCtx, p:Position, ilcls:IlClass):TypeDecl {
		p = new Position(p.file + " (abstract delegate)", p.min, p.max);
		// will have the following methods:
		// - new (haxeType:Func)
		// - FromHaxeFunction(haxeType)
		// - Invoke()
		// - AsDelegate():Super
		// - @:op(A+B) Add(d:absType)
		// - @:op(A-B) Remove(d:absType)
		var absType = mkTypePath(ctx, ilcls.cpath, classParams(ctx, ilcls));
		var invoke = Lambda.find(ilcls.cmethods, m -> m.mname == "Invoke");
		if (invoke == null) throw NotFound;
		var haxeType = convertFun(ctx, p, invoke.mret.snorm, [for (a in invoke.margs) a.sig.snorm]);
		var types = [for (t in ilcls.ctypes) typeParam("T" + t.tnumber)];
		function arg(name:String, ct:ComplexType):FunctionArg return {name: placed(name), opt: false, meta: [], type: hint(ct), value: null};
		function mkOpFn(op:Binop, name:String, p:Position):ClassFieldKind {
			var fnName = csBinop(op);
			var clsname = netpathToHx(ctx.nstd, delegateName(ilcls.cpath)).name;
			var expr = e(ECall(e(EField(ident(clsname, p), fnName, EFNormal), p), [ident("arg1", p), ident("arg2", p)]), p);
			return FFun({
				fParams: types,
				fArgs: [arg("arg1", absType), arg("arg2", absType)],
				fType: hint(absType),
				fExpr: e(EReturn(expr), p)
			});
		}
		function mkOp(op:Binop, name:String):ClassField {
			var p = new Position(p.file + " (op " + name + ")", p.min, p.max);
			return new ClassField(placed(name), null, p, [mkMeta(":op", p, [e(EBinop(op, ident("A", p), ident("B", p)), p)])],
				[acc(APublic), acc(AInline), acc(AStatic), acc(AExtern)], mkOpFn(op, name, p));
		}
		var params = [for (t in types) tpType(mkTypePath(ctx, ilp([], t.tpName.name), []))];
		var underlyingType = mkTypePath(ctx, delegateName(ilcls.cpath), params);
		var fnNew = FFun({
			fParams: [],
			fArgs: [arg("hxfunc", haxeType)],
			fType: null,
			fExpr: e(EBinop(OpAssign, ident("this", p), mkSpecialCall("__delegate__", p, [ident("hxfunc", p)])), p)
		});
		var fnFromHx = FFun({
			fParams: types,
			fArgs: [arg("hxfunc", haxeType)],
			fType: hint(mkTypePath(ctx, ilcls.cpath, params)),
			fExpr: e(EReturn(mkSpecialCall("__delegate__", p, [ident("hxfunc", p)])), p)
		});
		var fnAsdel = FFun({
			fParams: [],
			fArgs: [],
			fType: null,
			fExpr: e(EReturn(ident("this", p)), p)
		});
		var fields = [
			mkAbstractFun("new", p, fnNew, [], [acc(APublic), acc(AInline), acc(AExtern)]),
			mkAbstractFun("FromHaxeFunction", p, fnFromHx, [":from"], [acc(APublic), acc(AInline), acc(AStatic), acc(AExtern)]),
			mkAbstractFun("AsDelegate", p, fnAsdel, [], [acc(APublic), acc(AInline), acc(AExtern)]),
			mkOp(OpAdd, "Add"),
			mkOp(OpSub, "Remove")
		];
		var d:Definition<AbstractFlag, Array<ClassField>> = {
			dName: placed(netnameToHx(netpathToHx(ctx.nstd, ilcls.cpath).name)),
			dDoc: null,
			dParams: types,
			dMeta: [mkMeta(":delegate", p), mkMeta(":forward", p)],
			dFlags: [AbOver(hint(underlyingType))],
			dData: fields
		};
		return {decl: EAbstract(d), pos: p};
	}

	static function isSystem(path:IlPath, name:String):Bool
		return path.name == name && path.nested.length == 0 && path.ns.length == 1 && path.ns[0] == "System";

	static function isHaxeLang(path:IlPath, name:String):Bool
		return path.name == name && path.nested.length == 0 && path.ns.length == 2 && path.ns[0] == "haxe" && path.ns[1] == "lang";

	public static function convertIlClass(lib:NetLibCtx, p:Position, cls:IlClass, delegate:Bool):TypeDecl {
		var ctx = lib;
		var ilcls = cls;
		if (ilcls.csuper != null) switch (ilcls.csuper.snorm) {
			case LClass(path, []) if (isSystem(path, "Enum")):
				return convertIlEnum(ctx, p, ilcls, false);
			case _:
		}
		var com = ctx.ncom;
		var flags:Array<ClassFlag> = [HExtern];
		// todo: instead of CsNative, use more specific definitions
		if (debug(com)) {
			var sup = ilcls.csuper == null ? [] : [IlMetaTools.ilsigS(ilcls.csuper.ssig)];
			sup = sup.concat([for (i in ilcls.cimplements) IlMetaTools.ilsigS(i.ssig)]);
			Sys.println("converting " + ilpathS(ilcls.cpath) + " : " + sup.join(", "));
		}
		var meta = [mkMeta(":csNative", p), nativeMeta(ilpathS(ilcls.cpath), p)];
		var forceCheck = com.defines.rawDefined("force_lib_check");
		if (!forceCheck) meta.unshift(mkMeta(":libType", p));

		var isInterface = false;
		var isAbstract = false;
		var isSealed = false;
		for (f in ilcls.cflags.semantics) switch (f) {
			case SSealed:
				flags.unshift(HFinal);
				isSealed = true;
			case SInterface:
				isInterface = true;
				flags.unshift(HInterface);
			case SAbstract:
				meta.unshift(mkMeta(":abstract", p));
				isAbstract = true;
			case _:
		}

		// static class = abstract sealed class - in this case we don't want an abstract flag
		if (isAbstract && !isInterface && !isSealed) flags.unshift(HAbstract);

		inline function placedPath(ct:ComplexType):PlacedTypePath return {path: getTypePath(ct), pos: Position.nullPos};
		if (ilcls.csuper != null) switch (ilcls.csuper.snorm) {
			case LClass(path, []) if (isSystem(path, "Object")):
			case LClass(path, []) if (isSystem(path, "ValueType")):
				flags.unshift(HExtends(placedPath(convertSignature(ctx, p, ilcls.csuper.snorm))));
				meta.unshift(mkMeta(":struct", p));
			case LClass(path, []) if (isHaxeLang(path, "HxObject")):
				meta.unshift(mkMeta(":hxGen", p));
			case s:
				flags.unshift(HExtends(placedPath(convertSignature(ctx, p, s))));
		}

		var hasExplicitIfaces = false;
		for (i in ilcls.cimplements) switch (i.snorm) {
			case LClass(path, _) if (isHaxeLang(path, "IHxObject")):
				meta.unshift(mkMeta(":hxGen", p));
			case i:
				if (isExplicit(ilcls, i)) hasExplicitIfaces = true;
				var tp = placedPath(convertSignature(ctx, p, i));
				flags.unshift(isInterface ? HExtends(tp) : HImplements(tp));
		}
		// this is needed because of explicit interfaces. see http://msdn.microsoft.com/en-us/library/aa288461(v=vs.71).aspx
		// explicit interfaces can't be mapped into Haxe in any way - since their fields can't be accessed directly, but they
		// still implement that interface
		if (hasExplicitIfaces && forceCheck) // do not check on this specific case
			meta.unshift(mkMeta(":libType", p));

		// ArrayAccess
		for (prop in ilcls.cprops) switch (prop.psig.snorm) {
			case LMethod(_, ret, [_]):
				var tp:PlacedTypePath = {path: rawTypePath([], "ArrayAccess", [tpType(convertSignature(ctx, p, ret))]), pos: Position.nullPos};
				flags.unshift(isInterface ? HExtends(tp) : HImplements(tp));
				break;
			case _:
		}

		var fields:Array<ClassField> = [];
		function runFields<T>(fn:T->ClassField, l:Array<T>) {
			for (f in l) try fields.unshift(fn(f)) catch (_:NetExit) {}
		}
		var meths = isInterface ? [for (m in ilcls.cmethods) if (m.moverride == null) m] : ilcls.cmethods;
		inline function explicitSuffix(name:String, other:String) return other.charAt(0) != "." && StringTools.endsWith(other, "." + name);
		runFields(m -> convertIlmethod(ctx, p, isInterface, m, Lambda.exists(meths, m2 -> m != m2 && explicitSuffix(m.mname, m2.mname))),
			meths);
		runFields(f -> convertIlfield(ctx, p, f), ilcls.cfields);
		runFields(prop -> convertIlprop(ctx, p, prop,
			Lambda.exists(ilcls.cprops, p2 -> prop != p2 && explicitSuffix(prop.pname, p2.pname))), ilcls.cprops);
		runFields(ev -> convertIlevent(ctx, p, ev), ilcls.cevents);

		var params = [for (t in ilcls.ctypes) typeParam("T" + t.tnumber)];

		if (delegate) {
			// add op_Addition and op_Subtraction
			var thist = mkTypePath(ctx, ilcls.cpath, classParams(ctx, ilcls));
			function op(name:String):ClassField {
				function arg(n:String):FunctionArg return {name: placed(n), opt: false, meta: [], type: hint(thist), value: null};
				return new ClassField(placed(name), null, p, [], [acc(APublic), acc(AStatic)],
					FFun({fParams: params, fArgs: [arg("arg1"), arg("arg2")], fType: hint(thist), fExpr: null}));
			}
			fields = [op("op_Addition"), op("op_Subtraction")].concat(fields);
		}
		var path = delegate ? delegateName(ilcls.cpath) : ilcls.cpath;
		var d:Definition<ClassFlag, Array<ClassField>> = {
			dName: placed(netnameToHx(netpathToHx(ctx.nstd, path).name)),
			dDoc: null,
			dParams: params,
			dMeta: meta,
			dFlags: flags,
			dData: fields
		};
		return {decl: EClass(d), pos: p};
	}

	// ******* class normalization *********

	static function isStaticField(f:IlAnyField):Bool {
		return switch (f) {
			case AnyField(f): f.fflags.contract.indexOf(CStatic) >= 0;
			case AnyMethod(m): m.mflags.contract.indexOf(CMStatic) >= 0;
			case AnyProp(p): (p.pget != null && p.pget.flags.contract.indexOf(CMStatic) >= 0)
				|| (p.pset != null && p.pset.flags.contract.indexOf(CMStatic) >= 0);
		}
	}

	static function changeName(name:String, f:IlAnyField):IlAnyField {
		return switch (f) {
			case AnyField(f):
				var c = f.copy();
				c.fname = name;
				AnyField(c);
			case AnyMethod(m):
				var c = m.copy();
				c.mname = name;
				AnyMethod(c);
			case AnyProp(p):
				var c = p.copy();
				c.pname = name;
				AnyProp(c);
		}
	}

	// throws NotFound when the type is not one a superclass can be, or no library defines it
	static function ilclsFromIlsig(ctx:NetLibCtx, ilsig:IlSigNorm):{cls:IlClass, params:Array<IlSigNorm>} {
		var path:IlPath, params:Array<IlSigNorm>;
		switch (ilsig) {
			case LClass(p, pl) | LValueType(p, pl):
				path = p;
				params = pl;
			case LObject:
				path = ilp(["System"], "Object");
				params = [];
			case _:
				throw NotFound; // all other types won't appear as superclass
		}
		var c = lookupIlclass(ctx.nstd, ctx.ncom, path);
		if (c == null) throw NotFound;
		return {cls: c, params: params};
	}

	static function ilapplyParams(params:Array<IlSigNorm>, s:IlSigNorm):IlSigNorm {
		return switch (s) {
			case LManagedPointer(s): LManagedPointer(ilapplyParams(params, s));
			case LPointer(s): LPointer(ilapplyParams(params, s));
			case LValueType(p, pl): LValueType(p, [for (s in pl) ilapplyParams(params, s)]);
			case LClass(p, pl): LClass(p, [for (s in pl) ilapplyParams(params, s)]);
			case LTypeParam(i):
				if (i < 0) throw "List.nth";
				if (i >= params.length) throw "nth";
				params[i];
			case LVector(s): LVector(ilapplyParams(params, s));
			case LArray(s, a): LArray(ilapplyParams(params, s), a);
			case LMethod(c, r, args): LMethod(c, ilapplyParams(params, r), [for (s in args) ilapplyParams(params, s)]);
			case p: p;
		}
	}

	static function ilclsWithParams(cls:IlClass, params:Array<IlSigNorm>):IlClass {
		if (cls.ctypes.length == 0) return cls;
		inline function ap(s:IlSigT):IlSigT return s.withNorm(ilapplyParams(params, s.snorm));
		var c = cls.copy();
		c.cfields = [for (f in cls.cfields) {var n = f.copy(); n.fsig = ap(f.fsig); n;}];
		c.cmethods = [
			for (m in cls.cmethods) {
				var n = m.copy();
				n.msig = ap(m.msig);
				n.margs = [for (a in m.margs) {name: a.name, flags: a.flags, sig: ap(a.sig), constant: a.constant, pdefault: a.pdefault}];
				n.mret = ap(m.mret);
				n;
			}
		];
		c.cprops = [for (p in cls.cprops) {var n = p.copy(); n.psig = ap(p.psig); n;}];
		c.csuper = cls.csuper == null ? null : ap(cls.csuper);
		c.cimplements = [for (s in cls.cimplements) ap(s)];
		return c;
	}

	static function compatibleParams(t1:IlSigNorm, t2:IlSigNorm):Bool {
		return switch [t1, t2] {
			case [LManagedPointer(s1), LManagedPointer(s2)]: compatibleParams(s1, s2);
			case [LManagedPointer(s1), s2] | [s1, LManagedPointer(s2)]: compatibleParams(s1, s2);
			case _: IlPaths.sigEq(t1, t2);
		}
	}

	static function compatibleMethods(m1:IlSigNorm, m2:IlSigNorm):Bool {
		return switch [m1, m2] {
			case [LMethod(_, _, a1), LMethod(_, _, a2)]:
				if (a1.length != a2.length) return false;
				for (i in 0...a1.length) if (!compatibleParams(a1[i], a2[i])) return false;
				true;
			case _: false;
		}
	}

	static function compatibleField(f1:IlAnyField, f2:IlAnyField):Bool {
		return switch [f1, f2] {
			case [AnyMethod(m1), AnyMethod(m2)]: switch [m1.msig.snorm, m2.msig.snorm] {
					case [LMethod(_, _, a1), LMethod(_, _, a2)]: IlPaths.sigsEq(a1, a2);
					case _: false;
				}
			case [AnyProp(_), AnyProp(_)]: true;
			case [AnyField(_), AnyField(_)]: true;
			case _: false;
		}
	}

	static function getAllFields(cls:IlClass):Array<AllField> {
		var all:Array<AllField> = [
			for (f in cls.cfields) {f: AnyField(f), path: cls.cpath, name: f.fname, isStatic: f.fflags.contract.indexOf(CStatic) >= 0}
		];
		for (m in cls.cmethods) all.push({f: AnyMethod(m), path: cls.cpath, name: m.mname, isStatic: m.mflags.contract.indexOf(CMStatic) >= 0});
		for (p in cls.cprops) all.push({f: AnyProp(p), path: cls.cpath, name: p.pname, isStatic: isStaticField(AnyProp(p))});
		return all;
	}

	static inline function isMethodStatic(m:IlMethod):Bool return m.mflags.contract.indexOf(CMStatic) >= 0;

	public static function normalizeIlcls(ctx:NetLibCtx, cls:IlClass):IlClass {
		var forceCheck = ctx.ncom.defines.rawDefined("force_lib_check");
		// first filter out overloaded fields of same signature; the kept ones end up in reverse order
		var meths:Array<{v:IlMethod}> = [];
		var cm = cls.cmethods;
		for (i in 0...cm.length) {
			var m = cm[i];
			var isStatic = isMethodStatic(m);
			var dup = false;
			for (j in i + 1...cm.length) {
				var m2 = cm[j];
				if (m.mname == m2.mname && isMethodStatic(m2) == isStatic && compatibleMethods(m.msig.snorm, m2.msig.snorm)) {
					dup = true;
					break;
				}
			}
			if (!dup) meths.unshift({v: m});
		}
		// fix overrides
		// get only the methods that aren't declared as override, but may be
		var noOverrides = [for (m in meths) if (!isMethodStatic(m.v)) m];

		var allFields:Array<AllField> = [];
		var allEventsName = new Map<String, Bool>();
		// avoid naming collision between events and functions
		function addClsEventsCollision(cls:IlClass) {
			for (m in cls.cmethods) if (!isMethodStatic(m)) allEventsName.set(m.mname, true);
			for (p in cls.cprops) if (!isStaticField(AnyProp(p))) allEventsName.set(p.pname, true);
		}

		function loop(cls:IlClass) {
			try {
				if (cls.csuper != null) switch (cls.csuper.snorm) {
					case LClass(path, _) if (isSystem(path, "Object")):
						var r = ilclsFromIlsig(ctx, LObject);
						allFields = getAllFields(ilclsWithParams(r.cls, r.params)).concat(allFields);
					case LObject:
						var r = ilclsFromIlsig(ctx, LObject);
						allFields = getAllFields(ilclsWithParams(r.cls, r.params)).concat(allFields);
					case s:
						var r = ilclsFromIlsig(ctx, s);
						var sup = ilclsWithParams(r.cls, r.params);
						if (forceCheck) noOverrides = [
							for (v in noOverrides) {
								var m = v.v;
								var isOverrideHere = Lambda.exists(sup.cmethods,
									m2 -> m2.mname == m.mname && !isMethodStatic(m2) && compatibleMethods(m.msig.snorm, m2.msig.snorm));
								if (isOverrideHere) {
									var c = m.copy();
									c.moverride = {path: sup.cpath, name: m.mname};
									v.v = c;
								}
								if (isOverrideHere) continue;
								v;
							}
						];
						allFields = getAllFields(sup).concat(allFields);
						addClsEventsCollision(sup);
						for (ev in sup.cevents) allEventsName.set(ev.ename, true);
						loop(sup);
				}
			} catch (_:IlNotFound) {}
		}
		loop(cls);

		addClsEventsCollision(cls);
		if (forceCheck) for (v in noOverrides) {
			var c = v.v.copy();
			c.moverride = null;
			v.v = c;
		}
		var added:Array<AllField> = [];

		var currentAll = getAllFields(cls).concat(allFields);
		// look for interfaces and add missing implementations (some methods' implementation is optional)
		function loopInterface(cls:IlClass, iface:IlSigT) {
			try {
				switch (iface.snorm) {
					case LClass(path, _) if (isSystem(path, "Object")):
					case LObject:
					case LClass(path, _) if (IlPaths.equals(path, cls.cpath)):
					case s:
						var r = ilclsFromIlsig(ctx, s);
						var cif = ilclsWithParams(r.cls, r.params);
						for (ff in getAllFields(cif)) {
							if (ff.isStatic) continue;
							var f = ff.f, name = ff.name;
							// look for compatible fields; explicit implementations count as implementations
							var found = Lambda.exists(currentAll, f2 -> !f2.isStatic
								&& (name == f2.name || StringTools.endsWith(f2.name, "." + name))
								&& compatibleField(f, f2.f));
							if (!found) {
								currentAll.unshift(ff);
								added.unshift(ff);
							} else
								// ensure it's public
								for (mref in meths) {
									var m = mref.v;
									if (m.mname == name && compatibleField(f, AnyMethod(m))) {
										var c = m.copy();
										c.mflags = m.mflags.withAccess(FAPublic);
										mref.v = c;
									}
								}
						}
						for (i in cif.cimplements) loopInterface(cif, i);
				}
			} catch (_:IlNotFound) {}
		}
		if (cls.cflags.semantics.indexOf(SAbstract) < 0) for (i in cls.cimplements) loopInterface(cls, i);
		var addedPublic:Array<AllField> = [
			for (a in added) switch (a.f) {
				case AnyMethod(m) if (m.mflags.access != FAPublic):
					var c = m.copy();
					c.mflags = m.mflags.withAccess(FAPublic);
					{f: AnyMethod(c), path: a.path, name: a.name, isStatic: a.isStatic};
				case AnyField(f) if (f.fflags.access != FAPublic):
					var c = f.copy();
					c.fflags = f.fflags.withAccess(FAPublic);
					{f: AnyField(c), path: a.path, name: a.name, isStatic: a.isStatic};
				case _: a;
			}
		];

		// filter out properties that were already declared
		var props = if (forceCheck) [
			for (p in cls.cprops) {
				var isStatic = isStaticField(AnyProp(p));
				var name = p.pname;
				if (Lambda.exists(allFields, a -> a.f.match(AnyProp(_)) && a.isStatic == isStatic && a.name == name)) continue;
				p;
			}
		] else cls.cprops;
		var cls = cls.copy();
		cls.cmethods = [for (v in meths) v.v];
		cls.cprops = props;

		var clsfields = getAllFields(cls).concat(addedPublic);
		var superFields = allFields;
		allFields = clsfields.concat(allFields);
		// search static / non-static name clash
		// change field name to not collide with haxe keywords
		var refclsfields:Array<AllField> = [];
		for (v in clsfields) {
			var name = v.name, isStatic = v.isStatic;
			var change:Bool, copy:Bool;
			if (isHaxeKeyword(name)) {
				change = true;
				copy = false;
			} else {
				change = (isStatic && Lambda.exists(allFields, a -> !a.isStatic && a.name == name)) || (!isStatic && switch (v.f) {
					// filter methods that have the same name as fields
					case AnyMethod(_):
						Lambda.exists(superFields, a -> !a.isStatic && a.name == name && !a.f.match(AnyMethod(_)))
						|| Lambda.exists(clsfields, a -> a.name == name && !a.f.match(AnyMethod(_)));
					case _: false;
				});
				copy = true;
			}
			if (change) {
				var n = "%" + name;
				var changed:AllField = {f: changeName(n, v.f), path: v.path, name: n, isStatic: isStatic};
				if (copy) {
					refclsfields.unshift(changed);
					refclsfields.unshift(v);
				} else
					refclsfields.unshift(changed);
			} else
				refclsfields.unshift(v);
		}

		var fields:Array<IlField> = [], methods:Array<IlMethod> = [], props:Array<IlProp> = [];
		for (f in refclsfields) switch (f.f) {
			case AnyField(f): fields.unshift(f);
			case AnyMethod(m): methods.unshift(m);
			case AnyProp(p): props.unshift(p);
		}
		cls.cfields = fields;
		cls.cprops = props;
		cls.cmethods = methods;
		cls.cevents = [for (ev in cls.cevents) if (!allEventsName.exists(ev.ename)) ev];
		return cls;
	}
}
