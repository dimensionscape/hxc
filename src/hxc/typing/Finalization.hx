package hxc.typing;


import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.context.Context;
import hxc.context.Context.ContextError;
import hxc.context.ModuleLoader;
import haxe.ds.StringMap;

class Finalization {
	// The entry expression, a call to the -main class's static main() plus the entry-point or
	// per-thread event-loop tail.
	public static function getMain(ctx:Context, types:Array<ModuleType>):Null<TExpr> {
		var path = ctx.mainClass;
		if (path == null) return null;
		var p = Position.nullPos;
		var m = ModuleLoader.loadModule(ctx, path, p);
		var c:TClass = null;
		var f:TClassField = null;
		var errPos = p;
		if (m.statics != null) {
			errPos = m.statics.namePos;
			var cf = m.statics.statics.get("main");
			if (cf != null) {
				c = m.statics;
				f = cf;
			}
		}
		if (f == null) {
			// The main type is the one named exactly like the module (never a scan for any class carrying a
			// main), and its failure - private type, or the module not defining it - propagates rather than
			// degrading to "does not have static function main". Only the missing `main` field is recovered.
			var t = ModuleLoader.findTypeInModule(ctx, m, path.name, Position.nullPos);
			switch (t) {
				case null:
				case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
					throw new TypingError("Invalid -main : " + Context.sTypePath(path) + " is not a class", Position.nullPos);
				case TClassDecl(c2):
					errPos = c2.namePos;
					var cf = c2.statics.get("main");
					if (cf != null) {
						c = c2;
						f = cf;
					}
			}
		}
		if (f == null)
			throw new TypingError("Invalid -main : " + Context.sTypePath(path) + " does not have static function main", errPos);
		var ft = TypeFunctions.fieldType(f);
		var fmode:TFieldAccess;
		var r:T;
		switch (TypeFunctions.follow(ft)) {
			case TFun({args: [], ret: ret}):
				fmode = FStatic(c, f);
				r = ret;
			case _:
				throw new TypingError("Invalid -main : " + Context.sTypePath(path) + " has invalid main function", c.pos);
		}
		// A ret still open because the body typing aborted stays quiet: the body's error is fatal and
		// already reported.
		if (!isVoid(TypeFunctions.follow(r)) && !(ctx.hasError() && TypeFunctions.follow(r).match(TMono(_))))
			throw new TypingError("Return type of main function should be Void (found " + hxc.core.TPrinting.sTypeStr(r) + ")", f.namePos);
		// Keep main against DCE.
		f.meta = [{name: ":keep", params: [], pos: Globals.mkZeroRangePos(f.pos)}].concat(f.meta);
		var emain = TexprTools.makeTypeExpr(TClassDecl(c), Position.nullPos);
		var main = TypeFunctions.mk(TCall(TypeFunctions.mk(TField(emain, fmode), ft, Position.nullPos), []), r, Position.nullPos);
		function callStatic(path:Path, methodName:String):Null<TExpr> {
			var et:Null<ModuleType> = null;
			for (t in types) {
				var tp = TypeFunctions.tPath(t);
				if (tp.name == path.name && tp.pack.join(".") == path.pack.join(".")) { et = t; break; }
			}
			if (et == null) return null;
			var ec = switch (et) {
				case TClassDecl(c): c;
				case _: throw new TypingError("Invalid entry-point type " + Context.sTypePath(path), Position.nullPos);
			};
			var ef = ec.statics.get(methodName);
			if (ef == null) return null;
			var ete = TypeFunctions.mk(TTypeExpr(et), TypeFunctions.mkAnon(new hxc.core.Ref(Statics(ec))), Position.nullPos);
			return TypeFunctions.mk(TCall(TypeFunctions.mk(TField(ete, FStatic(ec, ef)), ef.type, Position.nullPos), []), ctx.basic.tvoid, Position.nullPos);
		}
		// Threaded targets run event loops per thread; others get haxe.EntryPoint.run()
		var tail = if (ctx.platformConfig.supportsThreads)
			callStatic({pack: ["sys", "thread", "_Thread"], name: "Thread_Impl_"}, "processEvents");
		else
			callStatic({pack: ["haxe"], name: "EntryPoint"}, "run");
		return tail == null ? main : TypeFunctions.mk(TBlock([main, tail]), ctx.basic.tvoid, p);
	}

	static function isVoid(t:T):Bool {
		return switch (t) {
			case TAbstract(a, []): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		};
	}

	static inline var NOT_YET = 0;
	static inline var GENERATING = 1;
	static inline var DONE = 2;

	// Types ordered by static-initialization dependency, modules sorted by path.
	public static function sortTypes(ctx:Context):{types:Array<ModuleType>, modules:Array<ModuleDef>} {
		var types:Array<ModuleType> = [];
		var states = new StringMap<Int>();
		function state(p:Path):Int {
			var s = states.get(Context.pathKey(p));
			return s == null ? NOT_YET : s;
		}
		var statics = new StringMap<Bool>();
		var sortDbg = ctx.defines.rawDefined("sort_debug");
		var sortStack:Array<String> = [];

		var loop:ModuleType->Void = null;

		function loopClass(p:Path, c:TClass):Void {
			if (!pathEq(c.path, p)) loop(TClassDecl(c));
		}
		function loopEnum(p:Path, e:TEnum):Void {
			if (!pathEq(e.path, p)) loop(TEnumDecl(e));
		}
		function loopAbstract(p:Path, a:TAbstract):Void {
			if (!pathEq(a.path, p)) loop(TAbstractDecl(a));
		}

		var walkExpr:(Path, TExpr)->Void = null;

		function walkStaticField(p:Path, c:TClass, cf:TClassField):Void {
			if (cf.expr == null) return;
			var key = Context.pathKey(c.path) + "#" + cf.name;
			if (statics.exists(key)) return;
			statics.set(key, true);
			walkExpr(p, cf.expr);
		}

		walkExpr = function(p:Path, e:TExpr):Void {
			switch (e.expr) {
				case TTypeExpr(t):
					switch (t) {
						case TClassDecl(c): loopClass(p, c);
						case TEnumDecl(en): loopEnum(p, en);
						case TAbstractDecl(a):
							// A static access on an abstract that has an implementation depends on that impl class. hxc
							// keeps the abstract in the type expression (the `A.new` and @:forward.new arms in Typer
							// match on it), so follow through to the impl here: otherwise the impl is never reached as a
							// dependency and falls through to the top-level types sweep.
							if (a.impl != null) loopClass(p, a.impl);
							loopAbstract(p, a);
						case TTypeDecl(_): throw new TypingError("Unexpected typedef in typed AST", e.pos);
					}
				case TNew(c, _, _):
					TexprTools.iter(function(e1) walkExpr(p, e1), e);
					loopClass(p, c);
					var cur = c;
					while (cur != null) {
						var key = Context.pathKey(cur.path) + "#new";
						if (statics.exists(key)) break;
						statics.set(key, true);
						if (cur.constructor != null && cur.constructor.expr != null)
							walkExpr(p, cur.constructor.expr);
						cur = cur.superClass == null ? null : cur.superClass.c;
					}
				case TField(e1, FStatic(c, cf)):
					walkExpr(p, e1);
					walkStaticField(p, c, cf);
				case _:
					TexprTools.iter(function(e1) walkExpr(p, e1), e);
			}
		}

		function walkClass(p:Path, c:TClass):Void {
			if (c.superClass != null) loopClass(p, c.superClass.c);
			for (i in c.interfaces) loopClass(p, i.c);
			// The init's dependencies (js Std.__init__ touching String.prototype pulls String ahead of
			// Std).
			if (c.init != null) walkExpr(p, c.init);
			// Statics are visited in ascending name order.
			var names = hxc.core.MapKeys.ofString(c.statics);
			hxc.core.StringSort.sort(names);
			for (n in names) {
				var f = c.statics.get(n);
				if (f.expr == null) continue;
				switch (f.expr.expr) {
					case TFunction(_):
					case _: walkExpr(p, f.expr);
				}
			}
		}

		loop = function(t:ModuleType):Void {
			var p = TypeFunctions.tPath(t);
			switch (state(p)) {
				case DONE:
				case GENERATING:
					ctx.warning(WStaticInitOrder, [], "Warning : maybe loop in static generation of " + Context.sTypePath(p), TypeFunctions.tInfos(t).pos);
				case _:
					if (sortDbg) {
						var par = sortStack.length > 0 ? sortStack[sortStack.length - 1] : "ROOT";
						Sys.println("[SORT] " + StringTools.lpad("", " ", sortStack.length * 2) + Context.sTypePath(p) + "  <- " + par);
					}
					if (sortDbg) sortStack.push(Context.sTypePath(p));
					states.set(Context.pathKey(p), GENERATING);
					switch (t) {
						case TClassDecl(c): walkClass(p, c);
						case TEnumDecl(_) | TTypeDecl(_) | TAbstractDecl(_):
					}
					states.set(Context.pathKey(p), DONE);
					if (sortDbg) sortStack.pop();
					types.unshift(t);
			}
		}

		var sortedModules = [for (m in ctx.moduleLut) m];
		sortedModules.sort(function(m1, m2) return comparePath(m1.path, m2.path));
		for (m in sortedModules)
			for (t in m.types) loop(t);
		types.reverse();
		return {types: types, modules: sortedModules};
	}

	static function pathEq(a:Path, b:Path):Bool {
		if (a.name != b.name || a.pack.length != b.pack.length) return false;
		for (i in 0...a.pack.length) if (a.pack[i] != b.pack[i]) return false;
		return true;
	}

	// Paths compare as (pack, name): the pack lists lexicographically (a prefix sorts first),
	// then the name.
	public static function comparePath(a:Path, b:Path):Int {
		var n = a.pack.length < b.pack.length ? a.pack.length : b.pack.length;
		for (i in 0...n) {
			var c = hxc.core.StringSort.compare(a.pack[i], b.pack[i]);
			if (c != 0) return c;
		}
		if (a.pack.length != b.pack.length) return a.pack.length - b.pack.length;
		return hxc.core.StringSort.compare(a.name, b.name);
	}

	// Fix com.main, com.types and com.modules for the filters and the generator.
	public static function run(ctx:Context):Void {
		var r = sortTypes(ctx);
		ctx.main = getMain(ctx, r.types);
		ctx.types = r.types;
		ctx.typesGenerated = true;
		ctx.modules = r.modules;
	}
}
