package hxc.codegen;

import haxe.ds.StringMap;
import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.core.NotFound;
import hxc.core.Ref;
import hxc.core.Type;
import hxc.core.TexprTools;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TypeUnification.UnifyError;
import hxc.core.TypingError;

// The target-independent half of the JVM generator: anonymous structure identification and the per-class
// bookkeeping the preprocessor builds on.

enum MethodType {
	MStatic;
	MInstance;
	MConstructor;
}

// pfmConverted caches GenJvm.convertFields: each field's name, in sorted order, with its JSignature.
typedef PathFieldMapping = {
	var pfmPath:Path;
	var pfmParams:TypeParams;
	var pfmFields:StringMap<TClassField>;
	var pfmConverted:Null<Array<{name:String, sig:Dynamic}>>;
	var pfmArity:Int;
}

class GenShared {
	public static function isExternAbstract(a:TAbstract):Bool {
		return switch (a.impl) {
			case null:
				switch (a.path.pack) {
					case []:
						switch (a.path.name) {
							case "Void" | "Float" | "Int" | "Single" | "Bool" | "Null": true;
							case _: false;
						}
					case _: false;
				}
			case c: TypeFunctions.hasClassFlag(c, CExtern);
		}
	}

	public static function countFields(pm:StringMap<TClassField>):Int {
		var i = 0;
		for (_ in pm) i++;
		return i;
	}

	public static function pfmOfTypedef(td:TDef):PathFieldMapping {
		return switch (TypeFunctions.follow(td.type)) {
			case TAnon(an): {
					pfmPath: td.path,
					pfmParams: td.params,
					pfmFields: an.fields,
					pfmConverted: null,
					pfmArity: countFields(an.fields)
				}
			case _: throw "die";
		}
	}

	// bind every still-unbound monomorph in t to Dynamic
	public static function replaceMono(t:T):Void {
		switch (t) {
			case TMono(r):
				if (r.type == null) TypeFunctions.monomorphBindRef(r, TypeFunctions.tDynamic);
			case TEnum(_, p) | TInst(_, p) | TType(_, p) | TAbstract(_, p):
				for (t in p) replaceMono(t);
			case TFun(sig):
				for (a in sig.args) replaceMono(a.t);
				replaceMono(sig.ret);
			case TAnon(_) | TDynamic(_):
			case TLazy(f):
				replaceMono(TypeFunctions.lazyType(f));
		}
	}
}

class TanonIdentification {
	static function isNormalAnon(an:TAnon):Bool {
		return switch (an.status.get()) {
			case Closed | Const: true;
			case _: false;
		}
	}

	var pfms:StringMap<PathFieldMapping> = new StringMap();
	var pfmByArity:Array<Array<PathFieldMapping>> = [];
	var num:Int = 0;

	public function new(emptyPath:Path) {}

	public var getPfms(get, never):StringMap<PathFieldMapping>;

	function get_getPfms() return pfms;

	var pfmsOrder = new hxc.core.NameHash.HashTableOrder();

	public function addPfm(path:Path, pfm:PathFieldMapping):Void {
		while (pfmByArity.length <= pfm.pfmArity) pfmByArity.push([]);
		pfmByArity[pfm.pfmArity].push(pfm);
		pfms.set(Globals.sTypePath(path), pfm);
		pfmsOrder.add(Globals.sTypePath(path), hxc.core.NameHash.pathHash(path.pack, path.name));
	}

	public function pfmKeysInHashtblOrder():Array<String> {
		return pfmsOrder.visitOrder();
	}

	public function unify(tc:T, pfm:PathFieldMapping):Void {
		function pairUp(fields:StringMap<TClassField>):Array<{cf:TClassField, cf2:TClassField}> {
			var acc = [];
			for (cf in pfm.pfmFields) {
				var cf2 = fields.get(cf.name);
				if (cf2 == null) throw new NotFound("genshared pair_up");
				acc.push({cf: cf, cf2: cf2});
			}
			return acc;
		}
		var monos;
		try {
			monos = switch (TypeFunctions.follow(tc)) {
				case TInst(c, tl):
					var pairs = pairUp(c.fields);
					var monos = [for (_ in pfm.pfmParams) TypeFunctions.mkMono()];
					for (p in pairs) {
						if (!TypeUnification.unifyKind(p.cf2.kind, p.cf.kind))
							throw new UnifyError([Unify_custom("kind mismatch")]);
						TypeUnification.unifyDefault(TypeFunctions.applyParams(c.params, tl,
							TypeFunctions.monomorphs(p.cf2.params, p.cf2.type)),
							TypeFunctions.applyParams(pfm.pfmParams, monos,
								TypeFunctions.monomorphs(p.cf.params, p.cf.type)));
					}
					monos;
				case TAnon(an1):
					var fields = new StringMap();
					for (k in an1.fields.keys()) fields.set(k, true);
					var pairs = pairUp(an1.fields);
					var monos = [for (_ in pfm.pfmParams) TypeFunctions.mkMono()];
					for (p in pairs) {
						if (!TypeUnification.unifyKind(p.cf2.kind, p.cf.kind))
							throw new UnifyError([Unify_custom("kind mismatch")]);
						fields.remove(p.cf.name);
						TypeUnification.typeEqKind(EqDoNotFollowNull, p.cf2.type,
							TypeFunctions.applyParams(pfm.pfmParams, monos,
								TypeFunctions.monomorphs(p.cf.params, p.cf.type)));
					}
					if (fields.keys().hasNext()) throw new UnifyError([Unify_custom("not enough fields")]);
					monos;
				case _:
					throw new UnifyError([Unify_custom("bad type")]);
			}
		} catch (e:NotFound) {
			throw new UnifyError([]);
		}
		// Type parameters left unbound become Dynamic; one bound to Void (for example through a function's
		// return
		// type) rejects the match.
		for (t in monos) {
			switch (TypeFunctions.follow(t)) {
				case TMono(r):
					TypeFunctions.monomorphBindRef(r, TypeFunctions.tDynamic);
				case t2:
					if (isVoid(t2)) throw new UnifyError([Unify_custom("return mono")]);
			}
		}
	}

	// on an already followed type
	static function isVoid(t:T):Bool {
		return switch (t) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		}
	}

	public function findCompatible(arity:Int, tc:T):PathFieldMapping {
		if (arity >= pfmByArity.length) throw new NotFound("findCompatible arity");
		var d = pfmByArity[arity];
		for (pfm in d) {
			try {
				unify(tc, pfm);
				return pfm;
			} catch (e:UnifyError) {}
		}
		throw new NotFound("findCompatible");
	}

	public function identifyTypedef(td:TDef):Void {
		function loop(t:T) {
			switch (t) {
				case TAnon(an) if (isNormalAnon(an) && an.fields.keys().hasNext()):
					addPfm(td.path, GenShared.pfmOfTypedef(td));
				case TMono(r) if (r.type != null):
					loop(r.type);
				case TLazy(f):
					loop(TypeFunctions.lazyType(f));
				case _:
			}
		}
		loop(td.type);
	}

	public function identify(acceptAnons:Bool, t:T):Null<PathFieldMapping> {
		return switch (t) {
			case TType(td, tl):
				var pfm = pfms.get(Globals.sTypePath(td.path));
				if (pfm != null) pfm else identify(acceptAnons, TypeFunctions.applyTypedef(td, tl));
			case TMono(r) if (r.type != null):
				identify(acceptAnons, r.type);
			case TAbstract(a, tl) if (!TypeFunctions.hasMeta(":coreType", a.meta)):
				identify(acceptAnons, TypeFunctions.getUnderlyingType(a, tl));
			case TAbstract(a, [t2]) if (a.path.pack.length == 0 && a.path.name == "Null"):
				identify(acceptAnons, t2);
			case TLazy(f):
				identify(acceptAnons, TypeFunctions.lazyType(f));
			case TAnon(an) if (acceptAnons && an.fields.keys().hasNext()):
				var arity = 0;
				for (cf in an.fields) {
					GenShared.replaceMono(cf.type);
					arity++;
				}
				try {
					findCompatible(arity, t);
				} catch (e:NotFound) {
					var id = num;
					num = num + 1;
					var path:Path = {pack: ["haxe", "generated"], name: "Anon" + id};
					var pfm:PathFieldMapping = {
						pfmPath: path,
						pfmParams: [],
						pfmFields: an.fields,
						pfmConverted: null,
						pfmArity: GenShared.countFields(an.fields)
					};
					addPfm(path, pfm);
					pfm;
				}
			case _:
				null;
		}
	}
}

typedef FieldGenerationInfo = {
	var hasThisBeforeSuper:Bool;
	// This is an ordered list of fields that are targets of super() calls which is determined during
	// pre-processing. The generator can pop from this list assuming that it processes the expression
	// in the same order (which it should).
	var superCallFields:Array<{c:TClass, cf:TClassField}>;
}

typedef TClassInfo = {
	var typedefImplements:Null<Array<TClass>>;
	var implicitCtors:StringMap<{c:TClass, cf:TClassField}>;
}

class InfoContext {
	var classInfos:Array<TClassInfo> = [];

	public function new() {}

	public function getClassInfo(c:TClass):TClassInfo {
		for (m in c.meta) {
			switch (m.name) {
				case ":jvm.classInfo":
					switch (m.params) {
						case [{expr: EConst(CInt(s, _))}]:
							return classInfos[Std.parseInt(s)];
						case _:
					}
				case _:
			}
		}
		var index = classInfos.length;
		var infos:TClassInfo = {
			typedefImplements: null,
			implicitCtors: new StringMap()
		};
		classInfos.push(infos);
		c.meta = [{
			name: ":jvm.classInfo",
			params: [new Expr(EConst(CInt(Std.string(index), null)), Position.nullPos)],
			pos: Position.nullPos
		}].concat(c.meta);
		return infos;
	}
}

// convert renders a field type to a string because the converted value is only ever used as part of an
// implicitCtors key.
class Preprocessor {
	var basic:BasicTypes;
	var convert:T->String;
	var infos = new InfoContext();
	var fieldInfos:Array<FieldGenerationInfo> = [];

	public function new(basic:BasicTypes, convert:T->String) {
		this.basic = basic;
		this.convert = convert;
	}

	static function makeNative(cf:TClassField) {
		cf.meta = [{name: ":nativeGen", params: [], pos: Position.nullPos}].concat(cf.meta);
	}

	static function makeHaxe(cf:TClassField) {
		cf.meta = [{name: ":hxGen", params: [], pos: Position.nullPos}].concat(cf.meta);
	}

	static function getConstructor(c:TClass):TClassField {
		if (c.constructor != null) return c.constructor;
		if (c.superClass == null) throw new NotFound("genshared get_constructor");
		return getConstructor(c.superClass.c);
	}

	public var getInfos(get, never):InfoContext;

	function get_getInfos() return infos;

	public function getImplicitCtor(c:TClass):StringMap<{c:TClass, cf:TClassField}> {
		return infos.getClassInfo(c).implicitCtors;
	}

	public function getFieldInfo(ml:Metadata):Null<FieldGenerationInfo> {
		for (m in ml) {
			if (m.name == ":jvm.fieldInfo") switch (m.params) {
				case [{expr: EConst(CInt(s, _))}]: return fieldInfos[Std.parseInt(s)];
				case _:
			}
		}
		return null;
	}

	public function addImplicitCtor(c:TClass, c2:TClass, cf:TClassField):Void {
		var jsig = convert(cf.type);
		var info = infos.getClassInfo(c);
		info.implicitCtors.set(Globals.sTypePath(c2.path) + "|" + jsig, {c: c2, cf: cf});
	}

	public function preprocessConstructorExpr(c:TClass, cf:TClassField, e:TExpr):FieldGenerationInfo {
		var usedThis = false;
		var thisBeforeSuper = false;
		var superCallFields:Array<{c:TClass, cf:TClassField}> = [];
		function isOnCurrentClass(cf:TClassField) return c.fields.exists(cf.name);
		function findSuperCtor(el:Array<TExpr>):{c:TClass, cf:TClassField} {
			if (c.superClass == null) throw "die";
			var csup = c.superClass.c;
			var tl = c.superClass.params;
			var mapType = function(t:T) return TypeFunctions.applyParams(csup.params, tl, t);
			switch (OverloadResolution.resolveInstanceOverload(true, mapType, csup, "new", el)) {
				case null:
					throw new TypingError("Could not find overload constructor", e.pos);
				case r:
					function loop(csup2:TClass) {
						if (r.c != csup2) {
							if (csup2.superClass == null) throw "die";
							addImplicitCtor(csup2, csup2.superClass.c, r.cf);
							loop(csup2.superClass.c);
						}
					}
					loop(csup);
					// This is a bit hacky: We always want the direct super class, not the one that
					// actually holds the ctor. It will be implicitly copied to it anyway.
					return {c: csup, cf: r.cf};
			}
		}
		function promoteThisBeforeSuper(c:TClass, cf:TClassField) {
			switch (getFieldInfo(cf.meta)) {
				case null:
					throw "Something went wrong";
				case info:
					if (!info.hasThisBeforeSuper) {
						makeHaxe(cf);
						info.hasThisBeforeSuper = true;
						for (p in info.superCallFields) promoteThisBeforeSuper(p.c, p.cf);
					}
			}
		}
		function loop(e:TExpr) {
			switch (e.expr) {
				// Assigning this.field = value is fine if field is declared on our current class
				case TBinop(OpAssign, {expr: TField({expr: TConst(TThis)}, FInstance(_, _, cf2))}, e2)
					if (isOnCurrentClass(cf2)):
					loop(e2);
				case TConst(TThis):
					usedThis = true;
				case TCall({expr: TConst(TSuper)}, el):
					for (e in el) loop(e);
					if (usedThis) {
						thisBeforeSuper = true;
						makeHaxe(cf);
					}
					var r = findSuperCtor(el);
					if (thisBeforeSuper) promoteThisBeforeSuper(r.c, r.cf);
					superCallFields.push(r);
				case _:
					TexprTools.iter(loop, e);
			}
		}
		loop(e);
		return {hasThisBeforeSuper: thisBeforeSuper, superCallFields: superCallFields};
	}

	public function preprocessClass(c:TClass):Void {
		var hasDynamicInstanceMethod = false;
		var hasFieldInit = false;
		function field(mtype:MethodType, cf:TClassField) {
			switch (mtype) {
				case MConstructor:
				case MInstance:
					switch (cf.kind) {
						case Method(MethDynamic):
							hasDynamicInstanceMethod = true;
						case Var(_) if (cf.expr != null && !hasFieldInit && c.constructor == null
							&& c.superClass == null):
							hasFieldInit = true;
							addImplicitCtor(c, c, TypeFunctions.mkField("new",
								TypeFunctions.tfun([], basic.tvoid), Position.nullPos, Position.nullPos));
						case _:
					}
				case MStatic:
			}
		}
		for (cf in c.orderedStatics) field(MStatic, cf);
		for (cf in c.orderedFields) field(MInstance, cf);
		switch (c.constructor) {
			case null:
				try {
					var cf = getConstructor(c);
					if (c.superClass == null) throw "die";
					var csup = c.superClass.c;
					for (cf2 in [cf].concat(cf.overloads)) addImplicitCtor(c, csup, cf2);
				} catch (_:NotFound) {}
			case ctor:
				function field(cf:TClassField) {
					if (hasDynamicInstanceMethod) makeHaxe(cf);
					switch (cf.expr) {
						case null:
						case e:
							var info = preprocessConstructorExpr(c, cf, e);
							var index = fieldInfos.length;
							fieldInfos.push(info);
							cf.meta = [{
								name: ":jvm.fieldInfo",
								params: [new Expr(EConst(CInt(Std.string(index), null)), Position.nullPos)],
								pos: Position.nullPos
							}].concat(cf.meta);
							if (!TypeFunctions.hasMeta(":hxGen", cf.meta)) {
								function loop(next:TClass->Void, c:TClass) {
									if (TypeFunctions.hasClassFlag(c, CExtern)) makeNative(cf);
									else switch (c.constructor) {
										case cf2 if (cf2 != null && TypeFunctions.hasMeta(":hxGen", cf2.meta)):
											makeHaxe(cf);
										case cf2 if (cf2 != null && TypeFunctions.hasMeta(":nativeGen", cf2.meta)):
											makeNative(cf);
										case _:
											next(c);
									}
								}
								function up(c:TClass) {
									if (c.superClass != null) loop(up, c.superClass.c);
								}
								function down(c:TClass) {
									for (c2 in c.descendants) loop(down, c2);
								}
								loop(up, c);
								loop(down, c);
							}
					}
				}
				for (cf in [ctor].concat(ctor.overloads)) field(cf);
		}
	}
}

class TypedefInterfaces {
	var infos:InfoContext;
	var anonIdentification:TanonIdentification;
	var interfaces:StringMap<TClass> = new StringMap();
	var interfacesOrder = new hxc.core.NameHash.HashTableOrder();
	var interfaceRewrites:StringMap<{path:Path, isExtern:Bool}> = new StringMap();

	public function new(infos:InfoContext, anonIdentification:TanonIdentification) {
		this.infos = infos;
		this.anonIdentification = anonIdentification;
	}

	public function addInterfaceRewrite(pathFrom:Path, pathTo:Path, isExtern:Bool):Void {
		interfaceRewrites.set(Globals.sTypePath(pathFrom), {path: pathTo, isExtern: isExtern});
	}

	public function getInterfaceClass(path:Path):Null<TClass> {
		return interfaces.get(Globals.sTypePath(path));
	}

	public var getInterfaces(get, never):StringMap<TClass>;

	function get_getInterfaces() return interfaces;

	public function interfaceKeysInHashtblOrder():Array<String> {
		return interfacesOrder.visitOrder();
	}

	public function processClass(c:TClass):Void {
		var info = infos.getClassInfo(c);
		if (info.typedefImplements == null) doProcessClass(c, info);
	}

	function implementsPath(c:TClass, pathInterface:Path):Bool {
		var info = infos.getClassInfo(c);
		for (i in c.interfaces)
			if (Globals.sTypePath(i.c.path) == Globals.sTypePath(pathInterface)) return true;
		if (info.typedefImplements == null) return false;
		for (c2 in info.typedefImplements)
			if (Globals.sTypePath(c2.path) == Globals.sTypePath(pathInterface)) return true;
		return false;
	}

	function implementsRecursively(c:TClass, path:Path):Bool {
		if (implementsPath(c, path)) return true;
		return c.superClass == null ? false : implementsRecursively(c.superClass.c, path);
	}

	function makeInterfaceClass(pfm:PathFieldMapping, path:Path, isExtern:Bool):TClass {
		var pathInner:Path = {pack: pfm.pfmPath.pack, name: pfm.pfmPath.name + "$Interface"};
		var existing = interfaces.get(Globals.sTypePath(pathInner));
		if (existing != null) return existing;
		var fields = new StringMap();
		for (name in pfm.pfmFields.keys()) {
			var cf = pfm.pfmFields.get(name);
			switch (cf.kind) {
				case Method(MethNormal) | Method(MethInline): fields.set(name, cf);
				case _:
			}
		}
		if (!fields.keys().hasNext()) throw new UnifyError([Unify_custom("no fields")]);
		var c = TypeFunctions.mkClass(TypeFunctions.nullModule, path, Position.nullPos, Position.nullPos);
		TypeFunctions.addClassFlag(c, CInterface);
		c.fields = fields;
		// Fields are ordered by descending name. That puts `next` before `hasNext` on the generated
		// haxe.root.Iterator, and the forward methods generated from it carry the order into the class
		// file.
		var names = [for (k in fields.keys()) k];
		names.sort(Reflect.compare);
		names.reverse();
		c.orderedFields = [for (n in names) fields.get(n)];
		if (isExtern) TypeFunctions.addClassFlag(c, CExtern);
		interfaces.set(Globals.sTypePath(pfm.pfmPath), c);
		interfacesOrder.add(Globals.sTypePath(pfm.pfmPath),
			hxc.core.NameHash.pathHash(pfm.pfmPath.pack, pfm.pfmPath.name));
		return c;
	}

	function doProcessClass(c:TClass, info:TClassInfo):Void {
		if (c.superClass != null) processClass(c.superClass.c);
		var tc = TInst(c, TypeFunctions.extractParamTypes(c.params));
		var l:Array<TClass> = [];
		for (key in anonIdentification.pfmKeysInHashtblOrder()) {
			var pfm = anonIdentification.getPfms.get(key);
			var path = pfm.pfmPath;
			var rewrite = interfaceRewrites.get(Globals.sTypePath(path));
			var pathInner:Path = rewrite != null ? rewrite.path : {pack: path.pack, name: path.name + "$Interface"};
			var isExtern = rewrite != null ? rewrite.isExtern : false;
			try {
				if (implementsRecursively(c, pathInner))
					throw new UnifyError([Unify_custom("already implemented")]);
				anonIdentification.unify(tc, pfm);
				var ci = makeInterfaceClass(pfm, pathInner, isExtern);
				c.interfaces = [{c: ci, params: []}].concat(c.interfaces);
				l.unshift(ci);
			} catch (_:UnifyError) {}
		}
		info.typedefImplements = l;
	}
}
