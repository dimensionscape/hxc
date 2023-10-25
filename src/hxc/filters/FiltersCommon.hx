package hxc.filters;


import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.context.Context;
import hxc.typing.TyperContext;

class FiltersCommon {
	public static function isRemovableClass(c:TClass):Bool {
		return switch (c.kind) {
			case KGeneric:
				if (TypeFunctions.hasMeta(":remove", c.meta)) true
				else if (c.superClass != null && isRemovableClass(c.superClass.c)) true
				else {
					var found = false;
					for (tp in c.params) switch (TypeFunctions.follow(tp.type)) {
						case TInst(pc, _):
							if (TypeFunctions.hasCtorConstraint(pc) || TypeFunctions.hasMeta(":const", pc.meta)) {
								found = true;
								break;
							}
						case _:
					}
					found;
				}
			case KTypeParameter(_): true;
			case _: false;
		};
	}

	public static function isRemovableField(com:Context, f:TClassField):Bool {
		if (TypeFunctions.hasClassFieldFlag(f, CfOverride)) return false;
		if (TypeFunctions.hasClassFieldFlag(f, CfExtern) || TypeFunctions.hasClassFieldFlag(f, CfGeneric)) return true;
		return switch (f.kind) {
			case Var(k): k.read.match(AccRequire(_, _));
			case Method(MethMacro): !com.isMacro;
			case _: false;
		};
	}

	// Apply the named filters to every field body, static init and constructor of a class, skipping
	// removable classes/fields and already post-processed fields.
	public static function runExpressionFilters(ctx:TyperContext, filters:Array<{name:String, f:TExpr->TExpr}>, t:ModuleType, ignoreProcessedStatus:Bool = false):Void {
		function run(e:TExpr):TExpr {
			for (fl in filters) e = fl.f(e);
			return e;
		}
		switch (t) {
			case TClassDecl(c) if (isRemovableClass(c)):
			case TClassDecl(c):
				ctx.curclass = c;
				function processField(f:TClassField):Void {
					if (ignoreProcessedStatus || !TypeFunctions.hasClassFieldFlag(f, CfPostProcessed)) {
						ctx.curfield = f;
						if (f.expr != null && !isRemovableField(ctx.com, f))
							f.expr = run(f.expr);
					}
					for (o in f.overloads) processField(o);
				}
				for (f in c.orderedFields) processField(f);
				for (f in c.orderedStatics) processField(f);
				if (c.constructor != null) processField(c.constructor);
				if (c.init != null) c.init = run(c.init);
			case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
		}
	}
}
