package hxc.codegen.dotnet;

import haxe.io.Bytes;
import hxc.codegen.dotnet.IlMeta.TableIdx as T;

// The metadata tables the generator writes (ECMA-335 II.22) and the #~ stream and metadata root that
// hold them (II.24.2.1, II.24.2.6). A row is its column values in schema order: plain numbers, heap
// indices, 1-based row indices, and coded indices already encoded with CodedIndex.
typedef Row = Array<Int>;

// The coded index kinds a written table uses (II.24.2.6), numbered as in TableIdx.
class CodedIndex {
	// Tag order is the table order of each kind; -1 marks an unused tag.
	static final typeDefOrRefTables = [T.ITypeDef, T.ITypeRef, T.ITypeSpec];
	static final hasCustomAttributeTables = [
		T.IMethod, T.IField, T.ITypeRef, T.ITypeDef, T.IParam, T.IInterfaceImpl, T.IMemberRef, T.IModule, T.IDeclSecurity,
		T.IProperty, T.IEvent, T.IStandAloneSig, T.IModuleRef, T.ITypeSpec, T.IAssembly, T.IAssemblyRef, T.IFile,
		T.IExportedType, T.IManifestResource, T.IGenericParam, T.IGenericParamConstraint, T.IMethodSpec
	];
	static final memberRefParentTables = [T.ITypeDef, T.ITypeRef, T.IModuleRef, T.IMethod, T.ITypeSpec];
	static final methodDefOrRefTables = [T.IMethod, T.IMemberRef];
	static final customAttributeTypeTables = [-1, -1, T.IMethod, T.IMemberRef, -1];
	static final resolutionScopeTables = [T.IModule, T.IModuleRef, T.IAssemblyRef, T.ITypeRef];
	static final typeOrMethodDefTables = [T.ITypeDef, T.IMethod];
	static final hasConstantTables = [T.IField, T.IParam, T.IProperty];
	static final hasSemanticsTables = [T.IEvent, T.IProperty];
	static final implementationTables = [T.IFile, T.IAssemblyRef, T.IExportedType];
	static final hasCustomDebugInformationTables = hasCustomAttributeTables.concat([
		T.IDocument, T.ILocalScope, T.ILocalVariable, T.ILocalConstant, T.IImportScope
	]);

	public static function tables(kind:Int):Array<Int> {
		return switch (kind) {
			case T.ITypeDefOrRef: typeDefOrRefTables;
			case T.IHasCustomAttribute: hasCustomAttributeTables;
			case T.IMemberRefParent: memberRefParentTables;
			case T.IMethodDefOrRef: methodDefOrRefTables;
			case T.ICustomAttributeType: customAttributeTypeTables;
			case T.IResolutionScope: resolutionScopeTables;
			case T.ITypeOrMethodDef: typeOrMethodDefTables;
			case T.IHasConstant: hasConstantTables;
			case T.IHasSemantics: hasSemanticsTables;
			case T.IImplementation: implementationTables;
			case T.IHasCustomDebugInformation: hasCustomDebugInformationTables;
			case _: throw "unsupported coded index " + kind;
		}
	}

	public static function tagBits(kind:Int):Int {
		var n = tables(kind).length - 1;
		var bits = 0;
		while (n > 0) {
			bits++;
			n >>= 1;
		}
		return bits;
	}

	public static function encode(kind:Int, table:Int, row:Int):Int {
		var tag = tables(kind).indexOf(table);
		if (tag < 0) throw "table " + table + " is not in coded index " + kind;
		return (row << tagBits(kind)) | tag;
	}

	public static inline function typeDefOrRef(table:Int, row:Int):Int return encode(T.ITypeDefOrRef, table, row);

	public static inline function hasCustomAttribute(table:Int, row:Int):Int return encode(T.IHasCustomAttribute, table, row);

	public static inline function memberRefParent(table:Int, row:Int):Int return encode(T.IMemberRefParent, table, row);

	public static inline function methodDefOrRef(table:Int, row:Int):Int return encode(T.IMethodDefOrRef, table, row);

	public static inline function customAttributeType(table:Int, row:Int):Int return encode(T.ICustomAttributeType, table, row);

	public static inline function resolutionScope(table:Int, row:Int):Int return encode(T.IResolutionScope, table, row);

	public static inline function typeOrMethodDef(table:Int, row:Int):Int return encode(T.ITypeOrMethodDef, table, row);

	public static inline function hasSemantics(table:Int, row:Int):Int return encode(T.IHasSemantics, table, row);
}

class MetaTables {
	// Column kinds besides a table number (a row index into it) or a coded index kind.
	public static inline var U16 = -1;
	public static inline var U32 = -2;
	public static inline var STR = -3;
	public static inline var GUID = -4;
	public static inline var BLOB = -5;

	// The Sorted mask: every table that ECMA-335 keeps sorted by its key column.
	static inline var SORTED_LO = 0x3301FA00;
	static inline var SORTED_HI = 0x1600;

	public final module:Array<Row> = [];
	public final typeRef:Array<Row> = [];
	public final typeDef:Array<Row> = [];
	public final field:Array<Row> = [];
	public final methodDef:Array<Row> = [];
	public final param:Array<Row> = [];
	public final interfaceImpl:Array<Row> = [];
	public final memberRef:Array<Row> = [];
	public final constant:Array<Row> = [];
	public final customAttribute:Array<Row> = [];
	public final classLayout:Array<Row> = [];
	public final fieldLayout:Array<Row> = [];
	public final standAloneSig:Array<Row> = [];
	public final eventMap:Array<Row> = [];
	public final event:Array<Row> = [];
	public final propertyMap:Array<Row> = [];
	public final property:Array<Row> = [];
	public final methodSemantics:Array<Row> = [];
	public final methodImpl:Array<Row> = [];
	public final typeSpec:Array<Row> = [];
	public final assembly:Array<Row> = [];
	public final assemblyRef:Array<Row> = [];
	public final manifestResource:Array<Row> = [];
	public final genericParam:Array<Row> = [];
	public final methodSpec:Array<Row> = [];
	public final genericParamConstraint:Array<Row> = [];

	// In table number order, which is the order the #~ stream holds them.
	final written:Array<{table:Int, rows:Array<Row>, schema:Array<Int>}>;

	public function new() {
		written = [
			{table: T.IModule, rows: module, schema: [U16, STR, GUID, GUID, GUID]},
			{table: T.ITypeRef, rows: typeRef, schema: [T.IResolutionScope, STR, STR]},
			{table: T.ITypeDef, rows: typeDef, schema: [U32, STR, STR, T.ITypeDefOrRef, T.IField, T.IMethod]},
			{table: T.IField, rows: field, schema: [U16, STR, BLOB]},
			{table: T.IMethod, rows: methodDef, schema: [U32, U16, U16, STR, BLOB, T.IParam]},
			{table: T.IParam, rows: param, schema: [U16, U16, STR]},
			{table: T.IInterfaceImpl, rows: interfaceImpl, schema: [T.ITypeDef, T.ITypeDefOrRef]},
			{table: T.IMemberRef, rows: memberRef, schema: [T.IMemberRefParent, STR, BLOB]},
			// The constant's type is one byte followed by a padding byte, written here as one U16.
			{table: T.IConstant, rows: constant, schema: [U16, T.IHasConstant, BLOB]},
			{table: T.ICustomAttribute, rows: customAttribute, schema: [T.IHasCustomAttribute, T.ICustomAttributeType, BLOB]},
			{table: T.IClassLayout, rows: classLayout, schema: [U16, U32, T.ITypeDef]},
			{table: T.IFieldLayout, rows: fieldLayout, schema: [U32, T.IField]},
			{table: T.IStandAloneSig, rows: standAloneSig, schema: [BLOB]},
			{table: T.IEventMap, rows: eventMap, schema: [T.ITypeDef, T.IEvent]},
			{table: T.IEvent, rows: event, schema: [U16, STR, T.ITypeDefOrRef]},
			{table: T.IPropertyMap, rows: propertyMap, schema: [T.ITypeDef, T.IProperty]},
			{table: T.IProperty, rows: property, schema: [U16, STR, BLOB]},
			{table: T.IMethodSemantics, rows: methodSemantics, schema: [U16, T.IMethod, T.IHasSemantics]},
			{table: T.IMethodImpl, rows: methodImpl, schema: [T.ITypeDef, T.IMethodDefOrRef, T.IMethodDefOrRef]},
			{table: T.ITypeSpec, rows: typeSpec, schema: [BLOB]},
			{table: T.IAssembly, rows: assembly, schema: [U32, U16, U16, U16, U16, U32, BLOB, STR, STR]},
			{table: T.IAssemblyRef, rows: assemblyRef, schema: [U16, U16, U16, U16, U32, BLOB, STR, STR, BLOB]},
			// Offset in the resources blob, flags, name, and the file holding it (0: this one).
			{table: T.IManifestResource, rows: manifestResource, schema: [U32, U32, STR, T.IImplementation]},
			{table: T.IGenericParam, rows: genericParam, schema: [U16, U16, T.ITypeOrMethodDef, STR]},
			{table: T.IMethodSpec, rows: methodSpec, schema: [T.IMethodDefOrRef, BLOB]},
			{table: T.IGenericParamConstraint, rows: genericParamConstraint, schema: [T.IGenericParam, T.ITypeDefOrRef]},
		];
	}

	static function compareBy(a:Row, b:Row, columns:Array<Int>):Int {
		for (c in columns) if (a[c] != b[c]) return a[c] < b[c] ? -1 : 1;
		return 0;
	}

	// Stable, so rows with equal keys keep the order they were added in.
	static function sortBy(rows:Array<Row>, columns:Array<Int>):Void {
		haxe.ds.ArraySort.sort(rows, (a, b) -> compareBy(a, b, columns));
	}

	// Tables whose row numbers other rows point at cannot be reordered here, so they must be added in
	// key order.
	static function checkSorted(name:String, rows:Array<Row>, columns:Array<Int>):Void {
		for (i in 1...rows.length)
			if (compareBy(rows[i - 1], rows[i], columns) > 0) throw "internal error: " + name + " rows are not in key order";
	}

	public function writeMetadata(h:MetaHeaps):{bytes:Bytes, mvidOffset:Int} {
		// Nothing points at a Constant, CustomAttribute, ClassLayout, FieldLayout, MethodSemantics or MethodImpl
		// row, so those tables alone are sorted here.
		sortBy(constant, [1]);
		sortBy(customAttribute, [0]);
		sortBy(classLayout, [2]);
		sortBy(fieldLayout, [1]);
		sortBy(methodSemantics, [2]);
		sortBy(methodImpl, [0]);
		checkSorted("InterfaceImpl", interfaceImpl, [0, 1]);
		checkSorted("EventMap", eventMap, [0]);
		checkSorted("PropertyMap", propertyMap, [0]);
		checkSorted("GenericParam", genericParam, [2, 0]);
		checkSorted("GenericParamConstraint", genericParamConstraint, [0]);

		var root = writeRoot("v4.0.30319", [
			{name: "#~", data: writeTables(written, h, rowCounts(), SORTED_LO, SORTED_HI)},
			{name: "#Strings", data: h.strings.bytes()},
			{name: "#US", data: h.userStrings.bytes()},
			{name: "#GUID", data: h.guids.bytes()},
			{name: "#Blob", data: h.blobs.bytes()},
		]);
		if (module.length != 1) throw "the Module table needs exactly one row";
		return {bytes: root.bytes, mvidOffset: root.offsets["#GUID"] + (module[0][2] - 1) * 16};
	}

	// Each table's row count, by table number.
	public function rowCounts():Array<Int> {
		var counts = [for (_ in 0...64) 0];
		for (w in written) counts[w.table] = w.rows.length;
		return counts;
	}

	// The #~ stream holding `written`, in table number order. Row and coded indices are sized by
	// `rowCounts`, which may count tables of another metadata, as a PDB's references into its DLL are.
	public static function writeTables(written:Array<{table:Int, rows:Array<Row>, schema:Array<Int>}>, h:MetaHeaps, rowCounts:Array<Int>,
			sortedLo:Int, sortedHi:Int):Bytes {
		function width(kind:Int):Int {
			return switch (kind) {
				case U16: 2;
				case U32: 4;
				case STR: h.strings.isLarge() ? 4 : 2;
				case GUID: h.guids.isLarge() ? 4 : 2;
				case BLOB: h.blobs.isLarge() ? 4 : 2;
				case k if (k >= 64):
					var limit = 1 << (16 - CodedIndex.tagBits(k));
					var w = 2;
					for (t in CodedIndex.tables(k)) if (t >= 0 && rowCounts[t] >= limit) w = 4;
					w;
				case t: rowCounts[t] < 0x10000 ? 2 : 4;
			}
		}

		var s = new IlBytes();
		s.u32(0);
		s.u8(2);
		s.u8(0);
		s.u8((h.strings.isLarge() ? 0x01 : 0) | (h.guids.isLarge() ? 0x02 : 0) | (h.blobs.isLarge() ? 0x04 : 0));
		s.u8(1);
		var validLo = 0, validHi = 0;
		for (w in written) {
			if (w.rows.length == 0) continue;
			if (w.table < 32) validLo |= 1 << w.table else validHi |= 1 << (w.table - 32);
		}
		s.u32(validLo);
		s.u32(validHi);
		s.u32(sortedLo);
		s.u32(sortedHi);
		for (w in written) if (w.rows.length > 0) s.u32(w.rows.length);
		for (w in written) {
			var widths = [for (k in w.schema) width(k)];
			for (r in w.rows) {
				if (r.length != widths.length) throw "table " + w.table + ": a row has " + r.length + " columns";
				for (i in 0...widths.length) {
					if (widths[i] == 4) {
						s.u32(r[i]);
					} else {
						if (r[i] < 0 || r[i] > 0xFFFF) throw "table " + w.table + ": column " + i + " does not fit 2 bytes";
						s.u16(r[i]);
					}
				}
			}
		}
		s.align(4);
		return s.getBytes();
	}

	// The metadata root and its streams, with each stream's offset from the root's start.
	public static function writeRoot(version:String, streams:Array<{name:String, data:Bytes}>):{bytes:Bytes, offsets:Map<String, Int>} {
		// The version string and each stream header's name are null-terminated and padded to 4; a stream
		// header is an offset, a size and the name.
		inline function padded(s:String) return (s.length + 4) & ~3;
		var offset = 20 + padded(version);
		for (st in streams) offset += 8 + padded(st.name);
		var root = new IlBytes();
		root.u32(0x424A5342);
		root.u16(1);
		root.u16(1);
		root.u32(0);
		root.u32(padded(version));
		root.bytes(Bytes.ofString(version));
		for (_ in version.length...padded(version)) root.u8(0);
		root.u16(0);
		root.u16(streams.length);
		var offsets = new Map<String, Int>();
		for (st in streams) {
			offsets[st.name] = offset;
			root.u32(offset);
			root.u32(st.data.length);
			root.bytes(Bytes.ofString(st.name));
			root.u8(0);
			root.align(4);
			offset += st.data.length;
		}
		for (st in streams) root.bytes(st.data);
		return {bytes: root.getBytes(), offsets: offsets};
	}
}
