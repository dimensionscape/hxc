package hxc.eval;

import hxc.ast.Position;
import hxc.eval.EvalValue;
import hxc.eval.EvalValue.EvalValueTools;
import hxc.eval.EvalContext;
import hxc.eval.EvalField;
import hxc.eval.EvalMisc;
import hxc.eval.EvalHash;

// Native builtins for extern standard-library types. Each entry maps a type and field name to a
// value (a function or a constant) that the prototype builder installs on the type's prototype.
class EvalStdLib {
	static function reg(map:Map<Int, Array<BuiltinField>>, typeName:String, fieldName:String, v:EvalValue):Void {
		var key = EvalHash.hash(typeName);
		var list = map.get(key);
		if (list == null) {
			list = [];
			map.set(key, list);
		}
		list.push({name: EvalHash.hash(fieldName), v: v});
	}

	static inline function vfn(f:VFunc):EvalValue return VFunction(f, true);

	// An instance builtin: a non-static function so dispatch wraps it with the receiver.
	static inline function vmethod(f:VFunc):EvalValue return VFunction(f, false);

	static inline function arg(a:Array<EvalValue>, i:Int):EvalValue return i < a.length ? a[i] : VNull;

	static function toInt(v:EvalValue):Int {
		return switch (v) {
			case VInt(i): i;
			case VFloat(f): Std.int(f);
			case _: 0;
		};
	}

	static function thisString(a:Array<EvalValue>):String {
		return switch (a[0]) {
			case VString(s): s.sstring;
			case _: "";
		};
	}

	static function thisArray(a:Array<EvalValue>):VArray {
		return switch (a[0]) {
			case VArray(va): va;
			case _: new VArray([], 0);
		};
	}

	static function fieldNames(v:EvalValue):Array<String> {
		return switch (v) {
			case VObject(o):
				switch (o.oproto) {
					case OProto(proto): [for (k in proto.pinstanceNames.keys()) EvalHash.revHash(k)];
					case ODictionary(l): [for (k in l.keys()) EvalHash.revHash(k)];
				};
			case VInstance(vi): [for (k in vi.iproto.pinstanceNames.keys()) EvalHash.revHash(k)];
			case _: [];
		};
	}

	static function argList(v:EvalValue):Array<EvalValue> {
		return switch (v) {
			case VArray(va): va.avalues.slice(0, va.alength);
			case _: [];
		};
	}

	static function thisBuffer(a:Array<EvalValue>):StringBuf {
		return switch (a[0]) {
			case VInstance(vi): switch (vi.ikind) { case IBuffer(b): b; case _: new StringBuf(); };
			case _: new StringBuf();
		};
	}

	static function thisRegex(a:Array<EvalValue>):EReg {
		return switch (a[0]) {
			case VInstance(vi): switch (vi.ikind) { case IRegex(r): r; case _: new EReg("", ""); };
			case _: new EReg("", "");
		};
	}

	static function toFloat(v:EvalValue):Float {
		return switch (v) {
			case VInt(i): i;
			case VFloat(f): f;
			case _: Math.NaN;
		};
	}

	static inline function mkStr(s:String):EvalValue return VString(new VString(s, s.length));

	static function stringOf(v:EvalValue):String {
		return switch (v) {
			case VNull: "null";
			case VTrue: "true";
			case VFalse: "false";
			case VInt(i): Std.string(i);
			case VFloat(f): Std.string(f);
			case VString(s): s.sstring;
			case VNativeString(s): s;
			case _: "<value>";
		};
	}

	public static function init(ctx:EvalContext):Void {
		var s = ctx.builtins.staticBuiltins;

		reg(s, "Math", "PI", VFloat(Math.PI));
		reg(s, "Math", "NaN", VFloat(Math.NaN));
		reg(s, "Math", "POSITIVE_INFINITY", VFloat(Math.POSITIVE_INFINITY));
		reg(s, "Math", "NEGATIVE_INFINITY", VFloat(Math.NEGATIVE_INFINITY));
		reg(s, "Math", "floor", vfn(a -> VInt(Math.floor(toFloat(arg(a, 0))))));
		reg(s, "Math", "ceil", vfn(a -> VInt(Math.ceil(toFloat(arg(a, 0))))));
		reg(s, "Math", "round", vfn(a -> VInt(Math.round(toFloat(arg(a, 0))))));
		reg(s, "Math", "abs", vfn(a -> VFloat(Math.abs(toFloat(arg(a, 0))))));
		reg(s, "Math", "sqrt", vfn(a -> VFloat(Math.sqrt(toFloat(arg(a, 0))))));
		reg(s, "Math", "pow", vfn(a -> VFloat(Math.pow(toFloat(arg(a, 0)), toFloat(arg(a, 1))))));
		reg(s, "Math", "min", vfn(a -> VFloat(Math.min(toFloat(arg(a, 0)), toFloat(arg(a, 1))))));
		reg(s, "Math", "max", vfn(a -> VFloat(Math.max(toFloat(arg(a, 0)), toFloat(arg(a, 1))))));

		reg(s, "Std", "int", vfn(a -> VInt(Std.int(toFloat(arg(a, 0))))));
		reg(s, "Std", "string", vfn(a -> mkStr(stringOf(arg(a, 0)))));
		reg(s, "Std", "parseInt", vfn(a -> { var r = Std.parseInt(stringOf(arg(a, 0))); r == null ? VNull : VInt(r); }));
		reg(s, "Std", "parseFloat", vfn(a -> VFloat(Std.parseFloat(stringOf(arg(a, 0))))));

		var inst = ctx.builtins.instanceBuiltins;

		reg(inst, "String", "charAt", vmethod(a -> mkStr(thisString(a).charAt(toInt(arg(a, 1))))));
		reg(inst, "String", "charCodeAt", vmethod(a -> {
			var str = thisString(a);
			var i = toInt(arg(a, 1));
			(i >= 0 && i < str.length) ? VInt(str.charCodeAt(i)) : VNull;
		}));
		reg(inst, "String", "indexOf", vmethod(a -> VInt(thisString(a).indexOf(stringOf(arg(a, 1)), a.length > 2 ? toInt(arg(a, 2)) : 0))));
		reg(inst, "String", "lastIndexOf", vmethod(a -> VInt(thisString(a).lastIndexOf(stringOf(arg(a, 1))))));
		reg(inst, "String", "toUpperCase", vmethod(a -> mkStr(thisString(a).toUpperCase())));
		reg(inst, "String", "toLowerCase", vmethod(a -> mkStr(thisString(a).toLowerCase())));
		reg(inst, "String", "substr", vmethod(a -> {
			var str = thisString(a);
			var pos = toInt(arg(a, 1));
			mkStr(a.length > 2 && arg(a, 2) != VNull ? str.substr(pos, toInt(arg(a, 2))) : str.substr(pos));
		}));
		reg(inst, "String", "substring", vmethod(a -> {
			var str = thisString(a);
			var start = toInt(arg(a, 1));
			mkStr(a.length > 2 && arg(a, 2) != VNull ? str.substring(start, toInt(arg(a, 2))) : str.substring(start));
		}));
		reg(inst, "String", "split", vmethod(a -> {
			var parts = thisString(a).split(stringOf(arg(a, 1)));
			VArray(new VArray([for (p in parts) mkStr(p)], parts.length));
		}));
		reg(inst, "String", "toString", vmethod(a -> arg(a, 0)));

		reg(inst, "Array", "push", vmethod(a -> {
			var va = thisArray(a);
			va.avalues.push(arg(a, 1));
			va.alength = va.avalues.length;
			VInt(va.alength);
		}));
		reg(inst, "Array", "pop", vmethod(a -> {
			var va = thisArray(a);
			if (va.alength == 0) VNull;
			else {
				var v = va.avalues.pop();
				va.alength = va.avalues.length;
				v;
			}
		}));
		reg(inst, "Array", "concat", vmethod(a -> {
			var va = thisArray(a);
			var other = thisArray([arg(a, 1)]);
			VArray(new VArray(va.avalues.concat(other.avalues), va.alength + other.alength));
		}));
		reg(inst, "Array", "join", vmethod(a -> {
			var va = thisArray(a);
			mkStr([for (i in 0...va.alength) stringOf(va.avalues[i])].join(stringOf(arg(a, 1))));
		}));
		reg(inst, "Array", "indexOf", vmethod(a -> {
			var va = thisArray(a);
			var target = arg(a, 1);
			var idx = -1;
			for (i in 0...va.alength) if (EvalValueTools.equals(va.avalues[i], target)) {
				idx = i;
				break;
			}
			VInt(idx);
		}));
		reg(inst, "Array", "toString", vmethod(a -> {
			var va = thisArray(a);
			mkStr("[" + [for (i in 0...va.alength) stringOf(va.avalues[i])].join(",") + "]");
		}));
		reg(inst, "Array", "iterator", vmethod(a -> EvalEmitter.constructPath(ctx, EvalHash.hash("haxe.iterators.ArrayIterator"), [a[0]])));

		reg(s, "Reflect", "fields", vfn(a -> {
			var names = fieldNames(arg(a, 0));
			VArray(new VArray([for (n in names) mkStr(n)], names.length));
		}));
		reg(s, "Reflect", "field", vfn(a -> EvalField.field(ctx, arg(a, 0), EvalHash.hash(stringOf(arg(a, 1))))));
		reg(s, "Reflect", "setField", vfn(a -> {
			EvalField.setField(ctx, arg(a, 0), EvalHash.hash(stringOf(arg(a, 1))), arg(a, 2), Position.nullPos);
			VNull;
		}));
		reg(s, "Reflect", "hasField", vfn(a -> {
			var name = stringOf(arg(a, 1));
			EvalValueTools.vbool(fieldNames(arg(a, 0)).indexOf(name) != -1);
		}));
		reg(s, "Reflect", "isFunction", vfn(a -> EvalValueTools.vbool(switch (arg(a, 0)) {
			case VFunction(_, _) | VFieldClosure(_, _): true;
			case _: false;
		})));
		reg(s, "Reflect", "compare", vfn(a -> VInt(switch (EvalMisc.compare(arg(a, 0), arg(a, 1))) {
			case CEq: 0;
			case CInf: -1;
			case CSup: 1;
			case CUndef: 0;
		})));

		reg(s, "Type", "getClass", vfn(a -> switch (arg(a, 0)) {
			case VInstance(vi):
				var p = ctx.staticPrototypes.get(vi.iproto.ppath);
				p == null ? VNull : p.pvalue;
			case _: VNull;
		}));
		reg(s, "Type", "getClassName", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto): mkStr(EvalHash.revHash(proto.ppath));
			case _: VNull;
		}));
		reg(s, "Type", "createInstance", vfn(a -> switch (arg(a, 0)) {
			case VPrototype(proto):
				var iproto = ctx.instancePrototypes.get(proto.ppath);
				if (iproto == null) VNull;
				else {
					var inst = new VInstance(iproto.pinstanceFields.copy(), iproto, INormal);
					var ctor = ctx.constructors.get(proto.ppath);
					if (ctor != null) ctor([VInstance(inst)].concat(argList(arg(a, 1))));
					VInstance(inst);
				}
			case _: VNull;
		}));

		var ctors = ctx.builtins.constructorBuiltins;
		ctors.set(EvalHash.hash("StringBuf"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("StringBuf"));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IBuffer(new StringBuf())));
		});
		ctors.set(EvalHash.hash("EReg"), function(a) {
			var proto = ctx.instancePrototypes.get(EvalHash.hash("EReg"));
			return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, IRegex(new EReg(stringOf(arg(a, 0)), stringOf(arg(a, 1))))));
		});

		reg(inst, "StringBuf", "add", vmethod(a -> {
			thisBuffer(a).add(stringOf(arg(a, 1)));
			VNull;
		}));
		reg(inst, "StringBuf", "addChar", vmethod(a -> {
			thisBuffer(a).addChar(toInt(arg(a, 1)));
			VNull;
		}));
		reg(inst, "StringBuf", "toString", vmethod(a -> mkStr(thisBuffer(a).toString())));

		reg(inst, "EReg", "match", vmethod(a -> EvalValueTools.vbool(thisRegex(a).match(stringOf(arg(a, 1))))));
		reg(inst, "EReg", "matched", vmethod(a -> mkStr(thisRegex(a).matched(toInt(arg(a, 1))))));
		reg(inst, "EReg", "replace", vmethod(a -> mkStr(thisRegex(a).replace(stringOf(arg(a, 1)), stringOf(arg(a, 2))))));
	}
}
