package hxc.eval;

import hxc.ast.Position;
import hxc.eval.EvalValue;
import hxc.eval.EvalValue.EvalValueTools.vresolve;
import hxc.eval.EvalContext;
import hxc.eval.EvalExceptions;
import hxc.eval.EvalHash;
import hxc.core.NotFound;

// Field reads against runtime values: prototypes walk the parent chain, instances try their own
// fields then their prototype's methods, objects read their offset array or dictionary.
class EvalField {
	public static function protoFieldDirect(proto:VPrototype, name:Int):EvalValue {
		return proto.pfields[EvalContext.getProtoFieldIndexRaise(proto, name)];
	}

	public static function protoFieldRaise(proto:VPrototype, name:Int):EvalValue {
		var p = proto;
		while (p != null) {
			var idx = p.pnames.get(name);
			if (idx != null) return p.pfields[idx];
			p = p.pparent;
		}
		throw new NotFound();
	}

	public static function instanceField(vi:VInstance, name:Int):EvalValue {
		return vi.ifields[EvalContext.getInstanceFieldIndexRaise(vi.iproto, name)];
	}

	public static function objectFieldRaise(o:VObject, name:Int):EvalValue {
		return switch (o.oproto) {
			case OProto(proto): o.ofields[EvalContext.getInstanceFieldIndexRaise(proto, name)];
			case ODictionary(l):
				var v = l.get(name);
				if (v == null) throw new NotFound();
				v;
		};
	}

	public static function objectField(o:VObject, name:Int):EvalValue {
		return try objectFieldRaise(o, name) catch (_:NotFound) VNull;
	}

	public static function fieldRaise(ctx:EvalContext, v:EvalValue, f:Int):EvalValue {
		return switch (vresolve(v)) {
			case VObject(o): objectFieldRaise(o, f);
			case VPrototype(proto): protoFieldRaise(proto, f);
			case VArray(va): f == EvalHash.keyLength ? VInt(va.alength) : sharedField(ctx.arrayPrototype, f);
			case VVector(vv): f == EvalHash.keyLength ? VInt(vv.length) : sharedField(ctx.vectorPrototype, f);
			case VString(s): f == EvalHash.keyLength ? VInt(EvalStdLib.runtimeStringLength(s)) : sharedField(ctx.stringPrototype, f);
				// eval.NativeString is the interpreter's raw-string optimization; for field access it is a
				// String, so length and the String methods resolve through the shared string prototype.
			case VNativeString(s): f == EvalHash.keyLength ? VInt(s.length) : sharedField(ctx.stringPrototype, f);
			case VInstance(vi):
				switch (vi.ikind) {
					case IBytes(b) if (f == EvalHash.keyLength): VInt(b.length);
					case IBuffer(buf) if (f == EvalHash.keyLength): VInt(buf.length);
					case _: try instanceField(vi, f) catch (_:NotFound) protoFieldRaise(vi.iproto, f);
				}
			case _: throw new NotFound();
		};
	}

	static inline function sharedField(proto:Null<VPrototype>, f:Int):EvalValue {
		if (proto == null) throw new NotFound();
		return protoFieldDirect(proto, f);
	}

	public static function field(ctx:EvalContext, v:EvalValue, f:Int):EvalValue {
		return try fieldRaise(ctx, v, f) catch (_:NotFound) VNull;
	}

	public static function dynamicField(ctx:EvalContext, v:EvalValue, name:Int):EvalValue {
		// A String method bound off eval.NativeString must receive a real VString as `this`, so the
		// String builtins (which read VString) see the text rather than an empty default.
		var recv = switch (vresolve(v)) {
			case VNativeString(s): VString(new VString(s, EvalStdLib.stringLength(s)));
			case r: r;
		};
		return switch (field(ctx, recv, name)) {
			case VFunction(f, false): VFieldClosure(recv, f);
			case other: other;
		};
	}

	public static function setField(ctx:EvalContext, v:EvalValue, name:Int, value:EvalValue, p:Position):Void {
		switch (vresolve(v)) {
			case VInstance(vi):
				vi.ifields[EvalContext.getInstanceFieldIndex(vi.iproto, name, p)] = value;
			case VObject(o):
				switch (o.oproto) {
					case OProto(proto):
						var idx = proto.pinstanceNames.get(name);
						if (idx != null) o.ofields[idx] = value;
						else EvalExceptions.excString(ctx, "Cannot add field " + EvalHash.revHash(name) + " to this object");
					case ODictionary(l):
						l.set(name, value);
				}
			case _:
				EvalExceptions.unexpectedValue(ctx, v, "object");
		}
	}
}
