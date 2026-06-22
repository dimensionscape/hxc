package hxc.filters;

// hxc.filters.Filters: the filter pipeline (the analyzer, DCE, RenameVars and Exceptions stages
// live in their own modules)

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.Globals;
import hxc.context.Context;
import hxc.typing.Calls;
import hxc.typing.Typer;
import hxc.typing.TyperContext;
import hxc.optimization.Optimizer;
import haxe.ds.StringMap;

class Filters {
	public static function addFinalReturn(e:TExpr):TExpr {
		function defReturn(t:T, p:Position):TExpr {
			var c:TConstant = switch (TypeFunctions.follow(t)) {
				case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Int"): TInt(0);
				case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Float"): TFloat("0.");
				case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Bool"): TBool(false);
				case _: TNull;
			};
			return TypeFunctions.mk(TReturn(TypeFunctions.mk(TConst(c), t, p)), TypeFunctions.tDynamic, p);
		}
		function loop(e:TExpr, t:T):TExpr {
			return switch (e.expr) {
				case TBlock(el):
					// An empty body still needs a value on a static platform. A non-Void return can be
					// inferred for an
					// empty-bodied reassignable dynamic method, so emit the default return rather than an
					// empty block
					// the C++ compiler rejects.
					if (el.length == 0) TypeFunctions.mk(TBlock([defReturn(t, e.pos)]), e.type, e.pos)
					else {
						var last = loop(el[el.length - 1], t);
						var rest = el.slice(0, el.length - 1);
						switch (last.expr) {
							case TBlock(el2): TypeFunctions.mk(TBlock(rest.concat(el2)), e.type, e.pos);
							case _: TypeFunctions.mk(TBlock(rest.concat([last])), e.type, e.pos);
						}
					}
				case TReturn(_): e;
				case _: TypeFunctions.mk(TBlock([e, defReturn(t, e.pos)]), e.type, e.pos);
			};
		}
		var e = TexprTools.mapExpr(addFinalReturn, e);
		return switch (e.expr) {
			case TFunction(f):
				var f2 = switch (TypeFunctions.follow(f.type)) {
					case TAbstract(a, []) if (a.path.pack.length == 0 && a.path.name == "Void"): f;
					case _: new TFunc(f.args, f.type, loop(f.expr, f.type));
				};
				TypeFunctions.mk(TFunction(f2), e.type, e.pos);
			case _: e;
		};
	}

	// A residual TFor left by the typer re-lowers now that the iterated type is concrete; when it still
	// lowers to a TFor, rewrite it to the plain iterator while loop.
	public static function forRemap(tctx:TyperContext, e:TExpr):TExpr {
		var basic = tctx.com.basic;
		function remapFallback(v:TVar, e1:TExpr, e2:TExpr, p:Position):TExpr {
			var v2 = TypeFunctions.allocVar(v.kind, v.name, e1.type, e1.pos);
			var ev2 = TypeFunctions.mk(TLocal(v2), e1.type, e1.pos);
			var t1 = TypeFunctions.followWithAbstracts(e1.type);
			var faHas = try TypeFunctions.quickField(t1, "hasNext")
				catch (_:hxc.core.NotFound) throw new TypingError(hxc.core.TPrinting.sTypeStr(t1) + " has no field hasNext()", p);
			var eHasNext = TypeFunctions.mk(TField(ev2, faHas), TypeFunctions.tfun([], basic.tbool), e1.pos);
			eHasNext = TypeFunctions.mk(TCall(eHasNext, []), basic.tbool, eHasNext.pos);
			var eNext = TypeFunctions.mk(TField(ev2, TypeFunctions.quickField(t1, "next")), TypeFunctions.tfun([], v.type), e1.pos);
			eNext = TypeFunctions.mk(TCall(eNext, []), v.type, e1.pos);
			var eAssign = TypeFunctions.mk(TVarExpr(v, eNext), basic.tvoid, p);
			var eBody = hxc.typing.ForLoop.ForLoopFaithful.concat(eAssign, e2);
			return TypeFunctions.mk(TBlock([
				TypeFunctions.mk(TVarExpr(v2, e1), basic.tvoid, e1.pos),
				TypeFunctions.mk(TWhile(TypeFunctions.mk(TParenthesis(eHasNext), eHasNext.type, eHasNext.pos), eBody, NormalWhile), basic.tvoid, e1.pos)
			]), basic.tvoid, p);
		}
		function loop(e:TExpr):TExpr {
			return switch (e.expr) {
				case TFor(v, e1, e2):
					var e1 = loop(e1);
					var e2 = loop(e2);
					var restore = Typer.saveLocals(tctx);
					var lowered = try {
						var iterator = hxc.typing.ForLoop.ForLoopFaithful.ofTexpr(tctx, e1, null, e.pos);
						hxc.typing.ForLoop.ForLoopFaithful.toTexpr(tctx, v, iterator, e2, e.pos);
					} catch (_:Dynamic) TypeFunctions.mk(TFor(v, e1, e2), tctx.com.basic.tvoid, e.pos);
					restore();
					switch (lowered.expr) {
						case TFor(_, _, _): remapFallback(v, e1, e2, e.pos);
						case _: lowered;
					}
				case _:
					TexprTools.mapExpr(loop, e);
			};
		}
		return loop(e);
	}

	// Promote `static var` locals to class statics
	public static function localStatics(ctx:TyperContext, e:TExpr):TExpr {
		var lut = new Map<Int, TClassField>();
		var c = ctx.curclass;
		function promote(v:TVar, eo:Null<TExpr>):Void {
			var name = ctx.curfield.name + "_" + v.name;
			if (c.statics.exists(name)) {
				var cf = c.statics.get(name);
				ctx.com.addDiagnostic("The expanded name of this local (" + name + ") conflicts with another static field", v.pos);
				ctx.com.addDiagnostic("Conflicting field was found here", cf.namePos, 1);
				return;
			}
			var cf = TypeFunctions.mkField(name, v.type, v.pos, v.pos, true, true);
			cf.meta = [{name: ":noCompletion", params: [], pos: Position.nullPos}].concat(v.meta);
			TypeFunctions.addClassFieldFlag(cf, CfNoLookup);
			if (eo != null) {
				function check(e:TExpr):Void {
					switch (e.expr) {
						case TLocal(_) | TFunction(_):
							throw new TypingError("Accessing local variables in static initialization is not allowed", e.pos);
						case TConst(TThis | TSuper):
							throw new TypingError("Accessing `this` in static initialization is not allowed", e.pos);
						case TReturn(_) | TBreak | TContinue:
							throw new TypingError("This kind of control flow in static initialization is not allowed", e.pos);
						case _:
							TexprTools.iter(check, e);
					}
				}
				check(eo);
				cf.expr = eo;
			}
			c.statics.set(cf.name, cf);
			// The promoted local static is PREPENDED to the ordered statics.
			c.orderedStatics.unshift(cf);
			lut.set(v.id, cf);
		}
		function run(e:TExpr):TExpr {
			return switch (e.expr) {
				case TBlock(el):
					var out = [];
					for (x in el) switch (x.expr) {
						case TVarExpr(v, eo) if (TypeFunctions.hasVarFlag(v, VStatic)):
							promote(v, eo);
						case _:
							out.push(run(x));
					}
					TypeFunctions.mk(TBlock(out), e.type, e.pos);
				case TLocal(v) if (TypeFunctions.hasVarFlag(v, VStatic)):
					var cf = lut.get(v.id);
					if (cf == null) throw new TypingError("Could not find local static " + v.name + " (id " + v.id + ")", e.pos);
					TexprTools.makeStaticField(c, cf, e.pos);
				case _:
					TexprTools.mapExpr(run, e);
			};
		}
		return run(e);
	}

	// Reject reads of uninitialized locals; loop-local state uses maps of var id to initialized flag.
	public static function checkLocalVarsInit(ctx:TyperContext, e:TExpr):TExpr {
		var vars = new Map<Int, Bool>();
		var declared:Array<Int> = [];
		var outsideVars = new Map<Int, Bool>();
		function copyVars():Map<Int, Bool> {
			var m = new Map<Int, Bool>();
			for (k => v in vars) m.set(k, v);
			return m;
		}
		function setVars(m:Map<Int, Bool>):Void {
			vars.clear();
			for (k => v in m) vars.set(k, v);
		}
		function intersectInto(v2:Map<Int, Bool>):Void {
			for (k => v in vars) vars.set(k, v && (v2.exists(k) ? v2.get(k) : false));
		}
		function setAllVars():Void {
			for (k in vars.keys()) if (!outsideVars.exists(k)) vars.set(k, true);
		}
		var loop:TExpr->Void = null;
		loop = function(e:TExpr):Void {
			switch (e.expr) {
				case TLocal(v):
					var init = vars.exists(v.id) ? vars.get(v.id) : true;
					if (!init) {
						if (outsideVars.exists(v.id)) {
							var msg = v.name == "this" ? "this might be used before assigning a value to it"
								: "Local variable " + v.name + " might be used before being initialized";
							// @:haxe.warning("-WVarInit") on the field or class silences this (the warning
							// options come from
							// the enclosing metas).
							var opts = hxc.core.WarningList.fromMeta(ctx.curfield.meta).concat(hxc.core.WarningList.fromMeta(ctx.curclass.meta));
							ctx.com.warning(WVarInit, opts, msg, e.pos);
						} else {
							if (v.name == "this") throw new TypingError("Missing this = value", e.pos);
							throw new TypingError("Local variable " + v.name + " used without being initialized", e.pos);
						}
					}
				case TVarExpr(v, eo):
					if (eo == null) {
						if (!v.kind.match(VInlinedConstructorVariable)) {
							declared.push(v.id);
							vars.set(v.id, false);
						}
					} else loop(eo);
				case TBlock(el):
					var old = declared;
					var oldVars = copyVars();
					declared = [];
					for (x in el) loop(x);
					// Restore variables declared in this block to their previous state
					for (v in declared) {
						if (oldVars.exists(v)) vars.set(v, oldVars.get(v)) else vars.remove(v);
					}
					declared = old;
				case TBinop(OpAssign, {expr: TLocal(v)}, e2) if (vars.exists(v.id)):
					switch (TexprTools.skip(e2).expr) {
						case TFunction(_):
							// The function does not run immediately (issue #9919)
							vars.set(v.id, true);
							loop(e2);
						case _:
							loop(e2);
							vars.set(v.id, true);
					}
				case TIf(e1, e2, eo):
					loop(e1);
					var vbase = copyVars();
					loop(e2);
					switch (eo) {
						case null: setVars(vbase);
						case {expr: TConst(TBool(false))}: // Side-effect handler artifact
						case e3:
							var v1 = copyVars();
							setVars(vbase);
							loop(e3);
							intersectInto(v1);
					}
				case TWhile(cond, body, flag):
					var alwaysTrue = switch (cond.expr) {
						case TParenthesis({expr: TConst(TBool(true))}): true;
						case _: false;
					};
					if (flag.match(NormalWhile) && !alwaysTrue) {
						loop(cond);
						var old = copyVars();
						loop(body);
						setVars(old);
					} else {
						loop(body);
						loop(cond);
					}
				case TTry(e1, catches):
					var cvars = [for (c in catches) {
						var old = copyVars();
						loop(c.expr);
						var v = copyVars();
						setVars(old);
						v;
					}];
					loop(e1);
					for (v in cvars) intersectInto(v);
				case TSwitch(e1, cases, def):
					loop(e1);
					var cvars = [for (c in cases) {
						var old = copyVars();
						for (v in c.values) loop(v);
						setVars(old);
						loop(c.expr);
						var v = copyVars();
						setVars(old);
						v;
					}];
					var exhaustive = switch (e1.expr) {
						case TMeta(m, _) if (m.name == ":exhaustive"): true;
						case TParenthesis({expr: TMeta(m, _)}) if (m.name == ":exhaustive"): true;
						case _: false;
					};
					if (def == null) {
						if (exhaustive && cvars.length > 0) {
							for (k => b in cvars[0]) if (b) vars.set(k, b);
							for (i in 1...cvars.length) intersectInto(cvars[i]);
						}
					} else {
						loop(def);
						for (v in cvars) intersectInto(v);
					}
				case TBreak | TContinue | TReturn(null):
					setAllVars();
				case TThrow(e1) | TReturn(e1):
					loop(e1);
					setAllVars();
				case TFunction(tf):
					var old = copyVars();
					var oldOutside = new Map<Int, Bool>();
					for (k => v in outsideVars) oldOutside.set(k, v);
					for (k in vars.keys()) outsideVars.set(k, true);
					loop(tf.expr);
					outsideVars = oldOutside;
					// (vars still tracks initializations the function makes)
					old = null;
				case _:
					TexprTools.iter(loop, e);
			}
		}
		loop(e);
		return e;
	}

	// Label loops whose inner switch breaks out
	public static function markSwitchBreakLoops(e:TExpr):TExpr {
		function addLoopLabel(n:Int, e:TExpr):TExpr {
			return TypeFunctions.mk(TMeta({name: ":loopLabel", params: [new Expr(EConst(CInt(Std.string(n), null)), e.pos)], pos: e.pos}, e), e.type, e.pos);
		}
		var inSwitch = false;
		var didFound = -1;
		var num = 0;
		var curNum = 0;
		function run(e:TExpr):TExpr {
			return switch (e.expr) {
				case TFunction(_):
					var oldNum = num;
					num = 0;
					var ret = TexprTools.mapExpr(run, e);
					num = oldNum;
					ret;
				case TWhile(_, _, _) | TFor(_, _, _):
					var lastSwitch = inSwitch;
					var lastFound = didFound;
					var lastNum = curNum;
					inSwitch = false;
					num++;
					curNum = num;
					didFound = -1;
					var newE = TexprTools.mapExpr(run, e); // No loop in the condition assumed
					if (didFound != -1) newE = addLoopLabel(didFound, newE);
					didFound = lastFound;
					inSwitch = lastSwitch;
					curNum = lastNum;
					newE;
				case TSwitch(_, _, _):
					var lastSwitch = inSwitch;
					inSwitch = true;
					var newE = TexprTools.mapExpr(run, e);
					inSwitch = lastSwitch;
					newE;
				case TBreak:
					if (inSwitch) {
						didFound = curNum;
						addLoopLabel(curNum, e);
					} else e;
				case _:
					TexprTools.mapExpr(run, e);
			};
		}
		return run(e);
	}

	public static function fixReturnDynamicFromVoidFunction(ctx:TyperContext, returnIsVoid:Bool, e:TExpr):TExpr {
		return switch (e.expr) {
			case TFunction(fn):
				var isVoid = switch (TypeFunctions.follow(fn.type)) {
					case TAbstract(a, []): a.path.pack.length == 0 && a.path.name == "Void";
					case _: false;
				};
				var body = fixReturnDynamicFromVoidFunction(ctx, isVoid, fn.expr);
				TypeFunctions.mk(TFunction(new TFunc(fn.args, fn.type, body)), e.type, e.pos);
			case TReturn(returnExpr) if (returnIsVoid && returnExpr != null && TypeFunctions.follow(returnExpr.type).match(TDynamic(null))):
				var returnPos = new Position(e.pos.file, e.pos.min, returnExpr.pos.min - 1);
				var exprs = [
					fixReturnDynamicFromVoidFunction(ctx, returnIsVoid, returnExpr),
					TypeFunctions.mk(TReturn(null), e.type, returnPos)
				];
				TypeFunctions.mk(TMeta({name: ":mergeBlock", params: [], pos: Position.nullPos},
					TypeFunctions.mk(TBlock(exprs), e.type, e.pos)), e.type, e.pos);
			case _:
				TexprTools.mapExpr(function(x) return fixReturnDynamicFromVoidFunction(ctx, returnIsVoid, x), e);
		};
	}

	public static function checkAbstractAsValue(e:TExpr):TExpr {
		function loop(e:TExpr):Void {
			switch (e.expr) {
				case TField({expr: TTypeExpr(_)}, _):
				case TTypeExpr(TClassDecl(c)):
					switch (c.kind) {
						case KAbstractImpl(a) if (!TypeFunctions.hasMeta(":runtimeValue", a.meta)):
							throw new TypingError("Cannot use abstract as value", e.pos);
						case _:
					}
				case _:
					TexprTools.iter(loop, e);
			}
		}
		loop(e);
		return e;
	}

	// Extractor variables initialize lazily at first read
	public static function varLazifier(com:Context, e:TExpr):TExpr {
		var varInits = new Map<Int, TExpr>();
		var loop:TExpr->TExpr = null;
		loop = function(e:TExpr):TExpr {
			return switch (e.expr) {
				case TVarExpr(v, e1) if (e1 != null && v.kind.match(VExtractorVariable)):
					varInits.set(v.id, e1);
					TypeFunctions.mk(TVarExpr(v, null), e.type, e.pos);
				case TLocal(v) if (varInits.exists(v.id)):
					var eInit = loop(varInits.get(v.id));
					var assigned = TypeFunctions.mk(TBinop(OpAssign, e, eInit), e.type, e.pos);
					varInits.remove(v.id);
					TypeFunctions.mk(TParenthesis(assigned), e.type, e.pos);
				case TIf(e1, e2, eo):
					var e1 = loop(e1);
					// Branches see the pending inits but do not consume them for the outside
					var saved = [for (k => x in varInits) {k: k, x: x}];
					var e2 = loop(e2);
					for (s in saved) varInits.set(s.k, s.x);
					var eo2 = eo == null ? null : loop(eo);
					for (s in saved) varInits.set(s.k, s.x);
					TypeFunctions.mk(TIf(e1, e2, eo2), e.type, e.pos);
				case TWhile(e1, e2, flag):
					var e1 = loop(e1);
					var saved = [for (k => x in varInits) {k: k, x: x}];
					var e2 = loop(e2);
					for (s in saved) varInits.set(s.k, s.x);
					TypeFunctions.mk(TWhile(e1, e2, flag), e.type, e.pos);
				case TTry(e1, catches):
					var saved = [for (k => x in varInits) {k: k, x: x}];
					var e1b = loop(e1);
					for (s in saved) varInits.set(s.k, s.x);
					var catches2 = [for (c in catches) {
						var c2 = {v: c.v, expr: loop(c.expr)};
						for (s in saved) varInits.set(s.k, s.x);
						c2;
					}];
					TypeFunctions.mk(TTry(e1b, catches2), e.type, e.pos);
				case TSwitch(e1, cases, edef):
					var e1 = loop(e1);
					var saved = [for (k => x in varInits) {k: k, x: x}];
					var cases2 = [for (c in cases) {
						var c2 = {values: c.values, expr: loop(c.expr)};
						for (s in saved) varInits.set(s.k, s.x);
						c2;
					}];
					var edef2 = edef == null ? null : loop(edef);
					for (s in saved) varInits.set(s.k, s.x);
					TypeFunctions.mk(TSwitch(e1, cases2, edef2), e.type, e.pos);
				case _:
					TexprTools.mapExpr(loop, e);
			};
		}
		return loop(e);
	}

	public static function removeGenericBase(t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c) if (FiltersCommon.isRemovableClass(c)):
				TypeFunctions.addClassFlag(c, CExtern);
			case _:
		}
	}

	public static function removeExternFields(com:Context, t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c):
				if (!com.defines.rawDefined("doc_gen")) {
					c.orderedFields = [for (f in c.orderedFields) if (!{
						var b = FiltersCommon.isRemovableField(com, f);
						if (b) c.fields.remove(f.name);
						b;
					}) f];
					c.orderedStatics = [for (f in c.orderedStatics) if (!{
						var b = FiltersCommon.isRemovableField(com, f);
						if (b) c.statics.remove(f.name);
						b;
					}) f];
				}
			case _:
		}
	}

	public static function checkPrivatePath(ctx:TyperContext, t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c) if (c.isPrivate):
				var rpath:hxc.core.Globals.Path = {pack: c.module.path.pack, name: "_" + c.module.path.name};
				if (ctx.com.typeToModule.exists(Context.pathKey(rpath)))
					throw new TypingError("This private class name will clash with " + Context.sTypePath(rpath), c.pos);
			case _:
		}
	}

	public static function applyNativePaths(com:Context, t:ModuleType):Void {
		function getRealName(meta:Metadata, name:String):Null<{meta:MetadataEntry, name:String}> {
			var nn = hxc.codegen.Codegen.getNativeName(com, meta);
			if (nn == null) return null;
			return {meta: {name: ":realPath", params: [new Expr(EConst(CString(name, SDoubleQuotes)), nn.pos)], pos: nn.pos}, name: nn.name};
		}
		function getRealPath(meta:Metadata, path:hxc.core.Globals.Path):Null<{meta:MetadataEntry, path:hxc.core.Globals.Path}> {
			var nn = hxc.codegen.Codegen.getNativeName(com, meta);
			if (nn == null) return null;
			return {meta: {name: ":realPath", params: [new Expr(EConst(CString(Context.sTypePath(path), SDoubleQuotes)), nn.pos)], pos: nn.pos}, path: Ast.parsePath(nn.name)};
		}
		switch (t) {
			case TClassDecl(c):
				function field(cf:TClassField):Bool {
					var r = getRealName(cf.meta, cf.name);
					if (r == null) return false;
					cf.name = r.name;
					cf.meta = [r.meta].concat(cf.meta);
					for (o in cf.overloads) o.name = r.name;
					return true;
				}
				function fields(cfs:Array<TClassField>, oldMap:StringMap<TClassField>):StringMap<TClassField> {
					var didChange = false;
					for (cf in cfs) if (field(cf)) didChange = true;
					if (!didChange) return oldMap;
					var m = new StringMap<TClassField>();
					for (cf in cfs) m.set(cf.name, cf);
					return m;
				}
				c.fields = fields(c.orderedFields, c.fields);
				c.statics = fields(c.orderedStatics, c.statics);
				var r = getRealPath(c.meta, c.path);
				if (r != null) {
					c.meta = [r.meta].concat(c.meta);
					c.path = r.path;
				}
			case TEnumDecl(en):
				var didChange = false;
				for (name in en.names) {
					var ef = en.constrs.get(name);
					if (ef == null) continue;
					var r = getRealName(ef.meta, ef.name);
					if (r != null) {
						ef.name = r.name;
						ef.meta = [r.meta].concat(ef.meta);
						didChange = true;
					}
				}
				if (didChange) {
					var oldNames = en.names;
					var m = new StringMap<TEnumField>();
					var names:Array<String> = [];
					for (name in oldNames) {
						var ef = en.constrs.get(name);
						if (ef == null) continue;
						m.set(ef.name, ef);
						names.push(ef.name);
					}
					en.constrs = m;
					en.names = names;
				}
				var r = getRealPath(en.meta, en.path);
				if (r != null) {
					en.meta = [r.meta].concat(en.meta);
					en.path = r.path;
				}
			case _:
		}
	}

	// Attach the __rtti static carrying the genxml type string.
	public static function addRtti(com:Context, t:ModuleType):Void {
		function hasRtti(c:TClass):Bool {
			return TypeFunctions.hasMeta(":rtti", c.meta) || (c.superClass != null && hasRtti(c.superClass.c));
		}
		switch (t) {
			case TClassDecl(c) if (hasRtti(c) && !c.statics.exists("__rtti")):
				// The __rtti field is PUBLIC; with false here --xml/--json would report it private.
				var f = TypeFunctions.mkField("__rtti", com.basic.tstring, c.pos, Position.nullPos, true, true);
				var str = hxc.codegen.GenXml.genTypeString(com, t);
				f.expr = TypeFunctions.mk(TConst(TString(str)), f.type, c.pos);
				c.orderedStatics.unshift(f);
				c.statics.set(f.name, f);
			case _:
		}
	}

	// Member var initializers become constructor assignments.
	public static function addFieldInits(com:Context, tctx:TyperContext, renameLocals:Null<hxc.filters.RenameVars>, t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c):
				var ethis = TypeFunctions.mk(TConst(TThis), TInst(c, TypeFunctions.extractParamTypes(c.params)), c.pos);
				// The (never used) `_g` is allocated for every class, inits or not.
				TypeFunctions.allocVar(VGenerated, "_g", ethis.type, ethis.pos);
				var inits = [for (cf in c.orderedFields) if (cf.kind.match(Var(_)) && cf.expr != null) cf];
				// The init list is built by PREPENDING over the ordered fields with no re-reversal, so the
				// assignments emit in REVERSE declaration order.
				inits.reverse();
				if (inits.length == 0) return;
				var el = [for (cf in inits) {
					var lhs = TypeFunctions.mk(TField(TypeFunctions.mk(ethis.expr, ethis.type, cf.pos), FInstance(c, TypeFunctions.extractParamTypes(c.params), cf)), cf.type, cf.pos);
					var einit = cf.expr;
					cf.expr = null;
					TypeFunctions.mk(TBinop(OpAssign, lhs, einit), cf.type, einit.pos);
				}];
				var cf = if (c.constructor == null) {
					var ct = TypeFunctions.tfun([], com.basic.tvoid);
					var ce = TypeFunctions.mk(TFunction(new TFunc([], com.basic.tvoid, TypeFunctions.mk(TBlock(el), com.basic.tvoid, c.pos))), ct, c.pos);
					var ctor = TypeFunctions.mkField("new", ct, c.pos, Position.nullPos);
					ctor.kind = Method(MethNormal);
					ctor.expr = ce;
					ctor;
				} else {
					var cf = c.constructor;
					switch (cf.expr) {
						case {expr: TFunction(f)}:
							var bl = switch (f.expr.expr) {
								case TBlock(b): b;
								case _: [f.expr];
							};
							cf.expr = TypeFunctions.mk(TFunction(new TFunc(f.args, f.type, TypeFunctions.mk(TBlock(el.concat(bl)), com.basic.tvoid, c.pos))), cf.type, cf.pos);
							cf;
						case _:
							throw new TypingError("Constructor without function body", c.pos);
					}
				}
				// The merged constructor goes through the analyzer again
				var config = hxc.optimization.AnalyzerConfig.getFieldConfig(com, c, cf);
				TypeFunctions.removeClassFieldFlag(cf, CfPostProcessed);
				hxc.optimization.Analyzer.Run.runOnField(com, config, c, cf);
				TypeFunctions.addClassFieldFlag(cf, CfPostProcessed);
				if (cf.expr != null) {
					var e = cf.expr;
					if (renameLocals != null) hxc.filters.RenameVarsRun.run(renameLocals, e);
					cf.expr = Optimizer.sanitize(com, tctx, e);
				}
				c.constructor = cf;
			case _:
		}
	}

	public static function addMetaField(com:Context, t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c):
				var e = TexprTools.buildMetadata(com.basic, t);
				if (e == null) return;
				com.addFeature("has_metadata");
				var cf = TypeFunctions.mkField("__meta__", e.type, e.pos, Position.nullPos, true, true);
				cf.expr = e;
				c.orderedStatics.unshift(cf);
				c.statics.set(cf.name, cf);
			case _:
		}
	}

	public static function checkRemoveMetadata(t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c):
				c.interfaces = [for (i in c.interfaces) if (!TypeFunctions.hasMeta(":remove", i.c.meta)) i];
			case _:
		}
	}

	// Cpp only: interfaces have no super, so the first extended interface becomes superClass for
	// efficiency and the remaining ones stay implemented. interfaces is prepend-built, so index 0 is
	// the list head. Downstream cpp passes depend on the mutation: CppFixOverrides walks superClass,
	// which is how a sub-interface's redeclared method gets dropped.
	public static function promoteFirstInterfaceToSuper(t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c) if (TypeFunctions.hasClassFlag(c, CInterface) && c.interfaces.length > 0):
				var first = c.interfaces[0];
				if (first.c.path.pack.length == 2 && first.c.path.pack[0] == "cpp" && first.c.path.pack[1] == "rtti") return;
				c.superClass = first;
				c.interfaces = c.interfaces.slice(1);
			case _:
		}
	}

	public static function checkVoidField(t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c):
				function check(f:TClassField):Void {
					switch (TypeFunctions.follow(f.type)) {
						case TAbstract(a, _) if (a.path.pack.length == 0 && a.path.name == "Void"):
							throw new TypingError("Fields of type Void are not allowed", f.pos);
						case _:
					}
				}
				for (f in c.orderedFields) check(f);
				for (f in c.orderedStatics) check(f);
			case _:
		}
	}

	public static function checkReservedTypePaths(ctx:TyperContext, t:ModuleType):Void {
		// The platform's reserved type paths are empty for js and eval, so nothing to check yet
	}

	public static function iterExpressions(fl:Array<TExpr->Void>, mt:ModuleType):Void {
		switch (mt) {
			case TClassDecl(c):
				function field(cf:TClassField):Void {
					if (cf.expr != null) for (f in fl) f(cf.expr);
				}
				for (cf in c.orderedStatics) field(cf);
				for (cf in c.orderedFields) field(cf);
				if (c.constructor != null) field(c.constructor);
			case _:
		}
	}

	public static function handleAbstractCasts(ctx:TyperContext, e:TExpr):TExpr {
		function underlying(a:TAbstract, pl:Array<T>, p:Position):T {
			if (!TypeFunctions.hasMeta(":multiType", a.meta))
				return TypeFunctions.applyParams(a.params, pl, a.thisType);
			// A multiType abstract always attempts its specialization and only falls back to the declared
			// underlying when that fails, i.e. no @:to matched or a DEFINITIVE parameter still holds a
			// monomorph. A type parameter is not a monomorph, so `Map<String, V>` inside a generic class
			// resolves to StringMap<V> like any closed key; treating it as open would leave the call on IMap
			// and block the inline forward in Map.clear/toString.
			return try Typer.resolveMultiTypeConcrete(a, pl, p)
				catch (_:Dynamic) TypeFunctions.applyParams(a.params, pl, a.thisType);
		}
		function maybeCast(e:TExpr, t:T, p:Position):TExpr {
			return TypeUnification.typeIseqDefault(e.type, t) ? e : TypeFunctions.mk(TCast(e, null), t, p);
		}
		function funType(fa:TFieldAccess):{t:T, args:Array<hxc.core.Type.TSignatureArg>, ret:T} {
			var t = switch (fa) {
				case FStatic(_, cf): cf.type;
				case FInstance(c, tl, cf): TypeFunctions.applyParams(c.params, tl, cf.type);
				case FAnon(cf): cf.type;
				case _: throw new hxc.core.NotFound();
			};
			return switch (TypeFunctions.follow(t)) {
				case TFun(sig): {t: t, args: sig.args, ret: sig.ret};
				case _: throw new hxc.core.NotFound();
			}
		}
		function findAbstract(e:TExpr):{a:TAbstract, pl:Array<T>, e:TExpr} {
			return switch [TypeFunctions.follow(e.type), e.expr] {
				case [TAbstract(a, pl), _] if (TypeFunctions.hasMeta(":multiType", a.meta)):
					{a: a, pl: pl, e: e};
				case [_, TCast(e1, null)]:
					findAbstract(e1);
				case [_, TLocal(v)] if (v.extra != null && v.extra.expr != null):
					var found = findAbstract(v.extra.expr);
					{a: found.a, pl: found.pl, e: TypeFunctions.mk(TCast(e, null), found.e.type, e.pos)};
				case _:
					throw new hxc.core.NotFound();
			}
		}
		function loop(e:TExpr):TExpr {
			return switch (e.expr) {
				// Std.string of an abstract whose impl has a toString static becomes
				// `e1 == null ? "null" : Impl.toString(e1)`; the impl call routes through makeCall so an
				// inline
				// toString expands.
				case TCall({expr: TField(_, FStatic({path: {pack: [], name: "Std"}}, {name: "string"}))}, [se1])
						if (switch (TypeFunctions.follow(se1.type)) { case TAbstract(a, _): a.impl != null && a.impl.statics.exists("toString"); case _: false; }):
					switch (TypeFunctions.follow(se1.type)) {
						case TAbstract(a, _) if (a.impl != null):
							var c = a.impl;
							var cf = c.statics.get("toString");
							var se1 = loop(se1);
							var ret = ctx.com.basic.tstring;
							inline function call():TExpr {
								var fe = TexprTools.makeStaticField(c, cf, e.pos);
								return Calls.makeCall(ctx, fe, [se1], ret, e.pos);
							}
							if (!TypeFunctions.isNullable(se1.type)) call()
							else {
								var p = e.pos;
								var chkNull = TypeFunctions.mk(TBinop(OpEq, se1, TypeFunctions.mk(TConst(TNull), se1.type, p)), ctx.com.basic.tbool, p);
								TypeFunctions.mk(TIf(chkNull, TypeFunctions.mk(TConst(TString("null")), ret, p), call()), ret, p);
							}
						case _:
							TexprTools.mapExpr(loop, e);
					}
				case TCall(e1, el):
					try {
						function findField(ef:TExpr):TExpr {
							return switch (ef.expr) {
								case TCast(e2, null):
									TypeFunctions.mk(TCast(findField(e2), null), ef.type, ef.pos);
								case TField(e2, fa):
									var abs = findAbstract(e2);
									var e2 = loop(abs.e);
									var m = try underlying(abs.a, abs.pl, e2.pos) catch (_:Dynamic) throw new hxc.core.NotFound();
									var fname = TypeFunctions.fieldName(fa);
									// quickField fails when m is itself an abstract; the static-extension call is then
									// replicated on that abstract's impl, passing the receiver as the first argument.
									// Otherwise the call would resolve against the multiType's DECLARED underlying instead of
									// the specialization, skipping a member the specialization overrides (and whose body
									// ignores an argument).
									var fa2 = try TypeFunctions.quickField(m, fname) catch (_:Dynamic) {
										switch (TypeFunctions.follow(m)) {
											case TAbstract(a2, pl2) if (a2.impl != null && a2.impl.statics.exists(fname)):
												var cf2 = a2.impl.statics.get(fname);
												hxc.typing.TypeFields.forceFieldBody(ctx.com, a2.impl, cf2);
												var map2 = function(t:T) return TypeFunctions.applyParams(a2.params, pl2, t);
												var callee = TypeFunctions.mk(
													TField(TexprTools.makeTypeExpr(TClassDecl(a2.impl), e2.pos), FStatic(a2.impl, cf2)),
													map2(cf2.type), e2.pos);
												var args2 = [e2].concat([for (arg in el) loop(arg)]);
												return maybeCast(Calls.makeCall(ctx, callee, args2, e.type, e.pos), e.type, e.pos);
											case _:
										}
										throw new hxc.core.NotFound();
									};
									var ft = funType(fa2);
									var args = [for (arg in el) loop(arg)];
									// A @:multiType call is rebuilt against the CONCRETE implementation, so
									// every argument is cast to
									// that implementation's parameter type. Otherwise the argument keeps
									// the abstract's type, and later
									// passes that key on the expression SHAPE go wrong: the inliner would
									// see a bare local instead of a
									// TCast and substitute an argument it must bind to a temporary (the
									// TLocal arm versus the
									// read-count arm).
									if (TypeFunctions.hasMeta(":multiType", abs.a.meta)) {
										var origArgs = switch (TypeFunctions.follow(ef.type)) {
											case TFun(sig): sig.args;
											case _: null;
										};
										if (origArgs != null) {
											var casted = [];
											for (ai in 0...args.length) {
												// Once the concrete signature runs out the remaining arguments pass through
												if (ai >= ft.args.length) { casted.push(args[ai]); continue; }
												var at = ft.args[ai].t;
												// An unresolved parameter type keeps the ORIGINAL one when that was Dynamic
												if (ai < origArgs.length) switch (TypeFunctions.follow(at)) {
													case TMono(_):
														switch (TypeFunctions.follow(origArgs[ai].t)) {
															case TDynamic(_): at = origArgs[ai].t;
															case _:
														}
													case _:
												}
												casted.push(maybeCast(args[ai], at, args[ai].pos));
											}
											args = casted;
										}
									}
									var field = TypeFunctions.mk(TField(TypeFunctions.mk(e2.expr, m, e2.pos), fa2), ft.t, e2.pos);
									// makeCall inlines what already has a body and calls the rest. In the main pipeline the
									// concrete type's module usually loads at this FILTER, so its bodies are untyped and the
									// call stays a call (StringMap.get has no expression here); the macro world types whole
									// modules, so there an inline body such as eval's StringMap.keyValueIterator expands.
									// Nothing is forced for it.
									var calledCf = switch (fa2) {
										case FInstance(_, _, cf) | FStatic(_, cf) | FAnon(cf): cf;
										case _: null;
									};
									maybeCast(calledCf != null && calledCf.expr != null
										? Calls.makeCall(ctx, field, args, ft.ret, e.pos)
										: TypeFunctions.mk(TCall(field, args), ft.ret, e.pos), e.type, e.pos);
								case _:
									throw new hxc.core.NotFound();
							}
						}
						findField(e1);
					} catch (_:hxc.core.NotFound) {
						TexprTools.mapExpr(loop, e);
					}
				case _:
					TexprTools.mapExpr(loop, e);
			}
		}
		return loop(e);
	}

	public static function runEvalAbstractCasts(tctx:TyperContext):Void {
		for (t in tctx.com.types) FiltersCommon.runExpressionFilters(tctx, [
			{name: "AbstractCast.handle_abstract_casts", f: function(e) return handleAbstractCasts(tctx, e)}
		], t);
	}

	// The typer emits TNew of the abstract impl for every @:multiType construction; here it rewrites to
	// the selected @:to cast's static call with a null receiver prepended, and the result is typed as
	// the UNDERLYING concrete type. Specialization failures are typing errors, never swallowed.
	public static function resolveDeferredMultiType(tctx:TyperContext, e:TExpr):TExpr {
		return switch (e.expr) {
			case TNew(c, tl, el):
				switch (c.kind) {
					case KAbstractImpl(a) if (!TypeFunctions.hasMeta(":multiType", a.meta)):
						// This must have been a @:generic expansion with a { new } constraint; construct
						// the underlying
						// type.
						switch (TypeFunctions.getUnderlyingType(a, tl)) {
							case TInst(uc, utl): TypeFunctions.mk(TNew(uc, utl, el), TInst(uc, utl), e.pos);
							case _: throw new hxc.core.TypingError("Cannot construct "
								+ hxc.core.TPrinting.sTypeStr(TAbstract(a, tl)), e.pos);
						}
					case KAbstractImpl(a):
						var sel = hxc.typing.Typer.resolveMultiType(tctx, a, tl, e.pos);
						var call = hxc.typing.Typer.buildMultiTypeCastCall(tctx, a, tl, sel.castField, sel.castType, sel.ret, el, e.pos);
						TypeFunctions.mk(call.expr, sel.ret, call.pos);
					case _: e;
				}
			case _: e;
		}
	}

	// HXC_DBG_STAGES: wall time between the filter pipeline's stage boundaries, without the forced
	// collection memProbe does. --times reports "filters" as one bucket, and the per-filter timer only
	// covers the expression filters, so everything else (analyzer, DCE, destruction) was invisible.
	static var stageT0:Float = -1;
	public static var stageTimes:Array<{n:String, t:Float}> = [];
	public static function stageMark(tag:String):Void {
		if (Sys.getEnv("HXC_DBG_STAGES") == null) return;
		var now = haxe.Timer.stamp();
		if (stageT0 >= 0) stageTimes.push({n: tag, t: now - stageT0});
		stageT0 = now;
	}
	public static function dumpStages():Void {
		if (Sys.getEnv("HXC_DBG_STAGES") == null) return;
		var o = Sys.stderr();
		for (r in stageTimes) o.writeString("[stage] " + StringTools.lpad(Std.string(Std.int(r.t * 1000)), " ", 7) + "ms  " + r.n + "
");
		o.flush();
	}

	public static function memProbe(tag:String):Void {
		if (Sys.getEnv("HXC_DBG_MEM") == null) return;
		#if cpp
		// Forced major collection first: separates LIVE heap from garbage-awaiting-collection.
		cpp.vm.Gc.run(true);
		var o = Sys.stderr();
		// Immix accounts memory by ROWS IN USE, so a sparsely populated block counts whole.
		// Comparing usage before and after a compaction separates real retention from
		// fragmentation; they are very different bugs.
		if (Sys.getEnv("HXC_DBG_COMPACT") != null) {
			var before = cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE) / 1048576.0;
			var t0 = haxe.Timer.stamp();
			cpp.vm.Gc.compact();
			var ms = (haxe.Timer.stamp() - t0) * 1000;
			o.writeString("[compact] " + tag + " " + Std.int(before) + "MB -> "
				+ Std.int(cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE) / 1048576.0) + "MB in "
				+ Std.int(ms) + "ms\n");
		}
		o.writeString("[mem] " + tag + " used=" + Std.string(Std.int(cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE) / 1048576.0)) + "MB reserved=" + Std.string(Std.int(cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_RESERVED) / 1048576.0)) + "MB
");
		o.flush();
		#end
	}

	public static function run(tctx:TyperContext):Void {
		var com = tctx.com;
		// A cached type (reused from the server cache, already restored to its post-RenameVars snapshot)
		// skips the whole filter pipeline; only the destructive stages below re-run on it. The
		// inheritance graph registers for every type (DCE walks descendants to keep overrides of used
		// fields), and an uncached class snapshots exprUnoptimized so the next compilation inlines from
		// the original expression.
		var reuse = hxc.context.ServerCache.enabled;
		var newTypes:Array<ModuleType> = [];
		for (t in com.types) {
			var cached = reuse && isCached(com, t);
			switch (t) {
				case TClassDecl(cls):
					for (i in cls.interfaces) TypeFunctions.addDescendant(i.c, cls);
					if (cls.superClass != null) TypeFunctions.addDescendant(cls.superClass.c, cls);
				case _:
			}
			if (!cached) newTypes.push(t);
		}
		// A class without its own constructor inherits a forwarding one from its super, so the generator
		// emits the super call rather than an empty body. Done before the filters so the synthesized body
		// is
		// processed too.
		for (t in newTypes) switch (t) {
			case TClassDecl(cls): hxc.typing.Typer.ensureInheritedCtor(tctx, cls);
			case _:
		}
		{
			var hc = Sys.getEnv("HXC_DBG_HEAPCENSUS");
			if (hc != null) {
				var lim = Std.parseInt(hc);
				var cap = lim == null || lim <= 1 ? 60000000 : lim;
				hxc.debug.HeapCensus.run(com, "context", cap);
			}
		}
		hxc.core.PerfCount.walk(com);
		stageMark("filters:start"); memProbe("filters:start");
		// Inline from the original body on the next compilation, not the analyzer-transformed one.
		if (reuse) for (t in newTypes) switch (t) {
			case TClassDecl(cls):
				inline function fld(cf:TClassField) cf.exprUnoptimized = cf.expr;
				for (cf in cls.orderedFields) fld(cf);
				for (cf in cls.orderedStatics) fld(cf);
				if (cls.constructor != null) fld(cls.constructor);
			case _:
		}
		for (t in newTypes) FiltersCommon.runExpressionFilters(tctx, [
			{name: "ForRemap", f: function(e) return forRemap(tctx, e)},
			{name: "VarLazifier", f: function(e) return varLazifier(com, e)},
			{name: "resolve_deferred_multitype", f: function(e) return { function walk(e2:hxc.core.Type.TExpr):hxc.core.Type.TExpr return resolveDeferredMultiType(tctx, TexprTools.mapExpr(walk, e2)); walk(e); }},
			{name: "AbstractCast.handle_abstract_casts", f: function(e) return handleAbstractCasts(tctx, e)},
		], t);
		stageMark("pass1:done"); memProbe("pass1:done");
		var exceptionsFilter = hxc.filters.Exceptions.filter(tctx);
		for (t in newTypes) FiltersCommon.runExpressionFilters(tctx, [
			{name: "local_statics", f: function(e) return localStatics(tctx, e)},
			{name: "fix_return_dynamic_from_void_function", f: function(e) return fixReturnDynamicFromVoidFunction(tctx, true, e)},
			{name: "check_local_vars_init", f: function(e) return checkLocalVarsInit(tctx, e)},
			{name: "check_abstract_as_value", f: checkAbstractAsValue},
			// Tre runs only with analyzer-optimize
			{name: "Tre", f: com.defines.rawDefined("analyzer_optimize") ? hxc.filters.Tre.run(tctx) : function(e) return e},
			{name: "reduce_expression", f: function(e) return Optimizer.reduceExpression(tctx, e)},
			{name: "inline_constructors", f: function(e) return hxc.optimization.InlineConstructors.apply(tctx, e)},
			{name: "Exceptions_filter", f: exceptionsFilter},
			{name: "captured_vars", f: function(e) return hxc.filters.CapturedVars.capturedVars(com, e)},
		], t);
		stageMark("pass1b:done"); memProbe("pass1b:done");
		// UnusedPure (pure-statement elimination) runs after inline_constructors so the trailing
		// result-local read of an inlined value block reaches finalMap first (InlineConstructors unwraps
		// the
		// block on that read).
		hxc.typing.UnusedPure.run(com);
		// The analyzer runs between the pre-analyzer type filters and RenameVars
		if (!com.platform.match(Cross)) hxc.optimization.Analyzer.Run.runOnTypes(com, newTypes);
		stageMark("analyzer:done"); memProbe("analyzer:done");
		var renameLocals = hxc.filters.RenameVars.init(com.types, com.platform.match(Cpp),
			com.platform.match(Js) && com.getEsVersion() >= 6);
		for (t in newTypes) FiltersCommon.runExpressionFilters(tctx, [
			{name: "sanitize", f: function(e) return Optimizer.sanitize(com, tctx, e)},
			// add_final_return: adds a trailing default-valued return to a non-Void function that can fall
			// off
			// its end, so a static backend (cpp) emits a value on every path. Gated on addFinalReturn
			// (false for js/eval).
			{name: "add_final_return", f: com.platformConfig.addFinalReturn ? addFinalReturn : function(e) return e},
			// Eval keeps its names.
			{name: "RenameVars", f: com.platform.match(Eval) ? function(e) return e : function(e) {
				try hxc.filters.RenameVarsRun.run(renameLocals, e)
				catch (err:Dynamic) throw new TypingError(Std.string(err) + " in " + tctx.curclass.path.name + "." + tctx.curfield.name, e.pos);
				return e;
			}},
			{name: "mark_switch_break_loops", f: markSwitchBreakLoops},
		], t);
		stageMark("pass2:done"); memProbe("pass2:done");
		// The onGenerate callbacks run after the expression passes and before saveClassState/destruction,
		// so macro-side type mutation (e.g. cpp.cppia.HostClasses marking host classes extern) is invisible
		// to the expression filters.
		hxc.eval.EvalMacro.runGenerateCallbacks(com);
		// Save state: the typed snapshot the compilation server restores on reuse, with the signature-level
		// dependency registration that must precede it. Both run unconditionally, and the registration is
		// not only about the server: updateCacheDependencies binds any monomorph still OPEN in a signature
		// to Dynamic. Otherwise a function whose return type was inferred from a Dynamic would keep an open
		// mono forever - linking deliberately does not bind against Dynamic - and --xml would print it as
		// <unknown/> instead of <d/>.
		// Each type registers its dependencies and then saves its state, which marks every field
		// CfPostProcessed; the later passes that must still reach them pass ignoreProcessedStatus.
		for (t in newTypes) {
			updateCacheDependencies(com, t);
			saveClassState(com, t);
		}
		// After the save: onGenerate(f, false).
		hxc.eval.EvalMacro.runGenerateCallbacks(com, true);
		destruction(tctx, renameLocals);
		stageMark("destruction:done"); memProbe("destruction:done");
		FiltersCommon.dumpFilterTimes();
		stageMark("generation");
		hxc.typing.TypeFields.dumpTypeTimes();
		dumpStages();
	}

	// A module whose saveClassState ran in an earlier server request is cached; its types skip the
	// whole filter pipeline (their restored state is already post-RenameVars) and only the destructive
	// stages re-run. One-shot compiles never increment the step, so processed < 0-step is false and
	// nothing is ever cached.
	static function isCached(com:Context, t:ModuleType):Bool {
		var m = TypeFunctions.tInfos(t).module.extra;
		return m.processed != 0 && m.processed < hxc.context.ServerCache.compilationStep;
	}

	// Field SIGNATURES can reference modules the expression loads never touched; register them as
	// dependencies so the server's module check walks them. A still-open monomorph in a signature binds
	// to Dynamic here.
	static function updateCacheDependencies(com:Context, t:ModuleType):Void {
		var visitedAnons:Array<hxc.core.Type.TAnon> = [];
		function checkT(m:hxc.core.Type.ModuleDef, t:T):Void {
			switch (t) {
				case TInst(c, tl):
					hxc.context.ModuleLoader.addDependency(m, c.module);
					for (x in tl) checkT(m, x);
				case TEnum(en, tl):
					hxc.context.ModuleLoader.addDependency(m, en.module);
					for (x in tl) checkT(m, x);
				case TType(td, tl):
					hxc.context.ModuleLoader.addDependency(m, td.module);
					for (x in tl) checkT(m, x);
				case TAbstract(a, tl):
					hxc.context.ModuleLoader.addDependency(m, a.module);
					for (x in tl) checkT(m, x);
				case TFun(sig):
					for (a in sig.args) checkT(m, a.t);
					checkT(m, sig.ret);
				case TAnon(an):
					if (visitedAnons.indexOf(an) < 0) {
						visitedAnons.push(an);
						for (n in an.fields.keys()) checkT(m, an.fields.get(n).type);
					}
				case TMono(r):
					switch (r.type) {
						case null: TypeUnification.doBind(r, TypeFunctions.tDynamic);
						case some: checkT(m, some);
					}
				case TLazy(f):
					checkT(m, TypeFunctions.lazyType(f));
				case TDynamic(null):
				case TDynamic(t2):
					checkT(m, t2);
			}
		}
		function checkField(m:hxc.core.Type.ModuleDef, cf:TClassField):Void {
			checkT(m, cf.type);
			for (o in cf.overloads) checkField(m, o);
		}
		switch (t) {
			case TClassDecl(c):
				for (cf in c.orderedStatics) checkField(c.module, cf);
				for (cf in c.orderedFields) checkField(c.module, cf);
				if (c.constructor != null) checkField(c.module, c.constructor);
			case _:
		}
	}

	// Snapshot each type so the compilation server can restore it after the destructive stages (DCE
	// sweep, native path rewrite, generator mutations). The mutable arrays are captured as copies so the
	// snapshot cannot change.
	static function saveClassState(com:Context, t:ModuleType):Void {
		// Nothing may add a dependency after this point, or the module immediately reads as
		// uncached again.
		TypeFunctions.tInfos(t).module.extra.processed = hxc.context.ServerCache.compilationStep;
		switch (t) {
			case TClassDecl(c):
				var vars:Array<{v:TVar, t:T}> = [];
				function saveVars(e:TExpr):Void {
					switch (e.expr) {
						case TFunction(fn):
							for (a in fn.args) vars.push({v: a.v, t: a.v.type});
							saveVars(fn.expr);
						case TVarExpr(v, e1):
							vars.push({v: v, t: v.type});
							if (e1 != null) saveVars(e1);
						case _:
							TexprTools.iter(saveVars, e);
					}
				}
				function mkOverloadRestore(f:TClassField) {
					TypeFunctions.addClassFieldFlag(f, CfPostProcessed);
					return {name: f.name, kind: f.kind, expr: f.expr, t: f.type, meta: f.meta.copy(), params: f.params.copy()};
				}
				function mkFieldRestore(f:TClassField) {
					if (f.expr != null) saveVars(f.expr);
					return {f: f, res: mkOverloadRestore(f), overloads: [for (o in f.overloads) {f: o, res: mkOverloadRestore(o)}]};
				}
				function restoreOne(f:TClassField, r:{name:String, kind:FieldKind, expr:Null<TExpr>, t:T, meta:Metadata, params:TypeParams}):TClassField {
					f.name = r.name;
					f.kind = r.kind;
					f.expr = r.expr;
					f.type = r.t;
					f.meta = r.meta.copy();
					f.params = r.params.copy();
					return f;
				}
				var meta = c.meta.copy();
				var path = c.path;
				var ext = TypeFunctions.hasClassFlag(c, CExtern);
				var sup = c.superClass;
				var impl = c.interfaces.copy();
				var csr = c.constructor == null ? null : mkFieldRestore(c.constructor);
				var ofr = [for (f in c.orderedFields) mkFieldRestore(f)];
				var osr = [for (f in c.orderedStatics) mkFieldRestore(f)];
				var init = c.init;
				if (init != null) saveVars(init);
				c.restore = function() {
					function restoreField(fr:{f:TClassField, res:{name:String, kind:FieldKind, expr:Null<TExpr>, t:T, meta:Metadata, params:TypeParams}, overloads:Array<{f:TClassField, res:{name:String, kind:FieldKind, expr:Null<TExpr>, t:T, meta:Metadata, params:TypeParams}}>}):TClassField {
						var f = restoreOne(fr.f, fr.res);
						f.overloads = [for (o in fr.overloads) restoreOne(o.f, o.res)];
						return f;
					}
					c.superClass = sup;
					c.interfaces = impl.copy();
					c.meta = meta.copy();
					if (ext) TypeFunctions.addClassFlag(c, CExtern) else TypeFunctions.removeClassFlag(c, CExtern);
					c.path = path;
					c.init = init;
					c.orderedFields = [for (fr in ofr) restoreField(fr)];
					c.orderedStatics = [for (fr in osr) restoreField(fr)];
					var fm = new StringMap<TClassField>();
					for (f in c.orderedFields) fm.set(f.name, f);
					c.fields = fm;
					var sm = new StringMap<TClassField>();
					for (f in c.orderedStatics) sm.set(f.name, f);
					c.statics = sm;
					c.constructor = csr == null ? null : restoreField(csr);
					c.descendants = [];
					for (x in vars) x.v.type = x.t;
				};
			case TEnumDecl(en):
				var path = en.path;
				en.restore = function() {
					// The :realPath meta records a native-path rewrite; restoring pops it back.
					var acc:Metadata = [];
					var rest = en.meta;
					var done = false;
					for (i in 0...rest.length) {
						var x = rest[i];
						if (x.name == ":realPath") switch (x.params) {
							case [{expr: EConst(CString(s, _))}]:
								en.path = hxc.ast.Ast.parsePath(s);
								en.meta = acc.concat(rest.slice(i + 1));
								done = true;
								break;
							case _: acc.push(x);
						} else acc.push(x);
					}
					if (!done) en.path = path;
				};
			case TTypeDecl(td):
				var path = td.path;
				td.restore = function() td.path = path;
			case TAbstractDecl(a):
				var path = a.path;
				a.restore = function() {
					a.path = path;
					a.meta = [for (m in a.meta) if (m.name != ":valueUsed") m];
				};
		}
	}

	// The type filters around DCE
	static function destruction(tctx:TyperContext, renameLocals:Null<hxc.filters.RenameVars>):Void {
		var com = tctx.com;
		for (t in com.types) {
			removeGenericBase(t);
			removeExternFields(com, t);
			checkRemoveMetadata(t);
		}
		// Re-register the inheritance graph: the exceptions filter can load types after the first
		// registration (addDescendant dedups)
		for (t in com.types) switch (t) {
			case TClassDecl(cls):
				for (i in cls.interfaces) TypeFunctions.addDescendant(i.c, cls);
				if (cls.superClass != null) TypeFunctions.addDescendant(cls.superClass.c, cls);
			case _:
		}
		// DCE: mode from the dce define; full downgrades to no under interp.
		// Feature collection runs in every mode.
		var dceMode:hxc.optimization.Dce.DceMode = switch (com.defines.rawDefinedValueSafe("dce", "no")) {
			case "full": com.defines.rawDefined("interp") ? DceNo : DceFull;
			case "std": DceStd;
			case "no": DceNo;
			case other: throw new TypingError("Unknown DCE mode " + other, Position.nullPos);
		};
		hxc.optimization.Dce.stdPath = com.stdPath;
		if (com.defines.rawDefined("dce_debug")) com.print = function(s) Sys.stderr().writeString(s);
		stageMark("preDce"); memProbe("preDce");
		hxc.optimization.Dce.run(com, dceMode);
		stageMark("dce:done"); memProbe("dce:done");
		// PASS 3: insert_save_stacks runs first (post-DCE so the feature flag is accurate), then
		// patchConstructors with the other type filters. Both run after the analyzer and
		// sanitize, so the blocks their inlined calls produce reach the generator untouched.
		var saveStacks = hxc.filters.Exceptions.insertSaveStacks(tctx);
		// This pass alone ignores the processed status. Otherwise a field reused from the server cache
		// still carries CfPostProcessed from the compilation that produced it, so runExpressionFilters
		// would skip it and the catch would never get its haxe.NativeStackTrace.saveStack call.
		for (t in com.types) FiltersCommon.runExpressionFilters(tctx, [{name: "insert_save_stacks", f: saveStacks}], t, true);
		hxc.typing.ExceptionFilters.run(com);
		for (t in com.types) {
			switch (t) {
				case TClassDecl(c): tctx.curclass = c;
				case _:
			}
			checkPrivatePath(tctx, t);
			applyNativePaths(com, t);
			addRtti(com, t);
			addFieldInits(com, tctx, renameLocals, t);
			addMetaField(com, t);
			checkVoidField(t);
			if (com.platform == Cpp) promoteFirstInterfaceToSuper(t);
			commitFeaturesOf(com, t);
			checkReservedTypePaths(tctx, t);
		}
		// After field inits have materialized the compiler-generated super constructors, insert an
		// auto super() into any explicit constructor that omits it.
		for (t in com.types) switch (t) {
			case TClassDecl(c): insertMissingSuper(com, c);
			case _:
		}
	}

	// A class with an explicit constructor whose body never calls super, when the superclass has a
	// compiler-generated (no required argument) constructor, gets an auto super() prepended so the
	// inherited field initializers run. The walk does not descend into a nested TFunction, so a super
	// call made from a closure does not satisfy the constructor. Typer.typeFunction shares it for the
	// missing-super report.
	public static function bodyCallsSuper(e:TExpr):Bool {
		return switch (e.expr) {
			case TCall({expr: TConst(TSuper)}, _): true;
			case TFunction(_): false;
			case _:
				var found = false;
				TexprTools.iter(function(x) if (!found && bodyCallsSuper(x)) found = true, e);
				found;
		}
	}

	static function insertMissingSuper(com:Context, c:TClass):Void {
		if (c.constructor == null || c.superClass == null) return;
		var sup = try TypeFunctions.getConstructorClass(c.superClass.c, [for (x in c.superClass.params) x]) catch (_:hxc.core.NotFound) return;
		if (!TypeFunctions.hasMeta(":compilerGenerated", sup.cf.meta)) return;
		switch (TypeFunctions.follow(sup.cf.type)) {
			case TFun(sig) if (Lambda.exists(sig.args, function(a) return !a.opt)): return;
			case _:
		}
		var cf = c.constructor;
		switch (cf.expr) {
			case {expr: TFunction(f)} if (!bodyCallsSuper(f.expr)):
				var tvoid = com.basic.tvoid;
				// The injected super call sits at the constructor body position (e.pos), not the class
				// declaration, so its stack frame line is the new line.
				var superPos = f.expr.pos;
				var superCall = TypeFunctions.mk(TCall(TypeFunctions.mk(TConst(TSuper), TInst(c.superClass.c, c.superClass.params), superPos), []), tvoid, superPos);
				var body = TypeFunctions.concat(superCall, f.expr);
				// The TFunction node keeps the body position it was typed at; rebuilding it here must not
				// move it
				// onto the field declaration.
				cf.expr = TypeFunctions.mk(TFunction(new TFunc(f.args, f.type, body)), cf.type, cf.expr.pos);
			case _:
		}
	}

	static function commitFeaturesOf(com:Context, t:ModuleType):Void {
		com.commitFeatures(t);
	}
}
