package hxc.codegen.hl;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlContext;

using hxc.codegen.hl.HlContext;

// The type layer: a port of hlcode.ml's type predicates (is_nullable .. get_index) and of genhl.ml's
// helpers and type functions (lines 139-311, 355-819: to_type, class_type, enum_type, real_type,
// resolve_class, the alloc_* functions, class_global, alloc_std), plus common_type and type_value.
//
// OCaml evaluates the arguments of a call and the components of a constructor or tuple right to left. Where
// two of them allocate in the same table, the port computes them in that order first.
class HlTypes {
	// ---- hlcode.ml

	// hlcode.ml: is_nullable
	public static function isNullable(t:HlType):Bool {
		return switch t {
			case HBytes | HDyn | HFun(_) | HObj(_) | HArray | HVirtual(_) | HDynObj | HAbstract(_) | HEnum(_) | HNull(_) | HRef(_) | HType | HMethod(_) | HStruct(_): true;
			case HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64 | HBool | HVoid | HPacked(_): false;
		}
	}

	// hlcode.ml: is_struct
	public static function isStruct(t:HlType):Bool {
		return switch t {
			case HStruct(_) | HPacked(_): true;
			case _: false;
		}
	}

	// hlcode.ml: is_int
	public static function isInt(t:HlType):Bool {
		return switch t {
			case HUI8 | HUI16 | HI32 | HI64: true;
			case _: false;
		}
	}

	// hlcode.ml: is_float
	public static function isFloat(t:HlType):Bool {
		return switch t {
			case HF32 | HF64: true;
			case _: false;
		}
	}

	// hlcode.ml: is_number
	public static function isNumber(t:HlType):Bool {
		return switch t {
			case HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64: true;
			case _: false;
		}
	}

	// hlcode.ml: is_dynamic
	public static inline function isDynamic(t:HlType):Bool {
		return HlCodeUtils.isDynamic(t);
	}

	// hlcode.ml: tsame
	public static function tsame(t1:HlType, t2:HlType):Bool {
		if (t1 == t2) return true;
		return switch [t1, t2] {
			case [HFun(args1, ret1), HFun(args2, ret2)] | [HMethod(args1, ret1), HMethod(args2, ret2)] if (args1.length == args2.length):
				var ok = true;
				for (i in 0...args1.length) if (!tsame(args1[i], args2[i])) {
					ok = false;
					break;
				}
				ok && tsame(ret2, ret1);
			case [HObj(p1), HObj(p2)]: p1 == p2;
			case [HEnum(e1), HEnum(e2)]: e1 == e2;
			case [HStruct(p1), HStruct(p2)]: p1 == p2;
			case [HAbstract(_, a1), HAbstract(_, a2)]: a1 == a2;
			case [HVirtual(v1), HVirtual(v2)]:
				if (v1 == v2) true else if (v1.vfields.length != v2.vfields.length) false else {
					var ok = true;
					for (i in 0...v1.vfields.length) {
						var f1 = v1.vfields[i], f2 = v2.vfields[i];
						if (!(f1.nameIndex == f2.nameIndex && tsame(f1.t, f2.t))) {
							ok = false;
							break;
						}
					}
					ok;
				}
			case [HNull(t1), HNull(t2)]: tsame(t1, t2);
			case [HRef(t1), HRef(t2)]: tsame(t1, t2);
			case _: false;
		}
	}

	// hlcode.ml: safe_cast (can a value of t1 be used as t2)
	public static function safeCast(t1:HlType, t2:HlType):Bool {
		if (t1 == t2) return true;
		return switch [t1, t2] {
			case [_, HDyn]: isDynamic(t1);
			case [HVirtual(v1), HVirtual(v2)] if (v2.vfields.length < v1.vfields.length):
				var ok = true;
				for (i in 0...v2.vfields.length) {
					var f1 = v1.vfields[i], f2 = v2.vfields[i];
					if (!(f1.name == f2.name && tsame(f1.t, f2.t))) {
						ok = false;
						break;
					}
				}
				ok;
			case [HObj(p1), HObj(p2)] | [HStruct(p1), HStruct(p2)]:
				// allow subtyping
				var p = p1;
				while (p != null && p.pname != p2.pname) p = p.psuper;
				p != null;
			case [HPacked(t1), HStruct(_)]:
				safeCast(t1, t2);
			case [HFun(args1, r1), HFun(args2, r2)] if (args1.length == args2.length):
				var ok = true;
				for (i in 0...args1.length) {
					var a1 = args1[i], a2 = args2[i];
					if (!(safeCast(a2, a1) || (teq(a1, HDyn) && isDynamic(a2)))) {
						ok = false;
						break;
					}
				}
				ok && safeCast(r1, r2);
			case _:
				tsame(t1, t2);
		}
	}

	// hlcode.ml: get_index
	public static function getIndex(name:String, p:HlClassProto):Null<{index:Int, t:HlType}> {
		while (p != null) {
			var i = p.pindex.get(name);
			if (i != null) return i;
			p = p.psuper;
		}
		return null;
	}

	// OCaml's structural compare on ttype, as a key: objects and enums by their name and string index (each
	// is built once), virtuals field by field, everything else by its shape.
	static var keyStack:Array<Dynamic> = [];

	public static function typeKey(t:HlType):String {
		return switch t {
			case HVoid: "v";
			case HUI8: "1";
			case HUI16: "2";
			case HI32: "3";
			case HI64: "4";
			case HF32: "5";
			case HF64: "6";
			case HBool: "b";
			case HBytes: "B";
			case HDyn: "d";
			case HFun(args, ret): "F(" + [for (a in args) typeKey(a)].join(",") + ")" + typeKey(ret);
			case HMethod(args, ret): "M(" + [for (a in args) typeKey(a)].join(",") + ")" + typeKey(ret);
			case HObj(p): "O" + p.pid + ":" + p.pname;
			case HStruct(p): "S" + p.pid + ":" + p.pname;
			case HArray: "a";
			case HType: "t";
			case HRef(t): "R" + typeKey(t);
			case HVirtual(v):
				var depth = keyStack.indexOf(v);
				if (depth >= 0) return "V@" + depth;
				keyStack.push(v);
				var k = "V(" + [for (f in v.vfields) f.name + ":" + f.nameIndex + ":" + typeKey(f.t)].join(",") + ")";
				keyStack.pop();
				k;
			case HDynObj: "o";
			case HAbstract(name, i): "A" + i + ":" + name;
			case HEnum(e) if (e.eid != 0): "E" + e.eid + ":" + e.ename;
			case HEnum(e):
				var depth = keyStack.indexOf(e);
				if (depth >= 0) return "E@" + depth;
				keyStack.push(e);
				var k = "E0(" + e.eglobal + ":" + [for (f in e.efields) f.name + ":" + f.nameIndex + ":" + [for (t in f.t) typeKey(t)].join("+")].join(",") + ")";
				keyStack.pop();
				k;
			case HNull(t): "N" + typeKey(t);
			case HPacked(t): "P" + typeKey(t);
		}
	}

	// OCaml's `=` on ttype
	public static function teq(a:HlType, b:HlType):Bool {
		return a == b || typeKey(a) == typeKey(b);
	}

	// ---- genhl.ml helpers (lines 139-311)

	// genhl.ml: is_to_string
	public static function isToString(t:T):Bool {
		return switch TypeFunctions.follow(t) {
			case TFun(sig) if (sig.args.length == 0):
				switch TypeFunctions.follow(sig.ret) {
					case TInst(c, []) if (c.path.pack.length == 0 && c.path.name == "String"): true;
					case _: false;
				}
			case _: false;
		}
	}

	// genhl.ml: is_string
	public static function isString(t:HlType):Bool {
		return switch t {
			case HObj(p) if (p.pname == "String"): true;
			case _: false;
		}
	}

	// genhl.ml: is_extern_field
	public static function isExternField(f:TClassField):Bool {
		return !TypeFunctions.isPhysicalField(f) || (switch f.kind {
			case Method(MethNormal): [for (m in f.meta) if (m.name == ":hlNative") m].length > 0;
			case _: false;
		}) || TypeFunctions.hasClassFieldFlag(f, CfExtern);
	}

	// genhl.ml: is_array_class
	public static function isArrayClass(name:String):Bool {
		return switch name {
			case "hl.types.ArrayDyn" | "hl.types.ArrayBytes_Int" | "hl.types.ArrayBytes_Float" | "hl.types.ArrayObj" | "hl.types.ArrayBytes_hl_F32" | "hl.types.ArrayBytes_hl_UI16": true;
			case _: false;
		}
	}

	// genhl.ml: is_array_type
	public static function isArrayType(t:HlType):Bool {
		return switch t {
			case HObj(p): isArrayClass(p.pname);
			case _: false;
		}
	}

	// genhl.ml: max_pos
	public static function maxPos(e:TExpr):Position {
		var p = e.pos;
		return new Position(p.file, p.max, p.max);
	}

	// genhl.ml: to_utf8. The string is UTF-16 in hxc; the count is its UTF-16 length, a lone surrogate is an
	// invalid char.
	public static function toUtf8(str:String, p:Position):{s:String, count:Int} {
		var i = 0;
		while (i < str.length) {
			var c = StringTools.fastCodeAt(str, i);
			if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
				var d = StringTools.fastCodeAt(str, i + 1);
				if (d >= 0xDC00 && d <= 0xDFFF) {
					i += 2;
					continue;
				}
			}
			if (c >= 0xD800 && c <= 0xDFFF) HlContext.abort("Invalid unicode char", p);
			i++;
		}
		return {s: str, count: str.length};
	}

	// genhl.ml: tuple_type
	public static function tupleType(ctx:HlContext, tl:Array<HlType>):HlType {
		var key = [for (t in tl) typeKey(t)].join(",");
		var ct = ctx.cachedTuples.get(key);
		if (ct != null) return ct;
		var ct = HEnum({eglobal: null, ename: "", eid: 0, efields: [{name: "", nameIndex: 0, t: tl}]});
		ctx.cachedTuples.set(key, ct);
		return ct;
	}

	// genhl.ml: type_size_bits
	public static function typeSizeBits(t:HlType):Int {
		return switch t {
			case HUI8 | HBool: 0;
			case HUI16: 1;
			case HI32 | HF32: 2;
			case HI64 | HF64: 3;
			case _: HlContext.die();
		}
	}

	// genhl.ml: field_name
	public static function fieldName(c:TClass, f:TClassField):String {
		return Globals.sTypePath(c.path) + ":" + f.name;
	}

	// genhl.ml: efield_name
	public static function efieldName(e:TEnum, f:TEnumField):String {
		return Globals.sTypePath(e.path) + ":" + f.name;
	}

	// genhl.ml: array_class
	public static function arrayClass(ctx:HlContext, t:HlType):TClass {
		return switch t {
			case HI32: ctx.arrayImpl.ai32;
			case HUI16: ctx.arrayImpl.aui16;
			case HF32: ctx.arrayImpl.af32;
			case HF64: ctx.arrayImpl.af64;
			case HDyn: ctx.arrayImpl.adyn;
			case _: ctx.arrayImpl.aobj;
		}
	}

	// genhl.ml: member_fun
	public static function memberFun(c:TClass, t:T):T {
		return switch TypeFunctions.follow(t) {
			case TFun(sig): TFun({args: [new TSignatureArg("this", false, TInst(c, []))].concat(sig.args), ret: sig.ret});
			case _: HlContext.die();
		}
	}

	// genhl.ml: unsigned
	public static function unsigned(t:T):Bool {
		return switch TypeFunctions.follow(t) {
			case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "UInt"): true;
			case TAbstract(a, pl): unsigned(TypeFunctions.getUnderlyingType(a, pl));
			case _: false;
		}
	}

	// genhl.ml: unsigned_op
	public static function unsignedOp(e1:TExpr, e2:TExpr):Bool {
		function isUnsigned(e:TExpr):Bool {
			return switch e.expr {
				case TConst(TInt(_)): true;
				case _: unsigned(e.type);
			}
		}
		return isUnsigned(e1) && isUnsigned(e2);
	}

	// ---- the type functions (genhl.ml lines 355-819)

	// genhl.ml: fake_tnull, a Null abstract to_type knows by its path
	static var fakeTnullValue:Null<TAbstract> = null;

	static function fakeTnull():TAbstract {
		if (fakeTnullValue == null) {
			var n = TypeFunctions.nullAbstract;
			fakeTnullValue = {
				path: new Path([], "Null"),
				module: n.module,
				pos: n.pos,
				namePos: n.namePos,
				isPrivate: n.isPrivate,
				doc: null,
				meta: [],
				params: [new TypedTypeParam("T", TypeFunctions.tDynamic)],
				usings: [],
				restore: function() {},
				ops: [],
				unops: [],
				impl: null,
				thisType: TypeFunctions.tDynamic,
				from: [],
				fromField: [],
				to: [],
				toField: [],
				array: [],
				read: null,
				write: null,
				call: null,
				isEnum: false
			};
		}
		return fakeTnullValue;
	}

	// genhl.ml: get_rec_cache (List.assq: the entry for this very type value)
	static function getRecCache(ctx:HlContext, t:T, noneCallback:Void->HlType, notFoundCallback:{v:Null<HlType>}->HlType):HlType {
		var i = ctx.recCache.length - 1;
		while (i >= 0) {
			var e = ctx.recCache[i];
			if (e.t == t) {
				var v = e.r.v;
				return v == null ? noneCallback() : v;
			}
			i--;
		}
		var tref = {v: null};
		ctx.recCache.push({t: t, r: tref});
		var r = notFoundCallback(tref);
		ctx.recCache.pop();
		return r;
	}

	// The anons_cache key: equal strings for two anons exactly when OCaml's compare finds them equal (when it
	// terminates). Records compare field by field and short-circuit on physically equal values, so:
	// - a class field is its name, type, positions, doc, meta (each entry's name, argument count and position),
	//   kind, params and flags, with its exprs and overloads by identity (an apply_params copy keeps all but
	//   the type; anons from different declarations differ in their positions);
	// - a class, enum, typedef or abstract is its identity: the same declaration is the same value, and two
	//   different ones differ by path, or by position for type parameters of the same path;
	// - a monomorph is its contents, as a ref is: bound ones by their type, unbound ones without constraints
	//   all alike (constraints, rare here, are keyed by identity); a lazy type once forced by its type;
	// - everything else is structural. An anon reaching itself (OCaml's compare would not end) is a back
	//   reference.
	public static function anonKey(ctx:HlContext, a:TAnon):String {
		var anons:Array<TAnon> = [];
		var monos:Array<TMono> = [];
		function id(o:{}):Int {
			var i = ctx.anonKeyIds.get(o);
			if (i == null) {
				i = ctx.anonKeyNext++;
				ctx.anonKeyIds.set(o, i);
			}
			return i;
		}
		function pos(p:Position):String {
			return p == null ? "-" : p.min + ":" + p.max + ":" + p.file.length + ":" + p.file;
		}
		function str(s:Null<String>):String {
			return s == null ? "-" : s.length + ":" + s;
		}
		var typeKey:T->String = null;
		function params(tl:TParams):String {
			return "<" + [for (t in tl) typeKey(t)].join(",") + ">";
		}
		function access(v:VarAccess):String {
			return switch v {
				case AccNormal: "n";
				case AccNo: "o";
				case AccNever: "v";
				case AccCtor: "c";
				case AccCall: "l";
				case AccInline: "i";
				case AccRequire(s, msg): "r" + str(s) + str(msg);
			}
		}
		function field(cf:TClassField):String {
			var b = new StringBuf();
			b.add(str(cf.name));
			b.add("(");
			b.add(typeKey(cf.type));
			b.add(")");
			b.add(pos(cf.pos));
			b.add("|");
			b.add(pos(cf.namePos));
			b.add("|");
			if (cf.doc == null) b.add("-") else {
				b.add(str(cf.doc.own));
				for (d in cf.doc.inherited) b.add(str(d));
			}
			b.add("|");
			for (m in cf.meta) b.add(str(m.name) + m.params.length + "@" + pos(m.pos) + ";");
			b.add("|");
			b.add(switch cf.kind {
				case Var(k): "V" + access(k.read) + access(k.write);
				case Method(k): "M" + k.getIndex();
			});
			b.add("|");
			for (p in cf.params) b.add(str(p.name) + typeKey(p.type) + ";");
			b.add("|");
			b.add(cf.expr == null ? "-" : "#" + id(cf.expr));
			b.add(cf.exprUnoptimized == null ? "-" : "#" + id(cf.exprUnoptimized));
			b.add(cf.overloads.length == 0 ? "-" : "#" + id(cf.overloads));
			b.add("|");
			b.add(cf.flags);
			return b.toString();
		}
		function anon(a:TAnon):String {
			var depth = anons.indexOf(a);
			if (depth >= 0) return "A@" + depth;
			anons.push(a);
			var b = new StringBuf();
			b.add("A{");
			for (n in hxc.core.PMapOrder.sortedKeys(a.fields)) {
				b.add(field(a.fields.get(n)));
				b.add(",");
			}
			b.add("}");
			b.add(switch a.status.get() {
				case Closed: "c";
				case Const: "k";
				case Extend(tl): "x" + params(tl);
				case Statics(c): "s" + id(c);
				case EnumStatics(e): "e" + id(e);
				case AbstractStatics(a): "a" + id(a);
			});
			anons.pop();
			return b.toString();
		}
		typeKey = function(t:T):String {
			return switch t {
				case TMono(r):
					var c = r.downConstraints.length == 0 && r.upConstraints.length == 0 ? "" : "#" + id(r);
					if (r.type == null) "_" + c else {
						var depth = monos.indexOf(r);
						if (depth >= 0) "M@" + depth else {
							monos.push(r);
							var k = "M(" + typeKey(r.type) + ")" + c;
							monos.pop();
							k;
						}
					}
				case TEnum(e, tl): "E" + id(e) + params(tl);
				case TInst(c, tl): "I" + id(c) + params(tl);
				case TType(d, tl): "T" + id(d) + params(tl);
				case TAbstract(a, tl): "B" + id(a) + params(tl);
				case TFun(sig):
					"F(" + [for (arg in sig.args) str(arg.name) + (arg.opt ? "?" : "") + typeKey(arg.t)].join(",") + ")" + typeKey(sig.ret);
				case TAnon(a): anon(a);
				case TDynamic(null): "D";
				case TDynamic(t): "D(" + typeKey(t) + ")";
				case TLazy(f):
					switch f.get() {
						case LAvailable(t): "L(" + typeKey(t) + ")";
						case _: "L#" + id(f);
					}
			}
		}
		return anon(a);
	}

	// genhl.ml: to_type
	public static function toType(ctx:HlContext, t:T, ?tref:{v:Null<HlType>}):HlType {
		switch t {
			case TMono(r):
				return r.type == null ? HDyn : toType(ctx, r.type, tref);
			case TType(td, tl):
				var t = getRecCache(ctx, t, () -> HlContext.abort("Unsupported recursive type", td.pos),
					tref -> toType(ctx, TypeFunctions.applyTypedef(td, tl), tref));
				if (td.path.pack.length == 2 && td.path.pack[0] == "haxe" && td.path.pack[1] == "macro")
					ctx.macroTypedefs.set(td.path.name, t);
				return t;
			case TLazy(f):
				return toType(ctx, TypeFunctions.lazyType(f), tref);
			case TFun(sig):
				// the constructor's arguments: the return type first
				var ret = toType(ctx, sig.ret);
				var args = [for (a in sig.args) {
					var pt = toType(ctx, a.t);
					if (a.opt && !isNullable(pt)) HRef(pt) else pt;
				}];
				return HFun(args, ret);
			case TAnon(a):
				switch a.status.get() {
					case Statics(c):
						return classType(ctx, c, TypeFunctions.extractParamTypes(c.params), true);
					case EnumStatics(e):
						return enumClass(ctx, e);
					case _:
				}
				if (!a.fields.keys().hasNext()) return HDyn;
				var key = anonKey(ctx, a);
				var cached = ctx.anonsCache.get(key);
				if (cached != null) return cached;
				var vp:HlVirtualProto = {vfields: [], vindex: new Map()};
				var t = HVirtual(vp);
				if (tref != null) tref.v = t;
				ctx.anonsCache.set(key, t);
				// PMap.fold visits the names in increasing order; the list is then sorted by name
				var fields = [for (n in hxc.core.PMapOrder.sortedKeys(a.fields)) cfieldType(ctx, a.fields.get(n))];
				vp.vfields = fields;
				for (i in 0...fields.length) vp.vindex.set(fields[i].name, i);
				return t;
			case TDynamic(_):
				return HDyn;
			case TEnum(e, _):
				return enumType(ctx, e, tref);
			case TInst(c, [TInst({kind: KExpr({expr: EConst(CString(name, _))})}, _)]) if (c.path.pack.length == 1 && c.path.pack[0] == "hl" && c.path.name == "Abstract"):
				return HAbstract(name, HlContext.allocString(ctx, name));
			case TInst(c, pl):
				switch c.kind {
					case KTypeParameter(tl):
						for (t in tl) {
							var t = TypeFunctions.follow(TypeFunctions.applyParams(c.params, pl, t));
							switch t {
								case TInst(c, _) if (!TypeFunctions.hasClassFlag(c, CInterface)):
									return toType(ctx, t, tref);
								case _:
							}
						}
						return HDyn;
					case _:
						return classType(ctx, c, pl, false, tref);
				}
			case TAbstract(a, [t1]) if (a.path.pack.length == 0 && a.path.name == "Null"):
				var t = toType(ctx, t1, tref);
				return if (!isNullable(t) && t != HVoid) HNull(t) else t;
			case TAbstract(a, pl):
				if (TypeFunctions.hasMeta(":coreType", a.meta)) {
					var path = a.path;
					return switch [path.pack.join("."), path.name] {
						case ["", "Void"]: HVoid;
						case ["", "Int"] | ["", "UInt"]: HI32;
						case ["", "Float"]: HF64;
						case ["", "Single"]: HF32;
						case ["", "Bool"]: HBool;
						case ["", "Dynamic"]: HDyn;
						case ["", "Class"]: classType(ctx, ctx.baseClass, [], false);
						case ["", "Enum"]: classType(ctx, ctx.baseType, [], false);
						case ["", "EnumValue"]: HDyn;
						case ["hl", "Ref"]: HRef(toType(ctx, pl[0]));
						case ["hl", "Bytes"] | ["hl", "BytesAccess"]: HBytes;
						case ["hl", "Type"]: HType;
						case ["hl", "UI16"]: HUI16;
						case ["hl", "UI8"]: HUI8;
						case ["hl", "I64"]: HI64;
						case ["hl", "NativeArray"]: HArray;
						case ["haxe.macro", "Position"]: HAbstract("macro_pos", HlContext.allocString(ctx, "macro_pos"));
						case _: throw "Unknown core type " + Globals.sTypePath(a.path);
					}
				}
				return getRecCache(ctx, t, () -> HDyn, tref -> toType(ctx, TypeFunctions.getUnderlyingType(a, pl), tref));
		}
	}

	// genhl.ml: resolve_class
	public static function resolveClass(ctx:HlContext, c:TClass, pl:TParams, statics:Bool):TClass {
		if (c.path.pack.length == 0 && c.path.name == "Array") {
			if (pl.length == 1) return statics ? ctx.arrayImpl.abase : arrayClass(ctx, toType(ctx, pl[0]));
			if (pl.length == 0) return HlContext.die();
		}
		if (TypeFunctions.hasClassFlag(c, CExtern))
			throw "Extern type not supported : " + hxc.core.TPrinting.sType(hxc.core.TPrinting.printContext(), TInst(c, pl));
		return c;
	}

	// genhl.ml: cfield_type
	public static function cfieldType(ctx:HlContext, cf:TClassField):HlField {
		var t = toType(ctx, cf.type);
		t = switch [cf.kind, t] {
			case [Method(MethNormal | MethInline), HFun(args, ret)]: HMethod(args, ret);
			case _: t;
		}
		return {name: cf.name, nameIndex: HlContext.allocString(ctx, cf.name), t: t};
	}

	// genhl.ml: field_type
	public static function fieldType(ctx:HlContext, f:TFieldAccess, p:Position):T {
		var inst = switch f {
			case FInstance(c, pl, cf): {c: c, params: pl, f: cf};
			case FClosure(cp, cf) if (cp != null): {c: cp.c, params: cp.params, f: cf};
			case _: null;
		}
		if (inst != null) {
			var f = inst.f;
			var creal = resolveClass(ctx, inst.c, inst.params, false);
			var c = creal;
			var found:Null<TClassField> = null;
			while (true) {
				found = c.fields.get(f.name);
				if (found != null) break;
				if (c.superClass == null) HlContext.abort(Globals.sTypePath(creal.path) + " is missing field " + f.name, p);
				c = c.superClass.c;
			}
			return found.type;
		}
		return switch f {
			case FInstance(_):
				HlContext.die();
			case FStatic(_, f) | FAnon(f) | FClosure(_, f): f.type;
			case FDynamic(_): TypeFunctions.tDynamic;
			case FEnum(_, f): f.type;
		}
	}

	// genhl.ml: real_type
	public static function realType(ctx:HlContext, e:TExpr):HlType {
		function loop(e:TExpr):T {
			return switch e.expr {
				case TField(_, f):
					var ft = fieldType(ctx, f, e.pos);
					switch [ft, e.type] {
						case [TFun(sig), TFun(sig2)]:
							if (sig.args.length != sig2.args.length) HlContext.die("List.map2");
							TFun({args: [for (i in 0...sig.args.length) {
								var a = sig.args[i], a2 = sig2.args[i];
								switch [a.t, a2.t] {
									// function variance: keep a type parameter's function type, for a cast
									case [TInst({kind: KTypeParameter(_)}, _), TFun(_)]: a2;
									// a number is cast to the type parameter before being wrapped as dynamic, except
									// for a dynamic method or a var (#7166)
									case [TInst({kind: KTypeParameter(_)}, _), t] if (isNumber(toType(ctx, t)) && !(switch f {
										case FInstance(_, _, {kind: Var(_) | Method(MethDynamic)}): true;
										case _: false;
									})):
										new TSignatureArg(a.name, a.opt, TAbstract(fakeTnull(), [t]));
									case _: a;
								}
							}], ret: sig.ret});
						case _: ft;
					}
				case TLocal(v): v.type;
				case TParenthesis(e): loop(e);
				case TArray(arr, _):
					function loop2(t:T):T {
						return switch TypeFunctions.follow(t) {
							case TInst(c, [t]) if (c.path.pack.length == 0 && c.path.name == "Array"): t;
							case TAbstract(a, pl): loop2(TypeFunctions.getUnderlyingType(a, pl));
							case _: TypeFunctions.tDynamic;
						}
					}
					loop2(arr.type);
				case _: e.type;
			}
		}
		return toType(ctx, loop(e));
	}

	static function pathKey(name:String, pack:Array<String>):String {
		return pack.join(".") + "|" + name;
	}

	// s_type_path (List.tl key_path, List.hd key_path)
	static function protoName(name:String, pack:Array<String>):String {
		return pack.length == 0 ? name : pack.join(".") + "." + name;
	}

	static function newProto(ctx:HlContext, pname:String):HlClassProto {
		return {
			pname: pname,
			pid: HlContext.allocString(ctx, pname),
			psuper: null,
			pclassglobal: null,
			pproto: [],
			pfields: [],
			pindex: new Map(),
			pvirtuals: [],
			pfunctions: new Map(),
			pnfields: -1,
			pinterfaces: [],
			pbindings: []
		};
	}

	// PMap.add on pinterfaces: replaces an equal key
	static function addInterface(p:HlClassProto, t:HlType, index:Int):Void {
		for (e in p.pinterfaces) if (teq(e.t, t)) {
			e.index = index;
			return;
		}
		p.pinterfaces.push({t: t, index: index});
	}

	// genhl.ml: class_type
	public static function classType(ctx:HlContext, c:TClass, pl:TParams, statics:Bool, ?tref:{v:Null<HlType>}):HlType {
		var c = TypeFunctions.hasClassFlag(c, CExtern) ? resolveClass(ctx, c, pl, statics) : c;
		var keyName = statics ? "$" + c.path.name : c.path.name;
		var key = pathKey(keyName, c.path.pack);
		var cached = ctx.cachedTypes.get(key);
		if (cached != null) return cached;
		if (TypeFunctions.hasClassFlag(c, CInterface) && !statics) {
			var vp:HlVirtualProto = {vfields: [], vindex: new Map()};
			var t = HVirtual(vp);
			ctx.cachedTypes.set(key, t);
			function loop(c:TClass):Array<HlField> {
				var fields:Array<HlField> = [];
				for (i in c.interfaces) fields = loop(i.c).concat(fields);
				// PMap.fold consing: the own fields in decreasing name order, in front
				var own = [for (n in hxc.core.PMapOrder.sortedKeys(c.fields)) cfieldType(ctx, c.fields.get(n))];
				own.reverse();
				return own.concat(fields);
			}
			var fields = loop(c);
			vp.vfields = fields;
			for (i in 0...fields.length) vp.vindex.set(fields[i].name, i);
			return t;
		}
		var p = newProto(ctx, protoName(keyName, c.path.pack));
		var t = TypeFunctions.hasMeta(":struct", c.meta) && !statics ? HStruct(p) : HObj(p);
		if (tref != null) tref.v = t;
		ctx.ctDepth++;
		ctx.cachedTypes.set(key, t);
		if (c.path.pack.length == 0 && c.path.name == "Array") HlContext.die();
		if (c == ctx.baseClass) {
			if (statics) HlContext.die();
			p.pnfields = 1;
		}
		var tsup = if (c.superClass != null && !statics) classType(ctx, c.superClass.c, [], statics) else if (statics) classType(ctx, ctx.baseClass, [], false) else null;
		var startField = 0;
		var virtuals:Array<Int> = [];
		if (tsup != null) switch tsup {
			case HObj(psup) | HStruct(psup):
				if (isStruct(t) != isStruct(tsup))
					HlContext.abort(isStruct(t) ? "Struct cannot extend a not struct class" : "Class cannot extend a struct", c.pos);
				if (psup.pnfields < 0) HlContext.die();
				p.psuper = psup;
				startField = psup.pnfields;
				virtuals = psup.pvirtuals.copy();
			case _:
				HlContext.die();
		}
		var fa:Array<HlField> = [];
		var pa:Array<HlFieldProto> = [];
		function addField(name:String, getT:Void->HlType):Int {
			var fid = fa.length + startField;
			var str = HlContext.allocString(ctx, name);
			p.pindex.set(name, {index: fid, t: HVoid});
			fa.push({name: name, nameIndex: str, t: HVoid});
			ctx.ctDelayed.push(function() {
				var t = getT();
				p.pindex.set(name, {index: fid, t: t});
				p.pfields[fid - startField] = {name: name, nameIndex: str, t: t};
			});
			return fid;
		}
		for (f in (statics ? c.orderedStatics : c.orderedFields)) {
			if (isExternField(f) || (statics && f.name == "__meta__")) continue;
			var fid:Null<Int> = switch f.kind {
				case Method(m) if (m != MethDynamic && !statics):
					var g = allocFid(ctx, c, f);
					p.pfunctions.set(f.name, g);
					var virt:Null<Int> = if (TypeFunctions.hasClassFieldFlag(f, CfOverride)) {
						var idx = getIndex(f.name, p);
						if (idx == null) HlContext.die();
						var vid = -idx.index - 1;
						virtuals[vid] = g;
						vid;
					} else if (HlContext.isOverridden(ctx, c, f)) {
						var vid = virtuals.length;
						virtuals.push(g);
						p.pindex.set(f.name, {index: -vid - 1, t: HVoid});
						vid;
					} else null;
					pa.push({fname: f.name, fid: HlContext.allocString(ctx, f.name), fmethod: g, fvirtual: virt});
					null;
				case Method(MethDynamic) if (TypeFunctions.hasClassFieldFlag(f, CfOverride)):
					var idx = getIndex(f.name, p);
					if (idx == null) HlContext.die();
					idx.index;
				case _:
					addField(f.name, function() {
						var t = toType(ctx, f.type);
						if (TypeFunctions.hasMeta(":packed", f.meta)) {
							switch t {
								case HStruct(_):
								case _: HlContext.abort("Packed field should be struct", f.pos);
							}
							return HPacked(t);
						}
						return t;
					});
			}
			switch f.kind {
				case Method(_) if (f.expr != null && fid != null):
					p.pbindings.unshift({fid: fid, fidx: allocFunPath(ctx, c.path, f.name)});
				case _:
			}
		}
		if (!statics) {
			// add interfaces
			for (i in c.interfaces) {
				var rid = -1;
				rid = addField("", function() {
					var t = toType(ctx, TInst(i.c, i.params));
					addInterface(p, t, rid);
					return t;
				});
			}
			// check toString
			var cf = c.fields.get("toString");
			if (cf != null && !(TypeFunctions.hasClassFieldFlag(cf, CfOverride) || c.fields.exists("__string") || !isToString(cf.type))) {
				pa.push({fname: "__string", fid: HlContext.allocString(ctx, "__string"), fmethod: allocFunPath(ctx, c.path, "__string"), fvirtual: null});
			}
		} else {
			var f = c.constructor;
			if (f != null && !isExternField(f)) {
				var idx = getIndex("__constructor__", p);
				if (idx == null) HlContext.die();
				p.pbindings.unshift({fid: idx.index, fidx: allocFid(ctx, c, f)});
			}
		}
		p.pnfields = fa.length + startField;
		p.pfields = fa;
		p.pproto = pa;
		p.pvirtuals = virtuals;
		ctx.ctDepth--;
		if (ctx.ctDepth == 0) {
			var todo = ctx.ctDelayed;
			ctx.ctDelayed = [];
			// the OCaml list is run head first: the last one added first
			var i = todo.length - 1;
			while (i >= 0) todo[i--]();
		}
		if (!statics && c != ctx.coreType && c != ctx.coreEnum) p.pclassglobal = classGlobal(ctx, c).g;
		return t;
	}

	// genhl.ml: enum_type
	public static function enumType(ctx:HlContext, e:TEnum, ?tref:{v:Null<HlType>}):HlType {
		var key = pathKey(e.path.name, e.path.pack);
		var cached = ctx.cachedTypes.get(key);
		if (cached != null) return cached;
		var ename = Globals.sTypePath(e.path);
		var et:HlEnumProto = {eglobal: null, ename: ename, eid: HlContext.allocString(ctx, ename), efields: []};
		var t = HEnum(et);
		if (tref != null) tref.v = t;
		ctx.cachedTypes.set(key, t);
		et.efields = [for (n in e.names) {
			var f = e.constrs.get(n);
			var args = switch f.type {
				case TFun(sig): [for (a in sig.args) toType(ctx, a.t)];
				case _: [];
			}
			{name: f.name, nameIndex: HlContext.allocString(ctx, f.name), t: args};
		}];
		var ct = enumClass(ctx, e);
		et.eglobal = allocGlobal(ctx, switch ct {
			case HObj(o): o.pname;
			case _: HlContext.die();
		}, ct);
		return t;
	}

	// genhl.ml: enum_class
	public static function enumClass(ctx:HlContext, e:TEnum):HlType {
		var keyName = "$" + e.path.name;
		var key = pathKey(keyName, e.path.pack);
		var cached = ctx.cachedTypes.get(key);
		if (cached != null) return cached;
		var p = newProto(ctx, protoName(keyName, e.path.pack));
		var t = HObj(p);
		ctx.cachedTypes.set(key, t);
		p.psuper = switch classType(ctx, ctx.baseEnum, [], false) {
			case HObj(o): o;
			case _: HlContext.die();
		}
		return t;
	}

	// genhl.ml: alloc_fun_path
	public static function allocFunPath(ctx:HlContext, path:Path, name:String):Int {
		return HlContext.lookup(ctx.cfids, HlContext.overrideKey(name, path), () -> true);
	}

	// genhl.ml: alloc_fid
	public static function allocFid(ctx:HlContext, c:TClass, f:TClassField):Int {
		return switch f.kind {
			case Var(_): HlContext.die();
			case _: allocFunPath(ctx, c.path, f.name);
		}
	}

	// genhl.ml: alloc_eid
	public static function allocEid(ctx:HlContext, e:TEnum, f:TEnumField):Int {
		return allocFunPath(ctx, e.path, f.name);
	}

	// genhl.ml: alloc_function_name
	public static function allocFunctionName(ctx:HlContext, f:String):Int {
		return allocFunPath(ctx, new Path([], ""), f);
	}

	// genhl.ml: alloc_global
	public static function allocGlobal(ctx:HlContext, name:String, t:HlType):Int {
		return HlContext.lookup(ctx.cglobals, name, () -> t);
	}

	// genhl.ml: class_global
	public static function classGlobal(ctx:HlContext, c:TClass, resolve:Bool = true):{g:Int, t:HlType} {
		var isStatic = c != ctx.baseClass;
		var c = resolve && isArrayClass(Globals.sTypePath(c.path)) ? ctx.arrayImpl.abase : c;
		var c = resolveClass(ctx, c, TypeFunctions.extractParamTypes(c.params), isStatic);
		var t = classType(ctx, c, [], isStatic);
		return {g: allocGlobal(ctx, "$" + Globals.sTypePath(c.path), t), t: t};
	}

	// genhl.ml: alloc_std
	public static function allocStd(ctx:HlContext, name:String, args:Array<HlType>, ret:HlType):Int {
		var lib = "std";
		// different from :hlNative to prevent mismatch
		var nid = HlContext.lookup(ctx.cnatives, "$" + name + "@" + lib + "|-1", function() {
			var fid = allocFunPath(ctx, new Path([], "std"), name);
			ctx.definedFuns.set(fid, true);
			// the tuple's components right to left
			var n = HlContext.allocString(ctx, name);
			var l = HlContext.allocString(ctx, lib);
			return {lib: l, name: n, t: HFun(args, ret), findex: fid};
		});
		return ctx.cnatives.arr[nid].findex;
	}

	// genhl.ml: common_type
	public static function commonType(ctx:HlContext, e1:TExpr, e2:TExpr, forEq:Bool, p:Position):HlType {
		var t1 = toType(ctx, e1.type);
		var t2 = toType(ctx, e2.type);
		function loop(t1:HlType, t2:HlType):HlType {
			if (t1 == t2) return t1;
			return switch [t1, t2] {
				case [HUI8, HUI16 | HI32 | HI64 | HF32 | HF64]: t2;
				case [HUI16, HI32 | HI64 | HF32 | HF64]: t2;
				case [HI32 | HI64, HF32]: t2; // possible loss of precision
				case [HI32 | HI64 | HF32, HF64]: t2;
				case [HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64, HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64]: t1;
				case [HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64, HNull(t2)]: forEq ? HNull(loop(t1, t2)) : loop(t1, t2);
				case [HNull(t1), HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64]: forEq ? HNull(loop(t1, t2)) : loop(t1, t2);
				case [HNull(t1), HNull(t2)]: forEq ? HNull(loop(t1, t2)) : loop(t1, t2);
				case [HDyn, HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64]: HF64;
				case [HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64, HDyn]: HF64;
				case [HDyn, _]: HDyn;
				case [_, HDyn]: HDyn;
				case _ if (forEq && safeCast(t1, t2)): t2;
				case _ if (forEq && safeCast(t2, t1)): t1;
				case [HBool, HNull(HBool)] if (forEq): t2;
				case [HNull(HBool), HBool] if (forEq): t1;
				case [HObj(_), HVirtual(_)] | [HVirtual(_), HObj(_)] | [HVirtual(_), HVirtual(_)]: HDyn;
				case [HFun(_), HFun(_)]: HDyn;
				case _: HlContext.abort("Don't know how to compare " + HlDump.tstr(t1) + " and " + HlDump.tstr(t2), p);
			}
		}
		return loop(t1, t2);
	}

	// genhl.ml: type_value
	public static function typeValue(ctx:HlContext, t:ModuleType, p:Position):Int {
		switch t {
			case TClassDecl(c):
				var cg = classGlobal(ctx, c);
				var r = ctx.allocTmp(cg.t);
				ctx.op(OGetGlobal(r, cg.g));
				return r;
			case TAbstractDecl(a):
				var r = ctx.allocTmp(classType(ctx, ctx.baseType, [], false));
				var g = switch [a.path.pack.length, a.path.name] {
					case [0, "Int"]: allocGlobal(ctx, "$Int", ctx.rtype(r));
					case [0, "Float"]: allocGlobal(ctx, "$Float", ctx.rtype(r));
					case [0, "Bool"]: allocGlobal(ctx, "$Bool", ctx.rtype(r));
					case [0, "Class"]: classGlobal(ctx, ctx.baseClass).g;
					case [0, "Enum"]: classGlobal(ctx, ctx.baseEnum).g;
					case [0, "Dynamic"]: allocGlobal(ctx, "$Dynamic", ctx.rtype(r));
					case _: HlContext.abort("Unsupported type value " + Globals.sTypePath(a.path), p);
				}
				ctx.op(OGetGlobal(r, g));
				return r;
			case TEnumDecl(e):
				var r = ctx.allocTmp(enumClass(ctx, e));
				var rt = ctx.rtype(r);
				ctx.op(OGetGlobal(r, allocGlobal(ctx, switch rt {
					case HObj(o): o.pname;
					case _: HlContext.die();
				}, rt)));
				return r;
			case TTypeDecl(_):
				return HlContext.die();
		}
	}
}
