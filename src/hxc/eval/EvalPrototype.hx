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
		EvalEmitter.numberClosures(tf.expr);
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
		var f = makeFunction(ctx, tf, true, info);
		// The constructor is lazy: the first construction compiles it.
		var compiled = false;
		return function(args:Array<EvalValue>):EvalValue {
			if (!compiled) {
				compiled = true;
				jitWalk(ctx, tf.expr);
			}
			return f(args);
		};
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
			case CString(s, _): hxc.eval.EvalString.EvalString.vOfText(s);
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
		pfields.push(hxc.eval.EvalString.EvalString.vOfText(s));
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

	// Record @:persistent on each static initializer; rerun only non-persistent initializers when
	// reusing the interpreter for a compilation. Validate bodies in compilation order before
	// interpreting them. Methods validate when their prototypes are added; static initializers and
	// __init__ validate when run. TIdent is invalid except for the reified $__mk_pos__ call, including
	// untyped or display-recovered names in code that will not execute. Static reads, writes, and
	// proper-method calls require an indexed prototype slot at compilation. Other static calls and the
	// StringTools intrinsics resolve names at the call. Follow the compiler's traversal order and
	// remap TFor using a fresh iterator variable; interpret the remapped loop.
	public static function jitWalk(ctx:EvalContext, e:TExpr):Void {
		var com = ctx.com != null ? ctx.com : @:privateAccess hxc.eval.EvalMacro.macroCom;
		function verdict(c:TClass, cf:TClassField):Void {
			if (!inStaticPrototype(ctx, c, cf))
				throw new hxc.core.TypingError("Field index for " + cf.name + " not found on prototype "
					+ hxc.core.Globals.sTypePath(c.path), hxc.ast.Position.nullPos);
		}
		// An instance call: the class's instance prototype and the method's slot in it.
		function instanceVerdict(c:TClass, cf:TClassField):Void {
			if (!inInstancePrototype(ctx, c, cf))
				throw new hxc.core.TypingError("Field index for " + cf.name + " not found on prototype "
					+ hxc.core.Globals.sTypePath(c.path), hxc.ast.Position.nullPos);
		}
		function isFinal(c:TClass, cf:TClassField):Bool return @:privateAccess EvalEmitter.isFinalMethod(ctx, c, cf);
		var loop:TExpr->Void = null;
		// An assignment or a compound assignment: the receiver (or array and index), then the value.
		function assign(e1:TExpr, e2:Null<TExpr>):Void {
			switch (e1.expr) {
				case TLocal(_):
					if (e2 != null) loop(e2);
				case TField(ef, fa):
					loop(ef);
					if (e2 != null) loop(e2);
					switch (fa) {
						case FStatic(c, cf): verdict(c, cf);
						case _:
					}
				case TArray(ea1, ea2):
					loop(ea1);
					loop(ea2);
					if (e2 != null) loop(e2);
				case _:
			}
		}
		loop = function(e:TExpr):Void {
			switch (e.expr) {
				case TVarExpr(_, eo):
					if (eo != null) loop(eo);
				case TConst(_) | TLocal(_) | TTypeExpr(_) | TBreak | TContinue:
				case TObjectDecl(fl):
					for (f in fl) loop(f.expr);
				case TArrayDecl(el):
					for (x in el) loop(x);
				// A closure compiles with its function (argument defaults are
				// constants).
				case TFunction(tf):
					loop(tf.expr);
				case TIf(c, a, b):
					loop(c);
					loop(a);
					if (b != null) loop(b);
				case TSwitch(e1, cases, def):
					loop(e1);
					for (c in cases) {
						for (v in c.values) loop(v);
						loop(c.expr);
					}
					if (def != null) loop(def);
				case TWhile(c, body, _):
					loop(c);
					loop(body);
				case TTry(e1, catches):
					loop(e1);
					for (c in catches) loop(c.expr);
				case TBlock(el):
					for (x in el) loop(x);
				case TReturn(eo):
					if (eo != null) loop(eo);
				case TThrow(e1) | TEnumParameter(e1, _, _) | TEnumIndex(e1) | TCast(e1, _) | TParenthesis(e1) | TMeta(_, e1):
					loop(e1);
				// Calls: a super method's arguments; on a field, the arguments and then the
				// receiver, except where the call goes to a static or enum slot and the receiver is
				// not compiled at all.
				case TCall({expr: TField({expr: TConst(TSuper)}, FInstance(_, _, _))}, el):
					for (x in el) loop(x);
				case TCall({expr: TField(ef, fa)}, el):
					for (x in el) loop(x);
					switch (fa) {
						case FStatic({path: {pack: [], name: "StringTools"}}, {name: "fastCodeAt" | "unsafeCodeAt"}) if (el.length == 2):
						case FEnum(_, _):
						case FStatic(c, cf) if (isProperStaticMethod(cf)):
							verdict(c, cf);
						// A proper method no subclass overrides is a call to its class's slot, the
						// receiver compiled first; an interface's, to its one implementer's.
						case FInstance(c, _, cf) if (isProperStaticMethod(cf) && isFinal(c, cf)):
							loop(ef);
							if (!TypeFunctions.hasClassFlag(c, CInterface))
								instanceVerdict(c, cf);
							else if (!ctx.isMacro && c.interfaces.length == 0 && c.superClass == null) switch (c.descendants) {
								case [c2] if (!TypeFunctions.hasClassFlag(c2, CInterface) && isFinal(c2, cf)): instanceVerdict(c2, cf);
								case _:
							}
						case _:
							loop(ef);
					}
				case TCall({expr: TConst(TSuper)}, el):
					for (x in el) loop(x);
				case TCall({expr: TIdent("$__mk_pos__")}, [a, b, c]):
					loop(a);
					loop(b);
					loop(c);
				case TCall(e1, el):
					loop(e1);
					for (x in el) loop(x);
				// A new Array compiles nothing of its arguments.
				case TNew({path: {pack: [], name: "Array"}}, _, _):
				case TNew({path: {pack: ["eval"], name: "Vector"}}, _, [{expr: TConst(TInt(_))}]):
				case TNew(_, _, el):
					for (x in el) loop(x);
				// A read of a static, an enum constructor or a plain method goes to the prototype;
				// `this.x` reads the slot.
				case TField(e1, fa):
					switch (fa) {
						case FStatic(c, cf): verdict(c, cf);
						case FEnum(_, _):
						case FInstance(_, _, {kind: Method(MethNormal | MethInline)}):
						case FInstance(c, _, _) if (!TypeFunctions.hasClassFlag(c, CInterface) && e1.expr.match(TConst(TThis))):
						case _: loop(e1);
					}
				case TArray(e1, e2):
					loop(e1);
					loop(e2);
				// A comparison with null compiles the other side only.
				case TBinop(OpEq | OpNotEq, e1, {expr: TConst(TNull)}) | TBinop(OpEq | OpNotEq, {expr: TConst(TNull)}, e1):
					loop(e1);
				case TBinop(OpAssign | OpAssignOp(_), e1, e2):
					assign(e1, e2);
				case TBinop(_, e1, e2):
					loop(e1);
					loop(e2);
				// Unary operators: ++ on an uncaptured local is a slot increment; any other ++ or -- is a
				// compound assignment with a constant one.
				case TUnop(Increment, _, e1) if (switch (hxc.core.TexprTools.skip(e1).expr) {
						case TLocal(v): !TypeFunctions.hasVarFlag(v, VCaptured);
						case _: false;
					}):
				case TUnop(Increment | Decrement, _, e1):
					assign(e1, null);
				case TUnop(_, _, e1):
					loop(e1);
				// A typed body is compiled once: a type is added again only from a new module, whose tree
				// is a
				// new one. Rebuilding the interpreter over the same tree reuses the loop the first compile
				// made.
				case TFor(v, e1, e2):
					var r = EvalEmitter.forRemapCache.get(e);
					if (r == null) {
						r = hxc.optimization.AnalyzerTexpr.TexprFilter.forRemap(com.basic, v, e1, e2, e.pos);
						EvalEmitter.forRemapCache.set(e, r);
					}
					loop(r);
				case TIdent(s):
					throw new hxc.core.TypingError("Unknown identifier: " + s, e.pos);
			}
		}
		loop(e);
	}

	// The methods compile in the order types are added: every instance prototype (a dynamic method's
	// instance slot first, then the prototype fields), then every static one. A field a builtin
	// replaces is never compiled.
	public static function jitTypes(ctx:EvalContext, types:Array<ModuleType>):Void {
		inline function fn(cf:TClassField):Null<TExpr>
			return switch (cf.expr) { case null: null; case {expr: TFunction(tf)}: tf.expr; case _: null; };
		inline function replaced(builtins:Null<Array<BuiltinField>>, cf:TClassField, skip:Null<Map<Int, Bool>>):Bool {
			var h = EvalHash.hash(cf.name);
			var hit = false;
			if (builtins != null) for (b in builtins) if (b.name == h) hit = true;
			return hit && (skip == null || !skip.exists(h));
		}
		for (mt in types) switch (mt) {
			case TClassDecl(c):
				if (TypeFunctions.hasClassFlag(c, CExtern) && !(c.path.pack.length == 0 && c.path.name == "String")) continue;
				var fields = [for (cf in c.orderedFields) if (!isRemovable(cf) && cf.kind.match(Method(_))) cf];
				for (cf in fields) if (cf.kind.match(Method(MethDynamic))) {
					var e = fn(cf);
					if (e != null) jitWalk(ctx, e);
				}
				var builtins:Null<Array<BuiltinField>> = ctx.builtins.instanceBuiltins.get(EvalHash.pathHash(c.path));
				for (cf in fields) if (!cf.kind.match(Method(MethDynamic)) && !replaced(builtins, cf, null)) {
					var e = fn(cf);
					if (e != null) jitWalk(ctx, e);
				}
			case _:
		}
		for (mt in types) switch (mt) {
			case TClassDecl(c):
				if (TypeFunctions.hasClassFlag(c, CExtern)) continue;
				var builtins:Null<Array<BuiltinField>> = ctx.builtins.staticBuiltins.get(EvalHash.pathHash(c.path));
				var skip:Null<Map<Int, Bool>> = null;
				if (isMacroApiClass(ctx, c)) {
					skip = new Map();
					for (cf in c.orderedStatics) if (cf.kind.match(Method(_))) skip.set(EvalHash.hash(cf.name), true);
				}
				for (cf in c.orderedStatics) if (!isRemovable(cf) && cf.kind.match(Method(_)) && !replaced(builtins, cf, skip)) {
					var e = fn(cf);
					if (e != null) jitWalk(ctx, e);
				}
			case _:
		}
	}

	static function isProperStaticMethod(cf:TClassField):Bool {
		return switch (cf.kind) {
			case Method(MethDynamic): false;
			case Method(_): true;
			case Var(_): false;
		};
	}

	// What a class's static prototype names: nothing of an extern class's own, no extern or generic
	// field, every method, and a variable with an initializer or storage, plus the builtins. The
	// compile step looks the name up in the class's prototype, whichever field holds it there
	// (buildStatic's slots). An extern is not in it, but its name can be: applying @:native paths
	// renames the field that implements it, as `@:native('add') function doAdd` does for an
	// `@:op extern function add`.
	static function inStaticPrototype(ctx:EvalContext, c:TClass, cf:TClassField):Bool {
		var builtins = ctx.builtins.staticBuiltins.get(EvalHash.pathHash(c.path));
		var name = EvalHash.hash(cf.name);
		if (builtins != null) for (b in builtins) if (b.name == name) return true;
		if (TypeFunctions.hasClassFlag(c, CExtern)) return false;
		function holds(f:TClassField):Bool {
			if (isRemovable(f) || (f.name != cf.name && nativeFieldName(f) != cf.name)) return false;
			return switch (f.kind) {
				case Method(_): true;
				case Var(_): f.expr != null || TypeFunctions.isPhysicalField(f);
			};
		}
		for (f in c.orderedStatics) if (holds(f)) return true;
		for (f in c.statics) if (holds(f)) return true;
		return false;
	}

	// What a class's instance prototype names (looked up in its own pnames): nothing of an extern
	// class's own but String's, no extern or generic field, every method, plus the builtins.
	static function inInstancePrototype(ctx:EvalContext, c:TClass, cf:TClassField):Bool {
		var builtins = ctx.builtins.instanceBuiltins.get(EvalHash.pathHash(c.path));
		var name = EvalHash.hash(cf.name);
		if (builtins != null) for (b in builtins) if (b.name == name) return true;
		if (TypeFunctions.hasClassFlag(c, CExtern) && !(c.path.pack.length == 0 && c.path.name == "String")) return false;
		for (f in c.orderedFields)
			if (!isRemovable(f) && (f.name == cf.name || nativeFieldName(f) == cf.name) && f.kind.match(Method(_)))
				return true;
		return false;
	}

	// Whether a static method's expr is null for good. hxc types statics lazily (the macro
	// interpreter forces nothing while it builds a prototype), so an unset expr is not yet that
	// verdict; the declaration's is: a @:multiType abstract's _new is never bound, nor is an abstract
	// field without a body, which is tagged @:noExpr.
	static function neverBound(c:TClass, cf:TClassField):Bool {
		if (TypeFunctions.hasMeta(":noExpr", cf.meta)) return true;
		return switch (c.kind) {
			case KAbstractImpl(a): cf.name == "_new" && TypeFunctions.hasMeta(":multiType", a.meta);
			case _: false;
		};
	}

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
						var tf = asFunction(cf.expr);
						if (tf != null) {
							var idx = pfields.length;
							pnames.set(EvalHash.hash(cf.name), idx);
							addNameAlias(pnames, cf, idx);
							var info = EvalContext.createEnvInfo(true, cf.namePos, EKMethod(key, EvalHash.hash(cf.name)), 0, 0);
							pfields.push(VFunction(makeFunction(ctx, tf, false, info, TypeFunctions.hasClassFieldFlag(cf, CfImpl)), true));
						} else if (neverBound(c, cf)) {
							// A method without an expression still has its slot, null, so a call to it
							// fails as
							// "Cannot call null".
							var idx = pfields.length;
							pnames.set(EvalHash.hash(cf.name), idx);
							addNameAlias(pnames, cf, idx);
							pfields.push(VNull);
						}
					case Var(_) if (cf.expr != null):
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
								jitWalk(ctx, init);
								EvalEmitter.numberClosures(init);
								proto.pfields[idx] = EvalEmitter.eval(ctx, init);
							} catch (e:haxe.Exception) {
								ctxEval.env = prev;
								throw e;
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
					try jitWalk(ctx, init) catch (e:haxe.Exception) {
						ctxEval.env = prev;
						throw e;
					}
					EvalEmitter.numberClosures(init);
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
