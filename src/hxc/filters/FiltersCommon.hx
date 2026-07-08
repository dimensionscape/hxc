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

	// Expression filters apply to every field body, static init and constructor of a class, skipping
	// removable classes/fields and already post-processed fields.
	// Per-filter timing (HXC_DBG_FILTERTIMES) localizes a slow pipeline to the filter, which the coarse
	// --times cannot.
	public static var filterTimes:haxe.ds.StringMap<Float> = new haxe.ds.StringMap();
	public static var timeFilters:Bool = Sys.getEnv("HXC_DBG_FILTERTIMES") != null;

	public static function dumpFilterTimes():Void {
		if (!timeFilters) return;
		var rows = [for (k in filterTimes.keys()) {name: k, t: filterTimes.get(k)}];
		rows.sort(function(a, b) return a.t < b.t ? 1 : -1);
		var o = Sys.stderr();
		for (r in rows) o.writeString("[ftime] " + StringTools.lpad(Std.string(Math.round(r.t * 1000)), " ", 7) + "ms  " + r.name + "\n");
		o.flush();
	}

	public static function runExpressionFilters(ctx:TyperContext, filters:Array<{name:String, f:TExpr->TExpr}>, t:ModuleType, ignoreProcessedStatus:Bool = false):Void {
		function run(e:TExpr):TExpr {
			if (timeFilters) {
				for (fl in filters) {
					var t0 = haxe.Timer.stamp();
					e = fl.f(e);
					var prev = filterTimes.get(fl.name);
					filterTimes.set(fl.name, (prev == null ? 0.0 : prev) + (haxe.Timer.stamp() - t0));
				}
				return e;
			}
			for (fl in filters) e = fl.f(e);
			return e;
		}
		switch (t) {
			case TClassDecl(c) if (isRemovableClass(c)):
			case TClassDecl(c):
				ctx.curclass = c;
				// The class's module is current while its fields filter, so what they load is its
				// dependency. The filters' context keeps it afterwards (filterModule); nothing else may
				// inherit it.
				ctx.filterModule = c.module;
				var savedModule = ctx.com.currentModule;
				ctx.com.currentModule = c.module;
				function processField(f:TClassField):Void {
					if (ignoreProcessedStatus || !TypeFunctions.hasClassFieldFlag(f, CfPostProcessed)) {
						ctx.curfield = f;
						if (f.expr != null && !isRemovableField(ctx.com, f))
							f.expr = run(f.expr);
					}
					for (o in f.overloads) processField(o);
				}
				try {
					// The lists are walked as they are when the walk starts: a static a filter adds
					// meanwhile (LocalStatic prepends one) is not visited.
					for (f in c.orderedFields.copy()) processField(f);
					for (f in c.orderedStatics.copy()) processField(f);
					if (c.constructor != null) processField(c.constructor);
					if (c.init != null) c.init = run(c.init);
				} catch (e:Dynamic) {
					ctx.com.currentModule = savedModule;
					throw e;
				}
				ctx.com.currentModule = savedModule;
			case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
		}
	}
}
