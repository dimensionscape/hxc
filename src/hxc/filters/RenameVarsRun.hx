package hxc.filters;

import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Ref;
import hxc.ast.Ast;
import hxc.ast.Position;
import haxe.ds.StringMap;
import haxe.ds.IntMap;

/**
 * Local-variable renaming, RUN half: collect, declare, use, maybe rename, rename, run. See
 * filters.RenameVars for the init half and the config rationale.
 *
 * hxc's TLocal(v)/TVarExpr(v) SHARE the same TVar object (by id), so renaming is just MUTATING
 * `v.name`, and every reference updates automatically. The full scope/collision analysis still
 * decides
 * when to rename.
 */
class RenameVarsRun {
	var hoisting:Bool;
	var noShadowing:Bool;
	var noCatchVarShadowing:Bool;
	var switchCasesNoBlocks:Bool;
	var blockScope:Bool;
	var reserved:StringMap<Bool>;

	function new(ri:RenameVars) {
		this.hoisting = ri.hoisting;
		this.noShadowing = ri.noShadowing;
		this.noCatchVarShadowing = ri.noCatchVarShadowing;
		this.switchCasesNoBlocks = ri.switchCasesNoBlocks;
		this.blockScope = ri.blockScope;
		this.reserved = ri.reserved;
	}

	static inline function reserve(reserved:StringMap<Bool>, name:String):Void {
		reserved.set(name, true);
	}

	static inline function intMapIsEmpty(m:IntMap<TVar>):Bool {
		return !m.keys().hasNext();
	}

	// A generated local's name starts with the escape char.
	static inline function isGenLocal(v:TVar):Bool {
		return v.name.length > 0 && v.name.charAt(0) == "`";
	}

	// Invoked for each declared var.
	function declareVar(scope:RenameScope, v:TVar):Void {
		var overlaps:IntMap<TVar>;
		if (!hoisting || intMapIsEmpty(scope.foreignVars)) {
			overlaps = (scope.loopCount == 0) ? new IntMap<TVar>() : copyIntMap(scope.loopVars.get());
		} else {
			if (scope.loopCount == 0) {
				overlaps = copyIntMap(scope.foreignVars);
			} else {
				overlaps = copyIntMap(scope.loopVars.get());
				for (i in scope.foreignVars.keys()) {
					if (!overlaps.exists(i)) overlaps.set(i, scope.foreignVars.get(i));
				}
			}
		}
		scope.ownVars.unshift(new OwnVar(v, new Ref(overlaps)));
		if (scope.loopCount > 0) scope.loopVars.get().set(v.id, v);
	}

	// Invoked for each TLocal v.
	function useVar(scope:RenameScope, v:TVar):Void {
		// ownVars is built with unshift, so it is in most-recent-first order.
		var declarations = scope.ownVars;
		var i = 0;
		var found = false;
		while (i < declarations.length) {
			var d = declarations[i];
			if (d.v == v) { found = true; break; } // Declaration of v in this scope: stop.
			var ov = d.overlaps.get();
			if (!ov.exists(v.id)) ov.set(v.id, v);
			i++;
		}
		if (!found) {
			// V is foreign to this scope (declared in an outer scope but used here).
			if ((noShadowing || hoisting) && !scope.foreignVars.exists(v.id))
				scope.foreignVars.set(v.id, v);
			switch (scope.parent) {
				case null: throw "RenameVars: Failed to locate variable declaration: " + v.name + " (id " + v.id + ")";
				case p: useVar(p, v);
			}
		}
		if (scope.loopCount > 0 && !scope.loopVars.get().exists(v.id))
			scope.loopVars.get().set(v.id, v);
	}

	function collectLoop(scope:RenameScope, fn:Void->Void):Void {
		scope.loopCount++;
		fn();
		scope.loopCount--;
		if (scope.loopCount < 0) throw "RenameVars: Unexpected loop count";
		if (scope.loopCount == 0) scope.loopVars.set(new IntMap<TVar>());
	}

	static inline function isBlockLike(e:TExpr):Bool {
		return switch (e.expr) { case TBlock(_) | TFunction(_): true; case _: false; };
	}

	// collect_vars . `in_block` only matters for BlockScope (deferred); kept for structural fidelity.
	function collectVars(scope:RenameScope, e:TExpr, in_block:Bool = false):Void {
		switch (e.expr) {
			// TVar with hoisting or a function initializer: declare before collecting the init. With
			// VarHoisting on (the JS config) this is the path every TVar takes.
			case TVarExpr(v, e_opt) if (hoisting || (e_opt != null && (switch (e_opt.expr) { case TFunction(_): true; case _: false; }))):
				declareVar(scope, v);
				if (e_opt != null) collectVars(scope, e_opt, isBlockLike(e_opt));
			// TVar: collect init first, then declare.
			case TVarExpr(v, e_opt):
				if (e_opt != null) collectVars(scope, e_opt, isBlockLike(e_opt));
				declareVar(scope, v);
			case TLocal(v):
				useVar(scope, v);
			// TFunction: new child scope; declare + use args.
			case TFunction(fn):
				var child = new RenameScope(scope);
				for (a in fn.args) declareVar(child, a.v);
				for (a in fn.args) useVar(child, a.v);
				switch (fn.expr.expr) {
					case TBlock(exprs): for (x in exprs) collectVars(child, x, true);
					case _: collectVars(child, fn.expr, isBlockLike(fn.expr));
				}
			// TTry: the catch var is treated as a TVar declared at the head of the catch body. With
			// NoCatchVarShadowing (the JS config) the catch var is ALSO `use`d so it is reserved against
			// the surrounding scope.
			case TTry(try_expr, catches):
				collectVars(scope, try_expr, isBlockLike(try_expr));
				for (c in catches) {
					var v_expr = TypeFunctions.mk(TVarExpr(c.v, null), TypeFunctions.tDynamic, c.v.pos);
					var wrapped = switch (c.expr.expr) {
						case TBlock(exprs): TypeFunctions.mk(TBlock([v_expr].concat(exprs)), c.expr.type, c.expr.pos);
						case _: TypeFunctions.mk(TBlock([v_expr, c.expr]), c.expr.type, c.expr.pos);
					};
					collectVars(scope, wrapped, true);
					if (noCatchVarShadowing) useVar(scope, c.v);
				}
			// TSwitch with SwitchCasesNoBlocks: sibling case bodies share the switch scope so their lets
			// get distinct names.
			case TSwitch(target, cases, edef) if (switchCasesNoBlocks):
				collectVars(scope, target, isBlockLike(target));
				for (c in cases) {
					for (val in c.values) collectVars(scope, val, isBlockLike(val));
					collectIgnoreBlock(scope, c.expr);
				}
				if (edef != null) collectIgnoreBlock(scope, edef);
			// TBlock under BlockScope: a bare block opens a scope.
			case TBlock(exprs) if (blockScope && !in_block):
				var child = new RenameScope(scope);
				for (x in exprs) collectVars(child, x, true);
			case TWhile(condition, body, flag):
				collectLoop(scope, function() {
					if (flag == NormalWhile) collectVars(scope, condition, false);
					collectVars(scope, body, isBlockLike(body));
					if (flag == DoWhile) collectVars(scope, condition, false);
				});
			// TFor. With hoisting, declare the loop var first.
			case TFor(v, iterator, body):
				collectLoop(scope, function() {
					if (hoisting) declareVar(scope, v);
					collectVars(scope, iterator, false);
					if (!hoisting) declareVar(scope, v);
					collectVars(scope, body, isBlockLike(body));
				});
			// Default: iter over sub-exprs.
			case _:
				iterSub(e, function(sub) collectVars(scope, sub, isBlockLike(sub)));
		}
	}

	// Iterate a block's elements into the current scope without opening one.
	function collectIgnoreBlock(scope:RenameScope, e:TExpr):Void {
		switch (e.expr) {
			case TBlock(el): for (x in el) collectVars(scope, x, true);
			case _: collectVars(scope, e, true);
		}
	}

	// Trailing-digit chop, as the regexp "[0-9]+$".
	static function stripTrailingNumbers(s:String):String {
		var end = s.length;
		while (end > 0) {
			var c = s.charCodeAt(end - 1);
			if (c >= 48 && c <= 57) end--; else break;
		}
		return s.substr(0, end);
	}

	/**
	 * The actual rename:
	 * - generated locals: chop the escape char, prefix "_g", strip trailing digits.
	 * - then bump a trailing count while the name collides with a reserved name or any overlapping
	 * (concurrently-live) var's name. hxc renames by MUTATING v.name (shared TVar => every reference
	 * updates).
	 */
	// `reserved` here is the per-scope OVERLAY over the shared reserved base: `reserve` builds a small
	// delta on top. The base holds every module-type name, so copying it per scope instead would copy all
	// of them for every function scope in the program.
	function maybeRenameVar(reserved:StringMap<Bool>, entry:OwnVar):Void {
		var v = entry.v;
		var overlaps = entry.overlaps.get();

		// Commit: record the pre-rename name as :realPath before mutating name, so the hxcpp debugger
		// shows the source name (HX_STACK_ARG / HX_VARI_NAME) rather than the renamed one. An unchanged
		// var gets :realPath == name (HX_VAR/HX_VARI), a renamed one gets the original.
		inline function commit(newName:String):Void {
			v.meta = [({name: ":realPath", params: [new Expr(EConst(CString(v.name, SDoubleQuotes)), Position.nullPos)], pos: Position.nullPos} : MetadataEntry)].concat(v.meta);
			v.name = newName;
		}

		// Chop the escape char for generated locals. (GenJS.ident also does the `_g` transform at print
		// time; doing it here first keeps the collision check consistent with the emitted name and is
		// idempotent.)
		if (isGenLocal(v)) {
			var name = v.name.substr(1);
			commit("_g" + stripTrailingNumbers(name));
		}

		var baseName = v.name;
		var name = baseName;
		var count = 0;
		// While the name is reserved or equals some overlapping var's name. Reserved = the shared base or
		// this scope's overlay.
		while (true) {
			var collides = reserved.exists(name) || this.reserved.exists(name);
			if (!collides) {
				for (id in overlaps.keys()) {
					if (overlaps.get(id).name == name) { collides = true; break; }
				}
			}
			if (!collides) break;
			count++;
			name = baseName + count;
		}
		commit(name);
		// NoShadowing / VCaptured reservation: a CAPTURED var under hoisting reserves its renamed name so a
		// same-named sibling in the shared function scope renames away from it; otherwise closures over an
		// unrolled/hoisted loop var all read the last one.
		if (noShadowing || (TypeFunctions.hasVarFlag(v, VCaptured) && hoisting)) reserve(reserved, v.name);
	}

	// Reserve foreign names, then rename own vars, then recurse into children.
	function renameVars(scope:RenameScope):Void {
		// The overlay is this scope's delta over the shared base: per-scope additions never touch the base
		// and cost nothing to set up. maybeRenameVar consults the shared base alongside it.
		var reserved = new StringMap<Bool>();
		if ((hoisting || noShadowing) && !intMapIsEmpty(scope.foreignVars)) {
			for (id in scope.foreignVars.keys()) reserve(reserved, scope.foreignVars.get(id).name);
		}
		// ownVars were prepended (unshift), so reverse to declaration order.
		var ordered = scope.ownVars.copy();
		ordered.reverse();
		for (entry in ordered) maybeRenameVar(reserved, entry);
		// Children are renamed in REVERSE creation order. hxc appends them, so it has to reverse here - the
		// same asymmetry ownVars is corrected for just above. Sibling scopes reserve names as they are
		// walked, so the order decides which of two same-named vars keeps the base name and which gets the
		// suffix.
		var kids = scope.children.copy();
		kids.reverse();
		for (child in kids) renameVars(child);
	}

	/**
		Rename local variables in `e` if needed.
		ReserveCurrentTopLevelSymbol is not in hxc's JS flag set, so the path-based reservation is
		skipped.
	**/
	public static function run(ri:RenameVars, e:TExpr):Void {
		var self = new RenameVarsRun(ri);
		var scope = new RenameScope(null);
		self.collectVars(scope, e, isBlockLike(e));
		self.renameVars(scope);
	}

	// ---- small map helpers (scope maps are copied, not shared) ----
	static function copyIntMap(m:IntMap<TVar>):IntMap<TVar> {
		var r = new IntMap<TVar>();
		for (k in m.keys()) r.set(k, m.get(k));
		return r;
	}
	static function copyStringMap(m:StringMap<Bool>):StringMap<Bool> {
		var r = new StringMap<Bool>();
		for (k in m.keys()) r.set(k, m.get(k));
		return r;
	}

	/**
		Iterate over the immediate sub-expressions of `e`. Duplicates Typer.iterTExpr so the filter is
		self-contained.
	**/
	static function iterSub(e:TExpr, f:TExpr->Void):Void {
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
}

/**
	A single scope. A nested TFunction makes a child scope.
**/
class RenameScope {
	public var parent:Null<RenameScope>;
	public var children:Array<RenameScope>;
	// ownVars: vars declared in this scope, each with the set of vars it overlaps.
	public var ownVars:Array<OwnVar>;
	// foreignVars: vars declared outside this scope but used inside (captured).
	public var foreignVars:IntMap<TVar>;
	// Loop tracking
	public var loopVars:Ref<IntMap<TVar>>;
	public var loopCount:Int;

	public function new(parent:Null<RenameScope>) {
		this.parent = parent;
		this.children = [];
		this.ownVars = [];
		this.foreignVars = new IntMap<TVar>();
		this.loopVars = new Ref(new IntMap<TVar>());
		this.loopCount = 0;
		if (parent != null) parent.children.push(this);
	}
}

// ownVars entry: (var declared, ref to IntMap of vars it overlaps with).
class OwnVar {
	public var v:TVar;
	public var overlaps:Ref<IntMap<TVar>>;
	public function new(v:TVar, overlaps:Ref<IntMap<TVar>>) {
		this.v = v;
		this.overlaps = overlaps;
	}
}
