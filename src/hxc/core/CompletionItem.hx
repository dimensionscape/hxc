package hxc.core;

// hxc.core.CompletionItem: the display protocol's completion/hover item model.

import hxc.core.Globals.Path;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Json;
import hxc.core.Genjson;

enum ImportStatus {
	Imported;
	Unimported;
	Shadowed;
}

class ImportStatusTools {
	public static function toInt(is_:ImportStatus):Int {
		return switch (is_) {
			case Imported: 0;
			case Unimported: 1;
			case Shadowed: 2;
		};
	}
}

enum ClassFieldOrigin {
	Self(mt:ModuleType);
	StaticImport(mt:ModuleType);
	Parent(mt:ModuleType);
	StaticExtension(mt:ModuleType);
	AnonymousStructure(an:TAnon);
	BuiltIn;
	Unknown;
}

// The display-facing type model with import status on every path.
enum CompletionType {
	CTMono;
	CTInst(pwp:CtPathWithParams);
	CTEnum(pwp:CtPathWithParams);
	CTTypedef(pwp:CtPathWithParams);
	CTAbstract(pwp:CtPathWithParams);
	CTFunction(args:Array<CtFunctionArgument>, ret:CompletionType);
	CTAnonymous(fields:Array<CtAnonymousField>, status:AnonStatus);
	CTDynamic(t:Null<CompletionType>);
}

typedef CtPathWithParams = {
	pack:Array<String>,
	typeName:String,
	moduleName:String,
	params:Array<CompletionType>,
	importStatus:ImportStatus
};

typedef CtFunctionArgument = {name:String, opt:Bool, t:CompletionType};
typedef CtAnonymousField = {field:TClassField, t:CompletionType};

class CompletionTypeTools {
	public static function fromType(getImportStatus:Path->ImportStatus, t:T):CompletionType {
		function ppath(mpath:Path, tpath:Path, tl:Array<T>):CtPathWithParams {
			return {
				pack: tpath.pack,
				moduleName: mpath.name,
				typeName: tpath.name,
				importStatus: getImportStatus(tpath),
				params: [for (t2 in tl) fromType(getImportStatus, t2)]
			};
		}
		return switch (t) {
			case TMono(r):
				r.type == null ? CTMono : fromType(getImportStatus, r.type);
			case TLazy(f):
				fromType(getImportStatus, TypeFunctions.lazyType(f));
			case TInst(c, _) if (c.kind.match(KTypeParameter(_))):
				CTInst({
					pack: c.path.pack,
					moduleName: c.module.path.name,
					typeName: c.path.name,
					importStatus: Imported,
					params: []
				});
			case TInst(c, tl):
				CTInst(ppath(c.module.path, c.path, tl));
			case TEnum(en, tl):
				CTEnum(ppath(en.module.path, en.path, tl));
			case TType(td, tl):
				CTTypedef(ppath(td.module.path, td.path, tl));
			case TAbstract(a, tl):
				CTAbstract(ppath(a.module.path, a.path, tl));
			case TFun(sig):
				CTFunction([for (a in sig.args) {name: a.name, opt: a.opt, t: fromType(getImportStatus, a.t)}],
					fromType(getImportStatus, sig.ret));
			case TAnon(an):
				var fields:Array<CtAnonymousField> = [];
				for (name in an.fields.keys()) {
					var cf = an.fields.get(name);
					fields.push({field: cf, t: fromType(getImportStatus, cf.type)});
				}
				CTAnonymous(fields, an.status.get());
			case TDynamic(null):
				CTDynamic(null);
			case TDynamic(t1):
				CTDynamic(fromType(getImportStatus, t1));
		};
	}

	public static function toJson(gen:Genjson, ct:CompletionType):JsonValue {
		function field(name:String, value:JsonValue):JsonField return {name: name, value: value};
		function adt(name:String, args:Null<JsonValue>):JsonValue {
			var fields = [field("kind", JString(name))];
			if (args != null) fields.push(field("args", args));
			return JObject(fields);
		}
		function pathWithParams(pwp:CtPathWithParams):JsonValue {
			return JObject([
				field("path", JObject([
					field("pack", JArray([for (p in pwp.pack) JString(p)])),
					field("moduleName", JString(pwp.moduleName)),
					field("typeName", JString(pwp.typeName)),
					field("importStatus", JInt(ImportStatusTools.toInt(pwp.importStatus)))
				])),
				field("params", JArray([for (p in pwp.params) toJson(gen, p)]))
			]);
		}
		return switch (ct) {
			case CTMono: adt("TMono", null);
			case CTInst(pwp): adt("TInst", pathWithParams(pwp));
			case CTEnum(pwp): adt("TEnum", pathWithParams(pwp));
			case CTTypedef(pwp): adt("TType", pathWithParams(pwp));
			case CTAbstract(pwp): adt("TAbstract", pathWithParams(pwp));
			case CTFunction(args, ret):
				adt("TFun", JObject([
					field("args", JArray([for (a in args) JObject([
						field("name", JString(a.name)),
						field("opt", JBool(a.opt)),
						field("t", toJson(gen, a.t)),
						field("value", JNull)
					])])),
					field("ret", toJson(gen, ret))
				]));
			case CTAnonymous(fields, status):
				// Fields sort by name position, and each field's declared type is swapped for the
				// completion type.
				var sorted = fields.copy();
				sorted.sort(function(a, b) return a.field.namePos.min - b.field.namePos.min);
				adt("TAnonymous", JObject([
					field("status", gen.generateAnonStatusJson(status)),
					field("fields", JArray([for (af in sorted) gen.generateClassFieldWithType(CFSMember, af.field, toJson(gen, af.t))]))
				]));
			case CTDynamic(null): adt("TDynamic", null);
			case CTDynamic(t1): adt("TDynamic", toJson(gen, t1));
		};
	}
}

class ClassFieldOriginTools {
	public static function toJson(gen:Genjson, cfo:ClassFieldOrigin):JsonValue {
		var i:Int;
		var args:Null<JsonValue>;
		switch (cfo) {
			case Self(mt): i = 0; args = gen.mode == GMMinimum ? null : gen.generateModuleType(mt);
			case StaticImport(mt): i = 1; args = gen.mode == GMMinimum ? null : gen.generateModuleType(mt);
			case Parent(mt): i = 2; args = gen.mode == GMMinimum ? null : gen.generateModuleType(mt);
			case StaticExtension(mt): i = 3; args = gen.mode == GMMinimum ? null : gen.generateModuleType(mt);
			case AnonymousStructure(an): i = 4; args = gen.mode == GMMinimum ? null : gen.generateAnonJson(an);
			case BuiltIn: i = 5; args = null;
			case Unknown: i = 6; args = null;
		}
		var fields:Array<JsonField> = [{name: "kind", value: JInt(i)}];
		if (args != null) fields.push({name: "args", value: args});
		return JObject(fields);
	}
}

class CompletionItem {
	// The ClassField arm: item = {kind, args:{field, origin, resolution}, type}. ITEnumAbstractField
	// serializes exactly like ITClassField, under a different kind name .
	public static function classFieldToJson(gen:Genjson, scope:ClassFieldScope, cf:TClassField, origin:ClassFieldOrigin,
			isQualified:Bool, ct:CompletionType, ?index:Int, enumAbstract:Bool = false):JsonValue {
		var qualifier:JsonValue = switch [scope, origin] {
			case [CFSStatic, Self(mt) | Parent(mt) | StaticExtension(mt) | StaticImport(mt)]:
				var infos = TypeFunctions.tInfos(mt);
				var pack = infos.module.path.pack;
				var dot = pack.concat(infos.module.path.name == infos.path.name
					? [infos.path.name]
					: [infos.module.path.name, infos.path.name]);
				JString(dot.join("."));
			case [CFSMember, Self(_)]: JString("this");
			case [CFSMember, Parent(_)]: JString("super");
			case _: JNull;
		};
		return JObject([
			{name: "kind", value: JString(enumAbstract ? "EnumAbstractField" : "ClassField")},
			{name: "args", value: JObject([
				{name: "field", value: gen.generateClassField(scope, cf)},
				{name: "origin", value: ClassFieldOriginTools.toJson(gen, origin)},
				{name: "resolution", value: JObject([
					{name: "isQualified", value: JBool(isQualified)},
					{name: "qualifier", value: qualifier}
				])}
			])},
			{name: "type", value: CompletionTypeTools.toJson(gen, ct)}
		].concat(index == null ? [] : ([{name: "index", value: JInt(index)}]:Array<JsonField>)));
	}

	// The Local item: {kind:"Local", args:generateTVar, type}.
	public static function localToJson(gen:Genjson, v:TVar, ct:CompletionType, ?index:Int):JsonValue {
		return JObject(([
			{name: "kind", value: JString("Local")},
			{name: "args", value: gen.generateTVar(v)},
			{name: "type", value: CompletionTypeTools.toJson(gen, ct)}
		]:Array<JsonField>).concat(index == null ? [] : ([{name: "index", value: JInt(index)}]:Array<JsonField>)));
	}

	// The TypeParameter item: {kind, args:{name, meta, constraints}, type}.
	public static function typeParamToJson(gen:Genjson, c:TClass, ct:CompletionType, ?index:Int):JsonValue {
		var constraints = switch (c.kind) {
			case KTypeParameter(tl): tl;
			case _: [];
		};
		return JObject(([
			{name: "kind", value: JString("TypeParameter")},
			{name: "args", value: JObject([
				{name: "name", value: JString(c.path.name)},
				{name: "meta", value: gen.generateMetadata(c.meta)},
				{name: "constraints", value: JArray([for (t in constraints) gen.generateType(t)])}
			])},
			{name: "type", value: CompletionTypeTools.toJson(gen, ct)}
		]:Array<JsonField>).concat(index == null ? [] : ([{name: "index", value: JInt(index)}]:Array<JsonField>)));
	}

	// The Keyword item: {kind:"Keyword", args:{name}}.
	public static function keywordToJson(name:String, ?index:Int):JsonValue {
		return JObject(([
			{name: "kind", value: JString("Keyword")},
			{name: "args", value: JObject([{name: "name", value: JString(name)}])}
		]:Array<JsonField>).concat(index == null ? [] : ([{name: "index", value: JInt(index)}]:Array<JsonField>)));
	}

	// The Type item (full mode) with the module-kind int code, the ctor-derived extern/final/abstract flags
	// and ast params.
	// A SYNTAX-side declaration (a parsed but unloaded module from class-path exploration) makes the same
	// Type item shape as a typed module type, with flags/kind read from the declaration flags.
	public static function declTypeToJson(gen:Genjson, pack:Array<String>, moduleName:String, td:hxc.ast.Ast.TypeDef,
			declPos:hxc.ast.Position, importStatus:Int, ?index:Int):JsonValue {
		var name:String;
		var params:Array<hxc.ast.Ast.TypeParam>;
		var meta:hxc.ast.Ast.Metadata;
		var doc:hxc.ast.Ast.Documentation;
		var kind = 0;
		var isExtern = false, isFinal = false, isAbstract = false;
		switch (td) {
			case EClass(d):
				name = d.dName.name; params = d.dParams; meta = d.dMeta; doc = d.dDoc;
				isExtern = d.dFlags.contains(HExtern);
				isFinal = d.dFlags.contains(HFinal);
				isAbstract = d.dFlags.contains(HAbstract);
				kind = d.dFlags.contains(HInterface) ? 1 : 0;
			case EEnum(d):
				name = d.dName.name; params = d.dParams; meta = d.dMeta; doc = d.dDoc;
				isExtern = d.dFlags.contains(EExtern);
				kind = 2;
			case ETypedef(d):
				name = d.dName.name; params = d.dParams; meta = d.dMeta; doc = d.dDoc;
				isExtern = d.dFlags.contains(EExtern);
				kind = switch (d.dData.ct) { case CTAnonymous(_): 6; case _: 5; };
			case EAbstract(d):
				name = d.dName.name; params = d.dParams; meta = d.dMeta; doc = d.dDoc;
				isExtern = d.dFlags.contains(AbExtern);
				kind = d.dFlags.contains(AbEnum) ? 4 : 3;
			case EStatic(d):
				// EStatic: final, of kind Static, the value after TypeParameter in the kind enum (Class
				// Interface Enum Abstract EnumAbstract TypeAlias Struct TypeParameter Static).
				name = d.dName.name; params = d.dParams; meta = d.dMeta; doc = d.dDoc;
				isFinal = true;
				kind = 8;
			case EImport(_) | EUsing(_):
				throw new hxc.core.NotFound();
		}
		function astParam(tp:hxc.ast.Ast.TypeParam):JsonValue {
			return JObject([
				{name: "name", value: JString(tp.tpName.name)},
				{name: "params", value: JArray([])},
				{name: "constraints", value: JNull},
				{name: "metadata", value: gen.generateMetadata(tp.tpMeta)}
			]);
		}
		return JObject(([
			{name: "kind", value: JString("Type")},
			{name: "args", value: JObject([
				{name: "path", value: JObject([
					{name: "pack", value: JArray([for (x in pack) JString(x)])},
					{name: "moduleName", value: JString(moduleName)},
					{name: "typeName", value: JString(name)},
					{name: "importStatus", value: JInt(importStatus)}
				])},
				{name: "kind", value: JInt(kind)},
				{name: "meta", value: gen.generateMetadata(meta)},
				{name: "pos", value: gen.generatePos(declPos)},
				{name: "params", value: JArray([for (tp in params) astParam(tp)])},
				{name: "isExtern", value: JBool(isExtern)},
				{name: "isFinal", value: JBool(isFinal)},
				{name: "isAbstract", value: JBool(isAbstract)},
				{name: "doc", value: doc == null ? JNull : JString(hxc.ast.Ast.genDocText(doc))}
			])}
		]:Array<JsonField>).concat(index == null ? [] : ([{name: "index", value: JInt(index)}]:Array<JsonField>)));
	}

	// A package item: {path: {pack}, contents: []}.
	public static function packageToJson(pack:Array<String>, ?index:Int):JsonValue {
		return JObject(([
			{name: "kind", value: JString("Package")},
			{name: "args", value: JObject([
				{name: "path", value: JObject([{name: "pack", value: JArray([for (x in pack) JString(x)])}])},
				{name: "contents", value: JArray([])}
			])}
		]:Array<JsonField>).concat(index == null ? [] : ([{name: "index", value: JInt(index)}]:Array<JsonField>)));
	}

	// The "type" field is present only when the item carries a ci_type. A toplevel Type item has none
	// (make_ci_type ... None); a HOVER on a type path does Some (t,ct)).
	public static function moduleTypeToJson(gen:Genjson, mt:hxc.core.Type.ModuleType, importStatus:Int, ?index:Int, ?ct:CompletionType):JsonValue {
		var infos = TypeFunctions.tInfos(mt);
		var kind:Int;
		var isExtern = false, isFinal = false, isAbstract = false;
		switch (mt) {
			case TClassDecl(c):
				isExtern = TypeFunctions.hasClassFlag(c, CExtern);
				isFinal = TypeFunctions.hasClassFlag(c, CFinal);
				isAbstract = TypeFunctions.hasClassFlag(c, CAbstract);
				kind = TypeFunctions.hasClassFlag(c, CInterface) ? 1 : 0;
			case TEnumDecl(en):
				isExtern = en.isExtern;
				kind = 2;
			case TTypeDecl(td):
				kind = switch (TypeFunctions.follow(td.type)) {
					case TAnon(_): 6;
					case _: 5;
				};
			case TAbstractDecl(a):
				kind = a.isEnum ? 4 : 3;
		}
		function astParam(tp:hxc.core.Type.TypedTypeParam):JsonValue {
			var meta:hxc.ast.Ast.Metadata = switch (TypeFunctions.follow(tp.type)) {
				case TInst(c, _): c.meta;
				case _: [];
			};
			return JObject([
				{name: "name", value: JString(tp.name)},
				{name: "params", value: JArray([])},
				{name: "constraints", value: JNull},
				{name: "metadata", value: gen.generateMetadata(meta)}
			]);
		}
		return JObject(([
			{name: "kind", value: JString("Type")},
			{name: "args", value: JObject([
				{name: "path", value: JObject([
					{name: "pack", value: JArray([for (x in infos.path.pack) JString(x)])},
					{name: "moduleName", value: JString(infos.module.path.name)},
					{name: "typeName", value: JString(infos.path.name)},
					{name: "importStatus", value: JInt(importStatus)}
				])},
				{name: "kind", value: JInt(kind)},
				{name: "meta", value: gen.generateMetadata(infos.meta)},
				{name: "pos", value: gen.generatePos(infos.pos)},
				{name: "params", value: JArray([for (tp in infos.params) astParam(tp)])},
				{name: "isExtern", value: JBool(isExtern)},
				{name: "isFinal", value: JBool(isFinal)},
				{name: "isAbstract", value: JBool(isAbstract)},
				{name: "doc", value: infos.doc == null ? JNull : JString(hxc.ast.Ast.genDocText(infos.doc))}
			])}
		]:Array<JsonField>)
			.concat(ct == null ? [] : ([{name: "type", value: CompletionTypeTools.toJson(gen, ct)}]:Array<JsonField>))
			.concat(index == null ? [] : ([{name: "index", value: JInt(index)}]:Array<JsonField>)));
	}

	// The EnumField item.
	public static function enumFieldToJson(gen:Genjson, ef:TEnumField, origin:ClassFieldOrigin, isQualified:Bool,
			ct:CompletionType, ?index:Int):JsonValue {
		var qualifier:JsonValue = switch (origin) {
			case Self(mt) | StaticImport(mt):
				var infos = TypeFunctions.tInfos(mt);
				var pack = infos.module.path.pack;
				var dot = pack.concat(infos.module.path.name == infos.path.name
					? [infos.path.name]
					: [infos.module.path.name, infos.path.name]);
				JString(dot.join("."));
			case _: JNull;
		};
		return JObject([
			{name: "kind", value: JString("EnumField")},
			{name: "args", value: JObject([
				{name: "field", value: gen.generateEnumField(ef)},
				{name: "origin", value: ClassFieldOriginTools.toJson(gen, origin)},
				{name: "resolution", value: JObject([
					{name: "isQualified", value: JBool(isQualified)},
					{name: "qualifier", value: qualifier}
				])}
			])},
			{name: "type", value: CompletionTypeTools.toJson(gen, ct)}
		].concat(index == null ? [] : ([{name: "index", value: JInt(index)}]:Array<JsonField>)));
	}

	// {kind: Define, args: {name, value}} plus the type, which is always String.
	public static function defineToJson(gen:Genjson, name:String, value:Null<String>, ct:CompletionType):JsonValue {
		return JObject(([
			{name: "kind", value: JString("Define")},
			{name: "args", value: JObject(([
				{name: "name", value: JString(name)},
				{name: "value", value: value == null ? JNull : JString(value)}
			]:Array<JsonField>))},
			{name: "type", value: CompletionTypeTools.toJson(gen, ct)}
		]:Array<JsonField>));
	}

	// {kind: Literal, args: {name}} plus the type.
	public static function literalToJson(gen:Genjson, name:String, ct:CompletionType, ?index:Int):JsonValue {
		return JObject(([
			{name: "kind", value: JString("Literal")},
			{name: "args", value: JObject([{name: "name", value: JString(name)}])},
			{name: "type", value: CompletionTypeTools.toJson(gen, ct)}
		]:Array<JsonField>).concat(index == null ? [] : ([{name: "index", value: JInt(index)}]:Array<JsonField>)));
	}

	// The Expression item: args would be the typed expression, which is not serialized (null).
	public static function expressionToJson(gen:Genjson, ct:CompletionType):JsonValue {
		return JObject([
			{name: "kind", value: JString("Expression")},
			{name: "args", value: JNull},
			{name: "type", value: CompletionTypeTools.toJson(gen, ct)}
		]);
	}
}
