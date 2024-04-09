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
	// The ClassField arm: item = {kind, args:{field, origin, resolution}, type}.
	public static function classFieldToJson(gen:Genjson, scope:ClassFieldScope, cf:TClassField, origin:ClassFieldOrigin,
			isQualified:Bool, ct:CompletionType):JsonValue {
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
			{name: "kind", value: JString("ClassField")},
			{name: "args", value: JObject([
				{name: "field", value: gen.generateClassField(scope, cf)},
				{name: "origin", value: ClassFieldOriginTools.toJson(gen, origin)},
				{name: "resolution", value: JObject([
					{name: "isQualified", value: JBool(isQualified)},
					{name: "qualifier", value: qualifier}
				])}
			])},
			{name: "type", value: CompletionTypeTools.toJson(gen, ct)}
		]);
	}

	// The Local item: {kind:"Local", args:generateTVar, type}.
	public static function localToJson(gen:Genjson, v:TVar, ct:CompletionType):JsonValue {
		return JObject([
			{name: "kind", value: JString("Local")},
			{name: "args", value: gen.generateTVar(v)},
			{name: "type", value: CompletionTypeTools.toJson(gen, ct)}
		]);
	}
}
