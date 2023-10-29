package hxc.filters;

// hxc.filters.Filters: the filter pipeline (the analyzer, DCE, RenameVars and Exceptions stages
// live in their own modules)

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.Globals;
import hxc.context.Context;
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
					if (el.length == 0) e
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
			c.orderedStatics.push(cf);
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
							ctx.com.warning(WVarInit, [], msg, e.pos);
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
			var nn = try hxc.codegen.Codegen.getNativeName(com, meta) catch (_:hxc.core.NotFound) return null;
			return {meta: {name: ":realPath", params: [new Expr(EConst(CString(name, SDoubleQuotes)), nn.pos)], pos: nn.pos}, name: nn.name};
		}
		function getRealPath(meta:Metadata, path:hxc.core.Globals.Path):Null<{meta:MetadataEntry, path:hxc.core.Globals.Path}> {
			var nn = try hxc.codegen.Codegen.getNativeName(com, meta) catch (_:hxc.core.NotFound) return null;
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

	// The XML payload needs the genxml port; error loudly rather than emit a wrong string.
	public static function addRtti(com:Context, t:ModuleType):Void {
		function hasRtti(c:TClass):Bool {
			return TypeFunctions.hasMeta(":rtti", c.meta) || (c.superClass != null && hasRtti(c.superClass.c));
		}
		switch (t) {
			case TClassDecl(c) if (hasRtti(c) && !c.statics.exists("__rtti")):
				throw new TypingError("@:rtti is not supported yet (genxml is not ported)", c.pos);
			case _:
		}
	}

	// Member var initializers become constructor assignments.
	public static function addFieldInits(com:Context, tctx:TyperContext, t:ModuleType):Void {
		switch (t) {
			case TClassDecl(c):
				var ethis = TypeFunctions.mk(TConst(TThis), TInst(c, TypeFunctions.extractParamTypes(c.params)), c.pos);
				var inits = [for (cf in c.orderedFields) if (cf.kind.match(Var(_)) && cf.expr != null) cf];
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
				if (cf.expr != null)
					cf.expr = Optimizer.sanitize(com, tctx, cf.expr);
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

	// The ordered filter driver. Stage slots that have their own rows (Tre, InlineConstructors,
	// Exceptions, analyzer, RenameVars, DCE) are marked below and join this order as they land.
	public static function run(tctx:TyperContext):Void {
		var com = tctx.com;
		var newTypes = com.types;
		// Register the inheritance graph first; DCE walks descendants to keep overrides of used fields
		for (t in newTypes) switch (t) {
			case TClassDecl(cls):
				for (i in cls.interfaces) TypeFunctions.addDescendant(i.c, cls);
				if (cls.superClass != null) TypeFunctions.addDescendant(cls.superClass.c, cls);
			case _:
		}
		for (t in newTypes) FiltersCommon.runExpressionFilters(tctx, [
			// Slot: ForRemap (the typer lowers for loops; GenJS handles residual TFor)
			{name: "VarLazifier", f: function(e) return varLazifier(com, e)},
			// Slot: AbstractCast.handle_abstract_casts (hxc types abstract casts during typing)
		], t);
		var exceptionsFilter = hxc.filters.Exceptions.filter(tctx);
		for (t in newTypes) FiltersCommon.runExpressionFilters(tctx, [
			{name: "local_statics", f: function(e) return localStatics(tctx, e)},
			{name: "fix_return_dynamic_from_void_function", f: function(e) return fixReturnDynamicFromVoidFunction(tctx, true, e)},
			{name: "check_local_vars_init", f: function(e) return checkLocalVarsInit(tctx, e)},
			{name: "check_abstract_as_value", f: checkAbstractAsValue},
			// Slot: Tre (tail recursion elimination, gated on analyzer-optimize)
			{name: "reduce_expression", f: function(e) return Optimizer.reduceExpression(tctx, e)},
			// Slot: inline_constructors
			{name: "Exceptions_filter", f: exceptionsFilter},
			{name: "captured_vars", f: function(e) return hxc.filters.CapturedVars.capturedVars(com, e)},
		], t);
		// Slot: Analyzer.Run.run_on_types PASS 2
		var renameLocals = hxc.filters.RenameVars.init(com.types);
		for (t in newTypes) FiltersCommon.runExpressionFilters(tctx, [
			{name: "sanitize", f: function(e) return Optimizer.sanitize(com, tctx, e)},
			// add_final_return: addFinalReturn is false for js
			{name: "RenameVars", f: function(e) {
				try hxc.filters.RenameVarsRun.run(renameLocals, e)
				catch (err:Dynamic) throw new TypingError(Std.string(err) + " in " + tctx.curclass.path.name + "." + tctx.curfield.name, e.pos);
				return e;
			}},
			{name: "mark_switch_break_loops", f: markSwitchBreakLoops},
		], t);
		// Slot: onGenerate callbacks + save_class_state (server cache; single-shot hxc skips)
		destruction(tctx);
	}

	// The type filters around DCE
	static function destruction(tctx:TyperContext):Void {
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
		hxc.optimization.Dce.run(com, dceMode);
		// PASS 3: type filters post-DCE
		// slot: Exceptions.insert_save_stacks, Exceptions.patch_constructors
		for (t in com.types) {
			switch (t) {
				case TClassDecl(c): tctx.curclass = c;
				case _:
			}
			checkPrivatePath(tctx, t);
			applyNativePaths(com, t);
			addRtti(com, t);
			addFieldInits(com, tctx, t);
			addMetaField(com, t);
			checkVoidField(t);
			commitFeaturesOf(com, t);
			checkReservedTypePaths(tctx, t);
		}
	}

	static function commitFeaturesOf(com:Context, t:ModuleType):Void {
		com.commitFeatures(t);
	}
}
