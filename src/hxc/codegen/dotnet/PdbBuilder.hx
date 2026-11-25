package hxc.codegen.dotnet;

import haxe.io.Bytes;
import hxc.ast.Position;
import hxc.codegen.dotnet.IlMeta.TableIdx as T;
import hxc.codegen.dotnet.IlCode.LocalScope;
import hxc.codegen.dotnet.MetaTables;

// The Portable PDB of one assembly (https://github.com/dotnet/runtime/blob/main/docs/design/specs/PortablePdb-Metadata.md):
// the debug tables, with their own heaps, and the #Pdb stream that names the DLL's tables they point
// into. MethodDebugInformation row n is MethodDef row n's. A Document row per source file, in the order
// methods first use them; a runtime file's, which exists only inside hxc.exe, embeds its text. A
// LocalScope row per block with a named local, inside its method's root scope.

class PdbBuilder {
	// The Sorted mask's high half: LocalScope, StateMachineMethod and CustomDebugInformation.
	static inline var SORTED_HI = (1 << (T.ILocalScope - 32)) | (1 << (T.IStateMachineMethod - 32)) | (1 << (T.ICustomDebugInformation - 32));

	// A Document's hash algorithm, SHA-256, and language, C#'s, so that a debugger's Watch window takes
	// C# syntax.
	static final sha256 = guid("8829d00f-11b8-4213-878b-770e8597ac16");
	static final csharp = guid("3f5162f8-07c6-11d3-9053-00c04fa302a1");
	// The CustomDebugInformation kind that holds a Document's text.
	static final embeddedSource = guid("0e8a571b-6926-466e-b4ad-8ab04611f5fe");

	final heaps = new MetaHeaps();
	final paths:PdbPaths;
	final documents:Array<Row> = [];
	// The Document row of each source file seen, by its position's file and by its name; 0 for a file
	// that cannot be read, whose points are hidden.
	final fileRows = new Map<String, Int>();
	final nameRows = new Map<String, Int>();
	// The CustomDebugInformation rows, one per runtime Document, in Document order (their parents' order).
	final customDebugInformation:Array<Row> = [];
	// The MethodDebugInformation rows of the methods with sequence points, by MethodDef row.
	final methodRows = new Map<Int, Row>();
	// The scopes written for each method with named locals, by MethodDef row, in LocalScope order.
	final scopeRows = new Map<Int, Array<LocalScope>>();
	var hashAlgorithm = 0;
	var language = 0;

	public function new(paths:PdbPaths) {
		this.paths = paths;
	}

	// The debug information of the method whose MethodDef token is `token`, with `localsSig` its
	// StandAloneSig token (0 for none) and `code` its body.
	public function method(token:Int, localsSig:Int, code:IlCode):Void {
		code.finish();
		scopes(token & 0xFFFFFF, code);
		if (code.points == null || code.points.length == 0) return;
		var points = [for (p in code.points) {offset: p.offset, at: resolve(p.pos)}];
		var first = 0, many = false;
		for (p in points) if (p.at != null) {
			if (first == 0) first = p.at.doc else if (p.at.doc != first) many = true;
		}
		// Only hidden points: nothing a debugger could show.
		if (first == 0) return;
		// The sequence-point blob: the locals' signature, the first document when there are more, then a
		// record per point, delta-encoded from the one before; a change of document is a record of its own.
		var b = new IlBytes();
		b.compressedU32(localsSig & 0xFFFFFF);
		if (many) b.compressedU32(first);
		var doc = first, offset = 0, line = -1, column = 0;
		for (p in points) {
			var at = p.at;
			if (at != null && at.doc != doc) {
				b.compressedU32(0);
				b.compressedU32(at.doc);
				doc = at.doc;
			}
			b.compressedU32(p.offset - offset);
			offset = p.offset;
			if (at == null) {
				b.compressedU32(0);
				b.compressedU32(0);
				continue;
			}
			b.compressedU32(at.endLine - at.line);
			if (at.endLine == at.line) b.compressedU32(at.endColumn - at.column) else b.compressedI32(at.endColumn - at.column);
			if (line < 0) {
				b.compressedU32(at.line);
				b.compressedU32(at.column);
			} else {
				b.compressedI32(at.line - line);
				b.compressedI32(at.column - column);
			}
			line = at.line;
			column = at.column;
		}
		methodRows.set(token & 0xFFFFFF, [many ? 0 : first, heaps.blobs.add(b.getBytes())]);
	}

	// The scopes of the method at MethodDef `row`: the root, then each block with a named local, by start
	// offset. The function body's block is the root, widened to the whole IL, as a method's first scope
	// must be; with several outermost blocks (a constructor's initializers and its body), a root without
	// names holds them. An empty block (dead code) is left out, and so is a block without names, its own
	// blocks taking its place.
	function scopes(row:Int, code:IlCode):Void {
		var top = code.scopes;
		if (top == null || top.length == 0) return;
		var root:LocalScope = top.length == 1 ? {start: 0, end: code.length, vars: top[0].vars, children: top[0].children}
			: {start: 0, end: code.length, vars: [], children: top};
		var rows = [root];
		function add(s:LocalScope) {
			if (s.end <= s.start) return;
			if (s.vars.length > 0) rows.push(s);
			for (c in s.children) add(c);
		}
		for (c in root.children) add(c);
		if (rows.length > 1 || root.vars.length > 0) scopeRows.set(row, rows);
	}

	// A point's Document row and span, with 1-based columns and the end column exclusive; null for a
	// hidden point. A position hxc cannot resolve (Position.nullPos, file `?`, a negative offset, a file
	// neither on disk nor in hxc's runtime) is hidden: Position.getInfos would give it line 1.
	function resolve(pos:Null<Position>):Null<{doc:Int, line:Int, column:Int, endLine:Int, endColumn:Int}> {
		if (pos == null || pos.file == "?" || pos.min < 0 || pos.max < 0) return null;
		var doc = document(pos.file);
		if (doc == 0) return null;
		var p = Position.getInfos(pos);
		var line = p.line, column = p.column + 1, endLine = p.endLine, endColumn = p.endColumn + 1;
		// A span ends after it starts: an empty or backwards one covers its first character.
		if (endLine < line || endLine == line && endColumn <= column) {
			endLine = line;
			endColumn = column + 1;
		}
		return {doc: doc, line: line, column: column, endLine: endLine, endColumn: endColumn};
	}

	// The Document row of `file`, added at its first use, with the SHA-256 of its bytes.
	function document(file:String):Int {
		var row = fileRows.get(file);
		if (row != null) return row;
		// A runtime file's text, through Position's cache, so that getInfos resolves its lines.
		var content = RuntimeSources.content(file) != null ? Position.getFileContent(file) : null;
		var name = paths.name(file);
		row = nameRows.get(name);
		if (row == null) {
			var bytes = content != null ? Bytes.ofString(content)
				: sys.FileSystem.exists(file) && !sys.FileSystem.isDirectory(file) ? sys.io.File.getBytes(file) : null;
			if (bytes == null) {
				row = 0;
			} else {
				if (hashAlgorithm == 0) {
					hashAlgorithm = heaps.guids.add(sha256);
					language = heaps.guids.add(csharp);
				}
				documents.push([documentName(name), hashAlgorithm, heaps.blobs.add(haxe.crypto.Sha256.make(bytes)), language]);
				row = documents.length;
				if (content != null) embed(row, bytes);
			}
			nameRows.set(name, row);
		}
		fileRows.set(file, row);
		return row;
	}

	// The EmbeddedSource of Document `row`: the format 0, for the text as it is, then the text.
	function embed(row:Int, text:Bytes):Void {
		var b = new IlBytes();
		b.u32(0);
		b.bytes(text);
		customDebugInformation.push([CodedIndex.encode(T.IHasCustomDebugInformation, T.IDocument, row), heaps.guids.add(embeddedSource), heaps.blobs.add(b.getBytes())]);
	}

	// A Document's name blob: the separator, then each part's UTF-8 as a blob.
	function documentName(name:String):Int {
		var b = new IlBytes();
		b.u8("/".code);
		for (part in name.split("/")) b.compressedU32(heaps.blobs.add(Bytes.ofString(part)));
		return heaps.blobs.add(b.getBytes());
	}

	// A GUID's 16 bytes, its first three fields little-endian.
	static function guid(s:String):Bytes {
		var hex = s.split("-").join("");
		var b = Bytes.alloc(16);
		for (i in 0...16) b.set(i, Std.parseInt("0x" + hex.substr(i * 2, 2)));
		for (swap in [[0, 3], [1, 2], [4, 5], [6, 7]]) {
			var t = b.get(swap[0]);
			b.set(swap[0], b.get(swap[1]));
			b.set(swap[1], t);
		}
		return b;
	}

	// The PDB, with `entryPoint` the entry method's MethodDef token or 0, `typeSystemRows` the DLL's
	// row counts by table number and `methodCount` its MethodDef rows. The 20-byte id at `idOffset` is
	// zero, for the caller to derive from the PDB's hash and patch in.
	public function write(entryPoint:Int, typeSystemRows:Array<Int>, methodCount:Int):{bytes:Bytes, idOffset:Int} {
		var methodDebugInformation:Array<Row> = [for (i in 0...methodCount) methodRows.exists(i + 1) ? methodRows.get(i + 1) : [0, 0]];
		// The root scope, with no imports, which every LocalScope row names.
		var importScope:Array<Row> = [[0, 0]];
		// By method, then as `scopes` ordered them; a scope's locals follow those of the scopes before it.
		var localScope:Array<Row> = [], localVariable:Array<Row> = [];
		for (i in 0...methodCount) {
			var rows = scopeRows.get(i + 1);
			if (rows == null) continue;
			for (s in rows) {
				localScope.push([i + 1, 1, localVariable.length + 1, 1, s.start, s.end - s.start]);
				for (v in s.vars) localVariable.push([0, v.index, heaps.strings.add(v.name)]);
			}
		}
		var written:Array<{table:Int, rows:Array<Row>, schema:Array<Int>}> = [
			{table: T.IDocument, rows: documents, schema: [MetaTables.BLOB, MetaTables.GUID, MetaTables.BLOB, MetaTables.GUID]},
			{table: T.IMethodDebugInformation, rows: methodDebugInformation, schema: [T.IDocument, MetaTables.BLOB]},
			{
				table: T.ILocalScope,
				rows: localScope,
				schema: [T.IMethod, T.IImportScope, T.ILocalVariable, T.ILocalConstant, MetaTables.U32, MetaTables.U32]
			},
			{table: T.ILocalVariable, rows: localVariable, schema: [MetaTables.U16, MetaTables.U16, MetaTables.STR]},
			{table: T.ILocalConstant, rows: [], schema: [MetaTables.STR, MetaTables.BLOB]},
			{table: T.IImportScope, rows: importScope, schema: [T.IImportScope, MetaTables.BLOB]},
			{table: T.IStateMachineMethod, rows: [], schema: [T.IMethod, T.IMethod]},
			{table: T.ICustomDebugInformation, rows: customDebugInformation, schema: [T.IHasCustomDebugInformation, MetaTables.GUID, MetaTables.BLOB]},
		];
		var rowCounts = typeSystemRows.copy();
		for (w in written) rowCounts[w.table] = w.rows.length;

		// The id, the entry point, then the mask of the DLL's tables with rows and their row counts.
		var pdb = new IlBytes();
		for (_ in 0...20) pdb.u8(0);
		pdb.u32(entryPoint);
		var lo = 0, hi = 0;
		for (t in 0...T.IDocument) {
			if (typeSystemRows[t] == 0) continue;
			if (t < 32) lo |= 1 << t else hi |= 1 << (t - 32);
		}
		pdb.u32(lo);
		pdb.u32(hi);
		for (t in 0...T.IDocument) if (typeSystemRows[t] > 0) pdb.u32(typeSystemRows[t]);

		var root = MetaTables.writeRoot("PDB v1.0", [
			{name: "#Pdb", data: pdb.getBytes()},
			{name: "#~", data: MetaTables.writeTables(written, heaps, rowCounts, 0, SORTED_HI)},
			{name: "#Strings", data: heaps.strings.bytes()},
			{name: "#US", data: heaps.userStrings.bytes()},
			{name: "#GUID", data: heaps.guids.bytes()},
			{name: "#Blob", data: heaps.blobs.bytes()},
		]);
		return {bytes: root.bytes, idOffset: root.offsets["#Pdb"]};
	}
}
