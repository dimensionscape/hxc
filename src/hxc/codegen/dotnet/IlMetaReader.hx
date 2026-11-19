package hxc.codegen.dotnet;

import haxe.io.Bytes;
import hxc.codegen.dotnet.IlMeta;
import hxc.codegen.dotnet.IlMeta.TableIdx as T;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.PeData;

// a read position in one of the metadata streams.
private class Cur {
	public var s:Bytes;
	public var pos:Int;

	public inline function new(s:Bytes, pos:Int) {
		this.s = s;
		this.pos = pos;
	}
}

// the reference's Exit, raised when an enum's underlying type is defined in another assembly.
private enum ReaderExit {
	Exit;
}

// reads the CLI metadata root, its streams and every metadata table (ECMA-335 II.24).
class IlMetaReader {
	var compressed:Bool;
	var stringsStream:Bytes;
	var stringsOffset = 2;
	var blobStream:Bytes;
	var blobOffset = 2;
	var guidStream:Bytes;
	var guidOffset = 2;
	var usStream:Bytes;
	var metaStream:Bytes;
	var metaEditContinue = false;
	var metaHasDeleted = false;
	var extraStreams:Array<ClrStreamHeader>;
	var tables:Array<Array<ClrMeta>>;
	// the width, 2 or 4, of an index into each table or coded index
	var tableSizes:Array<Int>;
	var relations:Map<Int, Array<ClrMeta>> = new Map();
	var typedefs:Map<String, MetaTypeDef> = new Map();
	var typedefOrder:Array<MetaTypeDef> = [];
	var delays:Array<Void->Void> = [];
	var stringCache:Map<Int, String> = new Map();

	static inline var maxClrMetaIdx = 76;

	function new() {}

	// ******* Reading from Strings *********

	static inline function sget(s:Bytes, pos:Int):Int {
		if (pos < 0 || pos >= s.length) throw "index out of bounds";
		return s.get(pos);
	}

	static function readCompressedI32(c:Cur):Int {
		var s = c.s, pos = c.pos;
		var v = sget(s, pos);
		if (v & 0x80 == 0x00) {
			c.pos = pos + 1;
			return v;
		} else if (v & 0xC0 == 0x80) {
			c.pos = pos + 2;
			return ((v & 0x3F) << 8) | sget(s, pos + 1);
		} else if (v & 0xE0 == 0xC0) {
			c.pos = pos + 4;
			return ((v & 0x1F) << 24) | (sget(s, pos + 1) << 16) | (sget(s, pos + 2) << 8) | sget(s, pos + 3);
		}
		throw new PeErrorMessage("Error reading compressed data. Invalid first byte: " + StringTools.hex(v).toLowerCase());
	}

	static function sreadUi8(c:Cur):Int {
		var v = sget(c.s, c.pos);
		c.pos++;
		return v;
	}

	// four bytes as an OCaml int: the sign is not extended
	static function sreadI32(c:Cur):Int {
		var s = c.s, pos = c.pos;
		var v = (sget(s, pos + 3) << 24) | (sget(s, pos + 2) << 16) | (sget(s, pos + 1) << 8) | sget(s, pos);
		c.pos = pos + 4;
		return v;
	}

	static inline function sreadRealI32(c:Cur):Int return sreadI32(c);

	// the reference reads the low word one byte late, and sign-extends it before or-ing in the high one
	static function sreadI64(c:Cur):haxe.Int64 {
		c.pos += 1;
		var v1 = sreadRealI32(c);
		var v2 = sreadRealI32(c);
		return haxe.Int64.make((v1 < 0 ? -1 : 0) | v2, v1);
	}

	static function sreadUi16(c:Cur):Int {
		var s = c.s, pos = c.pos;
		var v = (sget(s, pos + 1) << 8) | sget(s, pos);
		c.pos = pos + 2;
		return v;
	}

	static function sreadWidth(width:Int, c:Cur):Int return width == 2 ? sreadUi16(c) : sreadI32(c);

	function readCstring(pos:Int):String {
		var cached = stringCache.get(pos);
		if (cached != null) return cached;
		var s = stringsStream;
		var en = pos;
		while (sget(s, en) != 0) en++;
		var r = s.getString(pos, en - pos);
		stringCache.set(pos, r);
		return r;
	}

	function readSstringIdx(c:Cur):String {
		var i = sreadWidth(stringsOffset, c);
		return i == 0 ? "" : readCstring(i);
	}

	function readSblobIdx(c:Cur):Bytes {
		var i = sreadWidth(blobOffset, c);
		if (i == 0) return Bytes.alloc(0);
		var b = new Cur(blobStream, i);
		var len = readCompressedI32(b);
		return subBytes(blobStream, b.pos, len);
	}

	static function subBytes(s:Bytes, pos:Int, len:Int):Bytes {
		if (pos < 0 || len < 0 || pos + len > s.length) throw "String.sub / Bytes.sub";
		return s.sub(pos, len);
	}

	function readSguidIdx(c:Cur):Null<Bytes> {
		var i = sreadWidth(guidOffset, c);
		if (i == 0) return null;
		return subBytes(guidStream, (i - 1) * 16, 16);
	}

	static function callconvOfInt(i:Int, matchGenericInst:Bool):Array<CallConv> {
		var basic = switch (i & 0xF) {
			case 0x0: CallDefault;
			case 0x1: CallCDecl;
			case 0x2: CallStdCall;
			case 0x3: CallThisCall;
			case 0x4: CallFastCall;
			case 0x5: CallVararg;
			case 0x6: CallField;
			case 0x7: CallLocal;
			case 0x8: CallProp;
			case 0x9: CallUnmanaged;
			case 0xa if (matchGenericInst): CallGenericInst;
			case n: throw "Assertion failed: callconv 0x" + StringTools.hex(n).toLowerCase();
		}
		if (i & 0x20 == 0x20) return [CallHasThis, basic];
		if (i & 0x40 == 0x40) return [CallExplicitThis, basic];
		return [basic];
	}

	static function readCallconv(c:Cur):Array<CallConv> {
		var conv = readCompressedI32(c);
		var callconv = callconvOfInt(conv, true);
		if (conv & 0x10 == 0x10) readCompressedI32(c);
		return callconv;
	}

	static function readConstant(withType:ConstantType, c:Cur):IlConstant {
		var s = c.s;
		return switch (withType) {
			case CBool:
				var v = sget(s, c.pos) != 0;
				c.pos++;
				IBool(v);
			case CChar: IChar(sreadUi16(c));
			case CInt8 | CUInt8:
				var v = sget(s, c.pos);
				c.pos++;
				IByte(v);
			case CInt16 | CUInt16: IShort(sreadUi16(c));
			case CInt32 | CUInt32: IInt(sreadRealI32(c));
			case CInt64 | CUInt64:
				// The emitter writes the eight bytes as they are into code; the reference's reading stays
				// for the converter.
				var at = c.pos;
				var lo = sreadRealI32(c);
				var hi = sreadRealI32(c);
				c.pos = at;
				var ref = sreadI64(c);
				IInt64(ref, haxe.Int64.make(hi, lo));
			case CFloat32: IFloat32(haxe.io.FPHelper.i32ToFloat(sreadRealI32(c)));
			case CFloat64:
				// Unlike the 64-bit integer reader, which keeps the reference's offset, this reads the eight
				// bytes as they are: the emitter writes the value into code.
				var lo = sreadRealI32(c);
				var hi = sreadRealI32(c);
				IFloat64(haxe.io.FPHelper.i64ToDouble(lo, hi));
			case CString:
				if (sget(s, c.pos) == 0xff) {
					c.pos++;
					IString(Bytes.alloc(0));
				} else {
					var len = readCompressedI32(c);
					var r = subBytes(s, c.pos, len);
					c.pos += len;
					IString(r);
				}
			case CNullRef:
				c.pos++;
				INull;
		}
	}

	static function sigToConst(s:IlSig):ConstantType {
		return switch (s) {
			case SBool: CBool;
			case SChar: CChar;
			case SInt8: CInt8;
			case SUInt8: CUInt8;
			case SInt16: CInt16;
			case SUInt16: CUInt16;
			case SInt32: CInt32;
			case SUInt32: CUInt32;
			case SInt64: CInt64;
			case SUInt64: CUInt64;
			case SFloat32: CFloat32;
			case SFloat64: CFloat64;
			case SString: CString;
			case _: CNullRef;
		}
	}

	static function readConstantType(c:Cur):ConstantType {
		var t = switch (sget(c.s, c.pos)) {
			case 0x2: CBool;
			case 0x3: CChar;
			case 0x4: CInt8;
			case 0x5: CUInt8;
			case 0x6: CInt16;
			case 0x7: CUInt16;
			case 0x8: CInt32;
			case 0x9: CUInt32;
			case 0xA: CInt64;
			case 0xB: CUInt64;
			case 0xC: CFloat32;
			case 0xD: CFloat64;
			case 0xE: CString;
			case 0x12: CNullRef;
			case i: throw "Assertion failed: constant type 0x" + StringTools.hex(i).toLowerCase();
		}
		c.pos++;
		return t;
	}

	// SecRequest (0x1) .. SecNonCasInheritance (0xF)
	static function actionSecurityOfInt(i:Int):Int {
		if (i < 0x1 || i > 0xF) throw "Assertion failed: action security";
		return i;
	}

	static function implFlagsOfInt(i:Int):Int {
		switch (i & 0x700) {
			case 0x0 | 0x100 | 0x200 | 0x300 | 0x400 | 0x500:
			case _: throw "Assertion failed: impl callconv";
		}
		return i;
	}

	static function hashAlgoOfInt(i:Int):Int {
		return switch (i) {
			case 0x0 | 0x8003 | 0x8004: i;
			case _: throw "Assertion failed: hash algo";
		}
	}

	static function fileFlagOfInt(i:Int):Int {
		return switch (i) {
			case 0x0 | 0x1: i;
			case _: throw "Assertion failed: file flag";
		}
	}

	static function manifestResourceFlagOfInt(i:Int):Int {
		return switch (i & 0x7) {
			case 0x0 | 0x1 | 0x2: i & 0x7;
			case _: throw "Assertion failed: manifest resource flag";
		}
	}

	static function eventFlagsOfInt(i:Int):Array<EventFlag>
		return MetaFlags.flagsOfInt(i, [0x0200, 0x0400], f -> f == 0x0200 ? ESpecialName : ERTSpecialName);

	static function propertyFlagsOfInt(i:Int):Array<PropertyFlag>
		return MetaFlags.flagsOfInt(i, [0x0200, 0x0400, 0x1000, 0xE9FF], f -> switch (f) {
			case 0x0200: PSpecialName;
			case 0x0400: PRTSpecialName;
			case 0x1000: PHasDefault;
			case _: PUnused;
		});

	static function semanticFlagsOfInt(i:Int):Array<SemanticFlag>
		return MetaFlags.flagsOfInt(i, [0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020], f -> switch (f) {
			case 0x0001: SSetter;
			case 0x0002: SGetter;
			case 0x0004: SOther;
			case 0x0008: SAddOn;
			case 0x0010: SRemoveOn;
			case _: SFire;
		});

	// ******* Metadata Tables *********

	static function mkMeta(tbl:Int, id:Int):ClrMeta {
		return switch (tbl) {
			case T.IModule: Module(new MetaModule(id));
			case T.ITypeRef: TypeRef(new MetaTypeRef(id));
			case T.ITypeDef: TypeDef(new MetaTypeDef(id));
			case T.IFieldPtr: FieldPtr(new MetaFieldPtr(id));
			case T.IField: Field(new MetaField(id));
			case T.IMethodPtr: MethodPtr(new MetaMethodPtr(id));
			case T.IMethod: Method(new MetaMethod(id));
			case T.IParamPtr: ParamPtr(new MetaParamPtr(id));
			case T.IParam: Param(new MetaParam(id));
			case T.IInterfaceImpl: InterfaceImpl(new MetaInterfaceImpl(id));
			case T.IMemberRef: MemberRef(new MetaMemberRef(id));
			case T.IConstant: Constant(new MetaConstant(id));
			case T.ICustomAttribute: CustomAttribute(new MetaCustomAttribute(id));
			case T.IFieldMarshal: FieldMarshal(new MetaFieldMarshal(id));
			case T.IDeclSecurity: DeclSecurity(new MetaDeclSecurity(id));
			case T.IClassLayout: ClassLayout(new MetaClassLayout(id));
			case T.IFieldLayout: FieldLayout(new MetaFieldLayout(id));
			case T.IStandAloneSig: StandAloneSig(new MetaStandAloneSig(id));
			case T.IEventMap: EventMap(new MetaEventMap(id));
			case T.IEventPtr: EventPtr(new MetaEventPtr(id));
			case T.IEvent: Event(new MetaEvent(id));
			case T.IPropertyMap: PropertyMap(new MetaPropertyMap(id));
			case T.IPropertyPtr: PropertyPtr(new MetaPropertyPtr(id));
			case T.IProperty: Property(new MetaProperty(id));
			case T.IMethodSemantics: MethodSemantics(new MetaMethodSemantics(id));
			case T.IMethodImpl: MethodImpl(new MetaMethodImpl(id));
			case T.IModuleRef: ModuleRef(new MetaModuleRef(id));
			case T.ITypeSpec: TypeSpec(new MetaTypeSpec(id));
			case T.IImplMap: ImplMap(new MetaImplMap(id));
			case T.IFieldRVA: FieldRVA(new MetaFieldRva(id));
			case T.IENCLog: ENCLog(new MetaEncLog(id));
			case T.IENCMap: ENCMap(new MetaEncMap(id));
			case T.IAssembly: Assembly(new MetaAssembly(id));
			case T.IAssemblyProcessor: AssemblyProcessor(new MetaAssemblyProcessor(id));
			case T.IAssemblyOS: AssemblyOS(new MetaAssemblyOs(id));
			case T.IAssemblyRef: AssemblyRef(new MetaAssemblyRef(id));
			case T.IAssemblyRefProcessor: AssemblyRefProcessor(new MetaAssemblyRefProcessor(id));
			case T.IAssemblyRefOS: AssemblyRefOS(new MetaAssemblyRefOs(id));
			case T.IFile: File(new MetaFile(id));
			case T.IExportedType: ExportedType(new MetaExportedType(id));
			case T.IManifestResource: ManifestResource(new MetaManifestResource(id));
			case T.INestedClass: NestedClass(new MetaNestedClass(id));
			case T.IGenericParam: GenericParam(new MetaGenericParam(id));
			case T.IMethodSpec: MethodSpec(new MetaMethodSpec(id));
			case T.IGenericParamConstraint: GenericParamConstraint(new MetaGenericParamConstraint(id));
			case i: UnknownMeta(i);
		}
	}

	function getTable(idx:Int, rid:Int):ClrMeta {
		var cur = tables[idx];
		if (rid - 1 < 0 || rid - 1 >= cur.length) throw "DynArray.get: index out of bounds";
		return cur[rid - 1];
	}

	// special coded types: the tables each one may point at, and its tag width
	static final codedDescription:Array<{tbls:Array<Int>, size:Int}> = [
		{tbls: [T.ITypeDef, T.ITypeRef, T.ITypeSpec], size: 2},
		{tbls: [T.IField, T.IParam, T.IProperty], size: 2},
		{tbls: [T.IMethod, T.IField, T.ITypeRef, T.ITypeDef, T.IParam, T.IInterfaceImpl, T.IMemberRef, T.IModule, T.IDeclSecurity,
			T.IProperty, T.IEvent, T.IStandAloneSig, T.IModuleRef, T.ITypeSpec, T.IAssembly, T.IAssemblyRef, T.IFile,
			T.IExportedType, T.IManifestResource, T.IGenericParam, T.IGenericParamConstraint, T.IMethodSpec], size: 5},
		{tbls: [T.IField, T.IParam], size: 1},
		{tbls: [T.ITypeDef, T.IMethod, T.IAssembly], size: 2},
		{tbls: [T.ITypeDef, T.ITypeRef, T.IModuleRef, T.IMethod, T.ITypeSpec], size: 3},
		{tbls: [T.IEvent, T.IProperty], size: 1},
		{tbls: [T.IMethod, T.IMemberRef], size: 1},
		{tbls: [T.IField, T.IMethod], size: 1},
		{tbls: [T.IFile, T.IAssemblyRef, T.IExportedType], size: 2},
		{tbls: [T.ITypeRef, T.ITypeDef, T.IMethod, T.IMemberRef], size: 3},
		{tbls: [T.IModule, T.IModuleRef, T.IAssemblyRef, T.ITypeRef], size: 2},
		{tbls: [T.ITypeDef, T.IMethod], size: 1},
	];

	function setCodedSizes(rows:Array<Int>):Void {
		for (i in 64...maxClrMetaIdx + 1) {
			var d = codedDescription[i - 64];
			var max = 1 << (16 - d.size);
			for (t in d.tbls) if (rows[t] >= max) {
				tableSizes[i] = 4;
				break;
			}
		}
	}

	function sreadFromTableOpt(inBlob:Bool, tbl:Int, c:Cur):Null<ClrMeta> {
		var rid = inBlob ? readCompressedI32(c) : sreadWidth(tableSizes[tbl], c);
		if (tbl >= 64) {
			var d = codedDescription[tbl - 64];
			var mask = (1 << d.size) - 1;
			if (mask == 0) mask = 1;
			var tidx = rid & mask;
			var realRid = rid >>> d.size;
			if (tidx >= d.tbls.length) throw "index out of bounds";
			var realTbl = d.tbls[tidx];
			return realRid == 0 ? null : getTable(realTbl, realRid);
		}
		return rid == 0 ? null : getTable(tbl, rid);
	}

	function sreadFromTable(inBlob:Bool, tbl:Int, c:Cur):ClrMeta {
		var r = sreadFromTableOpt(inBlob, tbl, c);
		if (r == null) throw "Option.get";
		return r;
	}

	// ******* SIGNATURE READING *********

	static function readInlineStr(c:Cur):Bytes {
		var len = readCompressedI32(c);
		var ret = subBytes(c.s, c.pos, len);
		c.pos += len;
		return ret;
	}

	function readIlsig(c:Cur):IlSig {
		var i = sget(c.s, c.pos);
		c.pos++;
		return switch (i) {
			case 0x1: SVoid;
			case 0x2: SBool;
			case 0x3: SChar;
			case 0x4: SInt8;
			case 0x5: SUInt8;
			case 0x6: SInt16;
			case 0x7: SUInt16;
			case 0x8: SInt32;
			case 0x9: SUInt32;
			case 0xA: SInt64;
			case 0xB: SUInt64;
			case 0xC: SFloat32;
			case 0xD: SFloat64;
			case 0xE: SString;
			case 0xF: SPointer(readIlsig(c));
			case 0x10: SManagedPointer(readIlsig(c));
			case 0x11: SValueType(sreadFromTable(true, T.ITypeDefOrRef, c));
			case 0x12: SClass(sreadFromTable(true, T.ITypeDefOrRef, c));
			case 0x13:
				// a single byte, not a compressed integer
				var n = sget(c.s, c.pos);
				c.pos++;
				STypeParam(n);
			case 0x14:
				var ssig = readIlsig(c);
				var rank = readCompressedI32(c);
				var numsizes = readCompressedI32(c);
				var sizearray = [for (_ in 0...numsizes) readCompressedI32(c)];
				var bounds = readCompressedI32(c);
				var boundsarray = [
					for (_ in 0...bounds) {
						var b = readCompressedI32(c);
						var signed = b & 0x1 == 0x1;
						b = b >>> 1;
						signed ? -b : b;
					}
				];
				SArray(ssig, [
					for (i in 0...rank) {
						lower: i >= bounds ? null : boundsarray[i],
						size: i >= numsizes ? null : sizearray[i]
					}
				]);
			case 0x15:
				var ssig = readIlsig(c);
				var ntypes = readCompressedI32(c);
				var args = [for (_ in 0...ntypes) readIlsig(c)];
				SGenericInst(ssig, args);
			case 0x16: STypedReference;
			case 0x18: SIntPtr;
			case 0x19: SUIntPtr;
			case 0x1B:
				var conv = readCompressedI32(c);
				var callconv = callconvOfInt(conv, false);
				var ntypes = readCompressedI32(c);
				var ret = readIlsig(c);
				// one argument fewer than the count, as the reference reads them
				var args = [];
				var n = 1;
				while (n < ntypes) {
					args.push(readIlsig(c));
					n++;
				}
				SFunPtr(callconv, ret, args);
			case 0x1C: SObject;
			case 0x1D: SVector(readIlsig(c));
			case 0x1E: SMethodTypeParam(readCompressedI32(c));
			case 0x1F:
				var tdef = sreadFromTable(true, T.ITypeDefOrRef, c);
				SReqModifier(tdef, readIlsig(c));
			case 0x20:
				var tdef = sreadFromTable(true, T.ITypeDefOrRef, c);
				SOptModifier(tdef, readIlsig(c));
			case 0x41: SSentinel;
			case 0x45: SPinned(readIlsig(c));
			// special undocumented constants
			case 0x50: SType;
			case 0x51: SBoxed;
			case 0x55: SEnum(readInlineStr(c).toString());
			case _: throw "Assertion failed: unknown ilsig 0x" + StringTools.hex(i).toLowerCase();
		}
	}

	static function readVariantsig(c:Cur):Int {
		var b = sreadUi8(c);
		return switch (b) {
			case 0x00 | 0x01 | 0x02 | 0x03 | 0x04 | 0x05 | 0x06 | 0x07 | 0x08 | 0x09 | 0x0A | 0x0B | 0x0C | 0x0D | 0x0E | 0x10
				| 0x11 | 0x12 | 0x13 | 0x14 | 0x15 | 0x16 | 0x17 | 0x18 | 0x19 | 0x1A | 0x1B | 0x1C | 0x1D | 0x1E | 0x1F | 0x24
				| 0x40 | 0x41 | 0x42 | 0x43 | 0x44 | 0x45 | 0x46 | 0x47 | 0x48:
				b;
			case _: throw "Assertion failed: variant sig";
		}
	}

	static function readNativesig(c:Cur):NativeSig {
		var b = sreadUi8(c);
		return switch (b) {
			case 0x01: NVoid;
			case 0x02: NBool;
			case 0x03: NInt8;
			case 0x4: NUInt8;
			case 0x5: NInt16;
			case 0x6: NUInt16;
			case 0x7: NInt32;
			case 0x8: NUInt32;
			case 0x9: NInt64;
			case 0xA: NUInt64;
			case 0xB: NFloat32;
			case 0xC: NFloat64;
			case 0xD: NSysChar;
			case 0xE: NVariant;
			case 0xF: NCurrency;
			case 0x10: NPointer;
			case 0x11: NDecimal;
			case 0x12: NDate;
			case 0x13: NBStr;
			case 0x14: NLPStr;
			case 0x15: NLPWStr;
			case 0x16: NLPTStr;
			case 0x17: NFixedString(readCompressedI32(c));
			case 0x18: NObjectRef;
			case 0x19: NUnknown;
			case 0x1A: NDispatch;
			case 0x1B: NStruct;
			case 0x1C: NInterface;
			case 0x1D: NSafeArray(readVariantsig(c));
			case 0x1E:
				var size = readCompressedI32(c);
				NFixedArray(size, readVariantsig(c));
			case 0x1F: NIntPointer;
			case 0x20: NUIntPointer;
			case 0x21: NNestedStruct;
			case 0x22: NByValStr;
			case 0x23: NAnsiBStr;
			case 0x24: NTBStr;
			case 0x25: NVariantBool;
			case 0x26: NFunctionPtr;
			case 0x28: NAsAny;
			case 0x2A:
				var elt = readNativesig(c);
				var paramidx = readCompressedI32(c);
				var size = readCompressedI32(c);
				var paramMult = readCompressedI32(c);
				NArray(elt, paramidx, size, paramMult);
			case 0x2B: NLPStruct;
			case 0x2C:
				var guidVal = readInlineStr(c);
				var unmanaged = readInlineStr(c);
				NCustomMarshaler(guidVal, unmanaged);
			case 0x2D: NError;
			case i: NCustom(i);
		}
	}

	// the blob index read at the meta position, then the native type read at it without skipping the
	// blob's length, as the reference does.
	function readNativesigIdx(c:Cur):NativeSig {
		var i = sreadWidth(blobOffset, c);
		return readNativesig(new Cur(blobStream, i));
	}

	function readMethodIlsigIdx(c:Cur):IlSig {
		var i = sreadWidth(blobOffset, c);
		var b = new Cur(blobStream, i);
		var len = readCompressedI32(b);
		var endpos = b.pos + len;
		var callconv = readCallconv(b);
		var ntypes = readCompressedI32(b);
		var ret = readIlsig(b);
		var args = [];
		var n = 1;
		while (!(n > ntypes || b.pos >= endpos)) {
			args.push(readIlsig(b));
			n++;
		}
		return SFunPtr(callconv, ret, args);
	}

	function readIlsigIdx(c:Cur):IlSig {
		var i = sreadWidth(blobOffset, c);
		var b = new Cur(blobStream, i);
		readCompressedI32(b);
		return readIlsig(b);
	}

	function readFieldIlsigIdx(c:Cur, forceField:Bool):IlSig {
		var start = c.pos;
		var i = sreadWidth(blobOffset, c);
		var b = new Cur(blobStream, i);
		readCompressedI32(b);
		var first = sget(blobStream, b.pos);
		if (first != 0x6) {
			if (forceField) throw new PeErrorMessage("Invalid field signature: " + first);
			c.pos = start;
			return readMethodIlsigIdx(c);
		}
		b.pos++;
		return readIlsig(b);
	}

	function getUnderlyingEnumType(name:String):IlSig {
		// first try to get a typedef
		var parts = name.split(".");
		var n = parts.pop();
		var ns = parts;
		var tdefs = tables[T.ITypeDef];
		var tdef:Null<MetaTypeDef> = null;
		var idx = 1;
		while (idx < tdefs.length) {
			switch (tdefs[idx]) {
				case TypeDef(td):
					if (td.name == n && IlPaths.strsEq(td.namespace, ns)) {
						tdef = td;
						break;
					}
				case _:
					throw "Assertion failed: get_underlying_enum_type";
			}
			idx++;
		}
		// a type of another assembly is not looked up
		if (tdef == null) throw Exit;
		// now find the first non-static field associated with it
		for (f in tdef.fieldList) if (f.flags.contract.indexOf(CStatic) < 0) return f.signature;
		throw "Assertion failed: get_underlying_enum_type";
	}

	function readCustomAttr(attrType:ClrMeta, c:Cur):{fixed:Array<Instance>, named:Array<NamedAttribute>} {
		var s = c.s;
		var prolog = sreadUi16(c);
		if (prolog != 0x0001)
			throw new PeErrorMessage("Error reading custom attribute: Expected prolog 0x0001 ; got 0x" + StringTools.hex(prolog).toLowerCase());
		var isig = switch (attrType) {
			case Method(m): m.signature;
			case MemberRef(mr): mr.signature;
			case _: throw "Assertion failed: read_custom_attr";
		}
		var args = switch (IlMetaTools.follow(isig)) {
			case SFunPtr(_, _, args): args;
			case _: throw "Assertion failed: read_custom_attr";
		}
		function readInstance(ilsig:IlSig):Instance {
			return switch (IlMetaTools.follow(ilsig)) {
				case SBool | SChar | SInt8 | SUInt8 | SInt16 | SUInt16 | SInt32 | SUInt32 | SInt64 | SUInt64 | SFloat32 | SFloat64
					| SString:
					InstConstant(readConstant(sigToConst(ilsig), c));
				case SClass(cl) if (IlMetaTools.isType(["System"], "Type", cl)):
					if (sget(s, c.pos) == 0xff) {
						c.pos++;
						InstConstant(INull);
					} else
						InstType(readInlineStr(c));
				case SType:
					InstType(readInlineStr(c));
				case SObject | SBoxed:
					if (sget(s, c.pos) == 0x51) c.pos++;
					var boxed = readIlsig(c);
					InstBoxed(readInstance(boxed));
				case SEnum(e):
					readInstance(getUnderlyingEnumType(e));
				case SValueType(_):
					InstEnum(sreadI32(c));
				case _:
					throw "Assertion failed: read_instance";
			}
		}
		var fixed = [];
		for (a in args) switch (a) {
			case SVector(isig):
				var nelem = sreadRealI32(c);
				if (nelem == -1) fixed.push(InstConstant(INull));
				else fixed.push(InstArray([for (_ in 0...nelem) readInstance(isig)]));
			case isig:
				fixed.push(readInstance(isig));
		}
		// The named arguments (AttributeUsage's AllowMultiple, for AttributesToIl): FIELD 0x53 or PROPERTY 0x54,
		// the type, the name and the value. They are read as far as they can be: an enum of another assembly,
		// whose width is not known here, ends them.
		var named:Array<NamedAttribute> = [];
		try {
			var nnamed = sreadUi16(c);
			for (_ in 0...nnamed) {
				var isProp = sreadUi8(c) == 0x54;
				var t = readIlsig(c);
				var name = readInlineStr(c).toString();
				var inst = switch (t) {
					case SVector(e):
						var nelem = sreadRealI32(c);
						nelem == -1 ? InstConstant(INull) : InstArray([for (_ in 0...nelem) readInstance(e)]);
					case _: readInstance(t);
				}
				named.push({isProp: isProp, name: name, inst: inst});
			}
		} catch (_:Dynamic) {}
		return {fixed: fixed, named: named};
	}

	function readCustomAttrIdx(ca:MetaCustomAttribute, attrType:ClrMeta, c:Cur):Void {
		var i = sreadWidth(blobOffset, c);
		if (i == 0) return;
		var b = new Cur(blobStream, i);
		readCompressedI32(b);
		delays.push(function() {
			try {
				ca.value = readCustomAttr(attrType, b);
			} catch (e:ReaderExit) {}
		});
	}

	function readNextIndex(offset:Int, table:Int, last:Bool, pos:Int):Int {
		if (last) return tables[table].length + 1;
		return sreadWidth(tableSizes[table], new Cur(metaStream, pos + offset));
	}

	// the rows in [beginIdx, endIdx), through the pointer table when an uncompressed stream has one
	function getList(table:Int, ptrTable:Int, beginIdx:Int, endIdx:Int):Array<ClrMeta> {
		if (compressed || tables[ptrTable].length == 0)
			return [for (idx in beginIdx...endIdx) getTable(table, idx)];
		// the indirect walk includes the end index, as the reference's does
		var ptrs = [for (idx in beginIdx...endIdx + 1) getTable(ptrTable, idx)];
		return [
			for (meta in ptrs) getTable(table, switch (meta) {
				case FieldPtr(p): p.field == null ? -1 : p.field.id;
				case MethodPtr(p): p.method == null ? -1 : p.method.id;
				case ParamPtr(p): p.param == null ? -1 : p.param.id;
				case EventPtr(p): p.event == null ? -1 : p.event.id;
				case _: throw "Assertion failed: meta_root_ptr";
			})
		];
	}

	function readList(table:Int, ptrTable:Int, beginIdx:Int, offset:Int, last:Bool, pos:Int):Array<ClrMeta> {
		var endIdx = readNextIndex(offset, table, last, pos);
		return getList(table, ptrTable, beginIdx, endIdx);
	}

	static function parseNs(id:String):Array<String> {
		return id == "" ? [] : id.split(".");
	}

	static function getMetaPointer(m:ClrMeta):Int {
		return switch (m) {
			case Module(r): IlCtx.relationKey(T.IModule, r.id);
			case TypeRef(r): IlCtx.relationKey(T.ITypeRef, r.id);
			case TypeDef(r): IlCtx.relationKey(T.ITypeDef, r.id);
			case FieldPtr(r): IlCtx.relationKey(T.IFieldPtr, r.id);
			case Field(r): IlCtx.relationKey(T.IField, r.id);
			case MethodPtr(r): IlCtx.relationKey(T.IMethodPtr, r.id);
			case Method(r): IlCtx.relationKey(T.IMethod, r.id);
			case ParamPtr(r): IlCtx.relationKey(T.IParamPtr, r.id);
			case Param(r): IlCtx.relationKey(T.IParam, r.id);
			case InterfaceImpl(r): IlCtx.relationKey(T.IInterfaceImpl, r.id);
			case MemberRef(r): IlCtx.relationKey(T.IMemberRef, r.id);
			case Constant(r): IlCtx.relationKey(T.IConstant, r.id);
			case CustomAttribute(r): IlCtx.relationKey(T.ICustomAttribute, r.id);
			case FieldMarshal(r): IlCtx.relationKey(T.IFieldMarshal, r.id);
			case DeclSecurity(r): IlCtx.relationKey(T.IDeclSecurity, r.id);
			case ClassLayout(r): IlCtx.relationKey(T.IClassLayout, r.id);
			case FieldLayout(r): IlCtx.relationKey(T.IFieldLayout, r.id);
			case StandAloneSig(r): IlCtx.relationKey(T.IStandAloneSig, r.id);
			case EventMap(r): IlCtx.relationKey(T.IEventMap, r.id);
			case EventPtr(r): IlCtx.relationKey(T.IEventPtr, r.id);
			case Event(r): IlCtx.relationKey(T.IEvent, r.id);
			case PropertyMap(r): IlCtx.relationKey(T.IPropertyMap, r.id);
			case PropertyPtr(r): IlCtx.relationKey(T.IPropertyPtr, r.id);
			case Property(r): IlCtx.relationKey(T.IProperty, r.id);
			case MethodSemantics(r): IlCtx.relationKey(T.IMethodSemantics, r.id);
			case MethodImpl(r): IlCtx.relationKey(T.IMethodImpl, r.id);
			case ModuleRef(r): IlCtx.relationKey(T.IModuleRef, r.id);
			case TypeSpec(r): IlCtx.relationKey(T.ITypeSpec, r.id);
			case ImplMap(r): IlCtx.relationKey(T.IImplMap, r.id);
			case FieldRVA(r): IlCtx.relationKey(T.IFieldRVA, r.id);
			case ENCLog(r): IlCtx.relationKey(T.IENCLog, r.id);
			case ENCMap(r): IlCtx.relationKey(T.IENCMap, r.id);
			case Assembly(r): IlCtx.relationKey(T.IAssembly, r.id);
			case AssemblyProcessor(r): IlCtx.relationKey(T.IAssemblyProcessor, r.id);
			case AssemblyOS(r): IlCtx.relationKey(T.IAssemblyOS, r.id);
			case AssemblyRef(r): IlCtx.relationKey(T.IAssemblyRef, r.id);
			case AssemblyRefProcessor(r): IlCtx.relationKey(T.IAssemblyRefProcessor, r.id);
			case AssemblyRefOS(r): IlCtx.relationKey(T.IAssemblyRefOS, r.id);
			case File(r): IlCtx.relationKey(T.IFile, r.id);
			case ExportedType(r): IlCtx.relationKey(T.IExportedType, r.id);
			case ManifestResource(r): IlCtx.relationKey(T.IManifestResource, r.id);
			case NestedClass(r): IlCtx.relationKey(T.INestedClass, r.id);
			case GenericParam(r): IlCtx.relationKey(T.IGenericParam, r.id);
			case MethodSpec(r): IlCtx.relationKey(T.IMethodSpec, r.id);
			case GenericParamConstraint(r): IlCtx.relationKey(T.IGenericParamConstraint, r.id);
			case UnknownMeta(_): throw "Assertion failed: get_meta_pointer";
		}
	}

	function addRelation(key:ClrMeta, v:ClrMeta):Void {
		var k = getMetaPointer(key);
		var l = relations.get(k);
		if (l == null) relations.set(k, l = []);
		l.push(v);
	}

	static function getTypeDef(m:ClrMeta):MetaTypeDef return switch (m) {
		case TypeDef(r): r;
		case _: throw "Assertion failed: get_type_def";
	}

	static function getField(m:ClrMeta):MetaField return switch (m) {
		case Field(r): r;
		case _: throw "Assertion failed: get_field";
	}

	static function getMethod(m:ClrMeta):MetaMethod return switch (m) {
		case Method(r): r;
		case _: throw "Assertion failed: get_method";
	}

	static function getParam(m:ClrMeta):MetaParam return switch (m) {
		case Param(r): r;
		case _: throw "Assertion failed: get_param";
	}

	static function getEvent(m:ClrMeta):MetaEvent return switch (m) {
		case Event(r): r;
		case _: throw "Assertion failed: get_event";
	}

	static function getProperty(m:ClrMeta):MetaProperty return switch (m) {
		case Property(r): r;
		case _: throw "Assertion failed: get_property";
	}

	static function getModuleRef(m:Null<ClrMeta>):MetaModuleRef return switch (m) {
		case null: throw "Option.get";
		case ModuleRef(r): r;
		case _: throw "Assertion failed: get_module_ref";
	}

	static function getAssemblyRef(m:ClrMeta):MetaAssemblyRef return switch (m) {
		case AssemblyRef(r): r;
		case _: throw "Assertion failed: get_assembly_ref";
	}

	static function getGenericParam(m:ClrMeta):MetaGenericParam return switch (m) {
		case GenericParam(r): r;
		case _: throw "Assertion failed: get_generic_param";
	}

	function readTableAt(tbl:Int, n:Int, last:Bool, c:Cur):Void {
		var s = metaStream;
		switch (getTable(tbl, n + 1)) {
			case Module(m):
				m.generation = sreadUi16(c);
				m.name = readSstringIdx(c);
				m.vid = readSguidIdx(c);
				m.encid = readSguidIdx(c);
				m.encbaseId = readSguidIdx(c);
			case TypeRef(tr):
				var scope = sreadFromTable(false, T.IResolutionScope, c);
				var name = readSstringIdx(c);
				var ns = readSstringIdx(c);
				tr.resolutionScope = scope;
				tr.name = name;
				tr.namespace = parseNs(ns);
			case TypeDef(td):
				var startpos = c.pos;
				var flags = sreadI32(c);
				var name = readSstringIdx(c);
				var ns = parseNs(readSstringIdx(c));
				var ext = sreadFromTableOpt(false, T.ITypeDefOrRef, c);
				var fieldOffset = c.pos - startpos;
				var flistBegin = sreadWidth(tableSizes[T.IField], c);
				var methodOffset = c.pos - startpos;
				var mlistBegin = sreadWidth(tableSizes[T.IMethod], c);
				td.flags = TypeDefFlags.ofInt(flags);
				td.name = name;
				td.namespace = ns;
				td.extends_ = ext;
				td.fieldList = [for (f in readList(T.IField, T.IFieldPtr, flistBegin, fieldOffset, last, c.pos)) getField(f)];
				td.methodList = [for (m in readList(T.IMethod, T.IMethodPtr, mlistBegin, methodOffset, last, c.pos)) getMethod(m)];
				for (m in td.methodList) m.declaring = td;
				// keyed before the NestedClass table gives nested types their enclosing one
				typedefs.set(IlPaths.key(IlMetaTools.getPath(TypeDef(td))), td);
				typedefOrder.push(td);
			case FieldPtr(fp):
				fp.field = getField(sreadFromTable(false, T.IField, c));
			case Field(f):
				var flags = sreadUi16(c);
				var name = readSstringIdx(c);
				var ilsig = readFieldIlsigIdx(c, true);
				f.flags = FieldFlags.ofInt(flags);
				f.name = name;
				f.signature = ilsig;
			case MethodPtr(mp):
				mp.method = getMethod(sreadFromTable(false, T.IMethod, c));
			case Method(m):
				var startpos = c.pos;
				var rva = sreadI32(c);
				var iflags = sreadUi16(c);
				var flags = sreadUi16(c);
				var name = readSstringIdx(c);
				var ilsig = readMethodIlsigIdx(c);
				var offset = c.pos - startpos;
				var paramlist = sreadWidth(tableSizes[T.IParam], c);
				m.rva = rva;
				m.flags = MethodFlags.ofInt(iflags, flags);
				m.name = name;
				m.signature = ilsig;
				m.paramList = [for (p in readList(T.IParam, T.IParamPtr, paramlist, offset, last, c.pos)) getParam(p)];
			case ParamPtr(pp):
				pp.param = getParam(sreadFromTable(false, T.IParam, c));
			case Param(p):
				var flags = sreadUi16(c);
				var sequence = sreadUi16(c);
				var name = readSstringIdx(c);
				p.flags = ParamFlags.ofInt(flags);
				p.sequence = sequence;
				p.name = name;
			case InterfaceImpl(ii):
				var cls = sreadFromTable(false, T.ITypeDef, c);
				addRelation(cls, InterfaceImpl(ii));
				var cl = getTypeDef(cls);
				var iface = sreadFromTable(false, T.ITypeDefOrRef, c);
				ii.cls = cl;
				ii.iface = iface;
			case MemberRef(mr):
				var cls = sreadFromTable(false, T.IMemberRefParent, c);
				var name = readSstringIdx(c);
				var signature = readFieldIlsigIdx(c, false);
				mr.cls = cls;
				mr.name = name;
				mr.signature = signature;
				addRelation(cls, MemberRef(mr));
			case Constant(k):
				var ctype = readConstantType(c);
				c.pos++;
				var parent = sreadFromTable(false, T.IHasConstant, c);
				var blobpos = sreadWidth(blobOffset, c);
				var b = new Cur(blobStream, blobpos);
				var len = readCompressedI32(b);
				// A string constant's blob is its UTF-16 code units, not a custom attribute's SerString.
				var value = ctype.match(CString) ? IString(subBytes(blobStream, b.pos, len)) : readConstant(ctype, b);
				k.type = ctype;
				k.parent = parent;
				k.value = value;
				addRelation(parent, Constant(k));
			case CustomAttribute(ca):
				var parent = sreadFromTable(false, T.IHasCustomAttribute, c);
				var t = sreadFromTable(false, T.ICustomAttributeType, c);
				readCustomAttrIdx(ca, t, c);
				ca.parent = parent;
				ca.type = t;
				ca.value = null; // set by the delayed read
				addRelation(parent, CustomAttribute(ca));
			case FieldMarshal(fm):
				var parent = sreadFromTable(false, T.IHasFieldMarshal, c);
				var nativesig = readNativesigIdx(c);
				fm.parent = parent;
				fm.nativeType = nativesig;
				addRelation(parent, FieldMarshal(fm));
			case DeclSecurity(ds):
				var action = actionSecurityOfInt(sreadUi16(c));
				var parent = sreadFromTable(false, T.IHasDeclSecurity, c);
				var permissionSet = readSblobIdx(c);
				ds.action = action;
				ds.parent = parent;
				ds.permissionSet = permissionSet;
				addRelation(parent, DeclSecurity(ds));
			case ClassLayout(cl):
				var psize = sreadUi16(c);
				var csize = sreadI32(c);
				var parent = sreadFromTable(false, T.ITypeDef, c);
				addRelation(parent, ClassLayout(cl));
				cl.packingSize = psize;
				cl.classSize = csize;
				cl.parent = getTypeDef(parent);
			case FieldLayout(fl):
				var offset = sreadI32(c);
				var field = sreadFromTable(false, T.IField, c);
				fl.offset = offset;
				fl.field = getField(field);
				addRelation(field, FieldLayout(fl));
			case StandAloneSig(sa):
				sa.signature = readFieldIlsigIdx(c, false);
			case EventMap(em):
				var startpos = c.pos;
				var parent = sreadFromTable(false, T.ITypeDef, c);
				var offset = c.pos - startpos;
				var eventList = sreadWidth(tableSizes[T.IEvent], c);
				em.parent = getTypeDef(parent);
				em.eventList = [for (e in readList(T.IEvent, T.IEventPtr, eventList, offset, last, c.pos)) getEvent(e)];
				addRelation(parent, EventMap(em));
			case EventPtr(ep):
				ep.event = getEvent(sreadFromTable(false, T.IEvent, c));
			case Event(e):
				var flags = sreadUi16(c);
				var name = readSstringIdx(c);
				var eventType = sreadFromTable(false, T.ITypeDefOrRef, c);
				e.flags = eventFlagsOfInt(flags);
				e.name = name;
				e.eventType = eventType;
				addRelation(eventType, Event(e));
			case PropertyMap(pm):
				var startpos = c.pos;
				var parent = sreadFromTable(false, T.ITypeDef, c);
				var offset = c.pos - startpos;
				var propertyList = sreadWidth(tableSizes[T.IProperty], c);
				pm.parent = getTypeDef(parent);
				pm.propertyList = [for (p in readList(T.IProperty, T.IPropertyPtr, propertyList, offset, last, c.pos)) getProperty(p)];
				addRelation(parent, PropertyMap(pm));
			case PropertyPtr(pp):
				pp.property = getProperty(sreadFromTable(false, T.IProperty, c));
			case Property(prop):
				var flags = sreadUi16(c);
				var name = readSstringIdx(c);
				var t = readFieldIlsigIdx(c, false);
				prop.flags = propertyFlagsOfInt(flags);
				prop.name = name;
				prop.type = t;
			case MethodSemantics(ms):
				var semantic = sreadUi16(c);
				var m = sreadFromTable(false, T.IMethod, c);
				var association = sreadFromTable(false, T.IHasSemantics, c);
				ms.semantic = semanticFlagsOfInt(semantic);
				ms.method = getMethod(m);
				ms.association = association;
				addRelation(m, MethodSemantics(ms));
				addRelation(association, MethodSemantics(ms));
			case MethodImpl(mi):
				var cls = sreadFromTable(false, T.ITypeDef, c);
				var methodBody = sreadFromTable(false, T.IMethodDefOrRef, c);
				var methodDeclaration = sreadFromTable(false, T.IMethodDefOrRef, c);
				mi.cls = getTypeDef(cls);
				mi.methodBody = methodBody;
				mi.methodDeclaration = methodDeclaration;
				addRelation(methodBody, MethodImpl(mi));
			case ModuleRef(modr):
				modr.name = readSstringIdx(c);
			case TypeSpec(ts):
				ts.signature = readIlsigIdx(c);
			case ENCLog(el):
				el.token = sreadI32(c);
				el.funcCode = sreadI32(c);
			case ImplMap(im):
				var flags = sreadUi16(c);
				var forwarded = sreadFromTable(false, T.IMemberForwarded, c);
				var importName = readSstringIdx(c);
				var importScope = sreadFromTableOpt(false, T.IModuleRef, c);
				im.flags = implFlagsOfInt(flags);
				im.forwarded = forwarded;
				im.importName = importName;
				im.importScope = getModuleRef(importScope);
				addRelation(forwarded, ImplMap(im));
			case ENCMap(em):
				em.token = sreadI32(c);
			case FieldRVA(f):
				var rva = sreadRealI32(c);
				var field = sreadFromTable(false, T.IField, c);
				f.rva = rva;
				f.field = getField(field);
				addRelation(field, FieldRVA(f));
			case Assembly(a):
				var hashAlgo = sreadI32(c);
				var major = sreadUi16(c);
				var minor = sreadUi16(c);
				var build = sreadUi16(c);
				var rev = sreadUi16(c);
				var flags = sreadI32(c);
				var publicKey = readSblobIdx(c);
				var name = readSstringIdx(c);
				var locale = readSstringIdx(c);
				a.hashAlgo = hashAlgoOfInt(hashAlgo);
				a.major = major;
				a.minor = minor;
				a.build = build;
				a.rev = rev;
				a.flags = flags;
				a.publicKey = publicKey;
				a.name = name;
				a.locale = locale;
			case AssemblyProcessor(ap):
				ap.processor = sreadI32(c);
			case AssemblyOS(aos):
				aos.platformId = sreadI32(c);
				aos.majorVersion = sreadI32(c);
				aos.minorVersion = sreadI32(c);
			case AssemblyRef(ar):
				ar.major = sreadUi16(c);
				ar.minor = sreadUi16(c);
				ar.build = sreadUi16(c);
				ar.rev = sreadUi16(c);
				ar.flags = sreadI32(c);
				ar.publicKey = readSblobIdx(c);
				ar.name = readSstringIdx(c);
				ar.locale = readSstringIdx(c);
				ar.hashValue = readSblobIdx(c);
			case AssemblyRefProcessor(arp):
				arp.processor = sreadI32(c);
				arp.assemblyRef = getAssemblyRef(sreadFromTable(false, T.IAssemblyRef, c));
			case AssemblyRefOS(aros):
				aros.platformId = sreadI32(c);
				aros.major = sreadI32(c);
				aros.minor = sreadI32(c);
				aros.assemblyRef = getAssemblyRef(sreadFromTable(false, T.IAssemblyRef, c));
			case File(file):
				var flags = sreadI32(c);
				var name = readSstringIdx(c);
				var hashValue = readSblobIdx(c);
				file.flags = fileFlagOfInt(flags);
				file.name = name;
				file.hashValue = hashValue;
			case ExportedType(et):
				var flags = sreadI32(c);
				var typeDefId = sreadI32(c);
				var typeName = readSstringIdx(c);
				var typeNamespace = readSstringIdx(c);
				var impl = sreadFromTable(false, T.IImplementation, c);
				et.flags = TypeDefFlags.ofInt(flags);
				et.typeDefId = typeDefId;
				et.typeName = typeName;
				et.typeNamespace = parseNs(typeNamespace);
				et.implementation = impl;
				addRelation(impl, ExportedType(et));
			case ManifestResource(mr):
				var offset = sreadI32(c);
				var flags = sreadI32(c);
				var name = readSstringIdx(c);
				var peek = new Cur(s, c.pos);
				var i = sreadWidth(tableSizes[T.IImplementation], peek);
				var impl:Null<ClrMeta> = null;
				if (i == 0)
					c.pos = peek.pos;
				else {
					impl = sreadFromTable(false, T.IImplementation, c);
					addRelation(impl, ManifestResource(mr));
				}
				mr.offset = offset;
				mr.flags = manifestResourceFlagOfInt(flags);
				mr.name = name;
				mr.implementation = impl;
			case NestedClass(nc):
				var nested = sreadFromTable(false, T.ITypeDef, c);
				var enclosing = sreadFromTable(false, T.ITypeDef, c);
				nc.nested = getTypeDef(nested);
				nc.enclosing = getTypeDef(enclosing);
				if (nc.nested.extraEnclosing != null) throw "Assertion failed: nested class";
				nc.nested.extraEnclosing = nc.enclosing;
				addRelation(enclosing, NestedClass(nc));
			case GenericParam(gp):
				var number = sreadUi16(c);
				var flags = sreadUi16(c);
				var owner = sreadFromTable(false, T.ITypeOrMethodDef, c);
				var peek = new Cur(s, c.pos);
				var nidx = sreadWidth(stringsOffset, peek);
				var name:Null<String> = null;
				if (nidx == 0)
					c.pos = peek.pos;
				else
					name = readSstringIdx(c);
				gp.number = number;
				gp.flags = GenericFlags.ofInt(flags);
				gp.owner = owner;
				gp.name = name;
				addRelation(owner, GenericParam(gp));
			case MethodSpec(mspec):
				var meth = sreadFromTable(false, T.IMethodDefOrRef, c);
				var instantiation = readMethodIlsigIdx(c);
				mspec.method = meth;
				mspec.instantiation = instantiation;
				addRelation(meth, MethodSpec(mspec));
			case GenericParamConstraint(gc):
				var owner = sreadFromTable(false, T.IGenericParam, c);
				var k = sreadFromTable(false, T.ITypeDefOrRef, c);
				gc.owner = getGenericParam(owner);
				gc.constraint = k;
				addRelation(owner, GenericParamConstraint(gc));
			case UnknownMeta(_):
				throw "Assertion failed: read_table_at";
		}
	}

	// ******* META READING *********

	// The table stream's header: which tables there are and how many rows each has, with the cursor on
	// the first row. It sets the widths of the heap, table and coded indexes on the way.
	function readHeader():{setTable:Array<Bool>, rows:Array<Int>, c:Cur} {
		var s = metaStream;
		var pos = 4 + 1 + 1;
		var flags = sget(s, pos);
		for (i in [0x01, 0x02, 0x04, 0x20, 0x80]) if (flags & i == i) switch (i) {
			case 0x01: stringsOffset = 4;
			case 0x02: guidOffset = 4;
			case 0x04: blobOffset = 4;
			case 0x20:
				if (compressed) throw "Assertion failed: read_meta";
				metaEditContinue = true;
			case _:
				if (compressed) throw "Assertion failed: read_meta";
				metaHasDeleted = true;
		}
		pos += 2;
		var mask = [for (n in 0...8) sget(s, pos + n)];
		// loop over masks and check which table is set
		var setTable = [for (n in 0...64) (mask[n >> 3] >> (n & 7)) & 0x1 == 0x1];
		// there is an extra 'sorted' field, which is not used
		var c = new Cur(s, pos + 8 + 8);
		var rows = [
			for (i in 0...64) {
				if (!setTable[i]) 0 else {
					var nrows = sreadI32(c);
					if (nrows > 0xFFFF) tableSizes[i] = 4;
					nrows;
				}
			}
		];
		setCodedSizes(rows);
		return {setTable: setTable, rows: rows, c: c};
	}

	function readMeta():Void {
		var h = readHeader();
		var setTable = h.setTable, rows = h.rows, c = h.c;
		// pre-set all rows
		for (n in 0...64) if (setTable[n]) tables[n] = [for (id in 0...rows[n]) mkMeta(n, id + 1)];
		for (n in 0...64) if (setTable[n]) {
			var nrows = rows[n];
			for (r in 0...nrows) readTableAt(n, r, r == nrows - 1, c);
		}
	}

	// The bytes one row of a table takes (ECMA-335 II.22), or -1 for a table the standard does not have.
	function rowSize(n:Int):Int {
		var s = stringsOffset, g = guidOffset, b = blobOffset;
		var w = tableSizes;
		return switch (n) {
			case 0x00: 2 + s + g * 3; // Module
			case 0x01: w[T.IResolutionScope] + s * 2; // TypeRef
			case 0x02: 4 + s * 2 + w[T.ITypeDefOrRef] + w[T.IField] + w[T.IMethod]; // TypeDef
			case 0x03: w[T.IField]; // FieldPtr
			case 0x04: 2 + s + b; // Field
			case 0x05: w[T.IMethod]; // MethodPtr
			case 0x06: 8 + s + b + w[T.IParam]; // MethodDef
			case 0x07: w[T.IParam]; // ParamPtr
			case 0x08: 4 + s; // Param
			case 0x09: w[T.ITypeDef] + w[T.ITypeDefOrRef]; // InterfaceImpl
			case 0x0A: w[T.IMemberRefParent] + s + b; // MemberRef
			case 0x0B: 2 + w[T.IHasConstant] + b; // Constant
			case 0x0C: w[T.IHasCustomAttribute] + w[T.ICustomAttributeType] + b; // CustomAttribute
			case 0x0D: w[T.IHasFieldMarshal] + b; // FieldMarshal
			case 0x0E: 2 + w[T.IHasDeclSecurity] + b; // DeclSecurity
			case 0x0F: 6 + w[T.ITypeDef]; // ClassLayout
			case 0x10: 4 + w[T.IField]; // FieldLayout
			case 0x11: b; // StandAloneSig
			case 0x12: w[T.ITypeDef] + w[T.IEvent]; // EventMap
			case 0x13: w[T.IEvent]; // EventPtr
			case 0x14: 2 + s + w[T.ITypeDefOrRef]; // Event
			case 0x15: w[T.ITypeDef] + w[T.IProperty]; // PropertyMap
			case 0x16: w[T.IProperty]; // PropertyPtr
			case 0x17: 2 + s + b; // Property
			case 0x18: 2 + w[T.IMethod] + w[T.IHasSemantics]; // MethodSemantics
			case 0x19: w[T.ITypeDef] + w[T.IMethodDefOrRef] * 2; // MethodImpl
			case 0x1A: s; // ModuleRef
			case 0x1B: b; // TypeSpec
			case 0x1C: 2 + w[T.IMemberForwarded] + s + w[T.IModuleRef]; // ImplMap
			case 0x1D: 4 + w[T.IField]; // FieldRVA
			case 0x1E: 8; // ENCLog
			case 0x1F: 4; // ENCMap
			case 0x20: 16 + b + s * 2; // Assembly
			case 0x21: 4; // AssemblyProcessor
			case 0x22: 12; // AssemblyOS
			case 0x23: 12 + b * 2 + s * 2; // AssemblyRef
			case 0x24: 4 + w[T.IAssemblyRef]; // AssemblyRefProcessor
			case 0x25: 12 + w[T.IAssemblyRef]; // AssemblyRefOS
			case 0x26: 4 + s + b; // File
			case 0x27: 8 + s * 2 + w[T.IImplementation]; // ExportedType
			case 0x28: 8 + s + w[T.IImplementation]; // ManifestResource
			case 0x29: w[T.ITypeDef] * 2; // NestedClass
			case 0x2A: 4 + w[T.ITypeOrMethodDef] + s; // GenericParam
			case 0x2B: w[T.IMethodDefOrRef] + b; // MethodSpec
			case 0x2C: w[T.IGenericParam] + w[T.ITypeDefOrRef]; // GenericParamConstraint
			case _: -1;
		};
	}

	// The light reading of the tables: where each one starts follows from the row counts and row sizes,
	// and only the type, nesting, assembly reference and forwarder rows are read. Null when the stream is
	// not exactly its header and those rows, since a row size was then not what the standard gives.
	function readLightTables():Null<IlLight> {
		var s = metaStream;
		// an extra word after the row counts
		if (sget(s, 6) & 0x40 != 0) return null;
		var h = readHeader();
		var rows = h.rows;
		var start = [for (_ in 0...64) 0];
		var pos = h.c.pos;
		for (n in 0...64) {
			start[n] = pos;
			if (!h.setTable[n]) continue;
			var size = rowSize(n);
			if (size < 0) return null;
			pos += rows[n] * size;
		}
		// the stream ends with the last row and its padding: up to three zero bytes, or the one zero byte
		// some writers add and then the padding
		if (pos > s.length || s.length - pos > 4) return null;
		for (k in pos...s.length) if (sget(s, k) != 0) return null;

		var c = new Cur(s, 0);
		var nTypes = rows[T.ITypeDef];
		var names:Array<String> = [], nss:Array<Array<String>> = [];
		var size = rowSize(T.ITypeDef);
		for (i in 0...nTypes) {
			c.pos = start[T.ITypeDef] + i * size + 4;
			names.push(readSstringIdx(c));
			nss.push(parseNs(readSstringIdx(c)));
		}
		var enclosing = [for (_ in 0...nTypes) -1];
		var w = tableSizes[T.ITypeDef];
		c.pos = start[T.INestedClass];
		for (_ in 0...rows[T.INestedClass]) {
			var nested = sreadWidth(w, c) - 1;
			var outer = sreadWidth(w, c) - 1;
			if (nested < 0 || nested >= nTypes || outer < 0 || outer >= nTypes || enclosing[nested] != -1) return null;
			enclosing[nested] = outer;
		}
		// as IlMetaTools.getPath has it: a nested type takes its outermost type's namespace
		var paths:Array<Null<IlPath>> = [for (_ in 0...nTypes) null];
		var failed = false;
		function path(i:Int, depth:Int):IlPath {
			var p = paths[i];
			if (p != null) return p;
			if (enclosing[i] < 0 || depth > 64) {
				if (enclosing[i] >= 0) failed = true;
				p = {ns: nss[i], nested: [], name: names[i]};
			} else {
				var o = path(enclosing[i], depth + 1);
				p = {ns: o.ns, nested: o.nested.concat([o.name]), name: names[i]};
			}
			paths[i] = p;
			return p;
		}
		var types:Array<IlPath> = [for (i in 0...nTypes) path(i, 0)];
		if (failed) return null;

		var refs:Array<String> = [];
		size = rowSize(T.IAssemblyRef);
		for (i in 0...rows[T.IAssemblyRef]) {
			c.pos = start[T.IAssemblyRef] + i * size + 12 + blobOffset;
			refs.push(readSstringIdx(c));
		}

		var forwarders:Array<IlForwarder> = [];
		size = rowSize(T.IExportedType);
		var d = codedDescription[T.IImplementation - 64];
		for (i in 0...rows[T.IExportedType]) {
			c.pos = start[T.IExportedType] + i * size + 8;
			var name = readSstringIdx(c);
			var ns = parseNs(readSstringIdx(c));
			var rid = sreadWidth(tableSizes[T.IImplementation], c);
			var tidx = rid & ((1 << d.size) - 1), real = rid >>> d.size;
			if (tidx >= d.tbls.length || real == 0 || real > rows[d.tbls[tidx]]) return null;
			forwarders.push({name: name, ns: ns, to: d.tbls[tidx] == T.IAssemblyRef ? refs[real - 1] : null});
		}
		return new IlLight(types, refs, forwarders);
	}

	static function readPadded(i:PeInput, npad:Int):String {
		var buf = new haxe.io.BytesBuffer();
		var n = 1;
		while (true) {
			var chr = i.readByte();
			if (chr == 0) {
				var pad = n & 0x3;
				if (pad != 0) i.nread(4 - pad);
				break;
			}
			buf.addByte(chr);
			if (n == npad) break;
			n++;
		}
		return buf.getBytes().toString();
	}

	public static function readMetaTables(pctx:PeFile, header:ClrHeader):IlCtx {
		var r = open(pctx, header, false);
		r.tables = [for (_ in 0...64) []];
		r.readMeta();
		// the delays run most recent first
		var delays = r.delays;
		r.delays = [];
		var k = delays.length;
		while (k-- > 0) delays[k]();
		return new IlCtx(r.tables, r.relations, r.typedefs, r.typedefOrder);
	}

	// What the assembly's tables tell without all their rows being read (IlLight), or null when it takes
	// readMetaTables to know: tables that are not compressed, or not laid out as the standard has them.
	public static function readLight(pctx:PeFile, header:ClrHeader):Null<IlLight> {
		var r = open(pctx, header, true);
		if (!r.compressed) return null;
		return try r.readLightTables() catch (_:Dynamic) null;
	}

	// The metadata root and its streams. `light` leaves the heaps the light reading does not use.
	static function open(pctx:PeFile, header:ClrHeader, light:Bool):IlMetaReader {
		var i = pctx.input;
		PeReader.seekRva(pctx, header.meta.addr);
		var magic = i.nreadString(4);
		if (magic != "BSJB") throw new PeErrorMessage("Error reading metadata table: Expected magic 'BSJB'. Got " + magic);
		i.readUi16(); // major
		i.readUi16(); // minor
		i.readI32(); // reserved
		var vlen = i.readI32();
		i.nread(vlen); // version

		// meta storage header
		i.readUi16(); // reserved
		var nstreams = i.readUi16();
		var streams:Array<ClrStreamHeader> = [];
		var n = 0;
		while (true) {
			var offset = i.readI32();
			var size = i.readI32();
			var name = readPadded(i, 32);
			streams.unshift({offset: offset, size: size, name: name});
			if (n + 1 == nstreams) break;
			n++;
		}

		var r = new IlMetaReader();
		var compressed:Null<Bool> = null;
		var empty = Bytes.alloc(0);
		r.stringsStream = empty;
		r.blobStream = empty;
		r.guidStream = empty;
		r.usStream = empty;
		r.metaStream = empty;
		var extra = [];
		for (s in streams) {
			PeReader.seekRva(pctx, header.meta.addr + s.offset);
			switch (s.name.toLowerCase()) {
				case "#guid": if (!light) r.guidStream = i.nread(s.size);
				case "#strings": r.stringsStream = i.nread(s.size);
				case "#us": if (!light) r.usStream = i.nread(s.size);
				case "#blob": if (!light) r.blobStream = i.nread(s.size);
				case "#~":
					if (compressed != null) throw "Assertion failed: read_meta_tables";
					compressed = true;
					r.metaStream = i.nread(s.size);
				case "#-":
					if (compressed != null) throw "Assertion failed: read_meta_tables";
					compressed = false;
					r.metaStream = i.nread(s.size);
				case _:
					extra.unshift(s);
			}
		}
		if (compressed == null) throw new PeErrorMessage("No compressed or uncompressed metadata streams was found!");
		r.compressed = compressed;
		r.extraStreams = extra;
		r.tableSizes = [for (_ in 0...maxClrMetaIdx + 1) 2];
		return r;
	}
}
