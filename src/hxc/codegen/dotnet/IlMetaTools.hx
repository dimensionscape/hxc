package hxc.codegen.dotnet;

import hxc.codegen.dotnet.IlMeta;
import hxc.codegen.dotnet.IlMeta.TableIdx as T;
import hxc.codegen.dotnet.IlData;

// paths of metadata types, normalized signatures, and a type definition gathered into an IlClass.
class IlMetaTools {
	public static function follow(s:IlSig):IlSig {
		while (true) switch (s) {
			case SReqModifier(_, s1) | SOptModifier(_, s1) | SPinned(s1): s = s1;
			case _: return s;
		}
	}

	// tells if a type_def_or_ref is of type `ns.name`
	public static function isType(ns:Array<String>, name:String, t:ClrMeta):Bool {
		return switch (t) {
			case TypeDef(td): IlPaths.strsEq(td.namespace, ns) && td.name == name;
			case TypeRef(tr): IlPaths.strsEq(tr.namespace, ns) && tr.name == name;
			case TypeSpec(ts): switch (follow(ts.signature)) {
					case SClass(c) | SValueType(c): isType(ns, name, c);
					case SGenericInst(s, _): switch (follow(s)) {
							case SClass(c) | SValueType(c): isType(ns, name, c);
							case _: false;
						}
					case _: false;
				}
			case _: throw "Assertion failed: is_type";
		}
	}

	public static function getPath(t:ClrMeta):IlPath {
		return switch (t) {
			case TypeDef(td):
				if (td.extraEnclosing == null) return {ns: td.namespace, nested: [], name: td.name};
				var p = getPath(TypeDef(td.extraEnclosing));
				{ns: p.ns, nested: p.nested.concat([p.name]), name: td.name};
			case TypeRef(tr): switch (tr.resolutionScope) {
					case TypeRef(tr2):
						var p = getPath(TypeRef(tr2));
						{ns: p.ns, nested: p.nested.concat([p.name]), name: tr.name};
					case _:
						{ns: tr.namespace, nested: [], name: tr.name};
				}
			case TypeSpec(ts): switch (follow(ts.signature)) {
					case SClass(c) | SValueType(c): getPath(c);
					case SGenericInst(s, _): switch (follow(s)) {
							case SClass(c) | SValueType(c): getPath(c);
							case _: {ns: [], nested: [], name: ""};
						}
					case _: {ns: [], nested: [], name: ""};
				}
			case _: throw "Assertion failed: get_path";
		}
	}

	static function pathS(p:IlPath):String {
		return switch [p.ns, p.nested] {
			case [[], []]: p.name;
			case [ns, []]: ns.join(".") + "." + p.name;
			case [[], enc]: enc.join("@") + "." + p.name;
			case [ns, enc]: ns.join(".") + "." + enc.join("@") + "." + p.name;
		}
	}

	public static function ilsigS(s:IlSig):String {
		return switch (s) {
			case SBoxed: "boxed";
			case SEnum(e): "enum " + e;
			case SType: "System.Type";
			case SVoid: "void";
			case SBool: "bool";
			case SChar: "char";
			case SInt8: "int8";
			case SUInt8: "uint8";
			case SInt16: "int16";
			case SUInt16: "uint16";
			case SInt32: "int32";
			case SUInt32: "uint32";
			case SInt64: "int64";
			case SUInt64: "uint64";
			case SFloat32: "float";
			case SFloat64: "double";
			case SString: "string";
			case SPointer(s): ilsigS(s) + "*";
			case SManagedPointer(s): ilsigS(s) + "&";
			case SValueType(td): "valuetype " + pathS(getPath(td));
			case SClass(cl): "classtype " + pathS(getPath(cl));
			case STypeParam(t) | SMethodTypeParam(t): "!" + t;
			case SArray(s, opts):
				ilsigS(s) + "[" + [
					for (o in opts) {
						var l = o.lower, sz = o.size;
						if (l != null && sz == null && l != 0) l + "...";
						else if (l == null && sz != null && sz != 0) "" + sz;
						else if (l != null && sz != null && sz == 0 && l != 0) l + "...";
						else if (l != null && sz != null && (l != 0 || sz != 0)) {
							var b = sz > 0 ? sz - 1 : sz;
							l + "..." + (l + b);
						} else "";
					}
				].join(",") + "]";
			case SGenericInst(t, tl): "generic " + ilsigS(t) + "<" + [for (t in tl) ilsigS(t)].join(", ") + ">";
			case STypedReference: "typedreference";
			case SIntPtr: "native int";
			case SUIntPtr: "native unsigned int";
			case SFunPtr(_, ret, args): "function " + ilsigS(ret) + "(" + [for (a in args) ilsigS(a)].join(", ") + ")";
			case SObject: "object";
			case SVector(s): ilsigS(s) + "[]";
			case SReqModifier(_, s): "modreq() " + ilsigS(s);
			case SOptModifier(_, s): "modopt() " + ilsigS(s);
			case SSentinel: "...";
			case SPinned(s): "pinned " + ilsigS(s);
		}
	}

	public static function ilsigNorm(s:IlSig):IlSigNorm {
		return switch (s) {
			case SVoid: LVoid;
			case SBool: LBool;
			case SChar: LChar;
			case SInt8: LInt8;
			case SUInt8: LUInt8;
			case SInt16: LInt16;
			case SUInt16: LUInt16;
			case SInt32: LInt32;
			case SUInt32: LUInt32;
			case SInt64: LInt64;
			case SUInt64: LUInt64;
			case SFloat32: LFloat32;
			case SFloat64: LFloat64;
			case SString: LString;
			case SPointer(p): LPointer(ilsigNorm(p));
			case SManagedPointer(p): LManagedPointer(ilsigNorm(p));
			case SValueType(v): LValueType(getPath(v), []);
			case SClass(v): LClass(getPath(v), []);
			case STypeParam(i): LTypeParam(i);
			case SArray(t, opts): LArray(ilsigNorm(t), opts);
			case SGenericInst(p, args): switch (follow(p)) {
					case SClass(v): LClass(getPath(v), [for (a in args) ilsigNorm(a)]);
					case SValueType(v): LValueType(getPath(v), [for (a in args) ilsigNorm(a)]);
					case _: throw "Assertion failed: ilsig_norm";
				}
			case STypedReference: LTypedReference;
			case SIntPtr: LIntPtr;
			case SUIntPtr: LUIntPtr;
			case SFunPtr(conv, ret, args): LMethod(conv, ilsigNorm(ret), [for (a in args) ilsigNorm(a)]);
			case SObject: LObject;
			case SVector(s): LVector(ilsigNorm(s));
			case SMethodTypeParam(i): LMethodTypeParam(i);
			case SReqModifier(_, s) | SOptModifier(_, s): ilsigNorm(s);
			case SSentinel: LSentinel;
			case SPinned(s): ilsigNorm(s);
			case SType: LClass({ns: ["System"], nested: [], name: "Type"}, []);
			case SBoxed: LObject;
			case SEnum(e):
				var lst = e.split(".");
				var name = lst.pop();
				LValueType({ns: lst, nested: [], name: name}, []);
		}
	}

	public static function ilsigT(s:IlSig):IlSigT return {snorm: ilsigNorm(s), ssig: s};

	public static function ilsigOfTdefRef(t:ClrMeta):IlSig {
		return switch (t) {
			case TypeDef(_) | TypeRef(_): SClass(t);
			case TypeSpec(ts): ts.signature;
			case _: throw "Invalid tdef_or_ref";
		}
	}

	public static function convertField(ctx:IlCtx, f:MetaField):IlField {
		// the last one folded over is the first one added
		var constant:Null<IlConstant> = null;
		for (r in ctx.findAll(T.IField, f.id)) switch (r) {
			case Constant(c): constant = c.value;
			case _:
		}
		return {fname: f.name, fflags: f.flags, fsig: ilsigT(f.signature), fconstant: constant};
	}

	public static function convertGeneric(ctx:IlCtx, gp:MetaGenericParam):IlTypeParam {
		var constraints = [];
		for (r in ctx.findAll(T.IGenericParam, gp.id)) switch (r) {
			case GenericParamConstraint(gc): constraints.unshift(ilsigT(ilsigOfTdefRef(gc.constraint)));
			case _:
		}
		return {tnumber: gp.number, tflags: gp.flags, tname: gp.name, tconstraints: constraints};
	}

	public static function convertMethod(ctx:IlCtx, m:MetaMethod):IlMethod {
		var msig = ilsigT(m.signature);
		var ret:IlSigT, margs:Array<IlMethodArg>;
		switch (follow(msig.ssig)) {
			case SFunPtr(_, r, args):
				var paramList = [for (p in m.paramList) if (p.sequence > 0) p];
				ret = ilsigT(r);
				if (paramList.length != args.length) {
					var i = 0;
					margs = [
						for (s in args) {name: "arg" + (++i), flags: ParamFlags.nullFlags, sig: ilsigT(s), constant: null, pdefault: null}
					];
				} else
					margs = [
						for (i in 0...args.length) {
							var p = paramList[i];
							var constant:Null<IlConstant> = null, pdefault:Null<IlParamDefault> = null;
							for (r in ctx.findAll(T.IParam, p.id)) switch (r) {
								case Constant(c):
									constant = c.value;
								case CustomAttribute(a):
									var d = paramDefault(a);
									if (d != null) pdefault = d;
								case _:
							}
							{name: p.name, flags: p.flags, sig: ilsigT(args[i]), constant: constant, pdefault: pdefault};
						}
					];
			case _:
				throw "Assertion failed: convert_method";
		}
		var overridden:Null<{path:IlPath, name:String}> = null;
		var types = [];
		var semantics:Array<SemanticFlag> = [];
		for (r in ctx.findAll(T.IMethod, m.id)) switch (r) {
			case MethodImpl(mi):
				switch (mi.methodDeclaration) {
					case MemberRef(mr): overridden = {path: getPath(mr.cls), name: mr.name};
					case Method(m2) if (m2.declaring != null): overridden = {path: getPath(TypeDef(m2.declaring)), name: m2.name};
					case _:
				}
			case GenericParam(gp):
				types.unshift(convertGeneric(ctx, gp));
			case MethodSemantics(ms):
				semantics = ms.semantic.concat(semantics);
			case _:
		}
		return {
			mname: m.name,
			mflags: m.flags,
			msig: msig,
			margs: margs,
			mret: ret,
			moverride: overridden,
			mtypes: types,
			msemantics: semantics,
		};
	}

	// The namespace and name of a custom attribute's type, from its constructor.
	public static function attrType(a:MetaCustomAttribute):Null<{ns:Array<String>, name:String}> {
		return switch (a.type) {
			case Method(m) if (m.declaring != null): {ns: m.declaring.namespace, name: m.declaring.name};
			case MemberRef(r): switch (r.cls) {
					case TypeRef(t): {ns: t.namespace, name: t.name};
					case TypeDef(d): {ns: d.namespace, name: d.name};
					case _: null;
				}
			case _: null;
		}
	}

	// The default value a parameter's DecimalConstant or DateTimeConstant attribute gives, or its params
	// array; null for any other attribute.
	static function paramDefault(a:MetaCustomAttribute):Null<IlParamDefault> {
		var t = attrType(a);
		if (t == null) return null;
		if (t.name == "ParamArrayAttribute" && IlPaths.strsEq(t.ns, ["System"])) return PParamArray;
		if (!IlPaths.strsEq(t.ns, ["System", "Runtime", "CompilerServices"]) || a.value == null) return null;
		var fixed = a.value.fixed;
		// Both of DecimalConstantAttribute's constructors: (byte, byte, uint, uint, uint) and (byte, byte, int, int, int).
		function int(i:Int):Null<Int> {
			return switch (fixed[i]) {
				case InstConstant(IByte(v) | IInt(v)): v;
				case _: null;
			}
		}
		switch (t.name) {
			case "DecimalConstantAttribute" if (fixed.length == 5):
				var scale = int(0), sign = int(1), hi = int(2), mid = int(3), lo = int(4);
				if (scale != null && sign != null && hi != null && mid != null && lo != null) return PDecimal(scale, sign != 0, hi, mid, lo);
			case "DateTimeConstantAttribute" if (fixed.length == 1):
				switch (fixed[0]) {
					case InstConstant(IInt64(_, ticks)): return PDateTime(ticks);
					case _:
				}
			case _:
		}
		return null;
	}

	static function accessor(ms:MetaMethodSemantics):IlAccessor return {name: ms.method.name, flags: ms.method.flags};

	public static function convertProp(ctx:IlCtx, prop:MetaProperty):IlProp {
		var pget:Null<IlAccessor> = null, pset:Null<IlAccessor> = null;
		for (r in ctx.findAll(T.IProperty, prop.id)) switch (r) {
			case MethodSemantics(ms) if (ms.semantic.indexOf(SGetter) >= 0):
				if (pget != null) throw "Assertion failed: convert_prop";
				pget = accessor(ms);
			case MethodSemantics(ms) if (ms.semantic.indexOf(SSetter) >= 0):
				if (pset != null) throw "Assertion failed: convert_prop";
				pset = accessor(ms);
			case _:
		}
		return {pname: prop.name, psig: ilsigT(prop.type), pflags: prop.flags, pget: pget, pset: pset};
	}

	public static function convertEvent(ctx:IlCtx, event:MetaEvent):IlEvent {
		var esig = ilsigT(ilsigOfTdefRef(event.eventType));
		var add:Null<IlAccessor> = null, remove:Null<IlAccessor> = null, eraise:Null<IlAccessor> = null;
		for (r in ctx.findAll(T.IEvent, event.id)) switch (r) {
			case MethodSemantics(ms) if (ms.semantic.indexOf(SAddOn) >= 0):
				if (add != null) throw "Assertion failed: convert_event";
				add = accessor(ms);
			case MethodSemantics(ms) if (ms.semantic.indexOf(SRemoveOn) >= 0):
				if (remove != null) throw "Assertion failed: convert_event";
				remove = accessor(ms);
			case MethodSemantics(ms) if (ms.semantic.indexOf(SFire) >= 0):
				if (eraise != null) throw "Assertion failed: convert_event";
				eraise = accessor(ms);
			case _:
		}
		return {ename: event.name, eflags: event.flags, esig: esig, eadd: add, eremove: remove, eraise: eraise};
	}

	// throws NotFound when the library has no such type.
	public static function convertClass(ctx:IlCtx, path:IlPath):IlClass {
		var td = ctx.typedefs.get(IlPaths.key(path));
		if (td == null) throw NotFound;
		var cpath = getPath(TypeDef(td));
		var csuper = td.extends_ == null ? null : ilsigT(ilsigOfTdefRef(td.extends_));
		var cfields = [for (f in td.fieldList) convertField(ctx, f)];
		var cmethods = [for (m in td.methodList) convertMethod(ctx, m)];
		var enclosing = td.extraEnclosing == null ? null : getPath(TypeDef(td.extraEnclosing));
		var impl = [], types = [], nested = [], props = [], events = [], attrs = [];
		for (r in ctx.findAll(T.ITypeDef, td.id)) switch (r) {
			case InterfaceImpl(ii):
				impl.unshift(ilsigT(ilsigOfTdefRef(ii.iface)));
			case GenericParam(gp):
				types.unshift(convertGeneric(ctx, gp));
			case NestedClass(nc):
				if (nc.enclosing.id != td.id) throw "Assertion failed: convert_class";
				nested.unshift(getPath(TypeDef(nc.nested)));
			case PropertyMap(pm):
				if (props.length != 0) throw "Assertion failed: convert_class";
				props = [for (p in pm.propertyList) convertProp(ctx, p)];
			case EventMap(em):
				if (events.length != 0) throw "Assertion failed: convert_class";
				events = [for (e in em.eventList) convertEvent(ctx, e)];
			case CustomAttribute(a):
				attrs.unshift(a);
			case _:
		}
		return {
			cpath: cpath,
			cflags: td.flags,
			csuper: csuper,
			cfields: cfields,
			cmethods: cmethods,
			cevents: events,
			cprops: props,
			cimplements: impl,
			ctypes: types,
			cenclosing: enclosing,
			cnested: nested,
			cattrs: attrs,
		};
	}
}

// the reference's Not_found, for a type a library does not define.
enum IlNotFound {
	NotFound;
}
