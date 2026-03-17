package hxc.eval;

import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.Globals.Path;
import hxc.eval.EvalValue;
import hxc.eval.EvalContext;
import hxc.eval.EvalEmitter;
import hxc.eval.EvalHash;

typedef ProtoDelay = VPrototype->Void;

// Builds the runtime prototypes for a typed class. Static and instance methods become callables;
// fields are laid out in offset-indexed arrays addressed by the hashed-name maps.
class EvalPrototype {
	// An instance method or constructor receives the receiver as the first call argument and binds
	// it as this; a static method binds its arguments directly.
	public static function makeFunction(ctx:EvalContext, tf:TFunc, isInstance:Bool, info:EvalEnvInfo, abstractThis:Bool = false):VFunc {
		return function(args:Array<EvalValue>):EvalValue {
			var offset = isInstance ? 1 : 0;
			var bound:Array<{vid:Int, value:EvalValue}> = [];
			for (i in 0...tf.args.length) {
				var j = i + offset;
				bound.push({vid: tf.args[i].v.id, value: EvalEmitter.argValue(ctx, tf.args[i], j < args.length ? args[j] : VNull)});
			}
			var vthis = (isInstance || abstractThis) ? (args.length > 0 ? args[0] : VNull) : null;
			return EvalEmitter.runBody(ctx, bound, tf.expr, vthis, info, args.length > tf.args.length + offset);
		};
	}

	public static function makeConstructor(ctx:EvalContext, c:TClass):Null<VFunc> {
		if (c.constructor == null) return null;
		var tf = asFunction(c.constructor.expr);
		if (tf == null) return null;
		var field = c.constructor;
		var info = EvalContext.createEnvInfo(false, field.namePos, EKMethod(EvalHash.pathHash(c.path), EvalHash.hash(field.name)), 0, 0);
		return makeFunction(ctx, tf, true, info);
	}

	// The static face of an enum: each constructor is a value (no-arg) or a builder (with args).
	public static function buildEnum(ctx:EvalContext, en:TEnum):VPrototype {
		var key = EvalHash.pathHash(en.path);
		var pfields:Array<EvalValue> = [];
		var pnames:Map<Int, Int> = new Map();
		var constructors:Array<{name:String, args:Array<Int>}> = [];
		for (name in en.names) {
			var ef = en.constrs.get(name);
			var idx = ef.index;
			// A constructor's values, argument-less or made by its function, carry the constructor's
			// declaration position. The compiler's own encoder attaches none except for a ComplexType, so a
			// modifier a macro wrote, decoded with its position, reports inside haxe/macro/Expr.hx.
			var pos:Null<hxc.ast.Position> = ef.pos;
			var v:EvalValue = switch (TypeFunctions.follow(ef.type)) {
				case TFun(sig):
					constructors.push({name: name, args: [for (a in sig.args) EvalHash.hash(a.name)]});
					VFunction(function(args:Array<EvalValue>):EvalValue return EvalValue.VEnumValue(new VEnumValue(idx, args, key, pos)), false);
				case _:
					constructors.push({name: name, args: []});
					EvalValue.VEnumValue(new VEnumValue(idx, [], key, pos));
			};
			pnames.set(EvalHash.hash(name), pfields.length);
			pfields.push(v);
		}
		addMeta(enumMeta(en), pfields, pnames);
		var proto = new VPrototype(key, pfields, pnames, [], new Map(), null, PEnum(constructors), VNull);
		// The enum used as a value (Type.getEnumConstructs(E), createEnum) resolves to its prototype.
		proto.pvalue = VPrototype(proto);
		return proto;
	}

	static inline function asFunction(e:Null<TExpr>):Null<TFunc> {
		return e == null ? null : switch (e.expr) {
			case TFunction(f): f;
			case _: null;
		};
	}

	static inline function isRemovable(cf:TClassField):Bool {
		return TypeFunctions.hasClassFieldFlag(cf, CfExtern) || TypeFunctions.hasClassFieldFlag(cf, CfGeneric);
	}

	static function nativeFieldName(cf:TClassField):Null<String> {
		var meta = TypeFunctions.getMetaOpt(":native", cf.meta);
		if (meta == null) return null;
		return switch (meta.params.length > 0 ? meta.params[0].expr : null) {
			case EConst(CString(s, _)): s;
			case _: null;
		}
	}

	static function addNameAlias(pnames:Map<Int, Int>, cf:TClassField, idx:Int, ?owner:TClass):Void {
		var native = nativeFieldName(cf);
		// An override inherits its parent field's @:native name.
		if (native == null && owner != null) {
			var cur = owner.superClass;
			var guard = 0;
			while (cur != null && guard++ < 50) {
				var base = cur.c.fields.get(cf.name);
				if (base != null) {
					native = nativeFieldName(base);
					if (native != null) break;
				}
				cur = cur.c.superClass;
			}
		}
		if (native != null && native != "" && native != cf.name)
			pnames.set(EvalHash.hash(native), idx);
	}

	// Install native builtins for a type (extern stdlib classes get their fields from here).
	static function addBuiltins(list:Null<Array<BuiltinField>>, pfields:Array<EvalValue>, pnames:Map<Int, Int>, ?skipNames:Map<Int, Bool>):Void {
		if (list == null) return;
		for (b in list) {
			if (skipNames != null && skipNames.exists(b.name)) continue;
			var idx = pnames.get(b.name);
			if (idx == null) {
				pnames.set(b.name, pfields.length);
				pfields.push(b.v);
			} else {
				pfields[idx] = b.v;
			}
		}
	}

	// Runtime metadata (the compiler-synthesized __meta__ static). Only user metadata (a name not
	// starting with ':' or '$') is kept; the params, which must be constant-value expressions, are
	// evaluated to runtime values.

	// A metadata param is restricted to constant values: only constants, parentheses, object and
	// array literals; anything else is not a constant value.
	static function metaConstant(e:Expr):EvalValue {
		return switch (e.expr) {
			case EConst(c): metaConst(c);
			case EParenthesis(e1): metaConstant(e1);
			case EObjectDecl(fields):
				var m = new Map<Int, EvalValue>();
				for (f in fields) m.set(EvalHash.hash(f.name), metaConstant(f.expr));
				VObject(new VObject([], ODictionary(m)));
			case EArrayDecl(el): VArray(new VArray([for (x in el) metaConstant(x)], el.length));
			case _: throw new EvalMetaError();
		};
	}

	// Constant folding for a metadata leaf (int overflow / hex fall back to float, the three keyword
	// idents map to their values, any other ident is not a constant).
	static function metaConst(c:Constant):EvalValue {
		return switch (c) {
			case CInt(s, _):
				if (s.length > 10 && s.substr(0, 2) == "0x") throw new EvalMetaError();
				var i = Std.parseInt(s);
				(i == null || i < -2147483648 || i > 2147483647) ? VFloat(Std.parseFloat(s)) : VInt(i);
			case CFloat(f, _): VFloat(Std.parseFloat(f));
			case CString(s, _): VString(hxc.eval.EvalValue.VString.createUnknown(s));
			case CIdent("true"): VTrue;
			case CIdent("false"): VFalse;
			case CIdent("null"): VNull;
			case _: throw new EvalMetaError();
		};
	}

	// True for a user metadata name: not a compiler/reserved one (leading ':' or '$').
	static inline function isUserMeta(name:String):Bool {
		if (name.length == 0) return false;
		var c = name.charCodeAt(0);
		return c != ":".code && c != "$".code;
	}

	// One entry's params become an Array of values, or null when there are no params (both no-parens
	// and empty-parens yield the empty list, hence null).
	static function metaParams(params:Array<Expr>):EvalValue {
		if (params.length == 0) return VNull;
		return VArray(new VArray([for (p in params) metaConstant(p)], params.length));
	}

	// Turn one named-metadata list ({name -> Metadata}) into a VObject of {name -> params}, keeping
	// only user metadata and only entries that still carry some. Returns null when nothing remains.
	static function metaField(entries:Array<{name:String, meta:Metadata}>):Null<EvalValue> {
		var m = new Map<Int, EvalValue>();
		var any = false;
		for (e in entries) {
			var inner = new Map<Int, EvalValue>();
			var innerAny = false;
			for (me in e.meta) if (isUserMeta(me.name)) {
				inner.set(EvalHash.hash(me.name), metaParams(me.params));
				innerAny = true;
			}
			if (innerAny) {
				m.set(EvalHash.hash(e.name), VObject(new VObject([], ODictionary(inner))));
				any = true;
			}
		}
		return any ? VObject(new VObject([], ODictionary(m))) : null;
	}

	// The metadata of a single type (its own meta list under the "" key). Returns null when it has no
	// user metadata.
	static function metaObj(meta:Metadata):Null<EvalValue> {
		var inner = new Map<Int, EvalValue>();
		var any = false;
		for (me in meta) if (isUserMeta(me.name)) {
			inner.set(EvalHash.hash(me.name), metaParams(me.params));
			any = true;
		}
		return any ? VObject(new VObject([], ODictionary(inner))) : null;
	}

	// Assemble the __meta__ value {obj?, fields?, statics?} for a type, or null when nothing applies.
	// The nested metadata is dropped whole if any param is not a constant value, so a malformed entry
	// never aborts the run.
	static function buildMeta(obj:Metadata, fields:Array<{name:String, meta:Metadata}>,
			statics:Array<{name:String, meta:Metadata}>):Null<EvalValue> {
		try {
			var vObj = metaObj(obj);
			var vFields = metaField(fields);
			var vStatics = metaField(statics);
			if (vObj == null && vFields == null && vStatics == null) return null;
			var m = new Map<Int, EvalValue>();
			if (vObj != null) m.set(EvalHash.hash("obj"), vObj);
			if (vFields != null) m.set(EvalHash.hash("fields"), vFields);
			if (vStatics != null) m.set(EvalHash.hash("statics"), vStatics);
			return VObject(new VObject([], ODictionary(m)));
		} catch (_:EvalMetaError) {
			return null;
		}
	}

	// Install a computed __meta__ value as a static-prototype field.
	static function addMeta(v:Null<EvalValue>, pfields:Array<EvalValue>, pnames:Map<Int, Int>):Void {
		if (v == null) return;
		pnames.set(EvalHash.key___meta__, pfields.length);
		pfields.push(v);
	}

	static inline function addStaticString(name:String, s:String, pfields:Array<EvalValue>, pnames:Map<Int, Int>):Void {
		pnames.set(EvalHash.hash(name), pfields.length);
		pfields.push(VString(hxc.eval.EvalValue.VString.createUnknown(s)));
	}

	static function hasRtti(c:TClass):Bool {
		var cur:Null<TClass> = c;
		while (cur != null) {
			if (TypeFunctions.hasMeta(":rtti", cur.meta)) return true;
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		return false;
	}

	static function xmlEscape(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			switch (s.charCodeAt(i)) {
				case "&".code: b.add("&amp;");
				case "<".code: b.add("&lt;");
				case ">".code: b.add("&gt;");
				case '"'.code: b.add("&quot;");
				case "'".code: b.add("&apos;");
				case _: b.addChar(s.charCodeAt(i));
			}
		}
		return b.toString();
	}

	static function pathString(p:Path):String {
		return p.pack.length == 0 ? p.name : p.pack.join(".") + "." + p.name;
	}

	static function rttiTypeParams(params:TParams):String {
		var b = new StringBuf();
		for (t in params) b.add(rttiType(t));
		return b.toString();
	}

	static function rttiPath(kind:String, p:Path, params:TParams):String {
		return "<" + kind + " path=\"" + xmlEscape(pathString(p)) + "\">" + rttiTypeParams(params) + "</" + kind + ">";
	}

	static function rttiType(t:T, ?values:haxe.ds.StringMap<Expr>):String {
		return switch (TypeFunctions.follow(t)) {
			case TMono(m):
				m.type == null ? "<unknown/>" : rttiType(m.type, values);
			case TEnum(e, params):
				rttiPath("e", e.path, params);
			case TInst(c, params):
				rttiPath("c", c.path, params);
			case TType(td, params):
				rttiPath("t", td.path, params);
			case TAbstract(a, params):
				rttiPath("x", a.path, params);
			case TFun(sig):
				var b = new StringBuf();
				b.add("<f a=\"");
				b.add(xmlEscape([for (a in sig.args) (a.opt ? "?" : "") + a.name].join(":")));
				var valueAttr = rttiFunctionValues(sig, values);
				if (valueAttr != null) {
					b.add("\" v=\"");
					b.add(xmlEscape(valueAttr));
				}
				b.add("\">");
				for (a in sig.args) b.add(rttiType(a.t));
				b.add(rttiType(sig.ret));
				b.add("</f>");
				b.toString();
			case TAnon(a):
				var fields = [for (name in a.fields.keys()) name];
				fields.sort(Reflect.compare);
				var b = new StringBuf();
				b.add("<a>");
				for (name in fields) b.add(rttiClassField(a.fields.get(name), false));
				b.add("</a>");
				b.toString();
			case TDynamic(null):
				"<d/>";
			case TDynamic(t):
				"<d>" + rttiType(t) + "</d>";
			case TLazy(f):
				rttiType(TypeFunctions.lazyType(f), values);
		}
	}

	static function rttiFunctionValues(sig:TSignature, values:Null<haxe.ds.StringMap<Expr>>):Null<String> {
		if (values == null) return null;
		var hasValue = false;
		var out:Array<String> = [];
		for (a in sig.args) {
			var e = values.get(a.name);
			if (e == null)
				out.push("");
			else {
				hasValue = true;
				out.push(hxc.ast.Printer.sExpr(e));
			}
		}
		return hasValue ? out.join(":") : null;
	}

	static function valueMeta(meta:Metadata):haxe.ds.StringMap<Expr> {
		return Ast.getValueMeta(meta);
	}

	static function fieldValueExpr(meta:Metadata):Null<Expr> {
		var m = TypeFunctions.getMetaOpt(":value", meta);
		return m != null && m.params.length == 1 ? m.params[0] : null;
	}

	static function rttiAccess(a:VarAccess):String {
		return switch (a) {
			case AccNormal: "normal";
			case AccNo | AccNever: "null";
			case AccCall: "method";
			case AccInline: "inline";
			case AccRequire(s, _): s;
			case AccCtor: "null";
		}
	}

	static function inheritedField(c:Null<TClass>, name:String):Null<TClassField> {
		var cur = c == null || c.superClass == null ? null : c.superClass.c;
		while (cur != null) {
			if (cur.fields.exists(name)) return cur.fields.get(name);
			cur = cur.superClass == null ? null : cur.superClass.c;
		}
		return null;
	}

	static function rttiClassField(cf:TClassField, isStatic:Bool, ?owner:TClass):String {
		var inherited = isStatic ? null : inheritedField(owner, cf.name);
		var b = new StringBuf();
		b.add("<");
		b.add(xmlEscape(cf.name));
		if (isStatic) b.add(" static=\"1\"");
		if (TypeFunctions.hasClassFieldFlag(cf, CfPublic)
			|| (inherited != null && TypeFunctions.hasClassFieldFlag(inherited, CfPublic)))
			b.add(" public=\"1\"");
		if (TypeFunctions.hasClassFieldFlag(cf, CfFinal)) b.add(" final=\"1\"");
		if (TypeFunctions.hasClassFieldFlag(cf, CfOverride) || inherited != null) b.add(" override=\"1\"");
		switch (cf.kind) {
			case Method(_):
				b.add(" set=\"method\"");
			case Var(vk):
				var ve = fieldValueExpr(cf.meta);
				if (ve != null) {
					b.add(" expr=\"");
					b.add(xmlEscape(hxc.ast.Printer.sExpr(ve)));
					b.add("\"");
				}
				var r = rttiAccess(vk.read);
				var w = rttiAccess(vk.write);
				if (r != "normal") b.add(" get=\"" + xmlEscape(r) + "\"");
				if (w != "normal") b.add(" set=\"" + xmlEscape(w) + "\"");
		}
		if (cf.params.length > 0) {
			b.add(" params=\"");
			b.add(xmlEscape([for (tp in cf.params) tp.name].join(":")));
			b.add("\"");
		}
		b.add(">");
		b.add(rttiType(TypeFunctions.fieldType(cf), valueMeta(cf.meta)));
		b.add("</");
		b.add(xmlEscape(cf.name));
		b.add(">");
		return b.toString();
	}

	static function rttiPathParams(kind:String, p:Path, params:TParams):String {
		var empty = params.length == 0;
		if (empty) return "<" + kind + " path=\"" + xmlEscape(pathString(p)) + "\"/>";
		return "<" + kind + " path=\"" + xmlEscape(pathString(p)) + "\">" + rttiTypeParams(params) + "</" + kind + ">";
	}

	static function rttiClass(c:TClass):String {
		var b = new StringBuf();
		b.add("<class path=\"");
		b.add(xmlEscape(pathString(c.path)));
		b.add("\" params=\"");
		b.add(xmlEscape([for (tp in c.params) tp.name].join(":")));
		b.add("\"");
		if (c.isPrivate) b.add(" private=\"1\"");
		if (TypeFunctions.hasClassFlag(c, CExtern)) b.add(" extern=\"1\"");
		if (TypeFunctions.hasClassFlag(c, CInterface)) b.add(" interface=\"1\"");
		if (TypeFunctions.hasClassFlag(c, CFinal)) b.add(" final=\"1\"");
		b.add(">");
		if (c.superClass != null) b.add(rttiPathParams("extends", c.superClass.c.path, c.superClass.params));
		for (i in c.interfaces) b.add(rttiPathParams("implements", i.c.path, i.params));
		if (c.dynamicType != null) b.add("<haxe_dynamic>" + rttiType(c.dynamicType) + "</haxe_dynamic>");
		for (cf in c.orderedStatics) {
			if (isRemovable(cf) || cf.name == "__rtti" || cf.name == "__meta__") continue;
			b.add(rttiClassField(cf, true, c));
		}
		for (cf in c.orderedFields) {
			if (isRemovable(cf)) continue;
			b.add(rttiClassField(cf, false, c));
		}
		if (c.constructor != null) b.add(rttiClassField(c.constructor, false, c));
		b.add("</class>");
		return b.toString();
	}

	static function addRtti(c:TClass, pfields:Array<EvalValue>, pnames:Map<Int, Int>):Void {
		if (!hasRtti(c) || pnames.exists(EvalHash.hash("__rtti"))) return;
		addStaticString("__rtti", rttiClass(c), pfields, pnames);
	}

	// The runtime metadata of a class: its own meta, instance fields (the constructor keyed under "_"),
	// and statics.
	static function classMeta(c:TClass):Null<EvalValue> {
		var fields:Array<{name:String, meta:Metadata}> = [for (f in c.orderedFields) {name: f.name, meta: f.meta}];
		if (c.constructor != null) fields.push({name: "_", meta: c.constructor.meta});
		var statics:Array<{name:String, meta:Metadata}> = [for (f in c.orderedStatics) {name: f.name, meta: f.meta}];
		return buildMeta(c.meta, fields, statics);
	}

	// The runtime metadata of an enum: its own meta plus each constructor's meta (under fields).
	static function enumMeta(en:TEnum):Null<EvalValue> {
		var fields:Array<{name:String, meta:Metadata}> = [];
		for (n in en.names) {
			var ef = en.constrs.get(n);
			if (ef != null) fields.push({name: n, meta: ef.meta});
		}
		return buildMeta(en.meta, fields, []);
	}

	// The classes whose statics stay typed in the macro world (their natives are exposed only through
	// load).
	public static function isMacroApiClass(ctx:EvalContext, c:TClass):Bool {
		return ctx.isMacro && c.path.pack.length == 2 && c.path.pack[0] == "haxe" && c.path.pack[1] == "macro"
			&& (c.path.name == "Context" || c.path.name == "Compiler");
	}

	// Pick the world a class's decl lives in: a macro-world class must be forced against the
	// macro Context (the host parse drops its macro-only fields), and the macro interpreter's
	// ctx.com is null, so fall back through macroCom to hostCom.
	static function worldCom(ctx:EvalContext, c:TClass):Null<hxc.context.Context> {
		var com = ctx.com;
		var mc = hxc.eval.EvalMacro.getMacroCom();
		if (mc != null && c.module != null && mc.moduleLut.get(hxc.context.Context.pathKey(c.module.path)) == c.module) com = mc;
		if (com == null) com = hxc.eval.EvalMacro.hostCom;
		return com;
	}

	// Each static initializer records whether the field is @:persistent. The non-persistent ones are
	// re-run when the interpreter is reused for a new compilation which is what puts a macro-world
	// static back at its declared value at the start of every request.
	public static function buildStatic(ctx:EvalContext, c:TClass):{proto:VPrototype, delays:Array<ProtoDelay>, nonPersistent:Array<ProtoDelay>} {
		var key = EvalHash.pathHash(c.path);
		var pparent = c.superClass == null ? null : ctx.staticPrototypes.get(EvalHash.pathHash(c.superClass.c.path));
		var pfields:Array<EvalValue> = [];
		var pnames:Map<Int, Int> = new Map();
		var delays:Array<ProtoDelay> = [];
		var nonPersistent:Array<ProtoDelay> = [];
		if (!TypeFunctions.hasClassFlag(c, CExtern)) {
			var fields = c.orderedStatics.copy();
			var seen = new Map<String, Bool>();
			for (cf in fields) seen.set(cf.name, true);
			for (name in c.statics.keys()) if (!seen.exists(name)) fields.push(c.statics.get(name));
			for (cf in fields) {
				if (isRemovable(cf)) continue;
				switch (cf.kind) {
					case Method(_):
						if (cf.expr == null && ctx.com != null) hxc.typing.TypeFields.forceFieldBody(ctx.com, c, cf);
						var tf = asFunction(cf.expr);
						if (tf != null) {
							var idx = pfields.length;
							pnames.set(EvalHash.hash(cf.name), idx);
							addNameAlias(pnames, cf, idx);
							var info = EvalContext.createEnvInfo(true, cf.namePos, EKMethod(key, EvalHash.hash(cf.name)), 0, 0);
							pfields.push(VFunction(makeFunction(ctx, tf, false, info, TypeFunctions.hasClassFieldFlag(cf, CfImpl)), true));
						}
					case Var(_) if (cf.expr != null || {
						// Statics are typed lazily; an initializer never forced (reachable only
						// through a stored closure, say) would otherwise become a silent null slot.
						// Enum-abstract members and inline vars are exempt (reads are inlined, the
						// slot is never consulted), as are std classes (their inits were never
						// evaluated here, and some cannot run while the context is mid-build).
						var plainVar = !TypeFunctions.hasClassFieldFlag(cf, CfEnum) && switch (cf.kind) {
							case Var({read: AccNormal | AccNo, write: AccNormal | AccNo | AccNever | AccCtor}): true;
							case _: false;
						};
						if (plainVar) {
							var com = worldCom(ctx, c);
							var isStd = com != null && c.module != null && {
								var f = StringTools.replace(c.module.extra.file, "\\", "/");
								var std = false;
								for (p in com.stdPath) if (StringTools.startsWith(f, StringTools.replace(p, "\\", "/"))) { std = true; break; }
								std;
							};
							if (com != null && !isStd) {
								if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null) Sys.println("[varforce] " + c.path.name + "." + cf.name);
								hxc.typing.TypeFields.forceFieldBody(com, c, cf);
							}
						}
						cf.expr != null;
					}):
						var idx = pfields.length;
						pnames.set(EvalHash.hash(cf.name), idx);
						addNameAlias(pnames, cf, idx);
						pfields.push(VNull);
						var init = cf.expr;
						var d:ProtoDelay = function(proto) {
							var ctxEval = EvalContext.getEval(ctx);
							var prev = ctxEval.env;
							var env = EvalContext.pushEnvironment(ctx, EvalContext.createEnvInfo(true, init.pos, EKEntrypoint, 0, 0));
							try {
								proto.pfields[idx] = EvalEmitter.eval(ctx, init);
							} catch (e:haxe.Exception) {
								ctxEval.env = prev;
								if (Sys.getEnv("HXC_DEBUG_FIELDERR") != null)
									Sys.println("[staticinit] " + c.path.name + "." + cf.name + " threw: " + Std.string(e));
								// A static initializer that fails while building the macro context (a separate,
								// eagerly initialized interpreter) must not abort the macro; leave it null and go on.
								if (!ctx.isMacro) throw e;
							}
							EvalContext.popEnvironment(ctx, env);
						};
						delays.push(d);
						if (!TypeFunctions.hasMeta(":persistent", cf.meta)) nonPersistent.push(d);
					// A physical field without an initializer still occupies a slot.
					case _ if (TypeFunctions.isPhysicalField(cf)):
						var idx = pfields.length;
						pnames.set(EvalHash.hash(cf.name), idx);
						addNameAlias(pnames, cf, idx);
						pfields.push(VNull);
					case _:
				}
			}
		}
		// The class init is the last static delay, never persistent, and it is added whether or not the
		// class is extern.
		switch (c.init) {
			case null:
			case init:
				var d:ProtoDelay = function(proto) {
					var ctxEval = EvalContext.getEval(ctx);
					var prev = ctxEval.env;
					var env = EvalContext.pushEnvironment(ctx, EvalContext.createEnvInfo(true, init.pos, EKMethod(key, EvalHash.key___init__), 0, 0));
					try EvalEmitter.eval(ctx, init) catch (e:haxe.Exception) {
						ctxEval.env = prev;
						throw e;
					}
					EvalContext.popEnvironment(ctx, env);
				};
				delays.push(d);
				nonPersistent.push(d);
		}
		// The macro API classes keep their typed std wrappers (init-macro asserts, doc text, deprecation
		// checks) and reach the natives through load/callMacroApi: no builtin installs over a DECLARED
		// static; an unforced body late-types on first access instead. Everywhere else a registered
		// builtin replaces the typed body, which targets another platform's externs.
		var skipNames:Null<Map<Int, Bool>> = null;
		if (isMacroApiClass(ctx, c)) {
			skipNames = new Map();
			for (cf in c.orderedStatics) if (cf.kind.match(Method(_))) skipNames.set(EvalHash.hash(cf.name), true);
		}
		addBuiltins(ctx.builtins.staticBuiltins.get(key), pfields, pnames, skipNames);
		addRtti(c, pfields, pnames);
		addMeta(classMeta(c), pfields, pnames);
		var proto = new VPrototype(key, pfields, pnames, [], new Map(), pparent, PClass([]), VNull);
		proto.pvalue = VPrototype(proto);
		return {proto: proto, delays: delays, nonPersistent: nonPersistent};
	}

	public static function buildInstance(ctx:EvalContext, c:TClass):VPrototype {
		var key = EvalHash.pathHash(c.path);
		var pparent = c.superClass == null ? null : ctx.instancePrototypes.get(EvalHash.pathHash(c.superClass.c.path));
		// Methods are resolved through the parent chain, but instance data is stored flat, so the
		// instance-field layout starts from the parent's fields.
		var pfields:Array<EvalValue> = [];
		var pnames:Map<Int, Int> = new Map();
		var pinstFields:Array<EvalValue> = pparent != null ? pparent.pinstanceFields.copy() : [];
		var pinstNames:Map<Int, Int> = new Map();
		if (pparent != null) for (k in pparent.pinstanceNames.keys()) pinstNames.set(k, pparent.pinstanceNames.get(k));
		// An extern class other than String adds nothing of its own; what its instances do comes from the
		// builtins below.
		var externClass = TypeFunctions.hasClassFlag(c, CExtern) && !(c.path.pack.length == 0 && c.path.name == "String");
		if (!externClass) for (cf in c.orderedFields) {
			if (isRemovable(cf)) continue;
			switch (cf.kind) {
				case Method(_):
					// An override with an untyped body must still claim its slot: the lookup
					// would otherwise find the inherited method and never reach the late
					// forcing path, so dispatch through a base-typed ref runs the base body.
					// Macro world only: interp classes are fully typed before emission, and
					// forcing across worlds here re-enters typing with mismatched contexts.
					if (cf.expr == null && ctx.isMacro && TypeFunctions.hasClassFieldFlag(cf, CfOverride)) {
						var com = worldCom(ctx, c);
						if (com != null) try hxc.typing.TypeFields.forceFieldBody(com, c, cf) catch (_:Dynamic) {}
					}
					var tf = asFunction(cf.expr);
					if (tf != null) {
						var idx = pfields.length;
						pnames.set(EvalHash.hash(cf.name), idx);
						addNameAlias(pnames, cf, idx, c);
						var info = EvalContext.createEnvInfo(false, cf.namePos, EKMethod(key, EvalHash.hash(cf.name)), 0, 0);
						pfields.push(VFunction(makeFunction(ctx, tf, true, info), false));
						// A dynamic method is reassignable per instance, so it also occupies an instance
						// slot defaulting
						// to the same function.
						if (cf.kind.match(Method(MethDynamic))) {
							var instIdx = pinstFields.length;
							pinstNames.set(EvalHash.hash(cf.name), instIdx);
							addNameAlias(pinstNames, cf, instIdx, c);
							pinstFields.push(VFunction(makeFunction(ctx, tf, true, info), false));
						} else {
							// A plain override of an inherited dynamic method must replace that inherited
							// instance-slot's default so instances dispatch to this override, not the base.
							var inherited = pinstNames.get(EvalHash.hash(cf.name));
							if (inherited != null) pinstFields[inherited] = VFunction(makeFunction(ctx, tf, true, info), false);
						}
					} else if (TypeFunctions.hasClassFieldFlag(cf, CfAbstract)) {
						pnames.set(EvalHash.hash(cf.name), pfields.length);
						pfields.push(VNull);
					}
				case Var(_) if (TypeFunctions.isPhysicalField(cf)):
					var idx = pinstFields.length;
					pinstNames.set(EvalHash.hash(cf.name), idx);
					addNameAlias(pinstNames, cf, idx, c);
					pinstFields.push(VNull);
				case _:
			}
		}
		addBuiltins(ctx.builtins.instanceBuiltins.get(key), pfields, pnames);
		var proto = new VPrototype(key, pfields, pnames, pinstFields, pinstNames, pparent, PInstance, VNull);
		proto.pvalue = VPrototype(proto);
		return proto;
	}
}

// Signals that a metadata param is not a constant value, so its whole __meta__ is skipped.
class EvalMetaError extends haxe.Exception {
	public function new() super("not a constant metadata value");
}
