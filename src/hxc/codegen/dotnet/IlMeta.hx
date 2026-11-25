package hxc.codegen.dotnet;

// the raw CLI metadata: one row type per table, the flags they carry and the signature blobs.
// Rows are created empty when the table sizes are known and filled in place, since a row may
// reference one that is read later.

// the table and coded-index numbers.
class TableIdx {
	public static inline var IModule = 0;
	public static inline var ITypeRef = 1;
	public static inline var ITypeDef = 2;
	public static inline var IFieldPtr = 3;
	public static inline var IField = 4;
	public static inline var IMethodPtr = 5;
	public static inline var IMethod = 6;
	public static inline var IParamPtr = 7;
	public static inline var IParam = 8;
	public static inline var IInterfaceImpl = 9;
	public static inline var IMemberRef = 10;
	public static inline var IConstant = 11;
	public static inline var ICustomAttribute = 12;
	public static inline var IFieldMarshal = 13;
	public static inline var IDeclSecurity = 14;
	public static inline var IClassLayout = 15;
	public static inline var IFieldLayout = 16;
	public static inline var IStandAloneSig = 17;
	public static inline var IEventMap = 18;
	public static inline var IEventPtr = 19;
	public static inline var IEvent = 20;
	public static inline var IPropertyMap = 21;
	public static inline var IPropertyPtr = 22;
	public static inline var IProperty = 23;
	public static inline var IMethodSemantics = 24;
	public static inline var IMethodImpl = 25;
	public static inline var IModuleRef = 26;
	public static inline var ITypeSpec = 27;
	public static inline var IImplMap = 28;
	public static inline var IFieldRVA = 29;
	public static inline var IENCLog = 30;
	public static inline var IENCMap = 31;
	public static inline var IAssembly = 32;
	public static inline var IAssemblyProcessor = 33;
	public static inline var IAssemblyOS = 34;
	public static inline var IAssemblyRef = 35;
	public static inline var IAssemblyRefProcessor = 36;
	public static inline var IAssemblyRefOS = 37;
	public static inline var IFile = 38;
	public static inline var IExportedType = 39;
	public static inline var IManifestResource = 40;
	public static inline var INestedClass = 41;
	public static inline var IGenericParam = 42;
	public static inline var IMethodSpec = 43;
	public static inline var IGenericParamConstraint = 44;
	// the Portable PDB's tables
	public static inline var IDocument = 0x30;
	public static inline var IMethodDebugInformation = 0x31;
	public static inline var ILocalScope = 0x32;
	public static inline var ILocalVariable = 0x33;
	public static inline var ILocalConstant = 0x34;
	public static inline var IImportScope = 0x35;
	public static inline var IStateMachineMethod = 0x36;
	public static inline var ICustomDebugInformation = 0x37;
	// coded tokens
	public static inline var ITypeDefOrRef = 64;
	public static inline var IHasConstant = 65;
	public static inline var IHasCustomAttribute = 66;
	public static inline var IHasFieldMarshal = 67;
	public static inline var IHasDeclSecurity = 68;
	public static inline var IMemberRefParent = 69;
	public static inline var IHasSemantics = 70;
	public static inline var IMethodDefOrRef = 71;
	public static inline var IMemberForwarded = 72;
	public static inline var IImplementation = 73;
	public static inline var ICustomAttributeType = 74;
	public static inline var IResolutionScope = 75;
	public static inline var ITypeOrMethodDef = 76;
	public static inline var IHasCustomDebugInformation = 77;
}

enum ClrMeta {
	Module(r:MetaModule);
	TypeRef(r:MetaTypeRef);
	TypeDef(r:MetaTypeDef);
	FieldPtr(r:MetaFieldPtr);
	Field(r:MetaField);
	MethodPtr(r:MetaMethodPtr);
	Method(r:MetaMethod);
	ParamPtr(r:MetaParamPtr);
	Param(r:MetaParam);
	InterfaceImpl(r:MetaInterfaceImpl);
	MemberRef(r:MetaMemberRef);
	Constant(r:MetaConstant);
	CustomAttribute(r:MetaCustomAttribute);
	FieldMarshal(r:MetaFieldMarshal);
	DeclSecurity(r:MetaDeclSecurity);
	ClassLayout(r:MetaClassLayout);
	FieldLayout(r:MetaFieldLayout);
	StandAloneSig(r:MetaStandAloneSig);
	EventMap(r:MetaEventMap);
	EventPtr(r:MetaEventPtr);
	Event(r:MetaEvent);
	PropertyMap(r:MetaPropertyMap);
	PropertyPtr(r:MetaPropertyPtr);
	Property(r:MetaProperty);
	MethodSemantics(r:MetaMethodSemantics);
	MethodImpl(r:MetaMethodImpl);
	ModuleRef(r:MetaModuleRef);
	TypeSpec(r:MetaTypeSpec);
	ImplMap(r:MetaImplMap);
	FieldRVA(r:MetaFieldRva);
	ENCLog(r:MetaEncLog);
	ENCMap(r:MetaEncMap);
	Assembly(r:MetaAssembly);
	AssemblyProcessor(r:MetaAssemblyProcessor);
	AssemblyOS(r:MetaAssemblyOs);
	AssemblyRef(r:MetaAssemblyRef);
	AssemblyRefProcessor(r:MetaAssemblyRefProcessor);
	AssemblyRefOS(r:MetaAssemblyRefOs);
	File(r:MetaFile);
	ExportedType(r:MetaExportedType);
	ManifestResource(r:MetaManifestResource);
	NestedClass(r:MetaNestedClass);
	GenericParam(r:MetaGenericParam);
	MethodSpec(r:MetaMethodSpec);
	GenericParamConstraint(r:MetaGenericParamConstraint);
	UnknownMeta(i:Int);
}

// the text of a row not read yet.
class MetaEmpty {
	public static inline var empty = "<not initialized>";
}

class MetaModule {
	public var id:Int;
	public var generation:Int = 0;
	public var name:String = MetaEmpty.empty;
	public var vid:Null<haxe.io.Bytes> = null;
	public var encid:Null<haxe.io.Bytes> = null;
	public var encbaseId:Null<haxe.io.Bytes> = null;

	public function new(id:Int) this.id = id;
}

class MetaTypeRef {
	public var id:Int;
	public var resolutionScope:ClrMeta = UnknownMeta(-1);
	public var name:String = MetaEmpty.empty;
	public var namespace:Array<String> = [];

	public function new(id:Int) this.id = id;
}

class MetaTypeDef {
	public var id:Int;
	public var flags:TypeDefFlags = TypeDefFlags.nullFlags;
	public var name:String = MetaEmpty.empty;
	public var namespace:Array<String> = [];
	public var extends_:Null<ClrMeta> = null;
	public var fieldList:Array<MetaField> = [];
	public var methodList:Array<MetaMethod> = [];
	// extra field
	public var extraEnclosing:Null<MetaTypeDef> = null;

	public function new(id:Int) this.id = id;
}

class MetaFieldPtr {
	public var id:Int;
	public var field:Null<MetaField> = null;

	public function new(id:Int) this.id = id;
}

class MetaField {
	public var id:Int;
	public var flags:FieldFlags = FieldFlags.nullFlags;
	public var name:String = MetaEmpty.empty;
	public var signature:IlSig = SVoid;

	public function new(id:Int) this.id = id;
}

class MetaMethodPtr {
	public var id:Int;
	public var method:Null<MetaMethod> = null;

	public function new(id:Int) this.id = id;
}

class MetaMethod {
	public var id:Int;
	public var rva:Int = -1;
	public var flags:MethodFlags = MethodFlags.nullFlags;
	public var name:String = MetaEmpty.empty;
	public var signature:IlSig = SVoid;
	public var paramList:Array<MetaParam> = [];
	// extra field
	public var declaring:Null<MetaTypeDef> = null;

	public function new(id:Int) this.id = id;
}

class MetaParamPtr {
	public var id:Int;
	public var param:Null<MetaParam> = null;

	public function new(id:Int) this.id = id;
}

class MetaParam {
	public var id:Int;
	public var flags:ParamFlags = ParamFlags.nullFlags;
	// 0 means the return value
	public var sequence:Int = -1;
	public var name:String = MetaEmpty.empty;

	public function new(id:Int) this.id = id;
}

class MetaInterfaceImpl {
	public var id:Int;
	public var cls:Null<MetaTypeDef> = null;
	public var iface:ClrMeta = UnknownMeta(-1);

	public function new(id:Int) this.id = id;
}

class MetaMemberRef {
	public var id:Int;
	public var cls:ClrMeta = UnknownMeta(-1);
	public var name:String = MetaEmpty.empty;
	public var signature:IlSig = SVoid;

	public function new(id:Int) this.id = id;
}

class MetaConstant {
	public var id:Int;
	public var type:ConstantType = CNullRef;
	public var parent:ClrMeta = UnknownMeta(-1);
	public var value:IlConstant = INull;

	public function new(id:Int) this.id = id;
}

class MetaCustomAttribute {
	public var id:Int;
	public var parent:ClrMeta = UnknownMeta(-1);
	public var type:ClrMeta = UnknownMeta(-1);
	public var value:Null<{fixed:Array<Instance>, named:Array<NamedAttribute>}> = null;

	public function new(id:Int) this.id = id;
}

typedef NamedAttribute = {isProp:Bool, name:String, inst:Instance};

class MetaFieldMarshal {
	public var id:Int;
	public var parent:ClrMeta = UnknownMeta(-1);
	public var nativeType:NativeSig = NVoid;

	public function new(id:Int) this.id = id;
}

class MetaDeclSecurity {
	public var id:Int;
	// SecRequest (1) .. SecNonCasInheritance (15); 0 is SecNull
	public var action:Int = 0;
	public var parent:ClrMeta = UnknownMeta(-1);
	public var permissionSet:haxe.io.Bytes = null;

	public function new(id:Int) this.id = id;
}

class MetaClassLayout {
	public var id:Int;
	public var packingSize:Int = -1;
	public var classSize:Int = -1;
	public var parent:Null<MetaTypeDef> = null;

	public function new(id:Int) this.id = id;
}

class MetaFieldLayout {
	public var id:Int;
	public var offset:Int = -1;
	public var field:Null<MetaField> = null;

	public function new(id:Int) this.id = id;
}

class MetaStandAloneSig {
	public var id:Int;
	public var signature:IlSig = SVoid;

	public function new(id:Int) this.id = id;
}

class MetaEventMap {
	public var id:Int;
	public var parent:Null<MetaTypeDef> = null;
	public var eventList:Array<MetaEvent> = [];

	public function new(id:Int) this.id = id;
}

class MetaEventPtr {
	public var id:Int;
	public var event:Null<MetaEvent> = null;

	public function new(id:Int) this.id = id;
}

class MetaEvent {
	public var id:Int;
	public var flags:Array<EventFlag> = [];
	public var name:String = MetaEmpty.empty;
	public var eventType:ClrMeta = UnknownMeta(-1);

	public function new(id:Int) this.id = id;
}

class MetaPropertyMap {
	public var id:Int;
	public var parent:Null<MetaTypeDef> = null;
	public var propertyList:Array<MetaProperty> = [];

	public function new(id:Int) this.id = id;
}

class MetaPropertyPtr {
	public var id:Int;
	public var property:Null<MetaProperty> = null;

	public function new(id:Int) this.id = id;
}

class MetaProperty {
	public var id:Int;
	public var flags:Array<PropertyFlag> = [];
	public var name:String = MetaEmpty.empty;
	public var type:IlSig = SVoid;

	public function new(id:Int) this.id = id;
}

class MetaMethodSemantics {
	public var id:Int;
	public var semantic:Array<SemanticFlag> = [];
	public var method:Null<MetaMethod> = null;
	public var association:ClrMeta = UnknownMeta(-1);

	public function new(id:Int) this.id = id;
}

class MetaMethodImpl {
	public var id:Int;
	public var cls:Null<MetaTypeDef> = null;
	// the overriding method
	public var methodBody:ClrMeta = UnknownMeta(-1);
	// the overridden method
	public var methodDeclaration:ClrMeta = UnknownMeta(-1);

	public function new(id:Int) this.id = id;
}

class MetaModuleRef {
	public var id:Int;
	public var name:String = MetaEmpty.empty;

	public function new(id:Int) this.id = id;
}

class MetaTypeSpec {
	public var id:Int;
	public var signature:IlSig = SVoid;

	public function new(id:Int) this.id = id;
}

class MetaEncLog {
	public var id:Int;
	public var token:Int = -1;
	public var funcCode:Int = -1;

	public function new(id:Int) this.id = id;
}

class MetaImplMap {
	public var id:Int;
	// charset, call convention and flag bits, checked when read
	public var flags:Int = 0;
	public var forwarded:ClrMeta = UnknownMeta(-1);
	public var importName:String = MetaEmpty.empty;
	public var importScope:Null<MetaModuleRef> = null;

	public function new(id:Int) this.id = id;
}

class MetaEncMap {
	public var id:Int;
	public var token:Int = -1;

	public function new(id:Int) this.id = id;
}

class MetaFieldRva {
	public var id:Int;
	public var rva:Int = 0;
	public var field:Null<MetaField> = null;

	public function new(id:Int) this.id = id;
}

class MetaAssembly {
	public var id:Int;
	public var hashAlgo:Int = 0;
	public var major:Int = -1;
	public var minor:Int = -1;
	public var build:Int = -1;
	public var rev:Int = -1;
	public var flags:Int = 0;
	public var publicKey:haxe.io.Bytes = null;
	public var name:String = MetaEmpty.empty;
	public var locale:String = MetaEmpty.empty;

	public function new(id:Int) this.id = id;
}

class MetaAssemblyProcessor {
	public var id:Int;
	public var processor:Int = -1;

	public function new(id:Int) this.id = id;
}

class MetaAssemblyOs {
	public var id:Int;
	public var platformId:Int = -1;
	public var majorVersion:Int = -1;
	public var minorVersion:Int = -1;

	public function new(id:Int) this.id = id;
}

class MetaAssemblyRef {
	public var id:Int;
	public var major:Int = -1;
	public var minor:Int = -1;
	public var build:Int = -1;
	public var rev:Int = -1;
	public var flags:Int = 0;
	public var publicKey:haxe.io.Bytes = null;
	// no path, no extension
	public var name:String = MetaEmpty.empty;
	public var locale:String = MetaEmpty.empty;
	public var hashValue:haxe.io.Bytes = null;

	public function new(id:Int) this.id = id;
}

class MetaAssemblyRefProcessor {
	public var id:Int;
	public var processor:Int = -1;
	public var assemblyRef:Null<MetaAssemblyRef> = null;

	public function new(id:Int) this.id = id;
}

class MetaAssemblyRefOs {
	public var id:Int;
	public var platformId:Int = -1;
	public var major:Int = -1;
	public var minor:Int = -1;
	public var assemblyRef:Null<MetaAssemblyRef> = null;

	public function new(id:Int) this.id = id;
}

class MetaFile {
	public var id:Int;
	// 0 ContainsMetadata, 1 ContainsNoMetadata
	public var flags:Int = 0;
	public var name:String = MetaEmpty.empty;
	public var hashValue:haxe.io.Bytes = null;

	public function new(id:Int) this.id = id;
}

class MetaExportedType {
	public var id:Int;
	public var flags:TypeDefFlags = TypeDefFlags.nullFlags;
	// the TypeDef token in another module
	public var typeDefId:Int = -1;
	public var typeName:String = MetaEmpty.empty;
	public var typeNamespace:Array<String> = [];
	public var implementation:ClrMeta = UnknownMeta(-1);

	public function new(id:Int) this.id = id;
}

class MetaManifestResource {
	public var id:Int;
	public var offset:Int = -1;
	// 0 RNone, 1 RPublic, 2 RPrivate
	public var flags:Int = 0;
	public var name:String = MetaEmpty.empty;
	public var implementation:Null<ClrMeta> = null;

	public function new(id:Int) this.id = id;
}

class MetaNestedClass {
	public var id:Int;
	public var nested:Null<MetaTypeDef> = null;
	public var enclosing:Null<MetaTypeDef> = null;

	public function new(id:Int) this.id = id;
}

class MetaGenericParam {
	public var id:Int;
	public var number:Int = -1;
	public var flags:GenericFlags = GenericFlags.nullFlags;
	// the generic type or method
	public var owner:ClrMeta = UnknownMeta(-1);
	public var name:Null<String> = null;

	public function new(id:Int) this.id = id;
}

class MetaMethodSpec {
	public var id:Int;
	public var method:ClrMeta = UnknownMeta(-1);
	public var instantiation:IlSig = SVoid;

	public function new(id:Int) this.id = id;
}

class MetaGenericParamConstraint {
	public var id:Int;
	public var owner:Null<MetaGenericParam> = null;
	public var constraint:ClrMeta = UnknownMeta(-1);

	public function new(id:Int) this.id = id;
}

enum IlConstant {
	IBool(b:Bool);
	IChar(i:Int);
	IByte(i:Int);
	IShort(i:Int);
	IInt(i:Int);
	// `i` as the reference reads it (one byte late, for the converter's enum order); `exact` as stored.
	IInt64(i:haxe.Int64, exact:haxe.Int64);
	IFloat32(f:Float);
	IFloat64(f:Float);
	IString(s:haxe.io.Bytes);
	INull;
}

enum Instance {
	InstConstant(c:IlConstant);
	InstBoxed(i:Instance);
	InstType(t:haxe.io.Bytes);
	InstArray(l:Array<Instance>);
	InstEnum(e:Int);
}

enum ConstantType {
	CBool;
	CChar;
	CInt8;
	CUInt8;
	CInt16;
	CUInt16;
	CInt32;
	CUInt32;
	CInt64;
	CUInt64;
	CFloat32;
	CFloat64;
	CString;
	CNullRef;
}

enum TypeDefVis {
	VPrivate;
	VPublic;
	VNestedPublic;
	VNestedPrivate;
	VNestedFamily;
	VNestedAssembly;
	VNestedFamAndAssem;
	VNestedFamOrAssem;
}

enum TypeDefLayout {
	LAuto;
	LSequential;
	LExplicit;
}

enum TypeDefSemantics {
	SInterface;
	SAbstract;
	SSealed;
	SSpecialName;
}

enum TypeDefImpl {
	IImport;
	ISerializable;
	IBeforeFieldInit;
}

enum TypeDefString {
	SAnsi;
	SUnicode;
	SAutoChar;
}

class MetaFlags {
	// a flag list holds its flags in the reverse of the order they are tested, as the reference's fold
	// builds it.
	public static function flagsOfInt<T>(iprops:Int, tests:Array<Int>, f:Int->T):Array<T> {
		var acc = [];
		for (i in tests) if (iprops & i == i) acc.unshift(f(i));
		return acc;
	}

	public static function fieldAccessOfInt(i:Int):FieldAccess {
		return switch (i & 0x07) {
			case 0x0: FAPrivateScope;
			case 0x1: FAPrivate;
			case 0x2: FAFamAndAssem;
			case 0x3: FAAssembly;
			case 0x4: FAFamily;
			case 0x5: FAFamOrAssem;
			case 0x6: FAPublic;
			case _: throw "Assertion failed: field access";
		}
	}
}

@:structInit
class TypeDefFlags {
	public static final nullFlags:TypeDefFlags = TypeDefFlags.ofInt(0);

	public var vis:TypeDefVis;
	public var layout:TypeDefLayout;
	public var semantics:Array<TypeDefSemantics>;
	public var impl:Array<TypeDefImpl>;
	public var string:TypeDefString;

	public function new(vis, layout, semantics, impl, string) {
		this.vis = vis;
		this.layout = layout;
		this.semantics = semantics;
		this.impl = impl;
		this.string = string;
	}

	public static function ofInt(i:Int):TypeDefFlags {
		return {
			vis: switch (i & 0x7) {
				case 0x0: VPrivate;
				case 0x1: VPublic;
				case 0x2: VNestedPublic;
				case 0x3: VNestedPrivate;
				case 0x4: VNestedFamily;
				case 0x5: VNestedAssembly;
				case 0x6: VNestedFamAndAssem;
				case _: VNestedFamOrAssem;
			},
			layout: switch (i & 0x18) {
				case 0x0: LAuto;
				case 0x8: LSequential;
				case 0x10: LExplicit;
				case _: throw "Assertion failed: type layout";
			},
			semantics: MetaFlags.flagsOfInt(i, [0x20, 0x80, 0x100, 0x400], f -> switch (f) {
				case 0x20: SInterface;
				case 0x80: SAbstract;
				case 0x100: SSealed;
				case _: SSpecialName;
			}),
			impl: MetaFlags.flagsOfInt(i, [0x1000, 0x2000, 0x00100000], f -> switch (f) {
				case 0x1000: IImport;
				case 0x2000: ISerializable;
				case _: IBeforeFieldInit;
			}),
			string: switch (i & 0x00030000) {
				case 0x0: SAnsi;
				case 0x00010000: SUnicode;
				case 0x00020000: SAutoChar;
				case _: throw "Assertion failed: type string format";
			},
		};
	}
}

enum FieldAccess {
	FAPrivateScope;
	FAPrivate;
	FAFamAndAssem;
	FAAssembly;
	FAFamily;
	FAFamOrAssem;
	FAPublic;
}

enum FieldContract {
	CStatic;
	CInitOnly;
	CLiteral;
	CNotSerialized;
	CSpecialName;
}

enum FieldReserved {
	RSpecialName;
	RMarshal;
	RConstant;
	RFieldRVA;
}

@:structInit
class FieldFlags {
	public static final nullFlags:FieldFlags = FieldFlags.ofInt(0);

	public var access:FieldAccess;
	public var contract:Array<FieldContract>;
	public var reserved:Array<FieldReserved>;

	public function new(access, contract, reserved) {
		this.access = access;
		this.contract = contract;
		this.reserved = reserved;
	}

	public static function ofInt(i:Int):FieldFlags {
		return {
			access: MetaFlags.fieldAccessOfInt(i),
			contract: MetaFlags.flagsOfInt(i, [0x10, 0x20, 0x40, 0x80, 0x200], f -> switch (f) {
				case 0x10: CStatic;
				case 0x20: CInitOnly;
				case 0x40: CLiteral;
				case 0x80: CNotSerialized;
				case _: CSpecialName;
			}),
			reserved: MetaFlags.flagsOfInt(i, [0x400, 0x1000, 0x8000, 0x100], f -> switch (f) {
				case 0x400: RSpecialName;
				case 0x1000: RMarshal;
				case 0x8000: RConstant;
				case _: RFieldRVA;
			}),
		};
	}

	public function withAccess(a:FieldAccess):FieldFlags return {access: a, contract: contract, reserved: reserved};
}

enum MethodContract {
	CMStatic;
	CMFinal;
	CMVirtual;
	CMHideBySig;
}

enum MethodVtable {
	VNewSlot;
	VStrict;
}

enum MethodImplFlag {
	IAbstract;
	ISpecialName;
	IPInvokeImpl;
	IUnmanagedExp;
}

enum MethodReserved {
	RTSpecialName;
	RHasSecurity;
	RReqSecObj;
}

enum MethodCodeType {
	CCil;
	CNative;
	COptIl;
	CRuntime;
}

enum MethodCodeMngmt {
	MManaged;
	MUnmanaged;
}

enum MethodInterop {
	OForwardRef;
	OPreserveSig;
	OInternalCall;
	OSynchronized;
	ONoInlining;
}

@:structInit
class MethodFlags {
	public static final nullFlags:MethodFlags = MethodFlags.ofInt(0, 0);

	public var access:FieldAccess;
	public var contract:Array<MethodContract>;
	public var vtable:Array<MethodVtable>;
	public var impl:Array<MethodImplFlag>;
	public var reserved:Array<MethodReserved>;
	public var codeType:MethodCodeType;
	public var codeMngmt:MethodCodeMngmt;
	public var interop:Array<MethodInterop>;

	public function new(access, contract, vtable, impl, reserved, codeType, codeMngmt, interop) {
		this.access = access;
		this.contract = contract;
		this.vtable = vtable;
		this.impl = impl;
		this.reserved = reserved;
		this.codeType = codeType;
		this.codeMngmt = codeMngmt;
		this.interop = interop;
	}

	public static function ofInt(iflags:Int, flags:Int):MethodFlags {
		return {
			access: MetaFlags.fieldAccessOfInt(flags),
			contract: MetaFlags.flagsOfInt(flags, [0x10, 0x20, 0x40, 0x80], f -> switch (f) {
				case 0x10: CMStatic;
				case 0x20: CMFinal;
				case 0x40: CMVirtual;
				case _: CMHideBySig;
			}),
			vtable: MetaFlags.flagsOfInt(flags, [0x100, 0x200], f -> f == 0x100 ? VNewSlot : VStrict),
			impl: MetaFlags.flagsOfInt(flags, [0x0400, 0x0800, 0x2000, 0x0008], f -> switch (f) {
				case 0x0400: IAbstract;
				case 0x0800: ISpecialName;
				case 0x2000: IPInvokeImpl;
				case _: IUnmanagedExp;
			}),
			reserved: MetaFlags.flagsOfInt(flags, [0x1000, 0x4000, 0x8000], f -> switch (f) {
				case 0x1000: RTSpecialName;
				case 0x4000: RHasSecurity;
				case _: RReqSecObj;
			}),
			codeType: switch (iflags & 0x3) {
				case 0x0: CCil;
				case 0x1: CNative;
				case 0x2: COptIl;
				case _: CRuntime;
			},
			codeMngmt: iflags & 0x4 == 0 ? MManaged : MUnmanaged,
			interop: MetaFlags.flagsOfInt(iflags, [0x10, 0x80, 0x1000, 0x20, 0x08], f -> switch (f) {
				case 0x10: OForwardRef;
				case 0x80: OPreserveSig;
				case 0x1000: OInternalCall;
				case 0x20: OSynchronized;
				case _: ONoInlining;
			}),
		};
	}

	public function withAccess(a:FieldAccess):MethodFlags
		return {access: a, contract: contract, vtable: vtable, impl: impl, reserved: reserved, codeType: codeType,
			codeMngmt: codeMngmt, interop: interop};
}

enum ParamIo {
	PIn;
	POut;
	POpt;
}

enum ParamReserved {
	PHasConstant;
	PMarshal;
}

@:structInit
class ParamFlags {
	public static final nullFlags:ParamFlags = ParamFlags.ofInt(0);

	public var io:Array<ParamIo>;
	public var reserved:Array<ParamReserved>;

	public function new(io, reserved) {
		this.io = io;
		this.reserved = reserved;
	}

	public static function ofInt(i:Int):ParamFlags {
		return {
			io: MetaFlags.flagsOfInt(i, [0x1, 0x2, 0x10], f -> switch (f) {
				case 0x1: PIn;
				case 0x2: POut;
				case _: POpt;
			}),
			reserved: MetaFlags.flagsOfInt(i, [0x1000, 0x2000], f -> f == 0x1000 ? PHasConstant : PMarshal),
		};
	}
}

enum EventFlag {
	ESpecialName;
	ERTSpecialName;
}

enum PropertyFlag {
	PSpecialName;
	PRTSpecialName;
	PHasDefault;
	PUnused;
}

enum SemanticFlag {
	SSetter;
	SGetter;
	SOther;
	SAddOn;
	SRemoveOn;
	SFire;
}

enum GenericVariance {
	VNone;
	VCovariant;
	VContravariant;
}

enum GenericConstraint {
	CInstanceType;
	CValueType;
	CDefaultCtor;
}

@:structInit
class GenericFlags {
	public static final nullFlags:GenericFlags = GenericFlags.ofInt(0);

	public var variance:GenericVariance;
	public var constraint:Array<GenericConstraint>;

	public function new(variance, constraint) {
		this.variance = variance;
		this.constraint = constraint;
	}

	public static function ofInt(i:Int):GenericFlags {
		return {
			variance: switch (i & 0x3) {
				case 0x0: VNone;
				case 0x1: VCovariant;
				case 0x2: VContravariant;
				case _: throw "Assertion failed: generic variance";
			},
			constraint: MetaFlags.flagsOfInt(i & 0x1C, [0x4, 0x8, 0x10], f -> switch (f) {
				case 0x4: CInstanceType;
				case 0x8: CValueType;
				case _: CDefaultCtor;
			}),
		};
	}
}

enum IlSig {
	SVoid;
	SBool;
	SChar;
	SInt8;
	SUInt8;
	SInt16;
	SUInt16;
	SInt32;
	SUInt32;
	SInt64;
	SUInt64;
	SFloat32;
	SFloat64;
	SString;
	SPointer(s:IlSig);
	SManagedPointer(s:IlSig);
	SValueType(t:ClrMeta);
	SClass(t:ClrMeta);
	STypeParam(n:Int);
	// per rank, the lower bound and the size
	SArray(s:IlSig, dims:Array<ArrayDim>);
	SGenericInst(s:IlSig, args:Array<IlSig>);
	STypedReference;
	SIntPtr;
	SUIntPtr;
	SFunPtr(cc:Array<CallConv>, ret:IlSig, args:Array<IlSig>);
	SObject;
	SVector(s:IlSig);
	SMethodTypeParam(n:Int);
	SReqModifier(t:ClrMeta, s:IlSig);
	SOptModifier(t:ClrMeta, s:IlSig);
	SSentinel;
	SPinned(s:IlSig);
	SType;
	SBoxed;
	SEnum(name:String);
}

typedef ArrayDim = {lower:Null<Int>, size:Null<Int>};

enum CallConv {
	CallDefault;
	CallCDecl;
	CallStdCall;
	CallThisCall;
	CallFastCall;
	CallVararg;
	CallField;
	CallLocal;
	CallProp;
	CallUnmanaged;
	CallGenericInst;
	CallGeneric(n:Int);
	CallHasThis;
	CallExplicitThis;
}

enum NativeSig {
	NVoid;
	NBool;
	NInt8;
	NUInt8;
	NInt16;
	NUInt16;
	NInt32;
	NUInt32;
	NInt64;
	NUInt64;
	NFloat32;
	NFloat64;
	NSysChar;
	NVariant;
	NCurrency;
	NPointer;
	NDecimal;
	NDate;
	NBStr;
	NLPStr;
	NLPWStr;
	NLPTStr;
	NFixedString(size:Int);
	NObjectRef;
	NUnknown;
	NDispatch;
	NStruct;
	NInterface;
	// the VT_ variant code
	NSafeArray(v:Int);
	NFixedArray(size:Int, v:Int);
	NIntPointer;
	NUIntPointer;
	NNestedStruct;
	NByValStr;
	NAnsiBStr;
	NTBStr;
	NVariantBool;
	NFunctionPtr;
	NAsAny;
	NArray(elt:NativeSig, paramIdx:Int, size:Int, paramMult:Int);
	NLPStruct;
	NCustomMarshaler(guid:haxe.io.Bytes, unmanaged:haxe.io.Bytes);
	NError;
	NCustom(i:Int);
}
