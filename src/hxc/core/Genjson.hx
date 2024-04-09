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
		if (file != "?") file = try FileSystem.fullPath(file) catch (_:Dynamic) file;
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

	// Filters internal metas (meta.json m_internal); hxc has no meta registry, so the
	// compiler-synthesized internal names filter by hand.
	static var internalMetas = [
		":tailRecursion" => true, ":storedTypedExpr" => true, ":this" => true,
		":impl" => true, ":mergeBlock" => true, ":implicitReturn" => true,
		":realPath" => true, ":value" => true, ":usedOnlyBy" => true, ":directlyUsed" => true
	];

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
		var fields:Array<JsonValue> = [];
		for (name in an.fields.keys()) fields.push(generateClassField(CFSMember, an.fields.get(name)));
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
		var kind = switch (cf.kind) {
			case Var(vk): generateAdt("FVar", jobject([
				field("read", generateVarAccess(vk.read)),
				field("write", generateVarAccess(vk.write))
			]));
			case Method(m): generateAdt("FMethod", generateMethodKind(m));
		};
		// Only a @:value var serializes its expression (as a printed string); everything else is null.
		var expr:JsonValue = JNull;
		if (mode != GMMinimum) switch (cf.kind) {
			case Var(_):
				for (m in cf.meta) if (m.name == ":value" && m.params.length == 1) {
					expr = jobject([field("string", jstring(hxc.ast.Ast.Printer.sExpr(m.params[0])))]);
					break;
				}
			case _:
		}
		return jobject([
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
		]);
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
}
