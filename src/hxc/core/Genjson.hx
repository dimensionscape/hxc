package hxc.core;

// hxc.core.Genjson: serializes types, fields and positions into the JSON display protocol's format.
// Expressions serialize as null.

import haxe.ds.StringMap;
import hxc.core.Globals.Path;
import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Json;
import sys.FileSystem;

enum GenerationMode {
	GMFull;
	GMWithoutDoc;
	GMMinimum;
}

// The scope serializes as the variant index of hxc.core.Type.ClassFieldScope.

class Genjson {
	public var mode:GenerationMode;
	// The `meta` names of the request being answered, read the first time a minimum-mode answer needs them;
	// null outside a request.
	public var requestedMeta:Null<Void->Null<Array<String>>> = null;

	public function new(mode:GenerationMode) {
		this.mode = mode;
	}

	static inline function jstring(s:String):JsonValue return JString(s);
	static inline function jint(i:Int):JsonValue return JInt(i);
	static inline function jbool(b:Bool):JsonValue return JBool(b);
	static inline function jarray(l:Array<JsonValue>):JsonValue return JArray(l);
	static function jopt<T>(f:T->JsonValue, o:Null<T>):JsonValue return o == null ? JNull : f(o);

	static function jobject(fields:Array<JsonField>):JsonValue return JObject(fields);
	static function field(name:String, value:JsonValue):JsonField return {name: name, value: value};

	static function packagePathFields(pack:Array<String>):Array<JsonField> {
		return [field("pack", jarray([for (p in pack) jstring(p)]))];
	}

	static function modulePathFields(mpath:Path):Array<JsonField> {
		return [field("moduleName", jstring(mpath.name))].concat(packagePathFields(mpath.pack));
	}

	// @:realPath overrides the shown type path
	static function generateTypePath(mpath:Path, tpath:Path, meta:Metadata):JsonValue {
		for (m in meta) if (m.name == ":realPath" && m.params.length == 1) switch (m.params[0].expr) {
			case EConst(CString(s, _)):
				var parts = s.split(".");
				tpath = {pack: parts.slice(0, parts.length - 1), name: parts[parts.length - 1]};
			case _:
		}
		return jobject([field("typeName", jstring(tpath.name))].concat(modulePathFields(mpath)));
	}

	static function generateAdt(name:String, args:Null<JsonValue>):JsonValue {
		var fields = [field("kind", jstring(name))];
		if (args != null) fields.push(field("args", args));
		return jobject(fields);
	}

	// @:realPath overrides the shown name
	static function fieldName(name:String, meta:Metadata):String {
		for (m in meta) if (m.name == ":realPath" && m.params.length == 1) switch (m.params[0].expr) {
			case EConst(CString(s, _)): return s;
			case _:
		}
		return name;
	}

	public function classRef(c:TClass):JsonValue return generateTypePath(c.module.path, c.path, c.meta);
	public function enumRef(en:TEnum):JsonValue return generateTypePath(en.module.path, en.path, en.meta);
	public function abstractRef(a:TAbstract):JsonValue return generateTypePath(a.module.path, a.path, a.meta);

	public function generatePos(p:Position):JsonValue {
		return jobject([
			field("file", jstring(p.file)),
			field("min", jint(p.min)),
			field("max", jint(p.max))
		]);
	}

	function generateDoc(d:Documentation):JsonValue {
		return switch (mode) {
			case GMFull: d == null ? JNull : jstring(Ast.genDocText(d));
			case GMWithoutDoc | GMMinimum: JNull;
		};
	}

	// 0-based lines and characters (getInfos columns are already 0-based).
	public function posToRangeFields(p:Position):Array<JsonField> {
		var i = Position.getInfos(p);
		function point(line:Int, character:Int):JsonValue {
			return jobject([field("line", jint(line)), field("character", jint(character))]);
		}
		return [
			field("start", point(i.line - 1, i.column)),
			field("end", point(i.endLine - 1, i.endColumn))
		];
	}

	public function generatePosAsRange(p:Position):JsonValue {
		return p.min == -1 ? JNull : jobject(posToRangeFields(p));
	}

	// The file is the canonical real path.
	public function generatePosAsLocation(p:Position):JsonValue {
		if (p.min == -1) return JNull;
		var file = p.file;
		if (file != "?") file = hxc.core.PathKey.realPath(file);
		return jobject([
			field("file", jstring(file)),
			field("range", generatePosAsRange(p))
		]);
	}

	// Args serialize as expressions, which are null.
	function generateMetadataEntry(m:MetadataEntry):JsonValue {
		return jobject([
			field("name", jstring(m.name)),
			field("args", jarray([for (_ in m.params) JNull])),
			field("pos", generatePos(m.pos))
		]);
	}

	// Internal metas are filtered out: those the meta registry flags as internal, plus the hxc-only
	// synthetic metas that have no registry entry, filtered explicitly.
	static var internalMetas:Map<String, Bool> = buildInternalMetas();

	static function buildInternalMetas():Map<String, Bool> {
		var m = new Map<String, Bool>();
		// Hxc-only synthetic metas without a registry entry
		for (k in [":storedTypedExpr", ":mergeBlock", ":usedOnlyBy"]) m.set(k, true);
		for (entry in hxc.context.MetaRegistry.metas())
			if (hxc.context.MetaRegistry.boolField(entry, "internal"))
				m.set(hxc.context.MetaRegistry.stringField(entry, "metadata", ""), true);
		return m;
	}

	// None at all without a request naming metadata, and with one only the entries it names - internal ones
	// included.
	public function generateMinimumMetadata(ml:Metadata):Null<JsonValue> {
		var requested = requestedMeta == null ? null : requestedMeta();
		if (requested == null) return null;
		return jarray([for (m in ml) if (requested.indexOf(m.name) >= 0) generateMetadataEntry(m)]);
	}

	public function generateMetadata(ml:Metadata):JsonValue {
		return jarray([for (m in ml) if (!internalMetas.exists(m.name)) generateMetadataEntry(m)]);
	}

	public function generateType(t:T):JsonValue {
		function loop(t:T):{name:String, args:Null<JsonValue>} {
			return switch (t) {
				case TMono(r):
					r.type == null ? {name: "TMono", args: null} : loop(r.type);
				case TLazy(f):
					loop(TypeFunctions.lazyType(f));
				case TDynamic(null):
					{name: "TDynamic", args: JNull};
				case TDynamic(t1):
					{name: "TDynamic", args: generateType(t1)};
				case TInst(c, tl):
					{name: "TInst", args: generateTypePathWithParams(c.module.path, c.path, tl, c.meta)};
				case TEnum(en, tl):
					{name: "TEnum", args: generateTypePathWithParams(en.module.path, en.path, tl, en.meta)};
				case TType(td, tl):
					{name: "TType", args: generateTypePathWithParams(td.module.path, td.path, tl, td.meta)};
				case TAbstract(a, tl):
					{name: "TAbstract", args: generateTypePathWithParams(a.module.path, a.path, tl, a.meta)};
				case TAnon(an):
					{name: "TAnonymous", args: generateAnon(an)};
				case TFun(sig):
					{name: "TFun", args: jobject(generateFunctionSignature(sig.args, sig.ret))};
			};
		}
		var r = loop(t);
		return generateAdt(r.name, r.args);
	}

	function generateAnonStatus(status:AnonStatus):JsonValue {
		return switch (status) {
			case Closed: generateAdt("AClosed", null);
			case Const: generateAdt("AConst", null);
			case Extend(tl): generateAdt("AExtend", generateTypes(tl));
			case Statics(c): generateAdt("AClassStatics", classRef(c));
			case EnumStatics(en): generateAdt("AEnumStatics", enumRef(en));
			case AbstractStatics(a): generateAdt("AAbstractStatics", abstractRef(a));
		};
	}

	function generateAnon(an:TAnon):JsonValue {
		// The fields list in descending name order.
		var names = [for (name in an.fields.keys()) name];
		StringSort.sortDescending(names);
		var fields:Array<JsonValue> = [for (name in names) generateClassField(CFSMember, an.fields.get(name))];
		return jobject([
			field("fields", jarray(fields)),
			field("status", generateAnonStatus(an.status.get()))
		]);
	}

	function generateFunctionArgument(arg:TSignatureArg):JsonValue {
		return jobject([
			field("name", jstring(arg.name)),
			field("opt", jbool(arg.opt)),
			field("t", generateType(arg.t))
		]);
	}

	public function generateFunctionSignature(args:Array<TSignatureArg>, ret:T):Array<JsonField> {
		return [
			field("args", jarray([for (a in args) generateFunctionArgument(a)])),
			field("ret", generateType(ret))
		];
	}

	public function generateTypes(tl:Array<T>):JsonValue {
		return jarray([for (t in tl) generateType(t)]);
	}

	function generateTypePathWithParams(mpath:Path, tpath:Path, tl:Array<T>, meta:Metadata):JsonValue {
		return jobject([
			field("path", generateTypePath(mpath, tpath, meta)),
			field("params", generateTypes(tl))
		]);
	}

	public function generateTypeParameter(tp:TypedTypeParam):JsonValue {
		var constraints = switch (TypeFunctions.follow(tp.type)) {
			case TInst(c, _):
				switch (c.kind) {
					case KTypeParameter(tl): generateTypes(tl);
					case _: jarray([]);
				}
			case _: jarray([]);
		};
		return jobject([
			field("name", jstring(tp.name)),
			field("constraints", constraints),
			field("defaultType", jopt(generateType, tp.defaultType))
		]);
	}

	function generateVarAccess(va:VarAccess):JsonValue {
		return switch (va) {
			case AccNormal: generateAdt("AccNormal", null);
			case AccNo: generateAdt("AccNo", null);
			case AccNever: generateAdt("AccNever", null);
			case AccCtor: generateAdt("AccCtor", null);
			case AccCall: generateAdt("AccCall", null);
			case AccInline: generateAdt("AccInline", null);
			case AccRequire(s, so): generateAdt("AccRequire", jobject([
				field("require", jstring(s)),
				field("message", so == null ? JNull : jstring(so))
			]));
		};
	}

	function generateMethodKind(m:MethodKind):JsonValue {
		return jstring(switch (m) {
			case MethNormal: "MethNormal";
			case MethInline: "MethInline";
			case MethDynamic: "MethDynamic";
			case MethMacro: "MethMacro";
		});
	}

	public function generateClassField(scope:ClassFieldScope, cf:TClassField):JsonValue {
		return jobject(generateClassFieldFields(scope, cf));
	}

	// The declared type swaps for the completion type, which lands first in the field list.
	public function generateClassFieldWithType(scope:ClassFieldScope, cf:TClassField, typeJson:JsonValue):JsonValue {
		var fields = [field("type", typeJson)];
		for (f in generateClassFieldFields(scope, cf)) if (f.name != "type") fields.push(f);
		return jobject(fields);
	}

	public function generateAnonStatusJson(status:AnonStatus):JsonValue return generateAnonStatus(status);
	public function generateAnonJson(an:TAnon):JsonValue return generateAnon(an);

	public function generateTVar(v:TVar):JsonValue {
		var fields:Array<JsonField> = [];
		switch (v.kind) {
			case VUser(origin):
				var i = switch (origin) {
					case TVOLocalVariable: 0;
					case TVOArgument: 1;
					case TVOForVariable: 2;
					case TVOPatternVariable: 3;
					case TVOCatchVariable: 4;
					case TVOLocalFunction: 5;
				};
				fields.push(field("origin", jint(i)));
			case _:
		}
		var extra:JsonValue = JNull;
		if (v.extra != null) {
			var extraFields = [field("params", jarray([for (tp in v.extra.params) generateTypeParameter(tp)]))];
			if (v.extra.expr != null)
				extraFields.push(field("expr", jobject([field("string", jstring(hxc.core.TPrinting.sExprStr(v.extra.expr)))])));
			extra = jobject(extraFields);
		}
		return jobject(fields.concat([
			field("id", jint(v.id)),
			field("name", jstring(v.name)),
			field("type", generateType(v.type)),
			field("capture", jbool(TypeFunctions.hasVarFlag(v, VCaptured))),
			field("extra", extra),
			field("meta", generateMetadata(v.meta)),
			field("pos", generatePos(v.pos)),
			field("isFinal", jbool(TypeFunctions.hasVarFlag(v, VFinal))),
			field("isInline", jbool(v.extra != null && v.extra.expr != null))
		]));
	}

	function generateClassFieldFields(scope:ClassFieldScope, cf:TClassField):Array<JsonField> {
		var kind = switch (cf.kind) {
			case Var(vk): generateAdt("FVar", jobject([
				field("read", generateVarAccess(vk.read)),
				field("write", generateVarAccess(vk.write))
			]));
			case Method(m): generateAdt("FMethod", generateMethodKind(m));
		};
		// Only a @:value var serializes its expression (as a printed string); everything else is null.
		var expr:JsonValue = JNull;
		if (mode != GMMinimum) {
			var hasValue = false;
			switch (cf.kind) {
				case Var(_):
					for (m in cf.meta) if (m.name == ":value" && m.params.length == 1) {
						expr = jobject([field("string", jstring(hxc.ast.Ast.Printer.sExpr(m.params[0])))]);
						hasValue = true;
						break;
					}
				case _:
			}
			// A field carrying the custom :testHack meta serializes its typed expression instead, printed
			// the pretty way.
			if (!hasValue && TypeFunctions.hasMeta(":testHack", cf.meta) && cf.expr != null) {
				var pc = hxc.core.TPrinting.printContext();
				expr = jobject([field("testHack", jstring(hxc.core.TPrinting.sExprPretty(false, "", false,
					function(t) return hxc.core.TPrinting.sType(pc, t), cf.expr)))]);
			}
		}
		return [
			field("name", jstring(fieldName(cf.name, cf.meta))),
			field("type", generateType(cf.type)),
			field("isPublic", jbool(TypeFunctions.hasClassFieldFlag(cf, CfPublic))),
			field("isFinal", jbool(TypeFunctions.hasClassFieldFlag(cf, CfFinal))),
			field("isAbstract", jbool(TypeFunctions.hasClassFieldFlag(cf, CfAbstract))),
			field("params", jarray([for (tp in cf.params) generateTypeParameter(tp)])),
			field("meta", generateMetadata(cf.meta)),
			field("kind", kind),
			field("expr", expr),
			field("pos", generatePos(cf.pos)),
			field("doc", generateDoc(cf.doc)),
			field("overloads", jarray([for (o in cf.overloads) generateClassField(scope, o)])),
			field("scope", jint(scope.getIndex()))
		];
	}

	public function generateEnumField(ef:TEnumField):JsonValue {
		return jobject([
			field("name", jstring(fieldName(ef.name, ef.meta))),
			field("type", generateType(ef.type)),
			field("pos", generatePos(ef.pos)),
			field("meta", generateMetadata(ef.meta)),
			field("index", jint(ef.index)),
			field("doc", generateDoc(ef.doc)),
			field("params", jarray([for (tp in ef.params) generateTypeParameter(tp)]))
		]);
	}

	function generateBinopJson(op:Binop):JsonValue {
		function adt(name:String, args:Null<JsonValue>):JsonValue return generateAdt(name, args);
		return switch (op) {
			case OpAdd: adt("OpAdd", null);
			case OpMult: adt("OpMult", null);
			case OpDiv: adt("OpDiv", null);
			case OpSub: adt("OpSub", null);
			case OpAssign: adt("OpAssign", null);
			case OpEq: adt("OpEq", null);
			case OpNotEq: adt("OpNotEq", null);
			case OpGt: adt("OpGt", null);
			case OpGte: adt("OpGte", null);
			case OpLt: adt("OpLt", null);
			case OpLte: adt("OpLte", null);
			case OpAnd: adt("OpAnd", null);
			case OpOr: adt("OpOr", null);
			case OpXor: adt("OpXor", null);
			case OpBoolAnd: adt("OpBoolAnd", null);
			case OpBoolOr: adt("OpBoolOr", null);
			case OpShl: adt("OpShl", null);
			case OpShr: adt("OpShr", null);
			case OpUShr: adt("OpUShr", null);
			case OpMod: adt("OpMod", null);
			case OpAssignOp(op2): adt("OpAssignOp", generateBinopJson(op2));
			case OpInterval: adt("OpInterval", null);
			case OpArrow: adt("OpArrow", null);
			case OpIn: adt("OpIn", null);
			case OpNullCoal: adt("OpNullCoal", null);
		};
	}

	function generateUnopJson(op:Unop):JsonValue {
		return jstring(switch (op) {
			case Increment: "OpIncrement";
			case Decrement: "OpDecrement";
			case Not: "OpNot";
			case Neg: "OpNeg";
			case NegBits: "OpNegBits";
			case Spread: "OpSpread";
		});
	}

	static function classfieldRef(cf:TClassField):JsonValue {
		return jstring(fieldName(cf.name, cf.meta));
	}

	function generateModuleTypeFields(inf:TInfos):Array<JsonField> {
		return [
			field("pack", jarray([for (p in inf.path.pack) jstring(p)])),
			field("name", jstring(inf.path.name)),
			field("moduleName", jstring(inf.module.path.name)),
			field("pos", generatePos(inf.pos)),
			field("isPrivate", jbool(inf.isPrivate)),
			field("params", jarray([for (tp in inf.params) generateTypeParameter(tp)])),
			field("meta", generateMetadata(inf.meta)),
			field("doc", generateDoc(inf.doc))
		];
	}

	function generateClass(c:TClass):Array<JsonField> {
		function classKind(ck:TClassKind):JsonValue {
			return switch (ck) {
				case KNormal: generateAdt("KNormal", null);
				case KTypeParameter(tl): generateAdt("KTypeParameter", generateTypes(tl));
				case KExpr(_): generateAdt("KExpr", JNull);
				case KGeneric: generateAdt("KGeneric", null);
				case KGenericInstance(c2, tl): generateAdt("KGenericInstance", generateTypePathWithParams(c2.module.path, c2.path, tl, c2.meta));
				case KMacroType: generateAdt("KMacroType", null);
				case KGenericBuild(_): generateAdt("KGenericBuild", null);
				case KAbstractImpl(a): generateAdt("KAbstractImpl", abstractRef(a));
				case KModuleFields(m): generateAdt("KModuleFields", jobject(modulePathFields(m.path)));
			};
		}
		function classRelation(c2:TClass, tl:Array<T>):JsonValue {
			return jobject([
				field("path", classRef(c2)),
				field("params", generateTypes(tl))
			]);
		}
		var overrides = [for (cf in c.orderedFields) if (TypeFunctions.hasClassFieldFlag(cf, CfOverride)) classfieldRef(cf)];
		return [
			field("kind", classKind(c.kind)),
			field("isInterface", jbool(TypeFunctions.hasClassFlag(c, CInterface))),
			field("superClass", c.superClass == null ? JNull : classRelation(c.superClass.c, c.superClass.params)),
			field("interfaces", jarray([for (i in c.interfaces) classRelation(i.c, i.params)])),
			field("fields", jarray([for (cf in c.orderedFields) generateClassField(CFSMember, cf)])),
			field("statics", jarray([for (cf in c.orderedStatics) generateClassField(CFSStatic, cf)])),
			field("constructor", c.constructor == null ? JNull : generateClassField(CFSConstructor, c.constructor)),
			field("init", JNull),
			field("overrides", jarray(overrides)),
			field("isExtern", jbool(TypeFunctions.hasClassFlag(c, CExtern))),
			field("isFinal", jbool(TypeFunctions.hasClassFlag(c, CFinal))),
			field("isAbstract", jbool(TypeFunctions.hasClassFlag(c, CAbstract)))
		];
	}

	function generateEnum(en:TEnum):Array<JsonField> {
		return [
			field("constructors", jarray([for (name in en.names) generateEnumField(en.constrs.get(name))])),
			field("isExtern", jbool(en.isExtern))
		];
	}

	function generateTypedef(td:TDef):Array<JsonField> {
		return [field("type", generateType(td.type))];
	}

	function generateAbstract(a:TAbstract):Array<JsonField> {
		function castRelation(t:T, cf:Null<TClassField>):JsonValue {
			return jobject([
				field("t", generateType(t)),
				field("field", cf == null ? JNull : classfieldRef(cf))
			]);
		}
		function casts(fields:Array<TAbstractCast>, plain:Array<T>):JsonValue {
			return jarray([for (c in fields) castRelation(c.t, c.cf)].concat([for (t in plain) castRelation(t, null)]));
		}
		return [
			field("type", generateType(a.thisType)),
			field("impl", a.impl == null ? JNull : classRef(a.impl)),
			field("binops", jarray([for (o in a.ops) jobject([
				field("op", generateBinopJson(o.op)),
				field("field", classfieldRef(o.cf))
			])])),
			field("unops", jarray([for (o in a.unops) jobject([
				field("op", generateUnopJson(o.op)),
				field("postFix", jbool(o.flag.match(Postfix))),
				field("field", classfieldRef(o.cf))
			])])),
			field("from", casts(a.fromField, a.from)),
			field("to", casts(a.toField, a.to)),
			field("array", jarray([for (cf in a.array) classfieldRef(cf)])),
			field("read", a.read == null ? JNull : classfieldRef(a.read)),
			field("write", a.write == null ? JNull : classfieldRef(a.write))
		];
	}

	public function generateModuleType(mt:ModuleType):JsonValue {
		var fields1 = generateModuleTypeFields(TypeFunctions.tInfos(mt));
		var kind:String;
		var fields2:Array<JsonField>;
		switch (mt) {
			case TClassDecl(c): kind = "class"; fields2 = generateClass(c);
			case TEnumDecl(en): kind = "enum"; fields2 = generateEnum(en);
			case TTypeDecl(td): kind = "typedef"; fields2 = generateTypedef(td);
			case TAbstractDecl(a): kind = "abstract"; fields2 = generateAbstract(a);
		}
		return jobject([field("kind", jstring(kind))].concat(fields1).concat([field("args", jobject(fields2))]));
	}

	public static function sModuleSkipReason(reason:hxc.core.Type.ModuleSkipReason):String {
		function loop(stack:Array<Path>, r:hxc.core.Type.ModuleSkipReason):String {
			return switch (r) {
				case DependencyDirty(path, r2):
					var rec_ = false;
					for (p in stack) if (p.name == path.name && p.pack.join(".") == path.pack.join(".")) { rec_ = true; break; }
					(stack.length == 0 ? "DependencyDirty " : "") + hxc.core.Globals.sTypePath(path)
						+ " - " + (rec_ ? "rec" : loop(stack.concat([path]), r2));
				case Tainted(cause): "Tainted " + cause;
				case FileChanged(file): "FileChanged " + file;
				case Shadowed(file): "Shadowed " + file;
				case LibraryChanged: "LibraryChanged";
			};
		}
		return loop([], reason);
	}

	// The server/module payload. Dependencies list descending by id; dependents scan the context's
	// cached modules for ones depending on this id.
	public static function generateModule(cc:hxc.context.CompilationCache.CacheContext, m:hxc.core.Type.ModuleDef):JsonValue {
		var depIds = [for (id in m.extra.deps.keys()) id];
		depIds.sort(function(a, b) return a - b);
		depIds.reverse();
		// The dependents come out in the REVERSE of the module table's bucket visit order (modeled by
		// moduleOrder).
		var dependents:Array<JsonValue> = [];
		for (path in cc.moduleOrder.visitOrder()) {
			var m2 = cc.modules.get(path);
			if (m2 != null && m2.extra.deps.exists(m.id))
				dependents.push(jobject([
					field("path", jstring(hxc.core.Globals.sTypePath(m2.path))),
					field("sign", jstring(m2.extra.sign))
				]));
		}
		dependents.reverse();
		return jobject([
			field("id", jint(m.id)),
			field("path", jobject(modulePathFields(m.path))),
			field("types", jarray([for (mt in m.types) {
				var infos = TypeFunctions.tInfos(mt);
				generateTypePath(m.path, infos.path, infos.meta);
			}])),
			field("file", jstring(m.extra.file)),
			field("sign", jstring(m.extra.sign)),
			field("cacheState", jstring(switch (m.extra.cacheState) {
				case MSGood: "Good";
				case MSBad(reason): sModuleSkipReason(reason);
				case MSUnknown: "Unknown";
			})),
			field("dependencies", jarray([for (id in depIds) {
				var dm = m.extra.deps.get(id);
				jobject([
					field("path", jstring(hxc.core.Globals.sTypePath(dm.path))),
					field("sign", jstring(dm.extra.sign))
				]);
			}]))
		].concat([field("dependents", jarray(dependents))]));
	}
}
