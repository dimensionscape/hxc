package hxc.compiler;

import hxc.ast.Ast;
import hxc.ast.Position;

// These numeric values are protocol constants.
class SymbolKind {
	public static inline var KClass = 1;
	public static inline var KInterface = 2;
	public static inline var KEnum = 3;
	public static inline var KTypeAlias = 4;
	public static inline var KAbstract = 5;
	public static inline var KField = 6;
	public static inline var KProperty = 7;
	public static inline var KMethod = 8;
	public static inline var KConstructor = 9;
	public static inline var KFunction = 10;
	public static inline var KVariable = 11;
	public static inline var KStruct = 12;
	public static inline var KEnumAbstract = 13;
	public static inline var KOperator = 14;
	public static inline var KEnumMember = 15;
	public static inline var KConstant = 16;
	public static inline var KModule = 17;
}

typedef SymbolInformation = {
	name:String,
	kind:Int,
	pos:Position,
	containerName:Null<String>,
	deprecated:Bool,
};

class DocumentSymbols {
	public static function collectModuleSymbols(mname:Null<{file:String, name:String}>, withLocals:Bool, pkg:Package):Array<SymbolInformation> {
		var l:Array<SymbolInformation> = [];
		var pack = pkg.pack;
		function add(name:String, kind:Int, location:Position, parent:String, deprecated:Bool):Void {
			l.push({
				name: name,
				kind: kind,
				pos: location,
				containerName: parent == "" ? null : parent,
				deprecated: deprecated
			});
		}
		function isDeprecated(meta:Metadata):Bool {
			return hxc.core.TypeFunctions.hasMeta(":deprecated", meta);
		}
		var func:(String, Func) -> Void = null;
		function expr(parent:String, e:Expr):Void {
			switch (e.expr) {
				case EVars(vl):
					for (v in vl) {
						add(v.evName.name, SymbolKind.KVariable, v.evName.pos, parent, false);
						if (v.evExpr != null) expr(parent, v.evExpr);
					}
				case ETry(e1, catches):
					expr(parent, e1);
					for (c in catches) {
						add(c.name.name, SymbolKind.KVariable, c.name.pos, parent, false);
						expr(parent, c.expr);
					}
				case EFunction(FKNamed(n, _), f):
					add(n.name, SymbolKind.KFunction, e.pos, parent, false);
					func(parent, f);
				// A `for (x in it)` head declares x; the parser keeps it as an OpIn binop.
				case EBinop(OpIn, e1, e2) if (Expr.findIdent(e1) != null):
					add(Expr.findIdent(e1), SymbolKind.KVariable, e1.pos, parent, false);
					expr(parent, e2);
				case _:
					Ast.iterExpr(function(sub) expr(parent, sub), e);
			}
		}
		func = function(parent:String, f:Func):Void {
			for (a in f.fArgs) {
				add(a.name.name, SymbolKind.KVariable, a.name.pos, parent, false);
				if (a.value != null) expr(parent, a.value);
			}
			if (f.fExpr != null) expr(parent, f.fExpr);
		};
		function fieldRaw(parent:String, parentKind:Int, cffName:PlacedName, cffKind:ClassFieldKind,
				cffAccess:Array<PlacedAccess>, cffPos:Position, cffMeta:Metadata):Void {
			var fieldParent = parent + "." + cffName.name;
			function hasAccess(a:Access):Bool {
				for (x in cffAccess) if (Type.enumEq(x.access, a)) return true;
				return false;
			}
			inline function addField(kind:Int):Void
				add(cffName.name, kind, cffPos, parent, isDeprecated(cffMeta));
			switch (cffKind) {
				case FVar(_, eo):
					addField(if (parentKind == SymbolKind.KEnumAbstract && !hasAccess(AStatic)) SymbolKind.KEnumMember
						else if (hasAccess(AInline)) SymbolKind.KConstant
						else SymbolKind.KField);
					if (withLocals && eo != null) expr(fieldParent, eo);
				case FFun(f):
					addField(if (cffName.name == "new") SymbolKind.KConstructor
						else if ((parentKind == SymbolKind.KEnumAbstract || parentKind == SymbolKind.KAbstract)
							&& (hxc.core.TypeFunctions.hasMeta(":op", cffMeta)
								|| hxc.core.TypeFunctions.hasMeta(":arrayAccess", cffMeta)
								|| hxc.core.TypeFunctions.hasMeta(":resolve", cffMeta))) SymbolKind.KOperator
						else SymbolKind.KMethod);
					if (withLocals) func(fieldParent, f);
				case FProp(_, _, _, eo):
					addField(SymbolKind.KProperty);
					if (withLocals && eo != null) expr(fieldParent, eo);
			}
		}
		inline function field(parent:String, parentKind:Int, cff:ClassField):Void
			fieldRaw(parent, parentKind, cff.cffName, cff.cffKind, cff.cffAccess, cff.cffPos, cff.cffMeta);

		var typeDecls = new Map<String, Bool>();
		for (td in pkg.decls) {
			var p = td.pos;
			// A type matching the module name belongs directly to its package; other types are nested under
			// the module.
			function declPath(dName:PlacedName):{path:Array<String>, name:String} {
				var moduleName = moduleNameOfFile(p.file);
				var typeName = dName.name;
				return {path: typeName == moduleName ? pack : pack.concat([moduleName]), name: typeName};
			}
			function addType(dName:PlacedName, dMeta:Metadata, kind:Int):String {
				var dp = declPath(dName);
				typeDecls.set(dp.name, true);
				add(dp.name, kind, p, dp.path.join("."), isDeprecated(dMeta));
				return dp.path.concat([dp.name]).join(".");
			}
			switch (td.decl) {
				case EImport(_) | EUsing(_):
				case EClass(d):
					var kind = d.dFlags.indexOf(HInterface) >= 0 ? SymbolKind.KInterface : SymbolKind.KClass;
					var parent = addType(d.dName, d.dMeta, kind);
					for (f in d.dData) field(parent, kind, f);
				case EEnum(d):
					var parent = addType(d.dName, d.dMeta, SymbolKind.KEnum);
					for (ef in d.dData)
						add(ef.ecName.name, SymbolKind.KEnumMember, ef.ecPos, parent, isDeprecated(ef.ecMeta));
				case ETypedef(d):
					switch (d.dData.ct) {
						case CTAnonymous(fields):
							var parent = addType(d.dName, d.dMeta, SymbolKind.KStruct);
							for (f in fields) field(parent, SymbolKind.KStruct, f);
						case _:
							addType(d.dName, d.dMeta, SymbolKind.KTypeAlias);
					}
				case EAbstract(d):
					var kind = d.dFlags.indexOf(AbEnum) >= 0 ? SymbolKind.KEnumAbstract : SymbolKind.KAbstract;
					var parent = addType(d.dName, d.dMeta, kind);
					for (f in d.dData) field(parent, kind, f);
				case EStatic(d):
					// Module-level fields belong directly to the package, without a type declaration.
					var dp = declPath(d.dName);
					fieldRaw(dp.path.join("."), SymbolKind.KClass, d.dName, d.dData, d.dFlags, p, d.dMeta);
			}
		}
		// A module with no type of its own name still reports the module itself.
		if (mname != null && !typeDecls.exists(mname.name))
			add(mname.name, SymbolKind.KModule, new Position(mname.file, 0, 0), pack.join("."), false);
		return l;
	}

	// Drop the extension and any platform suffix, so Main.js.hx resolves to Main.
	public static function moduleNameOfFile(file:String):String {
		var parts = StringTools.replace(file, "\\", "/").split("/");
		var last = parts.length == 0 ? "" : parts[parts.length - 1];
		var dots = last.split(".");
		return switch (dots.length) {
			case 0: "";
			case 1: dots[0];
			case 2: dots[0];
			case _: dots.slice(0, dots.length - 2).join(".");
		}
	}

	// Deduplicate symbols by position, keep the first, and omit empty files. Workspace filters match
	// names case-insensitively.
	public static function printModuleSymbols(symbols:Array<{file:String, l:Array<SymbolInformation>}>, filter:Null<String>):String {
		var lower = filter == null ? null : filter.toLowerCase();
		var reported = new Map<String, Bool>();
		var ja:Array<hxc.core.Json.JsonValue> = [];
		for (entry in symbols) {
			var jl:Array<hxc.core.Json.JsonValue> = [];
			for (si in entry.l) {
				var key = si.pos.file + ":" + si.pos.min + ":" + si.pos.max;
				if (reported.exists(key)) continue;
				reported.set(key, true);
				if (lower != null && si.name.toLowerCase().indexOf(lower) < 0) continue;
				var fields:Array<hxc.core.Json.JsonField> = [
					{name: "name", value: JString(si.name)},
					{name: "kind", value: JInt(si.kind)},
					{name: "range", value: new hxc.core.Genjson(hxc.core.Genjson.GenerationMode.GMFull).generatePosAsRange(si.pos)}
				];
				if (si.containerName != null) fields.push({name: "containerName", value: JString(si.containerName)});
				if (si.deprecated) fields.unshift({name: "isDeprecated", value: JBool(true)});
				jl.push(JObject(fields));
			}
			if (jl.length == 0) continue;
			ja.push(JObject([{name: "file", value: JString(entry.file)}, {name: "symbols", value: JArray(jl)}]));
		}
		return hxc.core.Json.stringOfJson(JArray(ja));
	}
}
