package hxc.codegen.dotnet;

import haxe.io.Bytes;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta.CallConv;

// Signature blobs (ECMA-335 II.23.2) from normalized signatures. A named type goes through the
// callback, which gives its TypeDefOrRef coded index.

class SigWriter {
	final typeToken:(path:IlPath, valueType:Bool) -> Int;

	public function new(typeToken:(path:IlPath, valueType:Bool) -> Int) {
		this.typeToken = typeToken;
	}

	public function type(b:IlBytes, t:IlSigNorm):Void {
		switch (t) {
			case LVoid: b.u8(0x01);
			case LBool: b.u8(0x02);
			case LChar: b.u8(0x03);
			case LInt8: b.u8(0x04);
			case LUInt8: b.u8(0x05);
			case LInt16: b.u8(0x06);
			case LUInt16: b.u8(0x07);
			case LInt32: b.u8(0x08);
			case LUInt32: b.u8(0x09);
			case LInt64: b.u8(0x0A);
			case LUInt64: b.u8(0x0B);
			case LFloat32: b.u8(0x0C);
			case LFloat64: b.u8(0x0D);
			case LString: b.u8(0x0E);
			case LPointer(s):
				b.u8(0x0F);
				type(b, s);
			case LManagedPointer(s):
				b.u8(0x10);
				type(b, s);
			case LValueType(p, params) | LClass(p, params):
				var valueType = t.match(LValueType(_, _));
				if (params.length > 0) b.u8(0x15);
				b.u8(valueType ? 0x11 : 0x12);
				b.compressedU32(typeToken(p, valueType));
				if (params.length > 0) {
					b.compressedU32(params.length);
					for (a in params) type(b, a);
				}
			case LTypeParam(i):
				b.u8(0x13);
				b.compressedU32(i);
			case LArray(s, dims):
				b.u8(0x14);
				type(b, s);
				b.compressedU32(dims.length);
				// The sizes, then the lower bounds, each a run up to the last dimension that has one.
				var sizes = [], lows = [];
				for (d in dims) {
					if (d.size != null) sizes.push(d.size);
					if (d.lower != null) lows.push(d.lower);
				}
				b.compressedU32(sizes.length);
				for (s in sizes) b.compressedU32(s);
				b.compressedU32(lows.length);
				for (l in lows) b.compressedI32(l);
			case LTypedReference: b.u8(0x16);
			case LIntPtr: b.u8(0x18);
			case LUIntPtr: b.u8(0x19);
			case LMethod(cc, ret, args):
				b.u8(0x1B);
				methodInto(b, cc, ret, args);
			case LObject: b.u8(0x1C);
			case LVector(s):
				b.u8(0x1D);
				type(b, s);
			case LMethodTypeParam(i):
				b.u8(0x1E);
				b.compressedU32(i);
			case LSentinel: b.u8(0x41);
		}
	}

	public function field(t:IlSigNorm):Bytes {
		var b = new IlBytes();
		b.u8(0x06);
		type(b, t);
		return b.getBytes();
	}

	// A property's signature: PROPERTY, with HASTHIS for an instance property, the number of its index
	// parameters (an indexer's), its type, then the parameters' types.
	public function property(type:IlSigNorm, hasThis = true, ?index:Array<IlSigNorm>):Bytes {
		var b = new IlBytes();
		b.u8(hasThis ? 0x28 : 0x08);
		b.compressedU32(index == null ? 0 : index.length);
		this.type(b, type);
		if (index != null) for (t in index) this.type(b, t);
		return b.getBytes();
	}

	public function method(hasThis:Bool, ret:IlSigNorm, args:Array<IlSigNorm>, genericCount:Int):Bytes {
		var b = new IlBytes();
		var cc = [];
		if (hasThis) cc.push(CallHasThis);
		if (genericCount > 0) cc.push(CallGeneric(genericCount));
		methodInto(b, cc, ret, args);
		return b.getBytes();
	}

	// A method signature as a referenced assembly declares it, from its normalized LMethod form. The
	// reader drops the generic flag and count, so the method's type parameter count comes separately.
	public function methodSig(t:IlSigNorm, genericCount:Int):Bytes {
		return switch (t) {
			case LMethod(cc, ret, args):
				var b = new IlBytes();
				methodInto(b, genericCount > 0 ? cc.concat([CallGeneric(genericCount)]) : cc, ret, args);
				b.getBytes();
			case _: throw "internal error: not a method signature";
		}
	}

	function methodInto(b:IlBytes, cc:Array<CallConv>, ret:IlSigNorm, args:Array<IlSigNorm>):Void {
		var flags = 0, generic = 0;
		for (c in cc) switch (c) {
			case CallHasThis: flags |= 0x20;
			case CallExplicitThis: flags |= 0x40;
			case CallVararg: flags |= 0x05;
			case CallGeneric(n):
				flags |= 0x10;
				generic = n;
			case CallCDecl: flags |= 0x01;
			case CallStdCall: flags |= 0x02;
			case CallThisCall: flags |= 0x03;
			case CallFastCall: flags |= 0x04;
			case _:
		}
		b.u8(flags);
		if (generic > 0) b.compressedU32(generic);
		var n = 0;
		for (a in args) if (!a.match(LSentinel)) n++;
		b.compressedU32(n);
		type(b, ret);
		for (a in args) type(b, a);
	}

	public function locals(ts:Array<IlSigNorm>):Bytes {
		var b = new IlBytes();
		b.u8(0x07);
		b.compressedU32(ts.length);
		for (t in ts) type(b, t);
		return b.getBytes();
	}

	public function typeSpec(t:IlSigNorm):Bytes {
		var b = new IlBytes();
		type(b, t);
		return b.getBytes();
	}

	public function methodSpec(args:Array<IlSigNorm>):Bytes {
		var b = new IlBytes();
		b.u8(0x0A);
		b.compressedU32(args.length);
		for (a in args) type(b, a);
		return b.getBytes();
	}
}
