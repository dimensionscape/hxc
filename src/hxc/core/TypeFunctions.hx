package hxc.core;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Ref;
import hxc.core.Type;
import hxc.core.Globals.Path;
import hxc.core.NotFound;
import hxc.core.ExitException;
import haxe.ds.StringMap;
import haxe.Int32;

/** Typedef recursion breaker in apply_params. */
class ApplyParamsRecursion extends haxe.Exception {
	public function new() super("ApplyParamsRecursion");
}

class TypeFunctions {
	// These have minimal but correct defaults until unification installs its own.
	// monomorphCreateRef makes a fresh, unbound monomorph cell.
	public static var monomorphCreateRef:Void->TMono = function() {
		return new TMono(null, [], []);
	};
	// monomorphBindRef binds a monomorph to a type in place. The unification version also discharges
	// constraints; the structural default just sets type.
	public static var monomorphBindRef:TMono->T->Void = function(m:TMono, t:T) {
		m.type = t;
	};
	// monomorphClassifyConstraintsRef - not needed by the functions implemented here; stub.
	public static var monomorphClassifyConstraintsRef:TMono->TMonoConstraintKind = function(m:TMono) {
		return CUnknown;
	};

	public static function hasMeta(m:String, ml:Metadata):Bool {
		for (entry in ml) if (entry.name == m) return true;
		return false;
	}

	public static function getMeta(m:String, ml:Metadata):MetadataEntry {
		for (entry in ml) if (entry.name == m) return entry;
		throw new NotFound("TypeFunctions.hx:41");
	}

	// Null for absence. The throwing form above throws NotFound; probes that
	// EXPECT absence (the per-field :native/:value lookups, which nearly always miss) paid a
	// ~1.3us hxcpp throw per miss, 12926 of them per unit-suite compile.
	public static function getMetaOpt(m:String, ml:Metadata):Null<MetadataEntry> {
		for (entry in ml) if (entry.name == m) return entry;
		return null;
	}

	// Type.Flags already provides hasFlag/setFlag/unsetFlag over a bit index.
	public static inline function hasFlag(flags:Int, flag:Int):Bool return Flags.hasFlag(flags, flag);
	public static inline function setFlag(flags:Int, flag:Int):Int return Flags.setFlag(flags, flag);
	public static inline function unsetFlag(flags:Int, flag:Int):Int return Flags.unsetFlag(flags, flag);

	public static inline function intOfClassFlag(flag:FlagTClass):Int return flag.getIndex();

	public static function addClassFlag(c:TClass, flag:FlagTClass):Void
		c.flags = setFlag(c.flags, intOfClassFlag(flag));

	public static function removeClassFlag(c:TClass, flag:FlagTClass):Void
		c.flags = unsetFlag(c.flags, intOfClassFlag(flag));

	public static function hasClassFlag(c:TClass, flag:FlagTClass):Bool
		return hasFlag(c.flags, intOfClassFlag(flag));

	public static inline function intOfClassFieldFlag(flag:FlagTClassField):Int return flag.getIndex();

	public static function addClassFieldFlag(cf:TClassField, flag:FlagTClassField):Void
		cf.flags = setFlag(cf.flags, intOfClassFieldFlag(flag));

	public static function removeClassFieldFlag(cf:TClassField, flag:FlagTClassField):Void
		cf.flags = unsetFlag(cf.flags, intOfClassFieldFlag(flag));

	public static function hasClassFieldFlag(cf:TClassField, flag:FlagTClassField):Bool
		return hasFlag(cf.flags, intOfClassFieldFlag(flag));

	public static inline function intOfVarFlag(flag:FlagTVar):Int return flag.getIndex();

	public static function addVarFlag(v:TVar, flag:FlagTVar):Void
		v.flags = setFlag(v.flags, intOfVarFlag(flag));

	public static function removeVarFlag(v:TVar, flag:FlagTVar):Void
		v.flags = unsetFlag(v.flags, intOfVarFlag(flag));

	public static function hasVarFlag(v:TVar, flag:FlagTVar):Bool
		return hasFlag(v.flags, intOfVarFlag(flag));

	static var _uid:Int = 0;

	public static function allocVar(kind:TVarKind, n:String, t:T, p:Position):TVar {
		_uid++;
		var flags = switch (kind) {
			case VUser(TVOLocalFunction): intOfVarFlag(VFinal); // Stores the raw index here
			case _: 0;
		};
		return new TVar(_uid, n, t, kind, null, [], flags, p);
	}

	static var _mid:Int = 0;
	public static function allocMid():Int {
		_mid++;
		return _mid;
	}

	public static function mk(e:TExprExpr, t:T, p:Position):TExpr {
		return new TExpr(e, t, p);
	}

	public static function mkBlock(e:TExpr):TExpr {
		return switch (e.expr) {
			case TBlock(_): e;
			case _: mk(TBlock([e]), e.type, e.pos);
		}
	}

	public static function mkCast(e:TExpr, t:T, p:Position):TExpr {
		return mk(TCast(e, null), t, p);
	}

	public static function nullExpr(t:T, p:Position):TExpr {
		return mk(TConst(TNull), t, p);
	}

	public static function mkMono():T {
		return TMono(monomorphCreateRef());
	}

	public static var tDynamic(default, null):T = TDynamic(null);

	public static var tDynamicDef:Ref<T> = new Ref<T>(TDynamic(null));

	public static function mkAnon(status:Ref<AnonStatus>, ?fields:StringMap<TClassField>):T {
		var f = fields == null ? new StringMap<TClassField>() : fields;
		return TAnon({fields: f, status: status});
	}

	public static function tfun(pl:Array<T>, r:T):T {
		var args:Array<TSignatureArg> = [for (t in pl) {name: "", opt: false, t: t}];
		return TFun({args: args, ret: r});
	}

	public static function funArgs(l:Array<{name:String, c:Null<Dynamic>, t:T}>):Array<TSignatureArg> {
		return [for (a in l) {name: a.name, opt: a.c != null, t: a.t}];
	}

	public static function mkClass(m:ModuleDef, path:Path, pos:Position, name_pos:Position):TClass {
		return {
			path: path,
			module: m,
			pos: pos,
			namePos: name_pos,
			doc: null,
			meta: [],
			isPrivate: false,
			kind: KNormal,
			flags: 0,
			params: [],
			usings: [],
			superClass: null,
			interfaces: [],
			fields: new StringMap<TClassField>(),
			orderedStatics: [],
			orderedFields: [],
			statics: new StringMap<TClassField>(),
			dynamicType: null,
			arrayAccess: null,
			constructor: null,
			init: null,
			build: function() return Built,
			restore: function() {},
			descendants: []
		};
	}

	public static function mkTypedef(m:ModuleDef, path:Path, pos:Position, name_pos:Position, t:T):TDef {
		return {
			path: path,
			module: m,
			pos: pos,
			namePos: name_pos,
			isPrivate: false,
			doc: null,
			meta: [],
			params: [],
			usings: [],
			type: t,
			restore: function() {}
		};
	}

	public static function moduleExtra(file:String, sign:String, time:Float, kind:ModuleKind, policy:Array<ModuleCheckPolicy>):ModuleDefExtra {
		return {
			file: file,
			sign: sign,
			display: {
				inlineCalls: [],
				typeHints: [],
				importPositions: []
			},
			cacheState: MSGood,
			added: 0,
			checked: 0,
			time: time,
			processed: 0,
			deps: new Map(),
			kind: kind,
			bindedRes: new StringMap(),
			ifFeature: [],
			features: new StringMap(),
			checkPolicy: policy
		};
	}

	public static function mkField(name:String, t:T, p:Position, name_pos:Position, isPublic:Bool = true, isStatic:Bool = false):TClassField {
		var flags = isStatic ? setFlag(0, intOfClassFieldFlag(CfStatic)) : 0;
		if (isPublic) flags = setFlag(flags, intOfClassFieldFlag(CfPublic));
		return {
			name: name,
			type: t,
			pos: p,
			namePos: name_pos,
			doc: null,
			meta: [],
			kind: Var({read: AccNormal, write: AccNormal}),
			expr: null,
			exprUnoptimized: null,
			params: [],
			overloads: [],
			flags: flags
		};
	}

	public static var nullModule(get, never):ModuleDef;
	static var _nullModule:ModuleDef = null;
	static function get_nullModule():ModuleDef {
		if (_nullModule == null) {
			_nullModule = {
				id: allocMid(),
				path: {pack: [], name: ""},
				types: [],
				statics: null,
				extra: moduleExtra("", "", 0.0, MFake, [])
			};
		}
		return _nullModule;
	}

	public static var nullClass(get, never):TClass;
	static var _nullClass:TClass = null;
	static function get_nullClass():TClass {
		if (_nullClass == null) {
			var c = mkClass(nullModule, {pack: [], name: ""}, Position.nullPos, Position.nullPos);
			c.isPrivate = true;
			_nullClass = c;
		}
		return _nullClass;
	}

	public static var nullField(get, never):TClassField;
	static var _nullField:TClassField = null;
	static function get_nullField():TClassField {
		if (_nullField == null) _nullField = mkField("", tDynamic, Position.nullPos, Position.nullPos);
		return _nullField;
	}

	public static var nullAbstract(get, never):TAbstract;
	static var _nullAbstract:TAbstract = null;
	static function get_nullAbstract():TAbstract {
		if (_nullAbstract == null) {
			_nullAbstract = {
				path: {pack: [], name: ""},
				module: nullModule,
				pos: Position.nullPos,
				namePos: Position.nullPos,
				isPrivate: true,
				doc: null,
				meta: [],
				params: [],
				usings: [],
				restore: function() {},
				ops: [],
				unops: [],
				impl: null,
				thisType: tDynamic,
				from: [],
				fromField: [],
				to: [],
				toField: [],
				array: [],
				read: null,
				write: null,
				call: null,
				isEnum: false
			};
		}
		return _nullAbstract;
	}

	public static function addDependency(m:ModuleDef, mdep:ModuleDef, skip_postprocess:Bool = false):Void {
		if (m != nullModule && m != mdep) {
			m.extra.deps.set(mdep.id, mdep);
			// A new dependency invalidates the RESOLVE gate (a later resolveModule re-runs), not the
			// save_class_state cache mark (processed). The reference's save_class_state comment is explicit
			// that nothing may add a dependency after the save without making the module read as uncached;
			// here the split keeps the cache mark intact so a reused module's dependencies (added while
			// re-typing a dirty root above it) do not force it back through the filters.
			if (!skip_postprocess) {
				m.extra.resolved = 0;
				// Also clears the POST-PROCESSING mark, so a module served back from the cache runs through the
				// filters again now that its dependency set changed (issue #10635) - and its save_class_state
				// snapshot is retaken, which keeps a @:generic specialization another module added to it.
				m.extra.processed = 0;
			}
		}
	}

	public static function argName(a:TFuncArg):String return a.v.name;

	public static function tInfos(t:ModuleType):TInfos {
		return switch (t) {
			case TClassDecl(c):
				{
					path: c.path, module: c.module, pos: c.pos, namePos: c.namePos,
					isPrivate: c.isPrivate, doc: c.doc, meta: c.meta, params: c.params,
					usings: c.usings, restore: c.restore
				};
			case TEnumDecl(e):
				{
					path: e.path, module: e.module, pos: e.pos, namePos: e.namePos,
					isPrivate: e.isPrivate, doc: e.doc, meta: e.meta, params: e.params,
					usings: e.usings, restore: e.restore
				};
			case TTypeDecl(td):
				{
					path: td.path, module: td.module, pos: td.pos, namePos: td.namePos,
					isPrivate: td.isPrivate, doc: td.doc, meta: td.meta, params: td.params,
					usings: td.usings, restore: td.restore
				};
			case TAbstractDecl(a):
				{
					path: a.path, module: a.module, pos: a.pos, namePos: a.namePos,
					isPrivate: a.isPrivate, doc: a.doc, meta: a.meta, params: a.params,
					usings: a.usings, restore: a.restore
				};
		}
	}

	public static function tPath(t:ModuleType):Path return tInfos(t).path;

	public static function extendsClass(c:TClass, csup:TClass):Bool {
		if (c == csup) return true;
		for (i in c.interfaces) if (extendsClass(i.c, csup)) return true;
		return switch (c.superClass) {
			case null: false;
			case s: extendsClass(s.c, csup);
		}
	}

	// Records a descendant of C, once: heritage is re-resolved across the std body-typing loop, so a
	// duplicate is skipped rather than accumulating combinatorially.
	public static function addDescendant(c:TClass, descendant:TClass):Void {
		for (d in c.descendants) if (d == descendant) return;
		c.descendants.unshift(descendant);
	}

	public static function lazyType(f:Ref<TLazy>):T {
		return switch (f.get()) {
			case LAvailable(t): t;
			case LProcessing(fn) | LWait(fn): fn();
		}
	}

	public static function lazyAvailable(t:T):TLazy return LAvailable(t);
	public static function lazyProcessing(f:Void->T):TLazy return LProcessing(f);
	public static function lazyWait(f:Void->T):TLazy return LWait(f);

	// Copies a type, replacing each distinct unbound monomorph with a fresh one (memoized so shared monos
	// stay shared).
	public static function duplicate(t:T):T {
		var monos:Array<{src:TMono, copy:T}> = [];
		function loop(t:T):T {
			return switch (t) {
				case TMono(r) if (r.type == null):
					var found:Null<T> = null;
					for (m in monos) if (m.src == r) { found = m.copy; break; }
					if (found != null) found else {
						var m = mkMono();
						monos.push({src: r, copy: m});
						m;
					}
				case _:
					map(loop, t);
			}
		}
		return loop(t);
	}

	// Map loop t - applies loop to component types, rebuilding t (sharing-preserving on []).
	public static function map(loop:T->T, t:T):T {
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case null: t;
					case some: loop(some);
				}
			case TEnum(_, []) | TInst(_, []) | TType(_, []) | TAbstract(_, []):
				t;
			case TEnum(e, tl):
				TEnum(e, [for (x in tl) loop(x)]);
			case TInst(c, tl):
				TInst(c, [for (x in tl) loop(x)]);
			case TType(t2, tl):
				TType(t2, [for (x in tl) loop(x)]);
			case TAbstract(a, tl):
				TAbstract(a, [for (x in tl) loop(x)]);
			case TFun(sig):
				TFun({args: [for (arg in sig.args) {name: arg.name, opt: arg.opt, t: loop(arg.t)}], ret: loop(sig.ret)});
			case TAnon(a):
				var fields = new StringMap<TClassField>();
				for (k in a.fields.keys()) {
					var f = a.fields.get(k);
					fields.set(k, withCfType(f, loop(f.type)));
				}
				mkAnon(a.status, fields);
			case TLazy(f):
				var ft = lazyType(f);
				var ft2 = loop(ft);
				if (ft == ft2) t else ft2;
			case TDynamic(null):
				t;
			case TDynamic(t2):
				TDynamic(loop(t2));
		}
	}

	public static function iter(loop:T->Void, t:T):Void {
		switch (t) {
			case TMono(r):
				switch (r.type) {
					case null:
					case some: loop(some);
				}
			case TEnum(_, []) | TInst(_, []) | TType(_, []):
			case TEnum(_, tl) | TInst(_, tl) | TType(_, tl) | TAbstract(_, tl):
				for (x in tl) loop(x);
			case TFun(sig):
				for (arg in sig.args) loop(arg.t);
				loop(sig.ret);
			case TAnon(a):
				for (f in a.fields) loop(f.type);
			case TLazy(f):
				loop(lazyType(f));
			case TDynamic(null):
			case TDynamic(t2):
				loop(t2);
		}
	}

	// Shallow clone of a class field (a fresh record with the same fields). Used by
	// to build a per-`@:overload` field carrying its own type.
	public static function copyField(f:TClassField):TClassField {
		return {
			name: f.name, type: f.type, pos: f.pos, namePos: f.namePos,
			doc: f.doc, meta: f.meta, kind: f.kind, params: f.params,
			expr: f.expr, exprUnoptimized: f.exprUnoptimized, overloads: f.overloads,
			flags: f.flags
		};
	}

	static function withCfType(f:TClassField, t:T):TClassField {
		return {
			name: f.name, type: t, pos: f.pos, namePos: f.namePos,
			doc: f.doc, meta: f.meta, kind: f.kind, params: f.params,
			expr: f.expr, exprUnoptimized: f.exprUnoptimized, overloads: f.overloads,
			flags: f.flags
		};
	}

	public static var applyParamsStack:Ref<Array<{subject:T, applied:TParams}>> = new Ref([]);

	// Thread the stack so a self-referential
	// typedef expansion raises ApplyParamsRecursion, which is absorbed here as success.
	public static function tryApplyParamsRec(cparams:TypeParams, params:TParams, t:T, success:T->Void):Void {
		var old = applyParamsStack.get();
		try {
			success(applyParams(cparams, params, t, applyParamsStack));
			applyParamsStack.set(old);
		} catch (e:ApplyParamsRecursion) {
			applyParamsStack.set(old);
		} catch (e:haxe.Exception) {
			applyParamsStack.set(old);
			throw e;
		}
	}

	public static var napply:Int = 0;
	public static function applyParams(cparams:TypeParams, params:TParams, t:T, ?stack:Ref<Array<{subject:T, applied:TParams}>>):T {
		napply++;
		if (cparams.length == 0) return t;

		// Build substitutions, forcing lazy parameter types on the cparam side.
		var subst:Array<{from:T, to:T}> = [];
			{
				var i1 = 0, i2 = 0;
				while (i1 < cparams.length) {
					if (i2 >= params.length) throw "apply_params: arity mismatch";
					var tp = cparams[i1];
					// A lazy parameter type is forced before it goes into the substitution.
					var fromT = switch (tp.type) { case TLazy(f): lazyType(f); case other: other; };
					subst.push({from: fromT, to: params[i2]});
					i1++;
					i2++;
				}
				if (i2 != params.length) throw "apply_params: arity mismatch"; // Die on unequal lengths
			}

		function assq(x:T):Null<{from:T, to:T}> {
			for (e in subst) if (e.from == x) return e;
			return null;
		}

		function loop(t:T):T {
			var hit = assq(t);
			if (hit != null) return hit.to;
			return switch (t) {
				case TMono(r):
					switch (r.type) {
						case null: t;
						case some: loop(some);
					}
				case TEnum(e, tl):
					switch (tl) {
						case []: t;
						case _: TEnum(e, [for (x in tl) loop(x)]);
					}
				case TType(t2, tl):
					switch (tl) {
						case []: t;
						case _:
							var newApplied = [for (x in tl) loop(x)];
							if (stack != null) {
								for (entry in stack.get()) {
									if (entry.subject == t && entry.applied == params) throw new ApplyParamsRecursion();
								}
								stack.set([{subject: t, applied: newApplied}].concat(stack.get()));
							}
							TType(t2, newApplied);
					}
				case TAbstract(a, tl):
					switch (tl) {
						case []: t;
						case _: TAbstract(a, [for (x in tl) loop(x)]);
					}
				case TInst(c, tl):
					switch (tl) {
						case []:
							t;
						case [TMono(r)]:
							switch (r.type) {
								case some if (t == some):
									var pt = mkMono();
									var t2 = TInst(c, [pt]);
									switch (pt) {
										case TMono(r2): monomorphBindRef(r2, t2);
										case _: throw "apply_params: expected TMono";
									}
									t2;
								case _: TInst(c, [for (x in tl) loop(x)]);
							}
						case _:
							TInst(c, [for (x in tl) loop(x)]);
					}
				case TFun(sig):
					TFun({args: [for (arg in sig.args) {name: arg.name, opt: arg.opt, t: loop(arg.t)}], ret: loop(sig.ret)});
				case TAnon(a):
					var fields = new StringMap<TClassField>();
					for (k in a.fields.keys()) {
						var f = a.fields.get(k);
						fields.set(k, withCfType(f, loop(f.type)));
					}
					mkAnon(a.status, fields);
				case TLazy(f):
					var ft = lazyType(f);
					var ft2 = loop(ft);
					if (ft == ft2) t else ft2;
				case TDynamic(null):
					t;
				case TDynamic(t2):
					TDynamic(loop(t2));
			}
		}
		return loop(t);
	}

	public static function applyTypedef(td:TDef, tl:TParams):T {
		return applyParams(td.params, tl, td.type);
	}

	public static function monomorphs(eparams:TypeParams, t:T):T {
		return applyParams(eparams, [for (_ in eparams) mkMono()], t);
	}

	public static function follow(t:T):T {
		if (hxc.core.PerfCount.on) hxc.core.PerfCount.bump("follow");
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case some if (some != null): follow(some);
					case _: t;
				}
			case TLazy(f):
				follow(lazyType(f));
			case TType(td, tl):
				follow(applyTypedef(td, tl));
			case TAbstract(a, [t1]) if (a.path.pack.length == 0 && a.path.name == "Null"):
				follow(t1);
			case _: t;
		}
	}

	public static function followOnce(t:T):T {
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case null: t;
					case some: some;
				}
			case TAbstract(_, _) | TEnum(_, _) | TInst(_, _) | TFun(_) | TAnon(_) | TDynamic(_):
				t;
			case TType(td, tl):
				applyTypedef(td, tl);
			case TLazy(f):
				lazyType(f);
		}
	}

	public static function followWithoutNull(t:T):T {
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case some if (some != null): followWithoutNull(some);
					case _: t;
				}
			case TLazy(f):
				followWithoutNull(lazyType(f));
			case TType(td, tl):
				followWithoutNull(applyTypedef(td, tl));
			case _: t;
		}
	}

	public static function followWithoutType(t:T):T {
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case some if (some != null): followWithoutType(some);
					case _: t;
				}
			case TLazy(f):
				followWithoutType(lazyType(f));
			case TAbstract(a, [t1]) if (a.path.pack.length == 0 && a.path.name == "Null"):
				followWithoutType(t1);
			case _: t;
		}
	}

	static inline function isNullPath(path:Path):Bool {
		return path.pack.length == 0 && path.name == "Null";
	}

	// Abstracts traversed by the current getUnderlyingType chain; a repeat is a recursive chain and reports
	// instead of looping.
	static var underlyingTypeStack:Array<T> = [];

	// A @:multiType abstract's underlying type is its resolved specialization. The resolver lives in
	// the typer; ModuleLoader.attach assigns it. A null result falls through to thisType.
	public static var multiTypeResolver:Null<(TAbstract, TParams)->Null<T>> = null;

	public static function tryMultiType(a:TAbstract, pl:TParams):Null<T> {
		if (multiTypeResolver == null || !hasMeta(":multiType", a.meta)) return null;
		return multiTypeResolver(a, pl);
	}

	// The first underlying level, still running the full traversal so a mutually recursive chain reports.
	public static function getUnderlyingTypeFirst(a:TAbstract, pl:TParams):T {
		var mt = tryMultiType(a, pl);
		if (mt != null) return mt;
		if (hasMeta(":coreType", a.meta)) return tDynamic;
		var t = applyParams(a.params, pl, a.thisType);
		underlyingTypeStack.push(TAbstract(a, pl));
		try maybeRecurseUnderlying(t) catch (e:Dynamic) { underlyingTypeStack.pop(); throw e; }
		underlyingTypeStack.pop();
		return t;
	}

	public static function getUnderlyingType(a:TAbstract, pl:TParams):T {
		var mt = tryMultiType(a, pl);
		if (mt != null) return mt;
		if (hasMeta(":coreType", a.meta)) return tDynamic;
		underlyingTypeStack.push(TAbstract(a, pl));
		var r = try maybeRecurseUnderlying(applyParams(a.params, pl, a.thisType)) catch (e:Dynamic) {
			underlyingTypeStack.pop();
			throw e;
		};
		underlyingTypeStack.pop();
		return r;
	}

	static function maybeRecurseUnderlying(t:T):T {
		return switch (t) {
			case TMono(r):
				switch (r.type) { case null: t; case some: maybeRecurseUnderlying(some); }
			case TLazy(f):
				maybeRecurseUnderlying(lazyType(f));
			case TAbstract(a, [t1]) if (isNullPath(a.path)):
				TAbstract(a, [maybeRecurseUnderlying(t1)]);
			case TType(td, tl):
				maybeRecurseUnderlying(applyTypedef(td, tl));
			case TAbstract(a, tl) if (!hasMeta(":coreType", a.meta)):
				for (s in underlyingTypeStack) switch (s) {
					case TAbstract(a2, _) if (a2 == a):
						// The chain prints oldest first, the repeat last.
						var pctx = hxc.core.TPrinting.printContext();
						var parts = [for (x in underlyingTypeStack) hxc.core.TPrinting.sType(pctx, x)];
						parts.push(hxc.core.TPrinting.sType(pctx, t));
						throw new hxc.core.TypingError("Abstract chain detected: " + parts.join(" -> "), a.pos);
					case _:
				}
				getUnderlyingType(a, tl);
			case _: t;
		}
	}

	// T: follow, then keep unwrapping non-core
	// abstracts to their underlying type. Used by the @:op dispatch to compare an abstract
	public static function followWithAbstracts(t:T):T {
		return switch (follow(t)) {
			case TAbstract(a, tl) if (!hasMeta(":coreType", a.meta)):
				followWithAbstracts(getUnderlyingType(a, tl));
			case t2: t2;
		}
	}

	public static function isNullable(t:T, no_lazy:Bool = false):Bool {
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case null: false;
					case some: isNullable(some, no_lazy);
				}
			case TAbstract(a, [_]) if (isNullPath(a.path)):
				true;
			case TLazy(f):
				switch (f.get()) {
					case LAvailable(t2): isNullable(t2, no_lazy);
					case _ if (no_lazy): throw new ExitException();
					case _: isNullable(lazyType(f), no_lazy);
				}
			case TType(td, tl):
				isNullable(applyTypedef(td, tl), no_lazy);
			case TFun(_):
				false;
			case TAbstract(a, _) if (hasMeta(":coreType", a.meta)):
				!hasMeta(":notNull", a.meta);
			case TAbstract(a, tl):
				// The recursion needs a stop: a chain error is recorded and typing continues, so this can
				// meet a cycle. A depth cap keeps nested self-application such as C<C<String>> recursing
				// (an abstract-keyed stop would reject it) without comparing types structurally (cyclic
				// type graphs make enum equality unsafe on the cpp host).
				if (nullableDepth > 64) false
				else {
					nullableDepth++;
					var r = !hasMeta(":notNull", a.meta) && isNullable(applyParams(a.params, tl, a.thisType));
					nullableDepth--;
					r;
				}
			case _:
				true;
		}
	}

	static var nullableDepth:Int = 0;

	public static function isNull(t:T, no_lazy:Bool = false):Bool {
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case null: false;
					case some: isNull(some, no_lazy);
				}
			case TAbstract(a, [t1]) if (isNullPath(a.path)):
				!isNullable(follow(t1), no_lazy);
			case TLazy(f):
				switch (f.get()) {
					case LAvailable(t2): isNull(t2, no_lazy);
					case _ if (no_lazy): throw new ExitException();
					case _: isNull(lazyType(f), no_lazy);
				}
			case TType(td, tl):
				isNull(applyTypedef(td, tl), no_lazy);
			case _:
				false;
		}
	}

	public static function isExplicitNull(t:T):Bool {
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case null: false;
					case some: isExplicitNull(some);
				}
			case TAbstract(a, [_]) if (isNullPath(a.path)):
				true;
			case TLazy(f):
				isExplicitNull(lazyType(f));
			case TType(td, tl):
				isExplicitNull(applyTypedef(td, tl));
			case _:
				false;
		}
	}

	public static function hasMono(t:T):Bool {
		return switch (t) {
			case TMono(r):
				switch (r.type) {
					case null: true;
					case some: hasMono(some);
				}
			case TInst(_, pl) | TEnum(_, pl) | TAbstract(_, pl) | TType(_, pl):
				Lambda.exists(pl, hasMono);
			case TDynamic(_):
				false;
			case TFun(sig):
				if (hasMono(sig.ret)) true
				else {
					var b = false;
					for (a in sig.args) if (hasMono(a.t)) { b = true; break; }
					b;
				}
			case TAnon(a):
				var b = false;
				for (cf in a.fields) if (hasMono(cf.type)) { b = true; break; }
				b;
			case TLazy(f):
				hasMono(lazyType(f));
		}
	}

	public static function concat(e1:TExpr, e2:TExpr):TExpr {
		var e:TExprExpr = switch [e1.expr, e2.expr] {
			case [TBlock(el1), TBlock(el2)]: TBlock(el1.concat(el2));
			case [TBlock(el), _]: TBlock(el.concat([e2]));
			case [_, TBlock(el)]: TBlock([e1].concat(el));
			case [_, _]: TBlock([e1, e2]);
		};
		return mk(e, e2.type, Position.union(e1.pos, e2.pos));
	}

	public static function extractParamType(tp:TypedTypeParam):T return tp.type;
	public static function extractParamTypes(l:TypeParams):TParams return [for (tp in l) tp.type];
	public static function extractParamName(tp:TypedTypeParam):String return tp.name;

	// Null for "no such parameter". Every bare-name type hint probes the type parameters first and
	// usually misses, so a throwing miss would be costly (an hxcpp throw costs microseconds). The only
	// caller null-shapes the result already.
	public static function lookupParam(n:String, l:TypeParams):Null<T> {
		for (tp in l) if (n == tp.name) return tp.type;
		return null;
	}

	public static function mkTypeParam(n:String, t:T, def:Null<T>):TypedTypeParam {
		return {name: n, type: t, defaultType: def};
	}

	public static function typeOfModuleType(mt:ModuleType):T {
		return switch (mt) {
			case TClassDecl(c): TInst(c, extractParamTypes(c.params));
			case TEnumDecl(e): TEnum(e, extractParamTypes(e.params));
			case TTypeDecl(t): TType(t, extractParamTypes(t.params));
			case TAbstractDecl(a): TAbstract(a, extractParamTypes(a.params));
		}
	}

	public static function moduleTypeOfType(t:T):ModuleType {
		return switch (t) {
			case TInst(c, _): TClassDecl(c);
			case TEnum(en, _): TEnumDecl(en);
			case TType(td, _): TTypeDecl(td);
			case TAbstract(a, _): TAbstractDecl(a);
			case TLazy(f): moduleTypeOfType(lazyType(f));
			case TMono(r):
				switch (r.type) {
					case some if (some != null): moduleTypeOfType(some);
					case _: throw new ExitException();
				}
			case TAnon(an):
				switch (an.status.get()) {
					case Statics(c): TClassDecl(c);
					case EnumStatics(en): TEnumDecl(en);
					case AbstractStatics(a): TAbstractDecl(a);
					case _: throw new ExitException();
				}
			case _:
				throw new ExitException();
		}
	}

	public static function tconstToConst(c:TConstant):Constant {
		return switch (c) {
			case TInt(i): CInt(Std.string(i), null);
			case TFloat(s): CFloat(s, null);
			case TString(s): CString(s, SDoubleQuotes);
			case TBool(b): CIdent(b ? "true" : "false");
			case TNull: CIdent("null");
			case TThis: CIdent("this");
			case TSuper: CIdent("super");
		}
	}

	public static function hasCtorConstraint(c:TClass):Bool {
		return switch (c.kind) {
			case KTypeParameter(tl):
				Lambda.exists(tl, function(t) {
					return switch (follow(t)) {
						case TAnon(a) if (a.fields.exists("new")): true;
						case TAbstract(a, _) if (a.path.pack.length == 1 && a.path.pack[0] == "haxe" && a.path.name == "Constructible"): true;
						case _: false;
					}
				});
			case _: false;
		}
	}

	public static function fieldName(f:TFieldAccess):String {
		return switch (f) {
			case FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf) | FClosure(_, cf): cf.name;
			case FEnum(_, ef): ef.name;
			case FDynamic(n): n;
		}
	}

	public static function extractField(f:TFieldAccess):Null<TClassField> {
		return switch (f) {
			case FAnon(cf) | FInstance(_, _, cf) | FStatic(_, cf) | FClosure(_, cf): cf;
			case _: null;
		}
	}

	public static function isPhysicalVarField(f:TClassField):Bool {
		return switch (f.kind) {
			case Var(vk) if (
				(switch (vk.read) { case AccNormal | AccInline | AccNo: true; case _: false; })
				|| (switch (vk.write) { case AccNormal | AccNo: true; case _: false; })):
				true;
			case Var(_): hasMeta(":isVar", f.meta);
			case _: false;
		}
	}

	public static function isPhysicalField(f:TClassField):Bool {
		return switch (f.kind) {
			case Method(_): true;
			case _: isPhysicalVarField(f);
		}
	}

	public static function fieldType(f:TClassField):T {
		return switch (f.params) {
			case []: f.type;
			case l: monomorphs(l, f.type);
		}
	}

	// Return the field, its type, and the optional declaring class with type parameters.
	public static function rawClassField(buildType:TClassField->T, c:TClass, tl:TParams, i:String):{c2:Null<TClassWithParams>, t:T, f:TClassField} {
		var apply = function(x:T) return applyParams(c.params, tl, x);
		if (c.fields.exists(i)) {
			var f = c.fields.get(i);
			return {c2: {c: c, params: tl}, t: buildType(f), f: f};
		}
		// 2) constructor (when i = "new")
		if (i == "new") {
			switch (c.constructor) {
				case ctor if (ctor != null):
					return {c2: {c: c, params: tl}, t: buildType(ctor), f: ctor};
				case _:
			}
		}
		switch (c.superClass) {
			case sup if (sup != null):
				try {
					var r = rawClassField(buildType, sup.c, [for (x in sup.params) apply(x)], i);
					return {c2: r.c2, t: applyParams(sup.c.params, sup.params, r.t), f: r.f};
				} catch (e:NotFound) {
				}
			case _:
		}
		switch (c.kind) {
			case KTypeParameter(ctl):
				for (t in ctl) {
					switch (follow(t)) {
						case TAnon(a):
							if (a.fields.exists(i)) {
								var f = a.fields.get(i);
								return {c2: null, t: buildType(f), f: f};
							}
						case TInst(c2, tl2):
							try {
								var r = rawClassField(buildType, c2, [for (x in tl2) apply(x)], i);
								return {c2: r.c2, t: applyParams(c2.params, tl2, r.t), f: r.f};
							} catch (e:NotFound) {}
						case _:
					}
				}
				throw new NotFound("TypeFunctions.hx:1024");
			case _:
				if (!hasClassFlag(c, CInterface)) throw new NotFound("TypeFunctions.hx:1026");
				// An interface can implement other interfaces without redeclaring fields
				for (impl in c.interfaces) {
					try {
						var r = rawClassField(buildType, impl.c, [for (x in impl.params) apply(x)], i);
						return {c2: r.c2, t: applyParams(impl.c.params, impl.params, r.t), f: r.f};
					} catch (e:NotFound) {}
				}
				throw new NotFound("TypeFunctions.hx:1034");
		}
	}

	public static function classField(c:TClass, tl:TParams, i:String):{c2:Null<TClassWithParams>, t:T, f:TClassField} {
		return rawClassField(fieldType, c, tl, i);
	}

	public static function quickField(t:T, n:String):TFieldAccess {
		return switch (follow(t)) {
			case TInst(c, tl):
				var r = rawClassField(function(f) return f.type, c, tl, n);
				switch (r.c2) {
					case null: FAnon(r.f);
					case cwp: FInstance(cwp.c, cwp.params, r.f);
				}
			case TAnon(a):
				switch (a.status.get()) {
					case EnumStatics(e):
						if (!e.constrs.exists(n)) throw new NotFound("TypeFunctions.hx:1053");
						FEnum(e, e.constrs.get(n));
					case Statics(c):
						if (!c.statics.exists(n)) throw new NotFound("TypeFunctions.hx:1056");
						FStatic(c, c.statics.get(n));
					case AbstractStatics(a):
						switch (a.impl) {
							case c if (c != null):
								if (!c.statics.exists(n)) throw new NotFound("TypeFunctions.hx:1061");
								FStatic(c, c.statics.get(n)); // Is that right?
							case _:
								throw new NotFound("TypeFunctions.hx:1064");
						}
					case _:
						if (!a.fields.exists(n)) throw new NotFound("TypeFunctions.hx:1067");
						FAnon(a.fields.get(n));
				}
			case TDynamic(_):
				FDynamic(n);
			case TEnum(_, _) | TMono(_) | TAbstract(_, _) | TFun(_):
				throw new NotFound("TypeFunctions.hx:1073");
			case TLazy(_) | TType(_, _):
				throw "quick_field: unexpected TLazy/TType after follow";
		}
	}

	public static function quickFieldDynamic(t:T, s:String):TFieldAccess {
		return try quickField(t, s) catch (e:NotFound) FDynamic(s);
	}

	public static function getConstructorClass(c:TClass, tl:TParams):{cf:TClassField, c:TClass, tl:TParams} {
		return switch [c.constructor, c.superClass] {
			case [cf, _] if (cf != null): {cf: cf, c: c, tl: tl};
			case [_, null]: throw new NotFound("TypeFunctions.hx:1086");
			case [_, sup]: getConstructorClass(sup.c, [for (x in sup.params) applyParams(c.params, tl, x)]);
		}
	}

	public static function getConstructor(c:TClass):TClassField {
		return switch [c.constructor, c.superClass] {
			case [cf, _] if (cf != null): cf;
			case [_, null]: throw new NotFound("TypeFunctions.hx:1094");
			case [_, sup]: getConstructor(sup.c);
		}
	}

	public static function hasConstructor(c:TClass):Bool {
		return try { getConstructor(c); true; } catch (e:NotFound) false;
	}

	public static function isModuleFieldsClass(c:TClass):Bool {
		return switch (c.kind) { case KModuleFields(_): true; case _: false; }
	}

	public static function isPosOutsideClass(c:TClass, p:Position):Bool {
		return p.file != c.pos.file || p.max < c.pos.min || p.min > c.pos.max;
	}

	public static function resolveTypedef(t:ModuleType):ModuleType {
		return switch (t) {
			case TClassDecl(_) | TEnumDecl(_) | TAbstractDecl(_): t;
			case TTypeDecl(td):
				switch (follow(td.type)) {
					case TEnum(e, _): TEnumDecl(e);
					case TInst(c, _): TClassDecl(c);
					case TAbstract(a, _): TAbstractDecl(a);
					case _: t;
				}
		}
	}

	public static function typeHasMeta(t:T, m:String):Bool {
		return switch (t) {
			case TMono(_) | TFun(_) | TAnon(_) | TDynamic(_) | TLazy(_): false;
			case TEnum(e, _): hasMeta(m, e.meta);
			case TInst(c, _): hasMeta(m, c.meta);
			case TType(td, _): hasMeta(m, td.meta);
			case TAbstract(a, _): hasMeta(m, a.meta);
		}
	}

	public static function varExtra(params:TypeParams, e:Null<TExpr>):TVarExtra {
		return {params: params, expr: e};
	}

	public static function makeStubBasicTypes():BasicTypes {
		var p = Position.nullPos;
		var stdMod:ModuleDef = {
			id: allocMid(), path: {pack: [], name: "StdTypes"}, types: [],
			statics: null, extra: moduleExtra("StdTypes.hx", "", 0.0, MCode, [])
		};

		function coreAbstract(name:String, notNull:Bool):TAbstract {
			var a = nullAbstractCopy({pack: [], name: name}, stdMod);
			a.meta = [{name: ":coreType", params: [], pos: p}];
			if (notNull) a.meta.push({name: ":notNull", params: [], pos: p});
			return a;
		}

		var aInt = coreAbstract("Int", true);
		var aFloat = coreAbstract("Float", true);
		var aBool = coreAbstract("Bool", true);
		var aVoid = coreAbstract("Void", true);
		var aNull = nullAbstractCopy({pack: [], name: "Null"}, stdMod);
		aNull.meta = [{name: ":coreType", params: [], pos: p}];
		var nullParam = mkTypeParam("T", mkMono(), null);
		aNull.params = [nullParam];
		aNull.thisType = nullParam.type;

		var strMod:ModuleDef = {
			id: allocMid(), path: {pack: [], name: "String"}, types: [],
			statics: null, extra: moduleExtra("String.hx", "", 0.0, MCode, [])
		};
		var cString = mkClass(strMod, {pack: [], name: "String"}, p, p);

		var arrMod:ModuleDef = {
			id: allocMid(), path: {pack: [], name: "Array"}, types: [],
			statics: null, extra: moduleExtra("Array.hx", "", 0.0, MCode, [])
		};
		var cArray = mkClass(arrMod, {pack: [], name: "Array"}, p, p);
		cArray.params = [mkTypeParam("T", mkMono(), null)];

		return {
			tvoid: TAbstract(aVoid, []),
			tint: TAbstract(aInt, []),
			tfloat: TAbstract(aFloat, []),
			tbool: TAbstract(aBool, []),
			tnull: mkNull.bind(aNull),
			tstring: TInst(cString, []),
			tarray: function(t:T) return TInst(cArray, [t])
		};
	}

	// The nullability test runs without forcing lazies, so a type whose answer would need a lazy
	// forced (a typedef, whose type stays a TLazy for the recursion check) aborts instead, and the
	// wrap is DEFERRED behind a TLazy of its own. A plain TAbstract(Null,[t]) reads the same
	// everywhere that follows types, but not to the XML generator, which strips a Null off an optional
	// argument and does not follow a TLazy: deferred, `?infos:haxe.PosInfos` prints as
	// Null<haxe.PosInfos>; decided eagerly it would print as the bare typedef.
	public static function mkNull(aNull:TAbstract, t:T):T {
		return try {
			(isNull(t, true) || isExplicitNull(t)) ? t : TAbstract(aNull, [t]);
		} catch (_:ExitException) {
			var r:Ref<TLazy> = new Ref(lazyAvailable(tDynamic));
			r.set(lazyWait(function():T {
				var t2 = isNull(t) ? t : TAbstract(aNull, [t]);
				r.set(lazyAvailable(t2));
				return t2;
			}));
			TLazy(r);
		}
	}

	// Helper: a fresh null-abstract-shaped record under a given path/module (STUB use).
	static function nullAbstractCopy(path:Path, m:ModuleDef):TAbstract {
		var p = Position.nullPos;
		return {
			path: path, module: m, pos: p, namePos: p, isPrivate: false,
			doc: null, meta: [], params: [], usings: [], restore: function() {},
			ops: [], unops: [], impl: null, thisType: tDynamic, from: [],
			fromField: [], to: [], toField: [], array: [], read: null,
			write: null, call: null, isEnum: false
		};
	}
}
