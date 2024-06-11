package hxc.optimization;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.context.Context;
import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals.Platform;
import haxe.ds.StringMap;

/**
 * Dead Code Elimination, faithful port of ` `.
 *
 * Runs after typing, before GenJS (wired in `Compiler.run`). It computes the set of REACHABLE
 * types/fields starting from a set of roots (`com.main`, `@:keep`/`@:keepSub`/ `@:expose` types &
 * fields, kept classes, extern fields) and then SWEEPS away everything unmarked so GenJS only emits
 * live code.
 *
 * Modes (`-dce no|std|full`, default for -js = std, per the reference): - DceNo : collect entry
 * points + mark, but do not sweep (types unchanged). - DceStd : sweep, but std modules are kept
 * whole (`is_std_file` / `keep_whole_*`). - DceFull : sweep everything unreachable from the roots
 * (std_dirs = []).
 *
 * The Python-only `mark_instance_field_access` body is a no-op.
 *
 * `@:keep`/`@:keepSub`/`@:expose` force-keep faithfully (`keep_metas` / `super_forces_keep`).
 */

// Metadata names (the parser stores compiler-meta as `:`-prefixed strings).
class DceMeta {
	public static inline var Keep = ":keep";
	public static inline var KeepSub = ":keepSub";
	public static inline var KeepInit = ":keepInit";
	public static inline var Expose = ":expose";
	public static inline var Used = ":used";
	public static inline var MaybeUsed = ":maybeUsed";
	public static inline var DceMetaName = ":dce";
	public static inline var CoreType = ":coreType";
	public static inline var MultiType = ":multiType";
	public static inline var Optional = ":optional";
	public static inline var DirectlyUsed = ":directlyUsed";
	public static inline var ValueUsed = ":valueUsed";
	public static inline var Accessor = ":accessor";
}

enum DceMode {
	DceNo;
	DceStd;
	DceFull;
}

// An ifFeature entry value: the class, the field, and whether it is static.
typedef DceFeatureEntry = {c:TClass, cf:TClassField, stat:Bool};

class Dce {
	var com:Context;
	var full:Bool;
	var stdDirs:Array<String>;
	var debug:Bool;
	// Extra mark tracing under -D dce_debug_marks (hxc-only debugging aid)
	var debugMarks:Bool;
	var curclass:TClass;
	// The per-pass worklist of fields to mark.
	var addedFields:Array<DceFeatureEntry>;
	var markedFields:Array<TClassField>;
	var markedMaybeFields:Array<TClassField>;
	var tStack:Array<T>;
	var tsStack:Array<T>;
	// Each feature name's deferred fields.
	var features:StringMap<Array<DceFeatureEntry>>;

	function new(com:Context, full:Bool, stdDirs:Array<String>, debug:Bool) {
		this.com = com;
		this.full = full;
		this.stdDirs = stdDirs;
		this.debug = debug;
		this.debugMarks = com.defines.rawDefined("dce_debug_marks");
		this.addedFields = [];
		this.markedFields = [];
		this.markedMaybeFields = [];
		this.tStack = [];
		this.tsStack = [];
		this.features = new StringMap();
		this.curclass = TypeFunctions.nullClass;
	}

	// Swap curclass and return the thunk that restores it.
	function pushClass(c:TClass):Void->Void {
		var old = curclass;
		curclass = c;
		return function() { curclass = old; };
	}


	static function hasMeta(m:String, ml:Metadata):Bool return TypeFunctions.hasMeta(m, ml);

	static function hasOneOf(ms:Array<String>, ml:Metadata):Bool {
		for (m in ms) if (hasMeta(m, ml)) return true;
		return false;
	}

	static function metaEntry(name:String, p:Position):MetadataEntry return {name: name, params: [], pos: p};

	static function removeMeta(name:String, ml:Metadata):Metadata {
		return [for (e in ml) if (e.name != name) e];
	}


	// Check for @:keepSub metadata, which forces @:keep on child classes
	static function superForcesKeep(c:TClass):Bool {
		if (hasMeta(DceMeta.KeepSub, c.meta)) return true;
		return switch (c.superClass) {
			case null: false;
			case s: superForcesKeep(s.c);
		}
	}

	function overridesExternField(cf:TClassField, c:TClass):Bool {
		function isExtern(c:TClass, cf:TClassField):Bool {
			return TypeFunctions.hasClassFlag(c, CExtern) && cf.expr == null;
		}
		function loop(c:TClass, cf:TClassField):Bool {
			return switch (c.superClass) {
				case null: false;
				case s:
					var csup = s.c;
					if (csup.fields.exists(cf.name)) {
						var cf2 = csup.fields.get(cf.name);
						if (isExtern(csup, cf2)) true else loop(csup, cf2);
					} else {
						false;
					}
			}
		}
		return loop(c, cf);
	}

	function isStdFile(file:String):Bool {
		if (file == null) return false;
		var nf = StringTools.replace(file, "\\", "/");
		for (pfx in stdDirs) {
			var np = StringTools.replace(pfx, "\\", "/");
			if (StringTools.startsWith(nf, np)) return true;
		}
		return false;
	}

	static var keepMetas:Array<String> = [":keep", ":expose"];

	// Check if a class is kept entirely (keep_whole_class). Platform = Js specialized.
	function keepWholeClass(c:TClass):Bool {
		if (hasOneOf(keepMetas, c.meta)) return true;
		// Kept whole unless DCE is full, the class comes from a std file, or it has @:dce.
		var fileStd = isStdFile(c.module.extra.file);
		if (!(full || fileStd || hasMeta(DceMeta.DceMetaName, c.meta))) return true;
		if (superForcesKeep(c)) return true;
		var pack:Array<String> = c.path.pack;
		var n:String = c.path.name;
		var topLevel:Bool = pack.length == 0;
		// Platform = Js: Math/Array (top-level) -> false (do not keep whole)
		if (topLevel && (n == "Math" || n == "Array")) return false;
		// flash._Boot.RealBoot -> true (irrelevant on Js, kept for fidelity)
		if (pack.length == 1 && pack[0] == "flash" && n == "RealBoot") return true;
		if (TypeFunctions.hasClassFlag(c, CExtern)) return true;
		// String/Array (top-level): not (platform = Js) => false on Js
		if (topLevel && (n == "String" || n == "Array")) return false;
		return false;
	}

	function keepWholeEnum(en:TEnum):Bool {
		if (hasOneOf(keepMetas, en.meta)) return true;
		if (!(full || isStdFile(en.module.extra.file) || hasMeta(DceMeta.DceMetaName, en.meta))) return true;
		return false;
	}

	function mkUsedMeta(p:Position):MetadataEntry return metaEntry(DceMeta.Used, p);

	function mkKeepMeta(p:Position):MetadataEntry return metaEntry(DceMeta.Keep, p);

	// Is a field kept? (DCE entry-point check + sweep filter predicate).
	function keepField(cf:TClassField, c:TClass, isStatic:Bool):Bool {
		if (hasOneOf([DceMeta.Used].concat(keepMetas), cf.meta)) return true;
		if (cf.name == "__init__") return true;
		if (TypeFunctions.hasClassFieldFlag(cf, CfExtern)) return true;
		if (!isStatic && overridesExternField(cf, c)) return true;
		// `new` kept if the parent class kept its constructor
		if (cf.name == "new") {
			switch (c.superClass) {
				case s if (s != null && s.c.constructor != null):
					if (keepField(s.c.constructor, s.c, false)) return true;
				case _:
			}
		}
		// Accessor-of-a-kept-property
		function checkAccessor(prefix:String):Bool {
			var fields = isStatic ? c.statics : c.fields;
			var name = prefix + cf.name;
			if (!fields.exists(name)) return false;
			return keepField(fields.get(name), c, isStatic);
		}
		return switch (cf.kind) {
			case Var(vk) if (switch (vk.read) { case AccCall: true; case _: false; }): checkAccessor("get_");
			case Var(vk) if (switch (vk.write) { case AccCall: true; case _: false; }): checkAccessor("set_");
			case _: false;
		};
	}


	// If a registered feature `s` exists, mark its deferred fields.
	function checkFeature(s:String):Void {
		if (features.exists(s)) {
			var l = features.get(s);
			for (e in l) markField(e.c, e.cf, e.stat);
			features.remove(s);
		}
	}

	function checkAndAddFeature(s:String):Void {
		checkFeature(s);
		// Curclass is always a real class here.
		curclass.module.extra.features.set(s, true);
	}

	// Mark a field as kept.
	function markField(c:TClass, cf:TClassField, stat:Bool):Void {
		function add(cf:TClassField):Void {
			if (!hasMeta(DceMeta.Used, cf.meta)) {
				if (debugMarks) Sys.println("[DCE] Marked field " + Context.sTypePath(c.path) + "." + cf.name);
				cf.meta = ([mkUsedMeta(cf.pos)] : Metadata).concat(cf.meta);
				addedFields.unshift({c: c, cf: cf, stat: stat});
				markedFields.unshift(cf);
				checkFeature(Context.sTypePath(c.path) + "." + cf.name);
			}
		}
		if (cf.name == "new") {
			function loop(c:TClass):Void {
				switch (c.constructor) {
					case null:
					case ctor: add(ctor);
				}
				switch (c.superClass) {
					case null:
					case s: loop(s.c);
				}
			}
			loop(c);
		} else {
			var tbl = stat ? c.statics : c.fields;
			if (!tbl.exists(cf.name)) {
				switch (c.superClass) {
					case null: add(cf);
					case s: markField(s.c, cf, stat);
				}
			} else {
				add(cf);
			}
			if (!stat && TypeFunctions.isPhysicalField(cf)) {
				switch (c.constructor) {
					case null:
					case ctor: markField(c, ctor, false);
				}
			}
		}
	}

	function updateMarkedClassFields(c:TClass):Void {
		var pop = pushClass(c);
		// Mark all :?used fields as surely :used now
		for (cf in c.orderedStatics) if (hasMeta(DceMeta.MaybeUsed, cf.meta)) markField(c, cf, true);
		for (cf in c.orderedFields) if (hasMeta(DceMeta.MaybeUsed, cf.meta)) markField(c, cf, false);
		// We always have to keep super classes and implemented interfaces
		switch (c.init) { case null: case init: expr(init); }
		var initCf = c.statics.get("__init__");
		if (initCf != null) markField(c, initCf, true);
		for (i in c.interfaces) markClass(i.c);
		switch (c.superClass) { case null: case s: markClass(s.c); }
		pop();
	}

	// Mark a class as kept. If the class has fields marked as @:?keep, make sure to keep them.
	function markClass(c:TClass):Void {
		if (!hasMeta(DceMeta.Used, c.meta)) {
			if (debugMarks) Sys.println("[DCE] Marked class " + Context.sTypePath(c.path) + " while processing " + (curclass == null ? "?" : Context.sTypePath(curclass.path)));
			c.meta = ([mkUsedMeta(c.pos)] : Metadata).concat(c.meta);
			checkFeature(Context.sTypePath(c.path) + ".*");
			updateMarkedClassFields(c);
		}
	}

	function markEnum(e:TEnum):Void {
		if (!hasMeta(DceMeta.Used, e.meta)) {
			e.meta = ([mkUsedMeta(e.pos)] : Metadata).concat(e.meta);
			checkAndAddFeature("has_enum");
			checkFeature(Context.sTypePath(e.path) + ".*");
			for (n in e.constrs.keys()) {
				var ef = e.constrs.get(n);
				markT(ef.pos, ef.type);
			}
		}
	}

	function markAbstract(a:TAbstract):Void {
		if (!hasMeta(DceMeta.Used, a.meta)) {
			checkFeature(Context.sTypePath(a.path) + ".*");
			a.meta = ([mkUsedMeta(a.pos)] : Metadata).concat(a.meta);
		}
	}

	// Abstract.get_underlying_type a pl == apply_params a.params pl a.thisType (subset).
	static function getUnderlyingType(a:TAbstract, pl:TParams):T {
		return TypeFunctions.applyParams(a.params, pl, a.thisType);
	}

	// Mark a type as kept.
	function markT(p:Position, t:T):Void {
		var seen = false;
		for (t2 in tStack) if (TypeUnification.fastEq(t, t2)) { seen = true; break; }
		if (seen) return;
		tStack.unshift(t);
		switch (TypeFunctions.follow(t)) {
			case TInst(c, pl) if (switch (c.kind) { case KTypeParameter(_): true; case _: false; }):
				var tl = switch (c.kind) { case KTypeParameter(tl): tl; case _: []; };
				if (!hasMeta(DceMeta.Used, c.meta)) {
					c.meta = ([mkUsedMeta(c.pos)] : Metadata).concat(c.meta);
					for (tt in tl) markT(p, tt);
				}
				for (pp in pl) markT(p, pp);
			case TInst(c, pl):
				markClass(c);
				for (pp in pl) markT(p, pp);
			case TFun(sig):
				for (a in sig.args) markT(p, a.t);
				markT(p, sig.ret);
			case TEnum(e, pl):
				markEnum(e);
				for (pp in pl) markT(p, pp);
			case TAbstract(a, pl) if (hasMeta(DceMeta.MultiType, a.meta)):
				// Hxc does not populate the multitype specialization table, so the @:to specialization cannot
				// be resolved. The failure is swallowed here; follow the underlying defensively (the concrete
				// map type the typer already lowered to is reached via the exprs).
			case TAbstract(a, pl):
				markAbstract(a);
				for (pp in pl) markT(p, pp);
				if (!hasMeta(DceMeta.CoreType, a.meta)) markT(p, getUnderlyingType(a, pl));
			case TLazy(_) | TDynamic(_) | TType(_, _) | TAnon(_) | TMono(_):
		}
		tStack.shift();
	}

	function markMt(mt:ModuleType):Void {
		switch (mt) {
			case TClassDecl(c): markClass(c);
			case TEnumDecl(e): markEnum(e);
			case TAbstractDecl(a):
				// Abstract 'feature' = abstract used as a value (not as a type)
				if (!hasMeta(DceMeta.ValueUsed, a.meta))
					a.meta = ([metaEntry(DceMeta.ValueUsed, a.pos)] : Metadata).concat(a.meta);
				markAbstract(a);
			case TTypeDecl(_):
		}
	}

	// Find all dependent fields by checking implementing/subclassing types.
	function markDependentFields(csup:TClass, n:String, stat:Bool):Void {
		function loop(c:TClass):Void {
			var tbl = stat ? c.statics : c.fields;
			if (tbl.exists(n)) {
				var cf = tbl.get(n);
				// If the class is clearly kept, the field is kept too (also true for extern interfaces: cannot
				// remove their fields).
				if (hasMeta(DceMeta.Used, c.meta)
					|| (TypeFunctions.hasClassFlag(csup, CInterface) && TypeFunctions.hasClassFlag(csup, CExtern))) {
					markField(c, cf, stat);
				} else if (!hasMeta(DceMeta.MaybeUsed, cf.meta)) {
					cf.meta = ([metaEntry(DceMeta.MaybeUsed, cf.pos)] : Metadata).concat(cf.meta);
					markedMaybeFields.unshift(cf);
				}
			} else {
				// Not on current class, might come from a base class
				switch (c.superClass) { case null: case s: loop(s.c); }
			}
		}
		function loopInheritance(c:TClass):Void {
			loop(c);
			for (d in c.descendants) loopInheritance(d);
		}
		loopInheritance(csup);
	}


	static inline function optE(f:TExpr->Void, e:Null<TExpr>):Void if (e != null) f(e);

	function toString(t:T):Void {
		switch (t) {
			case TInst(c, _):
				field(c, "toString", false);
			case TType(tt, tl):
				var seen = false;
				for (t2 in tsStack) if (TypeUnification.fastEq(t, t2)) { seen = true; break; }
				if (!seen) {
					tsStack.unshift(t);
					toString(TypeFunctions.applyTypedef(tt, tl));
				}
			case TAbstract(a, tl) if (a.impl != null):
				if (hasMeta(DceMeta.CoreType, a.meta)) field(a.impl, "toString", false);
				else toString(getUnderlyingType(a, tl));
			case TMono(r):
				switch (r.type) { case null: case t2: toString(t2); }
			case TLazy(f):
				toString(TypeFunctions.lazyType(f));
			case TDynamic(t2) if (t2 != null):
				toString(t2);
			case _:
				// TEnum / TFun / TAnon / TAbstract(no impl) / TDynamic(None): toString does not
				// imply we need all the sub-types.
		}
	}

	// Find field `n` on `c` (own/super/interface/type-param) and mark it; a miss is a sentinel throw
	// caught locally.
	function field(c:TClass, n:String, stat:Bool):Void {
		try {
			markField(c, fieldFind(c, n, stat), stat);
		} catch (_:DceNotFound) {
			try {
				if (TypeFunctions.hasClassFlag(c, CInterface)) {
					var found = false;
					for (i in c.interfaces) {
						try { field(i.c, n, stat); found = true; break; }
						catch (_:DceNotFound) {}
					}
					if (!found) throw new DceNotFound();
				} else {
					switch (c.superClass) {
						case null: throw new DceNotFound();
						case s: field(s.c, n, stat);
					}
				}
			} catch (_:DceNotFound) {
				try {
					switch (c.kind) {
						case KTypeParameter(tl):
							var found = false;
							for (t in tl) switch (t) {
								case TInst(c2, _):
									try { field(c2, n, stat); found = true; break; }
									catch (_:DceNotFound) {}
								case _:
							}
							if (!found) throw new DceNotFound();
						case _: throw new DceNotFound();
					}
				} catch (_:DceNotFound) {
					if (debug) com.print("[DCE] Field " + n + " not found on " + Context.sTypePath(c.path) + "\n");
				}
			}
		}
	}

	// Find field `n` on the class itself; throws DceNotFound on a miss.
	static function fieldFind(c:TClass, n:String, stat:Bool):TClassField {
		if (n == "new") {
			return switch (c.constructor) { case null: throw new DceNotFound(); case cf: cf; };
		}
		var tbl = stat ? c.statics : c.fields;
		if (!tbl.exists(n)) throw new DceNotFound();
		return tbl.get(n);
	}

	function markDirectlyUsedClass(c:TClass):Void {
		if (c != curclass && !hasMeta(DceMeta.DirectlyUsed, c.meta))
			c.meta = ([metaEntry(DceMeta.DirectlyUsed, c.pos)] : Metadata).concat(c.meta);
	}

	function markDirectlyUsedEnum(e:TEnum):Void {
		if (!hasMeta(DceMeta.DirectlyUsed, e.meta))
			e.meta = ([metaEntry(DceMeta.DirectlyUsed, e.pos)] : Metadata).concat(e.meta);
	}

	function markDirectlyUsedMt(mt:ModuleType):Void {
		switch (mt) {
			case TClassDecl(c): markDirectlyUsedClass(c);
			case TEnumDecl(e): markDirectlyUsedEnum(e);
			case _:
		}
	}

	function markDirectlyUsedT(p:Position, t:T):Void {
		switch (TypeFunctions.follow(t)) {
			case TInst(c, pl) if (switch (c.kind) { case KNormal: true; case _: false; }):
				markDirectlyUsedClass(c);
				for (pp in pl) markDirectlyUsedT(p, pp);
			case TEnum(e, pl):
				markDirectlyUsedEnum(e);
				for (pp in pl) markDirectlyUsedT(p, pp);
			case TAbstract(a, pl) if (hasMeta(DceMeta.MultiType, a.meta)):
				// Multitype specialization unavailable in hxc (see markT), skip.
			case TAbstract(a, pl):
				for (pp in pl) markDirectlyUsedT(p, pp);
				if (!hasMeta(DceMeta.CoreType, a.meta)) markDirectlyUsedT(p, getUnderlyingType(a, pl));
			case _:
		}
	}

	function checkDynamicWrite(fa:TFieldAccess):Void {
		var n = TypeFunctions.fieldName(fa);
		checkAndAddFeature("dynamic_write");
		checkAndAddFeature("dynamic_write." + n);
	}

	function checkAnonOptionalWrite(fa:TFieldAccess):Void {
		var n = TypeFunctions.fieldName(fa);
		checkAndAddFeature("anon_optional_write");
		checkAndAddFeature("anon_optional_write." + n);
	}

	function checkAnonWrite(fa:TFieldAccess):Void {
		var n = TypeFunctions.fieldName(fa);
		checkAndAddFeature("anon_write");
		checkAndAddFeature("anon_write." + n);
	}

	function isArray(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, tl) if (!hasMeta(DceMeta.CoreType, a.meta)): isArray(getUnderlyingType(a, tl));
			case TInst(c, _) if (c.path.pack.length == 0 && c.path.name == "Array"): true;
			case _: false;
		}
	}

	function isDynamic(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, tl) if (!hasMeta(DceMeta.CoreType, a.meta)): isDynamic(getUnderlyingType(a, tl));
			case TDynamic(_): true;
			case _: false;
		}
	}

	function isString(t:T):Bool {
		return switch (TypeFunctions.follow(t)) {
			case TAbstract(a, tl) if (!hasMeta(DceMeta.CoreType, a.meta)): isString(getUnderlyingType(a, tl));
			case TInst(c, _) if (c.path.pack.length == 0 && c.path.name == "String"): true;
			case _: false;
		}
	}

	static function isConstString(e:TExpr):Bool {
		return switch (e.expr) { case TConst(TString(_)): true; case _: false; };
	}

	static function isTypeParam(t:T):Bool {
		return switch (t) {
			case TInst(c, _): switch (c.kind) { case KTypeParameter(_): true; case _: false; };
			case _: false;
		}
	}

	function exprField(e:TExpr, fa:TFieldAccess, isCallExpr:Bool):Void {
		function doDefault():Void {
			var n = TypeFunctions.fieldName(fa);
			switch (fa) {
				case FAnon(cf):
					if (hasMeta(DceMeta.Optional, cf.meta)) {
						checkAndAddFeature("anon_optional_read");
						checkAndAddFeature("anon_optional_read." + n);
					} else {
						checkAndAddFeature("anon_read");
						checkAndAddFeature("anon_read." + n);
					}
				case FDynamic(_):
					checkAndAddFeature("dynamic_read");
					checkAndAddFeature("dynamic_read." + n);
				case FClosure(_, _):
					checkAndAddFeature("closure_read");
					checkAndAddFeature("closure_read." + n);
				case _:
			}
			switch [TypeFunctions.follow(e.type), fa] {
				case [TInst(c, _), _]:
					markClass(c);
					field(c, n, false);
				case [_, FClosure(co, _)] if (co != null):
					markClass(co.c);
					field(co.c, n, false);
				case [TAnon(a), _]:
					switch (a.status.get()) {
						case Statics(c):
							markClass(c);
							field(c, n, true);
						case _:
					}
				case _:
			}
		}
		switch (fa) {
			case FStatic(c, cf):
				markClass(c);
				markField(c, cf, true);
			case FInstance(c, _, cf):
				markClass(c);
				markField(c, cf, false);
			case FClosure(co, cf) if (co != null):
				// Marking a closure's instance field access only matters for Python; nothing to do on Js.
				doDefault();
			case FClosure(_, _):
				doDefault();
			case _:
				doDefault();
		}
		expr(e);
	}

	function checkOp(op:Binop):Void {
		switch (op) {
			case OpMod: checkAndAddFeature("binop_%");
			case OpUShr: checkAndAddFeature("binop_>>>");
			case OpAssignOp(op2): checkOp(op2);
			case _:
		}
	}

	function expr(e:TExpr):Void {
		markT(e.pos, e.type);
		switch (e.expr) {
			case TNew(c, pl, el):
				markClass(c);
				markDirectlyUsedClass(c);
				field(c, "new", false);
				for (x in el) expr(x);
				for (pp in pl) markT(e.pos, pp);
			case TVarExpr(v, e1):
				optE(expr, e1);
				markT(e.pos, v.type);
			case TCast(e1, mt) if (mt != null):
				checkFeature("typed_cast");
				markMt(mt);
				markDirectlyUsedMt(mt);
				expr(e1);
			case TObjectDecl(vl):
				checkAndAddFeature("has_anon");
				for (of in vl) expr(of.expr);
			case TTypeExpr(mt):
				markMt(mt);
				markDirectlyUsedMt(mt);
			case TTry(e1, vl):
				expr(e1);
				for (cv in vl) {
					if (cv.v.type != TypeFunctions.tDynamic) {
						checkFeature("typed_catch");
						markDirectlyUsedT(cv.v.pos, cv.v.type);
					}
					expr(cv.expr);
					markT(cv.expr.pos, cv.v.type);
				}
			// The magic `trace call keeps its infos object fields alive
			case TCall({expr: TIdent("`trace")}, [p, {expr: TObjectDecl(v)}]):
				checkAndAddFeature("has_anon_trace");
				for (of in v) expr(of.expr);
				expr(p);
			case TCall({expr: TIdent("__define_feature__")}, [{expr: TConst(TString(ft))}, e1]):
				curclass.module.extra.features.set(ft, true);
				checkFeature(ft);
				expr(e1);
			// Keep toString method of T when array<T>.join() is called
			case TCall(ef, args) if (isArrayJoinCall(ef)):
				var pl = arrayJoinParams(ef);
				for (t in pl) toString(t);
				expr(ef);
				for (x in args) expr(x);
			// Keep toString method when the class is argument to Std.string or haxe.Log.trace
			case TCall(ef, args) if (args.length >= 1 && isStringOrTraceCall(ef)):
				var c = stringOrTraceClass(ef);
				if (c != null) markClass(c);
				toString(args[0].type);
				if (args.length == 2) switch (args[1].expr) {
					case TObjectDecl(fl):
						for (of in fl) if (of.key.name == "customParams") switch (of.expr.expr) {
							case TArrayDecl(el): for (x in el) toString(x.type);
							case _:
						}
					case _:
				}
				expr(ef);
				for (x in args) expr(x);
			case TCall(e1, el) if (switch (e1.expr) { case TConst(TSuper): true; case _: false; }):
				markT(e1.pos, e1.type);
				for (x in el) expr(x);
			case TUnop(op, _, e1) if ((op == Increment || op == Decrement) && isTArray(e1)):
				checkAndAddFeature("array_write");
				checkAndAddFeature("array_read");
				expr(e1);
			case TBinop(op, e1, e2) if ((op == OpAdd || isAssignOpAdd(op)) && (isDynamic(e1.type) || isDynamic(e2.type))):
				checkAndAddFeature("add_dynamic");
				expr(e1);
				expr(e2);
			case TBinop(op, e1, e2) if ((op == OpAdd || isAssignOpAdd(op)) && (isString(e1.type) || isString(e2.type)) && !(isConstString(e1) && isConstString(e2))):
				// array_write if += to an array element (this pattern precedes array_write)
				switch [op, e1.expr] {
					case [OpAssignOp(_), TArray(ae, _)] if (isArray(ae.type)): checkAndAddFeature("array_write");
					case _:
				}
				checkAndAddFeature("unsafe_string_concat");
				expr(e1);
				expr(e2);
			case TArray(e1, e2) if (isTDynamicNone(e1)):
				checkAndAddFeature("dynamic_array_read");
				expr(e1);
				expr(e2);
			case TBinop(OpAssign, e1, e2) if (isTArrayDynamicNone(e1)):
				checkAndAddFeature("dynamic_array_write");
				expr(e1);
				expr(e2);
			case TBinop(OpAssignOp(op), e1, e2) if (isTArrayDynamicNone(e1)):
				checkOp(op);
				checkAndAddFeature("dynamic_array_write");
				expr(e1);
				expr(e2);
			case TArray(e1, e2) if (isArray(e1.type)):
				checkAndAddFeature("array_read");
				expr(e1);
				expr(e2);
			case TBinop(op, e1, e2) if ((op == OpAssign || isAssignOp(op)) && isTArrayOfArray(e1)):
				checkAndAddFeature("array_write");
				expr(e1);
				expr(e2);
			case TBinop(OpAssign, e1, e2) if (isFieldDynamic(e1)):
				checkDynamicWrite(fieldOf(e1));
				expr(e1);
				expr(e2);
			case TBinop(OpAssign, e1, e2) if (isFieldAnon(e1)):
				var fa = fieldOf(e1);
				if (anonFieldOptional(fa)) checkAnonOptionalWrite(fa) else checkAnonWrite(fa);
				expr(e1);
				expr(e2);
			case TBinop(OpAssignOp(op), e1, e2) if (isFieldDynamic(e1)):
				checkOp(op);
				checkDynamicWrite(fieldOf(e1));
				expr(e1);
				expr(e2);
			case TBinop(OpAssignOp(op), e1, e2) if (isFieldAnon(e1)):
				checkOp(op);
				var fa = fieldOf(e1);
				if (anonFieldOptional(fa)) checkAnonOptionalWrite(fa) else checkAnonWrite(fa);
				expr(e1);
				expr(e2);
			case TBinop(OpEq, e1, e2) if (isDynamic(e1.type) || isDynamic(e2.type)):
				checkAndAddFeature("dynamic_binop_==");
				expr(e1);
				expr(e2);
			case TBinop(OpEq, e1, e2) if (isTypeParam(TypeFunctions.follow(e1.type)) || isTypeParam(TypeFunctions.follow(e2.type))):
				checkAndAddFeature("type_param_binop_==");
				expr(e1);
				expr(e2);
			case TBinop(OpNotEq, e1, e2) if (isDynamic(e1.type) || isDynamic(e2.type)):
				checkAndAddFeature("dynamic_binop_!=");
				expr(e1);
				expr(e2);
			case TBinop(OpNotEq, e1, e2) if (isTypeParam(TypeFunctions.follow(e1.type)) || isTypeParam(TypeFunctions.follow(e2.type))):
				checkAndAddFeature("type_param_binop_!=");
				expr(e1);
				expr(e2);
			case TBinop(op, e1, e2):
				checkOp(op);
				expr(e1);
				expr(e2);
			case TCall(e2, el) if (switch (e2.expr) { case TField(_, _): true; case _: false; }):
				markT(e2.pos, e2.type);
				switch (e2.expr) { case TField(ef, fa): exprField(ef, fa, true); case _: }
				for (x in el) expr(x);
			case TField(e1, fa):
				exprField(e1, fa, false);
			case TThrow(e1):
				checkAndAddFeature("has_throw");
				expr(e1);
				function loop(e:TExpr):Void {
					toString(e.type);
					iterTExpr(e, loop);
				}
				loop(e1);
			case TFor(_, e1, e2):
				// Hxc keeps the generic `TFor` and synthesizes the iterator protocol at GenJS time (genFor),
				// after DCE, so the protocol methods (`it.hasNext()`/`it.next()`, and
				// `it.iterator()` for an Iterable) are invisible to the plain `iterTExpr` walk and would be
				// swept. Mark them here, exactly as genFor will emit them (Array + IntIterator-range use a
				// counter `while` loop with no protocol calls, so they're skipped). Without this a `for (c in
				// StringIteratorUnicode.unicodeIterator(s))` emits a `hasNext`/`next`-less iterator shell ->
				// `$it.hasNext is not a function`.
				markForIterator(e1);
				expr(e1);
				expr(e2);
			case _:
				iterTExpr(e, expr);
		}
	}

	// Mark the iterator-protocol fields GenJS's `genFor` will synthesize for a `for (x in it)` whose
	// iterator expression is `it`. Mirrors `Typer.markIteratorProtocolReached` + the genFor lowering
	// decisions: Array + IntIterator-range use a counter `while` loop (no protocol), everything else
	// uses `it.hasNext()`/`it.next()` (and `it.iterator()` first if
	// `it` is an ITERABLE rather than an ITERATOR). The iterator's class is taken from the expr
	// SHAPE (`new C()` / `C.factory(...)`), an inline factory's return is often an unbound mono ,
	// falling back to the static type.
	function markForIterator(e1:TExpr):Void {
		// IntIterator literal range -> genFor counter loop, no protocol.
		switch (e1.expr) {
			case TNew(c, _, _) if (c.path.pack.length == 0 && c.path.name == "IntIterator"): return;
			case _:
		}
		// Array -> genFor indexed loop, no protocol.
		if (isArray(e1.type)) return;
		switch (TypeFunctions.follow(e1.type)) {
			case TInst(c, _) if (c.path.pack.length == 0 && c.path.name == "IntIterator"): return;
			case _:
		}
		// Resolve the iterator class from the expression shape, then the static type.
		var itc:Null<TClass> = null;
		switch (e1.expr) {
			case TNew(c, _, _): itc = c;
			case TCall({expr: TField(_, FStatic(c, _))}, _): itc = c;
			case _:
		}
		if (itc == null) {
			itc = switch (TypeFunctions.follow(e1.type)) {
				case TInst(c, _): c;
				case _: null;
			};
		}
		if (itc == null) return;
		// If the source is an ITERABLE (has `iterator` but not `hasNext`), genFor calls
		// `.iterator()` first to obtain the iterator. Keep `iterator` then mark the protocol on
		// the same class (its `iterator()` returns the iterator; whichever class carries
		// hasNext/next, the super-walking `field` resolves it).
		var hasHasNext = classHasField(itc, "hasNext");
		var hasIterator = classHasField(itc, "iterator");
		if (!hasHasNext && hasIterator) {
			field(itc, "iterator", false);
		}
		field(itc, "new", false);
		field(itc, "hasNext", false);
		field(itc, "next", false);
	}

	// Does `c` (or a super) declare instance field `name`?
	static function classHasField(c:TClass, name:String):Bool {
		var cur = c;
		while (cur != null) {
			if (cur.fields.exists(name)) return true;
			cur = cur.superClass != null ? cur.superClass.c : null;
		}
		return false;
	}


	static function isAssignOp(op:Binop):Bool return switch (op) { case OpAssignOp(_): true; case _: false; };
	static function isAssignOpAdd(op:Binop):Bool return switch (op) { case OpAssignOp(OpAdd): true; case _: false; };

	static function isTArray(e:TExpr):Bool return switch (e.expr) { case TArray(_, _): true; case _: false; };

	static function isTDynamicNone(e:TExpr):Bool return switch (e.type) { case TDynamic(null): true; case _: false; };

	static function isTArrayDynamicNone(e:TExpr):Bool {
		return switch (e.expr) { case TArray(ae, _): isTDynamicNone(ae); case _: false; };
	}

	function isTArrayOfArray(e:TExpr):Bool {
		return switch (e.expr) { case TArray(ae, _): isArray(ae.type); case _: false; };
	}

	static function isFieldDynamic(e:TExpr):Bool {
		return switch (e.expr) { case TField(_, FDynamic(_)): true; case _: false; };
	}

	static function isFieldAnon(e:TExpr):Bool {
		return switch (e.expr) { case TField(_, FAnon(_)): true; case _: false; };
	}

	static function fieldOf(e:TExpr):TFieldAccess {
		return switch (e.expr) { case TField(_, fa): fa; case _: throw "not a field"; };
	}

	function anonFieldOptional(fa:TFieldAccess):Bool {
		return switch (fa) { case FAnon(cf): hasMeta(DceMeta.Optional, cf.meta); case _: false; };
	}

	// TField(_, FInstance(Array, pl, {join})) call, keep T.toString().
	static function isArrayJoinCall(ef:TExpr):Bool {
		return switch (ef.expr) {
			case TField(_, FInstance(c, _, cf)):
				c.path.pack.length == 0 && c.path.name == "Array" && cf.name == "join";
			case _: false;
		}
	}

	static function arrayJoinParams(ef:TExpr):TParams {
		return switch (ef.expr) { case TField(_, FInstance(_, pl, _)): pl; case _: []; };
	}

	// TField(TTypeExpr(Std)/{string} or haxe.Log/{trace}) call.
	static function isStringOrTraceCall(ef:TExpr):Bool {
		return stringOrTraceClass(ef) != null;
	}

	static function stringOrTraceClass(ef:TExpr):Null<TClass> {
		return switch (ef.expr) {
			case TField(te, FStatic(_, cf)):
				switch (te.expr) {
					case TTypeExpr(TClassDecl(c)):
						if (c.path.pack.length == 1 && c.path.pack[0] == "haxe" && c.path.name == "Log" && cf.name == "trace") c
						else if (c.path.pack.length == 0 && c.path.name == "Std" && cf.name == "string") c
						else null;
					case _: null;
				}
			case _: null;
		}
	}

	// Type.iter (subset) over a typed expr, faithful to TExpr iteration in the typer.
	static function iterTExpr(e:TExpr, f:TExpr->Void):Void {
		switch (e.expr) {
			case TConst(_) | TLocal(_) | TBreak | TContinue | TTypeExpr(_) | TIdent(_):
			case TArray(e1, e2) | TBinop(_, e1, e2) | TFor(_, e1, e2): f(e1); f(e2);
			case TField(e1, _) | TParenthesis(e1) | TUnop(_, _, e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1) | TThrow(e1) | TCast(e1, _) | TMeta(_, e1): f(e1);
			case TObjectDecl(fl): for (of in fl) f(of.expr);
			case TArrayDecl(el) | TBlock(el): for (x in el) f(x);
			case TCall(e1, el): f(e1); for (x in el) f(x);
			case TNew(_, _, el): for (x in el) f(x);
			case TFunction(tf): for (a in tf.args) if (a.c != null) f(a.c); f(tf.expr);
			case TVarExpr(_, e1): if (e1 != null) f(e1);
			case TIf(ec, e1, e2): f(ec); f(e1); if (e2 != null) f(e2);
			case TWhile(ec, e1, _): f(ec); f(e1);
			case TSwitch(e1, cases, edef): f(e1); for (c in cases) { for (v in c.values) f(v); f(c.expr); } if (edef != null) f(edef);
			case TTry(e1, catches): f(e1); for (c in catches) f(c.expr);
			case TReturn(e1): if (e1 != null) f(e1);
		}
	}


	function collectEntryPoints():Void {
		for (t in com.types) {
			var mt = TypeFunctions.tInfos(t);
			// Reset @:used from a previous compilation-server run (cleanup)
			switch (t) {
				case TClassDecl(c): c.meta = removeMeta(DceMeta.Used, c.meta);
				case TEnumDecl(e): e.meta = removeMeta(DceMeta.Used, e.meta);
				case TAbstractDecl(a): a.meta = removeMeta(DceMeta.Used, a.meta);
				case TTypeDecl(td): td.meta = removeMeta(DceMeta.Used, td.meta);
			}
			switch (t) {
				case TClassDecl(c):
					var keepClass = keepWholeClass(c) && (!TypeFunctions.hasClassFlag(c, CExtern) || TypeFunctions.hasClassFlag(c, CInterface));
					var pop = pushClass(c);
					function loop(stat:Bool, cf:TClassField):Void {
						if (keepClass || keepField(cf, c, stat)) markField(c, cf, stat);
					}
					// Hxc keeps static __init__ as a field; the reference moves it to init, which is only an entry
					// point for kept or @:keepInit classes
					for (cf in c.orderedStatics)
						if (cf.name != "__init__" || keepClass || hasMeta(DceMeta.KeepInit, c.meta))
							loop(true, cf);
					for (cf in c.orderedFields) loop(false, cf);
					switch (c.constructor) { case null: case cf: loop(false, cf); }
					switch (c.init) {
						case e if (e != null && (keepClass || hasMeta(DceMeta.KeepInit, c.meta))):
							// Create a fake __init__ field to deal with internal logic
							var cf = TypeFunctions.mkField("__init__", e.type, e.pos, Position.nullPos);
							cf.expr = e;
							loop(true, cf);
						case _:
					}
					pop();
				case TEnumDecl(en) if (keepWholeEnum(en)):
					// Push a fake class carrying the enum's module (curclass.module must be valid).
					var fake = TypeFunctions.mkClass(en.module, {pack: [], name: ""}, Position.nullPos, Position.nullPos);
					var pop = pushClass(fake);
					markEnum(en);
					pop();
				case _:
			}
		}
	}

	function keepCppInterfaceSlots():Void {
		// (Intentionally empty.) There is no IMap-specific rule; normal DCE keeps haxe.IMap.toString
		// whenever a map value is stringified (Std.string / trace / concat / join), which then cascades to
		// each implementor via markDependentFields. Unconditionally marking IMap.toString for cpp
		// over-keeps every map implementor's toString in programs that never stringify a map, and the cpp
		// interface dispatch works without it.
	}

	function mark():Void {
		var loop = true;
		while (loop) {
			var cfl = addedFields;
			if (cfl.length == 0) { loop = false; break; }
			addedFields = [];
			// Extend to dependent (overriding/implementing) class fields
			for (e in cfl) markDependentFields(e.c, e.cf.name, e.stat);
			// Mark fields as used
			for (e in cfl) {
				var pop = pushClass(e.c);
				if (TypeFunctions.isPhysicalField(e.cf)) markClass(e.c);
				markField(e.c, e.cf, e.stat);
				markT(e.cf.pos, e.cf.type);
				pop();
			}
			// Follow expressions to new types/fields
			for (e in cfl) {
				if (!TypeFunctions.hasClassFlag(e.c, CExtern)) {
					var pop = pushClass(e.c);
					optE(expr, e.cf.expr);
					for (ov in e.cf.overloads) if (ov.expr != null) optE(expr, ov.expr);
					pop();
				}
			}
		}
	}

	function sweep():Void {
		var acc:Array<ModuleType> = [];
		var types = com.types.copy();
		types.reverse();
		for (mt in types) {
			switch (mt) {
				case TClassDecl(c) if (keepWholeClass(c)):
					acc.unshift(mt);
				case TClassDecl(c):
					function checkProperty(cf:TClassField, stat:Bool):Void {
						function addAccessorMetadata(cf:TClassField):Void {
							if (!hasMeta(DceMeta.Accessor, cf.meta))
								cf.meta = ([metaEntry(DceMeta.Accessor, c.pos)] : Metadata).concat(cf.meta);
						}
						var tbl = stat ? c.statics : c.fields;
						switch (cf.kind) {
							case Var(vk) if (switch (vk.read) { case AccCall: true; case _: false; }):
								if (tbl.exists("get_" + cf.name)) addAccessorMetadata(tbl.get("get_" + cf.name));
							case _:
						}
						switch (cf.kind) {
							case Var(vk) if (switch (vk.write) { case AccCall: true; case _: false; }):
								if (tbl.exists("set_" + cf.name)) addAccessorMetadata(tbl.get("set_" + cf.name));
							case _:
						}
					}
					// Add :keep so subsequent filter calls do not process class fields again
					c.meta = ([mkKeepMeta(c.pos)] : Metadata).concat(c.meta);
					c.orderedStatics = filterFields(c.orderedStatics, function(cf) {
						var b = keepField(cf, c, true);
						if (!b) {
							if (debug) com.print("[DCE] Removed field " + Context.sTypePath(c.path) + "." + cf.name + "\n");
							checkProperty(cf, true);
							c.statics.remove(cf.name);
						}
						return b;
					});
					c.orderedFields = filterFields(c.orderedFields, function(cf) {
						var b = keepField(cf, c, false);
						if (!b) {
							if (debug) com.print("[DCE] Removed field " + Context.sTypePath(c.path) + "." + cf.name + "\n");
							checkProperty(cf, false);
							c.fields.remove(cf.name);
						}
						return b;
					});
					switch (c.constructor) {
						case cf if (cf != null && !keepField(cf, c, false)): c.constructor = null;
						case _:
					}
					// The __init__ static stands in for the reference's init: it does not count as a class-keeping
					// field and only survives on a kept class
					var hasNonExternFields = false;
					for (cf in c.orderedFields) if (TypeFunctions.isPhysicalField(cf)) { hasNonExternFields = true; break; }
					if (!hasNonExternFields) for (cf in c.orderedStatics) if (cf.name != "__init__" && TypeFunctions.isPhysicalField(cf)) { hasNonExternFields = true; break; }
					var hasInit = c.init != null || c.statics.exists("__init__");
					// Keep a class if it was used or has a used field
					if (hasMeta(DceMeta.Used, c.meta) || hasNonExternFields) {
						acc.unshift(mt);
					} else if (hasInit && hasMeta(DceMeta.KeepInit, c.meta)) {
						// Only the __init__ block is needed
						TypeFunctions.addClassFlag(c, CExtern);
						acc.unshift(mt);
					} else {
						if (debug) com.print("[DCE] Removed class " + Context.sTypePath(c.path) + "\n");
					}
				case TEnumDecl(en) if (hasMeta(DceMeta.Used, en.meta) || en.isExtern || keepWholeEnum(en)):
					acc.unshift(mt);
				case TEnumDecl(e):
					if (debug) com.print("[DCE] Removed enum " + Context.sTypePath(e.path) + "\n");
				case _:
					acc.unshift(mt);
			}
		}
		com.types = acc;
	}

	static function filterFields(l:Array<TClassField>, pred:TClassField->Bool):Array<TClassField> {
		return [for (cf in l) if (pred(cf)) cf];
	}

	// fixAccessors: adjust properties whose accessors were removed; flag empty abstract impls as
	// extern. Only the Js-relevant part is here: the Php/Cpp-only effects do not apply, the
	// property-kind adjustment is shared.
	function isEmptyAbstractImpl(c:TClass):Bool {
		var isAbsImpl = switch (c.kind) { case KAbstractImpl(_): true; case _: false; };
		return isAbsImpl && c.orderedStatics.length == 0 && c.orderedFields.length == 0 && !hasMeta(DceMeta.Used, c.meta);
	}

	function fixAccessors():Void {
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (isEmptyAbstractImpl(c)):
				TypeFunctions.addClassFlag(c, CExtern);
			case TClassDecl(c) if (switch (c.kind) { case KAbstractImpl(a): a.isEnum; case _: false; }):
				var hasRuntime = false;
				for (cf in c.orderedStatics) if (!TypeFunctions.hasClassFieldFlag(cf, CfEnum)) { hasRuntime = true; break; }
				if (!hasRuntime) TypeFunctions.addClassFlag(c, CExtern);
			case TClassDecl(c):
				function hasAccessor(c:TClass, n:String, stat:Bool):Bool {
					var tbl = stat ? c.statics : c.fields;
					if (tbl.exists(n)) return true;
					return switch (c.superClass) { case null: false; case s: hasAccessor(s.c, n, stat); };
				}
				function checkProp(stat:Bool, cf:TClassField):Void {
					switch (cf.kind) {
						case Var(vk) if (switch (vk.read) { case AccCall: true; case _: false; }):
							var s = "get_" + cf.name;
							cf.kind = Var({read: hasAccessor(c, s, stat) ? AccCall : AccNever, write: vk.write});
						case _:
					}
					switch (cf.kind) {
						case Var(vk) if (switch (vk.write) { case AccCall: true; case _: false; }):
							var s = "set_" + cf.name;
							cf.kind = Var({write: hasAccessor(c, s, stat) ? AccCall : AccNever, read: vk.read});
						case _:
					}
				}
				for (cf in c.orderedStatics) checkProp(true, cf);
				for (cf in c.orderedFields) checkProp(false, cf);
			case _:
		}
	}

	// The public entry. `mode` controls sweeping; entry-point collection + mark always run (only sweep
	// is gated on mode != DceNo).
	public static function run(com:Context, mode:DceMode):Void {
		var full = mode == DceFull;
		var stdDirs = full ? [] : Dce.stdPath.map(function(p) return StringTools.replace(p, "\\", "/"));
		var debug = com.defines.rawDefined("dce_debug");
		var dce = new Dce(com, full, stdDirs, debug);

		// Seed the feature table from each module's ifFeature (@:ifFeature). Each element carries a
		// feature name with its class, field and static flag.
		for (m in com.modules) {
			for (mf in m.extra.ifFeature) {
				var v:DceFeatureEntry = {c: mf.cls, cf: mf.cf, stat: mf.b};
				if (dce.features.exists(mf.name)) dce.features.get(mf.name).unshift(v);
				else dce.features.set(mf.name, [v]);
			}
		}

		// 1) entry points (com.main + @:keep/@:keepSub/@:expose + used types/fields).
		dce.collectEntryPoints();
		dce.keepCppInterfaceSlots();
		// 2) mark, keep going until no new fields are added.
		dce.mark();
		// 3) sweep, filter types (only if mode != DceNo).
		if (mode != DceNo) dce.sweep();
		// Extra: fix accessors that had their getters/setters removed.
		dce.fixAccessors();

		// Remove "override" from fields that no longer override anything.
		for (mt in com.types) switch (mt) {
			case TClassDecl(c):
				for (cf in c.orderedFields) {
					if (TypeFunctions.hasClassFieldFlag(cf, CfOverride)) {
						function loop(c:TClass):Bool {
							return switch (c.superClass) {
								case s if (s != null && s.c.fields.exists(cf.name)): true;
								case s if (s != null): loop(s.c);
								case _: false;
							}
						}
						if (!loop(c)) TypeFunctions.removeClassFieldFlag(cf, CfOverride);
					}
				}
			case _:
		}

		// Mark extern classes as really used if extended by non-extern ones.
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (c.superClass != null && !TypeFunctions.hasClassFlag(c, CExtern) && TypeFunctions.hasClassFlag(c.superClass.c, CExtern)):
				dce.markDirectlyUsedClass(c.superClass.c);
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern) && c.interfaces.length > 0):
				for (i in c.interfaces) if (TypeFunctions.hasClassFlag(i.c, CExtern)) dce.markDirectlyUsedClass(i.c);
			case _:
		}

		// Cleanup added-fields metadata, compatibility with compilation server.
		for (cf in dce.markedFields) cf.meta = removeMeta(DceMeta.Used, cf.meta);
		for (cf in dce.markedMaybeFields) cf.meta = removeMeta(DceMeta.MaybeUsed, cf.meta);
	}

	// The std path roots used by `isStdFile` (DceStd keeps std whole). Set by the Compiler before calling
	// `run`. For DceFull this is ignored.
	public static var stdPath:Array<String> = [];
}

// Not-found control flow for the nested lookups in `field`.
class DceNotFound extends haxe.Exception {
	public function new() super("Not_found");
}
