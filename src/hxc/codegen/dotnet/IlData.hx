package hxc.codegen.dotnet;

import hxc.codegen.dotnet.IlMeta;

// the class model the converter reads: a type definition with its members gathered and its
// signatures normalized.

typedef IlPath = {ns:Array<String>, nested:Array<String>, name:String};

enum IlSigNorm {
	LVoid;
	LBool;
	LChar;
	LInt8;
	LUInt8;
	LInt16;
	LUInt16;
	LInt32;
	LUInt32;
	LInt64;
	LUInt64;
	LFloat32;
	LFloat64;
	LString;
	LObject;
	LPointer(s:IlSigNorm);
	LTypedReference;
	LIntPtr;
	LUIntPtr;
	LManagedPointer(s:IlSigNorm);
	LValueType(p:IlPath, params:Array<IlSigNorm>);
	LClass(p:IlPath, params:Array<IlSigNorm>);
	LTypeParam(i:Int);
	LMethodTypeParam(i:Int);
	LVector(s:IlSigNorm);
	LArray(s:IlSigNorm, dims:Array<ArrayDim>);
	LMethod(cc:Array<CallConv>, ret:IlSigNorm, args:Array<IlSigNorm>);
	LSentinel;
}

@:structInit
class IlSigT {
	public var snorm:IlSigNorm;
	public var ssig:IlSig;

	public function new(snorm, ssig) {
		this.snorm = snorm;
		this.ssig = ssig;
	}

	public function withNorm(n:IlSigNorm):IlSigT return {snorm: n, ssig: ssig};
}

@:structInit
class IlClass {
	public var cpath:IlPath;
	public var cflags:TypeDefFlags;
	public var csuper:Null<IlSigT>;
	public var cfields:Array<IlField>;
	public var cmethods:Array<IlMethod>;
	public var cimplements:Array<IlSigT>;
	public var ctypes:Array<IlTypeParam>;
	public var cprops:Array<IlProp>;
	public var cevents:Array<IlEvent>;
	public var cenclosing:Null<IlPath>;
	public var cnested:Array<IlPath>;
	public var cattrs:Array<MetaCustomAttribute>;

	public function new(cpath, cflags, csuper, cfields, cmethods, cimplements, ctypes, cprops, cevents, cenclosing, cnested, cattrs) {
		this.cpath = cpath;
		this.cflags = cflags;
		this.csuper = csuper;
		this.cfields = cfields;
		this.cmethods = cmethods;
		this.cimplements = cimplements;
		this.ctypes = ctypes;
		this.cprops = cprops;
		this.cevents = cevents;
		this.cenclosing = cenclosing;
		this.cnested = cnested;
		this.cattrs = cattrs;
	}

	public function copy():IlClass
		return {cpath: cpath, cflags: cflags, csuper: csuper, cfields: cfields, cmethods: cmethods, cimplements: cimplements,
			ctypes: ctypes, cprops: cprops, cevents: cevents, cenclosing: cenclosing, cnested: cnested, cattrs: cattrs};
}

@:structInit
class IlTypeParam {
	public var tnumber:Int;
	public var tflags:GenericFlags;
	public var tname:Null<String>;
	public var tconstraints:Array<IlSigT>;

	public function new(tnumber, tflags, tname, tconstraints) {
		this.tnumber = tnumber;
		this.tflags = tflags;
		this.tname = tname;
		this.tconstraints = tconstraints;
	}
}

typedef IlAccessor = {name:String, flags:MethodFlags};

@:structInit
class IlEvent {
	public var ename:String;
	public var eflags:Array<EventFlag>;
	public var eadd:Null<IlAccessor>;
	public var eremove:Null<IlAccessor>;
	public var eraise:Null<IlAccessor>;
	public var esig:IlSigT;

	public function new(ename, eflags, eadd, eremove, eraise, esig) {
		this.ename = ename;
		this.eflags = eflags;
		this.eadd = eadd;
		this.eremove = eremove;
		this.eraise = eraise;
		this.esig = esig;
	}
}

@:structInit
class IlField {
	public var fname:String;
	public var fflags:FieldFlags;
	public var fsig:IlSigT;
	public var fconstant:Null<IlConstant>;

	public function new(fname, fflags, fsig, fconstant) {
		this.fname = fname;
		this.fflags = fflags;
		this.fsig = fsig;
		this.fconstant = fconstant;
	}

	public function copy():IlField return {fname: fname, fflags: fflags, fsig: fsig, fconstant: fconstant};
}

// A parameter's default value as a custom attribute gives it, not a Constant row, or its `params` array:
// what C# fills the argument with when a call leaves it out.
enum IlParamDefault {
	// DecimalConstantAttribute: the decimal(lo, mid, hi, negative, scale) constructor's arguments.
	PDecimal(scale:Int, negative:Bool, hi:Int, mid:Int, lo:Int);
	// DateTimeConstantAttribute.
	PDateTime(ticks:haxe.Int64);
	// ParamArrayAttribute: an empty array.
	PParamArray;
}

// `constant` is the parameter's Constant row (its C# default value), if any.
typedef IlMethodArg = {name:String, flags:ParamFlags, sig:IlSigT, constant:Null<IlConstant>, pdefault:Null<IlParamDefault>};

@:structInit
class IlMethod {
	public var mname:String;
	public var mflags:MethodFlags;
	public var msig:IlSigT;
	public var margs:Array<IlMethodArg>;
	public var mret:IlSigT;
	// the declaring class and the name of the method this one implements (method_impl)
	public var moverride:Null<{path:IlPath, name:String}>;
	public var mtypes:Array<IlTypeParam>;
	public var msemantics:Array<SemanticFlag>;

	public function new(mname, mflags, msig, margs, mret, moverride, mtypes, msemantics) {
		this.mname = mname;
		this.mflags = mflags;
		this.msig = msig;
		this.margs = margs;
		this.mret = mret;
		this.moverride = moverride;
		this.mtypes = mtypes;
		this.msemantics = msemantics;
	}

	public function copy():IlMethod
		return {mname: mname, mflags: mflags, msig: msig, margs: margs, mret: mret, moverride: moverride, mtypes: mtypes,
			msemantics: msemantics};
}

@:structInit
class IlProp {
	public var pname:String;
	public var psig:IlSigT;
	public var pflags:Array<PropertyFlag>;
	public var pget:Null<IlAccessor>;
	public var pset:Null<IlAccessor>;

	public function new(pname, psig, pflags, pget, pset) {
		this.pname = pname;
		this.psig = psig;
		this.pflags = pflags;
		this.pget = pget;
		this.pset = pset;
	}

	public function copy():IlProp return {pname: pname, psig: psig, pflags: pflags, pget: pget, pset: pset};
}

// the relations are kept per table row in the order they were added; il_typedefs is keyed by
// IlData.pathKey and listed in table order.
class IlCtx {
	public var tables:Array<Array<ClrMeta>>;
	public var relations:Map<Int, Array<ClrMeta>>;
	public var typedefs:Map<String, MetaTypeDef>;
	public var typedefOrder:Array<MetaTypeDef>;

	public function new(tables, relations, typedefs, typedefOrder) {
		this.tables = tables;
		this.relations = relations;
		this.typedefs = typedefs;
		this.typedefOrder = typedefOrder;
	}

	public static inline function relationKey(table:Int, id:Int):Int return (table << 24) | id;

	// what Hashtbl.find_all gives: the most recently added first.
	public function findAll(table:Int, id:Int):Array<ClrMeta> {
		var l = relations.get(relationKey(table, id));
		if (l == null) return [];
		var r = l.copy();
		r.reverse();
		return r;
	}
}

// A type forwarder: the type it names and the assembly it sends it to (null when it sends it elsewhere,
// to a file of this assembly or to another forwarder's type).
typedef IlForwarder = {name:String, ns:Array<String>, to:Null<String>};

// What an assembly's tables tell without all their rows being read: the types it defines, in table
// order, the names of the assemblies it references, in table order, and its type forwarders.
class IlLight {
	public var types:Array<IlPath>;
	public var assemblyRefs:Array<String>;
	public var forwarders:Array<IlForwarder>;

	public function new(types, assemblyRefs, forwarders) {
		this.types = types;
		this.assemblyRefs = assemblyRefs;
		this.forwarders = forwarders;
	}
}

class IlPaths {
	public static function key(p:IlPath):String
		return p.ns.join(".") + "\n" + p.nested.join("\n") + "\n" + p.nested.length + "\n" + p.name;

	public static function equals(a:IlPath, b:IlPath):Bool
		return a.name == b.name && strsEq(a.ns, b.ns) && strsEq(a.nested, b.nested);

	public static function strsEq(a:Array<String>, b:Array<String>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (a[i] != b[i]) return false;
		return true;
	}

	// the reference's structural equality on normalized signatures.
	public static function sigEq(a:IlSigNorm, b:IlSigNorm):Bool {
		return switch [a, b] {
			case [LPointer(s1), LPointer(s2)] | [LManagedPointer(s1), LManagedPointer(s2)] | [LVector(s1), LVector(s2)]:
				sigEq(s1, s2);
			case [LValueType(p1, l1), LValueType(p2, l2)] | [LClass(p1, l1), LClass(p2, l2)]:
				equals(p1, p2) && sigsEq(l1, l2);
			case [LTypeParam(i1), LTypeParam(i2)] | [LMethodTypeParam(i1), LMethodTypeParam(i2)]:
				i1 == i2;
			case [LArray(s1, d1), LArray(s2, d2)]:
				if (!sigEq(s1, s2) || d1.length != d2.length) return false;
				for (i in 0...d1.length) if (d1[i].lower != d2[i].lower || d1[i].size != d2[i].size) return false;
				true;
			case [LMethod(c1, r1, a1), LMethod(c2, r2, a2)]:
				if (c1.length != c2.length) return false;
				for (i in 0...c1.length) if (!Type.enumEq(c1[i], c2[i])) return false;
				sigEq(r1, r2) && sigsEq(a1, a2);
			case [LPointer(_) | LManagedPointer(_) | LVector(_) | LValueType(_, _) | LClass(_, _) | LTypeParam(_)
				| LMethodTypeParam(_) | LArray(_, _) | LMethod(_, _, _), _]:
				false;
			case _:
				Type.enumIndex(a) == Type.enumIndex(b);
		}
	}

	public static function sigsEq(a:Array<IlSigNorm>, b:Array<IlSigNorm>):Bool {
		if (a.length != b.length) return false;
		for (i in 0...a.length) if (!sigEq(a[i], b[i])) return false;
		return true;
	}
}
