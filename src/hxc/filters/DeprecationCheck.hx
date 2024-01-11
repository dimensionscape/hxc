package hxc.filters;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.WarningList;
import hxc.context.Context;

// Warns on every use of a @:deprecated type or field.
class DeprecationCheck {
	// One warning per usage position.
	static var warnedPositions:Map<String, Bool> = new Map();
	static var typedefConstructionPositions:Map<String, Bool> = new Map();
	static var typedefTypePositions:Map<String, Bool> = new Map();

	static function warnDeprecation(com:Context, classMeta:Metadata, fieldMeta:Metadata, s:String, p:Position):Void {
		var key = p.file + ":" + p.min;
		if (warnedPositions.exists(key)) return;
		warnedPositions.set(key, true);
		var options = WarningList.fromMeta(classMeta.concat(fieldMeta));
		com.warning(WDeprecated, options, s, p);
	}

	static function printDeprecationMessage(com:Context, classMeta:Metadata, fieldMeta:Metadata, meta:MetadataEntry, s:String, p:Position):Void {
		var msg = switch (meta.params) {
			case [{expr: EConst(CString(m, _))}]: m;
			case _: "Usage of this " + s + " is deprecated";
		};
		warnDeprecation(com, classMeta, fieldMeta, msg, p);
	}

	static function checkMeta(com:Context, classMeta:Metadata, fieldMeta:Metadata, meta:Metadata, s:String, p:Position):Void {
		for (entry in meta) if (entry.name == ":deprecated") {
			printDeprecationMessage(com, classMeta, fieldMeta, entry, s, p);
			return;
		}
	}

	public static function checkTypedefUse(com:Context, td:TDef, p:Position):Void {
		typedefTypePositions.set(p.file + ":" + p.min, true);
		for (entry in td.meta) if (entry.name == ":deprecated") {
			printDeprecationMessage(com, [], [], entry, "typedef", p);
			return;
		}
	}

	public static function checkTypedefConstruction(com:Context, td:TDef, p:Position):Void {
		for (entry in td.meta) if (entry.name == ":deprecated") {
			var msg = switch (entry.params) {
				case [{expr: EConst(CString(m, _))}]: m;
				case _: "This typedef is deprecated in favor of " + hxc.core.TPrinting.sTypeStr(td.type);
			};
			warnDeprecation(com, [], [], msg, p);
			return;
		}
	}

	public static function markTypedefConstruction(p:Position):Void {
		typedefConstructionPositions.set(p.file + ":" + p.min, true);
	}

	static function isTypedefType(p:Position):Bool return typedefTypePositions.exists(p.file + ":" + p.min);

	public static function checkEnumUse(ctx:hxc.typing.TyperContext, en:TEnum, ef:TEnumField, p:Position):Void {
		checkMeta(ctx.com, ctx.curclass == null ? [] : ctx.curclass.meta, ctx.curfield == null ? [] : ctx.curfield.meta, en.meta, "enum", p);
		if (!TypeFunctions.hasMeta(":deprecated", en.meta))
			checkMeta(ctx.com, ctx.curclass == null ? [] : ctx.curclass.meta, ctx.curfield == null ? [] : ctx.curfield.meta, ef.meta, "enum field", p);
	}

	// A property access resolves to its accessor at typing, so the property field never appears
	// in the typed tree the run() walker visits; the use is checked at resolution instead.
	public static function checkPropertyUse(ctx:hxc.typing.TyperContext, cf:TClassField, p:Position):Void {
		if (ctx.com.isMacro) return;
		var classMeta = ctx.curclass != null ? ctx.curclass.meta : [];
		var fieldMeta = ctx.curfield != null ? ctx.curfield.meta : [];
		if (TypeFunctions.hasMeta(":deprecated", classMeta) || TypeFunctions.hasMeta(":deprecated", fieldMeta)) return;
		checkMeta(ctx.com, classMeta, fieldMeta, cf.meta, "field", p);
	}

	public static function run(com:Context):Void {
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasMeta(":deprecated", c.meta)):
				if (c.constructor != null) runOnField(com, c.meta, c.constructor);
				for (cf in c.orderedStatics) runOnField(com, c.meta, cf);
				for (cf in c.orderedFields) runOnField(com, c.meta, cf);
			case _:
		}
	}

	static function runOnField(com:Context, classMeta:Metadata, cf:TClassField):Void {
		if (cf.expr != null && !TypeFunctions.hasMeta(":deprecated", cf.meta))
			runOnExpr(com, classMeta, cf.meta, cf.expr);
	}

	static function runOnExpr(com:Context, classMeta:Metadata, fieldMeta:Metadata, e:TExpr):Void {
		inline function checkCf(cf:TClassField, p:Position)
			checkMeta(com, classMeta, fieldMeta, cf.meta, "field", p);
		inline function checkClass(c:TClass, p:Position)
			checkMeta(com, classMeta, fieldMeta, c.meta, "class", p);
		function checkModuleType(mt:ModuleType, p:Position):Void switch (mt) {
			case TClassDecl(c): checkClass(c, p);
			case TEnumDecl(en): checkMeta(com, classMeta, fieldMeta, en.meta, "enum", p);
			case TTypeDecl(td): checkTypedefUse(com, td, p);
			case _:
		}
		function expr(e:TExpr):Void {
			switch (e.expr) {
				case TField(e1, fa):
					expr(e1);
					var viaTypedef = isTypedefType(e1.pos) || switch (e1.expr) { case TTypeExpr(TTypeDecl(_)): true; case _: false; };
					switch (fa) {
						case FStatic(c, cf) | FInstance(c, _, cf):
							checkClass(c, e.pos);
							checkCf(cf, e.pos);
						case FAnon(cf):
							checkCf(cf, e.pos);
						case FClosure(co, cf):
							if (co != null) checkClass(co.c, e.pos);
							checkCf(cf, e.pos);
						case FEnum(en, ef):
							if (!viaTypedef) {
								checkMeta(com, classMeta, fieldMeta, en.meta, "enum", e.pos);
								if (!TypeFunctions.hasMeta(":deprecated", en.meta)) checkMeta(com, classMeta, fieldMeta, ef.meta, "enum field", e.pos);
							}
						case _:
					}
				case TNew(c, _, el):
					for (x in el) expr(x);
					var abstractImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
					if (!typedefConstructionPositions.exists(e.pos.file + ":" + e.pos.min) && !TypeFunctions.hasClassFlag(c, CAbstract) && !abstractImpl) checkClass(c, e.pos);
					// The AST doesn't carry the correct overload for TNew (#8557).
					if (!typedefConstructionPositions.exists(e.pos.file + ":" + e.pos.min) && !TypeFunctions.hasClassFlag(c, CAbstract) && !abstractImpl && c.constructor != null && c.constructor.overloads.length == 0)
						checkCf(c.constructor, e.pos);
				case TTypeExpr(mt):
					checkModuleType(mt, e.pos);
				case TCast(_, mt) if (mt != null):
					checkModuleType(mt, e.pos);
					hxc.core.TexprTools.iter(expr, e);
				case TMeta(m, e1) if (m.name == ":deprecated"):
					printDeprecationMessage(com, classMeta, fieldMeta, m, "field", e1.pos);
					expr(e1);
				case _:
					hxc.core.TexprTools.iter(expr, e);
			}
		}
		expr(e);
	}
}
