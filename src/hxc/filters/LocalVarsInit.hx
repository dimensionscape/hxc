package hxc.filters;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TexprTools;
import hxc.core.WarningList;
import hxc.context.Context;

// Unwinds the analysis once the first uninitialized use has been reported (reporting it raises).
private class StopInit extends haxe.Exception {
	public function new() super("stop-init");
}

// A definite-assignment analysis: a local read on a path that has not assigned it errors "Local variable X
// used without being initialized"; a read of a variable captured from an enclosing function downgrades to
// the WVarInit warning.
class LocalVarsInit {
	public static function run(ctx:Context):Void {
		// Only newly typed modules are checked: a module reused from the compilation cache (its body
		// already analyzer-transformed and definite-assignment-clean on the compile that cached it) is not
		// re-checked. This runs as a standalone post-typing pass over ctx.modules, so it applies that skip
		// itself; a one-shot compile never caches, so processed stays 0 and nothing is skipped.
		for (m in ctx.modules) {
			if (m.extra.processed != 0 && m.extra.processed < hxc.context.ServerCache.compilationStep) continue;
			for (mt in m.types) switch (mt) {
			case TClassDecl(c):
				inline function field(cf:TClassField) if (cf.expr != null) check(ctx, c.meta, cf.meta, cf.expr);
				for (cf in c.orderedFields) field(cf);
				for (cf in c.orderedStatics) field(cf);
				if (c.constructor != null) field(c.constructor);
				if (c.init != null) check(ctx, c.meta, [], c.init);
			case _:
			}
		}
	}

	// The var-state maps a id to whether it is initialized; a missing entry means the variable is
	// not tracked (treated as initialized). The maps are never mutated in place: every change copies
	// the map, so a captured snapshot stays valid.
	static function check(ctx:Context, classMeta:Metadata, fieldMeta:Metadata, root:TExpr):Void {
		var options = WarningList.fromMeta(classMeta.concat(fieldMeta));
		// A holder so the recursive loop can reassign the current var-state.
		var st = {vars: new Map<Int, Bool>()};
		var declared:Array<Int> = [];
		var outsideVars:Map<Int, Bool> = new Map();

		inline function copy(m:Map<Int, Bool>):Map<Int, Bool> {
			var o = new Map<Int, Bool>();
			for (k in m.keys()) o.set(k, m.get(k));
			return o;
		}
		inline function addVar(id:Int, b:Bool):Void {
			var m = copy(st.vars);
			m.set(id, b);
			st.vars = m;
		}
		// Keep vl1's keys, each ANDed with vl2's value.
		function intersect(vl1:Map<Int, Bool>, vl2:Map<Int, Bool>):Map<Int, Bool> {
			var o = new Map<Int, Bool>();
			for (k in vl1.keys()) o.set(k, vl1.get(k) == true && (vl2.exists(k) ? vl2.get(k) == true : true));
			return o;
		}
		function join(cvars:Array<Map<Int, Bool>>):Void {
			for (cv in cvars) st.vars = intersect(st.vars, cv);
		}
		// Restore the variables declared in a block to their previous state (removing those that were
		// not present before).
		function restore(oldVars:Map<Int, Bool>, decl:Array<Int>):Void {
			var m = copy(st.vars);
			for (v in decl) {
				if (oldVars.exists(v)) m.set(v, oldVars.get(v));
				else m.remove(v);
			}
			st.vars = m;
		}
		// Mark every variable that belongs to the current function as initialized (a path that does
		// not fall through: break/continue/return/throw).
		function setAllVars():Void {
			var m = new Map<Int, Bool>();
			for (id in st.vars.keys()) m.set(id, outsideVars.exists(id) ? st.vars.get(id) : true);
			st.vars = m;
		}

		function loop(e:TExpr):Void {
			switch (e.expr) {
				case TLocal(v):
					var init = st.vars.exists(v.id) ? st.vars.get(v.id) == true : true;
					if (!init) {
						if (outsideVars.exists(v.id)) {
							if (v.name == "this") ctx.warning(WVarInit, options, "this might be used before assigning a value to it", e.pos);
							else ctx.warning(WVarInit, options, "Local variable " + v.name + " might be used before being initialized", e.pos);
						} else {
							ctx.addDiagnostic(v.name == "this" ? "Missing this = value" : "Local variable " + v.name + " used without being initialized", e.pos);
							throw new StopInit();
						}
					}
				case TVarExpr(v, eo):
					if (eo == null) {
						if (!v.kind.match(VInlinedConstructorVariable)) {
							declared.push(v.id);
							addVar(v.id, false);
						}
					} else {
						loop(eo);
					}
				case TBlock(el):
					var old = declared;
					var oldVars = st.vars;
					declared = [];
					for (x in el) loop(x);
					var blockDeclared = declared.copy();
					blockDeclared.reverse();
					restore(oldVars, blockDeclared);
					declared = old;
				case TBinop(OpAssign, {expr: TLocal(v)}, e2) if (st.vars.exists(v.id)):
					switch (TexprTools.skip(e2).expr) {
						// A function value does not run immediately, so the target is safe to consider
						// initialized before typing the body (issue #9919).
						case TFunction(_):
							addVar(v.id, true);
							loop(e2);
						case _:
							loop(e2);
							addVar(v.id, true);
					}
				case TIf(e1, e2, eo):
					loop(e1);
					var vbase = st.vars;
					loop(e2);
					if (eo == null) {
						st.vars = vbase;
					} else switch (eo.expr) {
						// A synthesized `else false` (added by the side-effect handler) is ignored.
						case TConst(TBool(false)):
						case _:
							var v1 = st.vars;
							st.vars = vbase;
							loop(eo);
							st.vars = intersect(st.vars, v1);
					}
				case TWhile(cond, body, flag):
					var alwaysTrue = switch (cond.expr) {
						case TParenthesis({expr: TConst(TBool(true))}): true;
						case _: false;
					};
					if (flag == NormalWhile && !alwaysTrue) {
						loop(cond);
						var old = st.vars;
						loop(body);
						st.vars = old;
					} else {
						loop(body);
						loop(cond);
					}
				case TTry(e1, catches):
					var cvars:Array<Map<Int, Bool>> = [];
					for (c in catches) {
						var old = st.vars;
						loop(c.expr);
						cvars.push(st.vars);
						st.vars = old;
					}
					loop(e1);
					join(cvars);
				case TSwitch(subj, cases, def):
					loop(subj);
					var cvars:Array<Map<Int, Bool>> = [];
					for (c in cases) {
						var old = st.vars;
						for (v in c.values) loop(v);
						st.vars = old;
						loop(c.expr);
						cvars.push(st.vars);
						st.vars = old;
					}
					var exhaustive = switch (subj.expr) {
						case TMeta(mm, _) if (mm.name == ":exhaustive"): true;
						case TParenthesis({expr: TMeta(mm, _)}) if (mm.name == ":exhaustive"): true;
						case _: false;
					};
					if (def == null) {
						if (exhaustive && cvars.length > 0) {
							var cv = cvars[0];
							var m = copy(st.vars);
							for (i in cv.keys()) if (cv.get(i) == true) m.set(i, true);
							st.vars = m;
							join(cvars.slice(1));
						}
						// A non-exhaustive switch without a default leaves the state unchanged.
					} else {
						loop(def);
						join(cvars);
					}
				case TBreak | TContinue | TReturn(null):
					setAllVars();
				case TThrow(e1):
					loop(e1);
					setAllVars();
				case TReturn(e1) if (e1 != null):
					loop(e1);
					setAllVars();
				case TFunction(tf):
					var old = copy(outsideVars);
					for (id in st.vars.keys()) outsideVars.set(id, true);
					loop(tf.expr);
					outsideVars = old;
				case _:
					TexprTools.iter(loop, e);
			}
		}

		try loop(root) catch (_:StopInit) {}
	}
}
