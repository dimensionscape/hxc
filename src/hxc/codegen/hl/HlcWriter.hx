package hxc.codegen.hl;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import hxc.codegen.hl.HlCode;
import hxc.codegen.hl.HlcNames;
import hxc.codegen.hl.HlcOcaml;

// HL/C output: a port of Haxe 4.3.7's hl2c.ml context (59), its file and declaration helpers (230-352),
// generate_reflection (365-520), make_modules, generate_module_types and write_c (1256-1833).
// generate_function (520-1099) is HlcFunctions' (Task 5); until then a function body writes nothing.
// This module imports nothing from hxc outside hxc.codegen.hl, so tools/hl/HlcCheck can run it under
// haxe --run. Text is built as Haxe strings whose UTF-8 is the bytes hl2c writes.

// hl2c.ml: context. The PMaps keyed by types (defined_types, type_module) are keyed by the type's index in
// the gathered table: PMap.find and PMap.exists find a type by compare = 0, as HlTypeTable.indexOf does.
class HlcContext {
	public final version:Int;
	public var out:StringBuf = new StringBuf();
	public var tabs:String = "";
	// hash_cache, hash_mem and hash_cache_list
	public final hashes:HashCache = new HashCache();
	public final hlcode:HlCodeData;
	public final dir:String;
	public var curfile:String = "";
	// An OCaml list: index 0 is the head, the file closed last.
	public var cfiles:Array<String> = [];
	public final ftable:Array<FunctionEntry>;
	public final htypes:HlcTypeIdents;
	public final gnames:Array<String>;
	public final bytesNames:Array<String>;
	// List.rev ctx.defines: the lines in the order they were added.
	public var defines:Array<String> = [];
	public var definedFuns:Map<Int, Bool> = new Map();
	public var hdefines:Map<String, Bool> = new Map();
	public var definedTypes:Map<Int, Bool> = new Map();
	public var filePrefix:String = "";
	public var funIndex:Int = 0;
	public var typeModule:Map<Int, CodeModule> = new Map();
	// gcon's part hl2c reads: the source_header define (Codegen.map_source_header).
	public final sourceHeader:String;

	public function new(version:Int, hlcode:HlCodeData, dir:String, ftable:Array<FunctionEntry>, htypes:HlcTypeIdents, gnames:Array<String>,
			bytesNames:Array<String>, sourceHeader:String) {
		this.version = version;
		this.hlcode = hlcode;
		this.dir = dir;
		this.ftable = ftable;
		this.htypes = htypes;
		this.gnames = gnames;
		this.bytesNames = bytesNames;
		this.sourceHeader = sourceHeader;
	}
}

class HlcWriter {
	static final BOM = "\u{FEFF}";
	static inline var STRING_DATA_LIMIT = 64;

	// ---- hl2c.ml 230-352 ----

	// The index of a gathered type; PMap.find on a type that isn't there dies, as here.
	public static function typeIndex(ctx:HlcContext, t:HlType):Int {
		var i = ctx.htypes.table.indexOf(t);
		if (i == null) throw "hl2c: not a gathered type: " + HlDump.tstr(t);
		return i;
	}

	// type_name
	public static function typeName(ctx:HlcContext, t:HlType):String
		return ctx.htypes.get(t);

	// define
	public static function define(ctx:HlcContext, s:String):Void {
		if (!ctx.hdefines.exists(s)) {
			ctx.defines.push(s);
			ctx.hdefines.set(s, true);
		}
	}

	// define_type
	public static function defineType(ctx:HlcContext, t:HlType):Void {
		switch t {
			case HVoid | HUI8 | HUI16 | HI32 | HI64 | HF32 | HF64 | HBool | HBytes | HDyn | HArray | HType | HDynObj | HNull(_) | HRef(_):
			case HAbstract(_, _):
				define(ctx, "#include <hl/natives.h>");
			case HFun(args, ret) | HMethod(args, ret):
				for (a in args) defineType(ctx, a);
				defineType(ctx, ret);
			case HEnum(_) | HObj(_) | HStruct(_):
				var i = typeIndex(ctx, t);
				if (ctx.definedTypes.exists(i)) return;
				ctx.definedTypes.set(i, true);
				var m = ctx.typeModule.get(i);
				if (m == null) throw "hl2c: define_type: no module for " + HlDump.tstr(t);
				define(ctx, "#include <" + m.name + ".h>");
			case HVirtual(vp):
				var i = typeIndex(ctx, t);
				if (ctx.definedTypes.exists(i)) return;
				ctx.definedTypes.set(i, true);
				for (f in vp.vfields) defineType(ctx, f.t);
			case HPacked(t):
				defineType(ctx, t);
		}
	}

	// type_value (the one that declares the type; types.c uses "&" ^ type_name)
	public static function typeValue(ctx:HlcContext, t:HlType):String {
		var n = typeName(ctx, t);
		define(ctx, "extern hl_type " + n + ";");
		return "&" + n;
	}

	// enum_constr_type
	public static function enumConstrType(ctx:HlcContext, e:HlEnumProto, i:Int):String {
		defineType(ctx, HEnum(e));
		var c = e.efields[i];
		if (c.t.length == 0) return "venum";
		var name = e.eid == 0 ? "Enum" + typeName(ctx, HEnum(e)) : nsplitConcat(e.ename, ".", "_");
		return c.name == "" ? name : name + "_" + c.name;
	}

	public static inline function output(ctx:HlcContext, s:String):Void
		ctx.out.add(s);

	// line
	public static function line(ctx:HlcContext, s:String):Void {
		ctx.out.add(ctx.tabs);
		ctx.out.add(s);
		ctx.out.add("\n");
	}

	// expr
	public static function expr(ctx:HlcContext, s:String):Void {
		ctx.out.add(ctx.tabs);
		ctx.out.add(s);
		ctx.out.add(";\n");
	}

	public static inline function block(ctx:HlcContext):Void
		ctx.tabs += "\t";

	public static inline function unblock(ctx:HlcContext):Void
		ctx.tabs = ctx.tabs.substr(0, ctx.tabs.length - 1);

	public static inline function unamedField(fid:Int):String
		return "f$" + fid;

	public static function objField(fid:Int, name:String):String
		return name == "" ? unamedField(fid) : HlcNames.ident(name);

	// string
	public static function string(ctx:HlcContext, sid:Int):String
		return HlcNames.stringLiteral(ctx.hlcode, sid, s -> define(ctx, s));

	// hash
	public static function hash(ctx:HlcContext, sid:Int):Int
		return ctx.hashes.hash(ctx.hlcode.strings, sid);

	// close_file: the declarations, a blank line and the text, after a BOM except in hlc.json. A file is
	// written (and its directory made) only when its bytes differ from what is on disk.
	public static function closeFile(ctx:HlcContext):Void {
		var out = ctx.out.toString();
		var content = ctx.defines.length == 0 ? out : ctx.defines.join("\n") + "\n\n" + out;
		var str = ctx.curfile == "hlc.json" ? content : BOM + content;
		ctx.defines = [];
		ctx.definedTypes = new Map();
		ctx.hdefines = new Map();
		ctx.definedFuns = new Map();
		ctx.out = new StringBuf();
		var fpath = ctx.dir + "/" + ctx.curfile;
		if (StringTools.endsWith(ctx.curfile, ".c")) ctx.cfiles.unshift(ctx.curfile);
		ctx.curfile = "";
		var bytes = Bytes.ofString(str);
		var fcontent = try sys.io.File.getBytes(fpath) catch (_:Dynamic) null;
		if (fcontent == null || fcontent.compare(bytes) != 0) {
			mkdirRecursive(dirname(fpath));
			sys.io.File.saveBytes(fpath, bytes);
		}
	}

	static function mkdirRecursive(dir:String):Void {
		if (dir == "" || dir == "." || sys.FileSystem.exists(dir)) return;
		sys.FileSystem.createDirectory(dir);
	}

	// define_global
	public static function defineGlobal(ctx:HlcContext, g:Int):Void {
		var t = ctx.hlcode.globals[g];
		defineType(ctx, t);
		define(ctx, "extern " + HlcNames.varType(ctx.gnames[g], t) + ";");
	}

	// define_function. Every native is fid -1, so they share one #include <hl/natives.h>.
	public static function defineFunction(ctx:HlcContext, fid:Int):String {
		var ft = ctx.ftable[fid];
		var key = ft.decl == null ? -1 : fid;
		if (!ctx.definedFuns.exists(key)) {
			ctx.definedFuns.set(key, true);
			if (ft.decl == null) define(ctx, "#include <hl/natives.h>") else {
				defineType(ctx, ft.decl.ftype);
				// added past define, so hdefines doesn't hold it
				ctx.defines.push(HlcNames.ctype(ft.ret) + " " + ft.name + "(" + HlcNames.argsRepr(ft.args) + ");");
			}
		}
		return ft.name;
	}

	// open_file
	public static function openFile(ctx:HlcContext, file:String):Void {
		if (ctx.curfile != "") closeFile(ctx);
		if (file != "hlc.json" && ctx.sourceHeader != "") define(ctx, "// " + ctx.sourceHeader);
		ctx.curfile = file;
		ctx.funIndex = 0;
		ctx.filePrefix = HlcNames.shortDigest(file) + "_";
	}

	// generate_function. A stub until HlcFunctions ports it (Task 5): a function body writes nothing.
	static function generateFunction(ctx:HlcContext, f:HlFunction):Void {}

	// ---- generate_reflection (hl2c.ml 365-520) ----

	// type_kind: void, the floats and i64 stay, the small ints are i32, the rest dyn.
	static function typeKind(t:HlType):HlType {
		return switch t {
			case HVoid | HF32 | HF64 | HI64: t;
			case HBool | HUI8 | HUI16 | HI32: HI32;
			default: HDyn;
		}
	}

	static function typeKindId(t:HlType):Int {
		return switch t {
			case HVoid: 0;
			case HBool | HUI8 | HUI16 | HI32: 1;
			case HF32: 2;
			case HF64: 3;
			case HI64: 4;
			default: 5;
		}
	}

	static function wrapChar(t:HlType):String {
		return switch t {
			case HVoid: "v";
			case HUI8 | HUI16 | HBool | HI32: "i";
			case HF32: "f";
			case HF64: "d";
			case HI64: "i64";
			default: "p";
		}
	}

	static function makeWrapName(args:Array<HlType>, t:HlType):String
		return [for (a in args) wrapChar(a)].join("") + "_" + wrapChar(t);

	// The chk value of a signature: the kind of t, then of each argument, three bits each.
	static function signatureChk(args:Array<HlType>, t:HlType):Int {
		var chk = 0;
		var s = 0;
		chk |= typeKindId(t);
		for (a in args) chk |= typeKindId(a) << (++s * 3);
		return chk;
	}

	// TKIND: type_kind_id (type_kind t) of each of hl2c's core_types (HVoid .. HStruct, as hl.h numbers them).
	static final TKIND = [0, 1, 1, 1, 4, 2, 3, 1, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5];

	static function generateReflection(ctx:HlcContext):Void {
		inline function line(s:String) HlcWriter.line(ctx, s);
		inline function expr(s:String) HlcWriter.expr(ctx, s);

		// funByArgs: nargs -> the Hashtbl of (kargs, kt). Only the inner tables' order reaches the output;
		// their key is the OCaml tuple of a list of kinds and a kind, all constant constructors.
		var funByArgs = new Map<Int, CamlHashtbl<{args:Array<HlType>, t:HlType}>>();
		function addFun(args:Array<HlType>, t:HlType) {
			var kargs = [for (a in args) typeKind(a)];
			var kt = typeKind(t);
			var h = funByArgs.get(args.length);
			if (h == null) funByArgs.set(args.length, h = new CamlHashtbl());
			var l = OInt(0);
			var i = kargs.length;
			while (i-- > 0) l = OBlock(new OBlockRef(0, [HlcOcaml.ttypeValue(kargs[i]), l]));
			h.replace(OBlock(new OBlockRef(0, [l, HlcOcaml.ttypeValue(kt)])), {args: kargs, t: kt});
		}
		for (f in ctx.hlcode.functions)
			for (op in f.code)
				switch op {
					case OSafeCast(dst, _) | ODynGet(dst, _, _):
						switch f.regs[dst] {
							case HFun(args, t): addFun(args, t);
							default:
						}
					default:
				}
		for (f in ctx.ftable) addFun(f.args, f.ret);
		var argsCounts = [for (k in funByArgs.keys()) k];
		argsCounts.sort((a, b) -> a - b);

		expr("static int TKIND[] = {" + TKIND.join(",") + "}");
		line("");
		line("void *hlc_static_call( void *fun, hl_type *t, void **args, vdynamic *out ) {");
		block(ctx);
		expr("int chk = TKIND[t->fun->ret->kind]");
		expr("vdynamic *d");
		line("switch( t->fun->nargs ) {");
		for (nargs in argsCounts) {
			line("case " + nargs + ":");
			block(ctx);
			if (nargs > 9) expr("hl_fatal(\"Too many arguments, TODO:use more bits\")") else {
				for (i in 0...nargs) expr("chk |= TKIND[t->fun->args[" + i + "]->kind] << " + ((i + 1) * 3));
				line("switch( chk ) {");
				funByArgs.get(nargs).iter((_, s) -> {
					var args = s.args, t = s.t;
					line("case " + signatureChk(args, t) + ":");
					block(ctx);
					var vargs = [
						for (idx in 0...args.length)
							HlcNames.isPtr(args[idx]) ? "(" + HlcNames.ctype(args[idx]) + ")args[" + idx + "]" : "*(" + HlcNames.ctype(args[idx]) + "*)args[" + idx + "]"
					];
					var call = HlcNames.castFun("fun", args, t) + "(" + vargs.join(",") + ")";
					if (HlcNames.isPtr(t)) expr("return " + call) else if (t == HVoid) {
						expr(call);
						expr("return NULL");
					} else {
						expr("out" + HlcNames.dynValueField(t) + " = " + call);
						expr("return &out" + HlcNames.dynValueField(t));
					}
					unblock(ctx);
				});
				line("}");
				expr("break");
			}
			unblock(ctx);
		}
		line("}");
		expr("hl_fatal(\"Unsupported dynamic call\")");
		expr("return NULL");
		unblock(ctx);
		line("}");
		line("");
		for (nargs in argsCounts) {
			funByArgs.get(nargs).iter((_, s) -> {
				var args = s.args, t = s.t;
				var name = makeWrapName(args, t);
				line("static " + HlcNames.ctype(t) + " wrap_" + name + "(void *value" + [for (i in 0...args.length) "," + HlcNames.varType("p" + i, args[i])].join("") + ") {");
				block(ctx);
				if (args.length > 0) expr("void *args[] = {" + [for (i in 0...args.length) HlcNames.isPtr(args[i]) ? "p" + i : "&p" + i].join(",") + "}");
				var vargs = args.length == 0 ? "NULL" : "args";
				if (t == HVoid) expr("hl_wrapper_call(value," + vargs + ",NULL)") else if (HlcNames.isPtr(t))
					expr("return hl_wrapper_call(value," + vargs + ",NULL)") else {
					expr("vdynamic ret");
					expr("hl_wrapper_call(value," + vargs + ",&ret)");
					expr("return ret.v." + wrapChar(t));
				}
				unblock(ctx);
				line("}");
			});
		}
		line("");
		line("void *hlc_get_wrapper( hl_type *t ) {");
		block(ctx);
		expr("int chk = TKIND[t->fun->ret->kind]");
		line("switch( t->fun->nargs ) {");
		for (nargs in argsCounts) {
			line("case " + nargs + ":");
			block(ctx);
			if (nargs > 9) expr("hl_fatal(\"Too many arguments, TODO:use more bits\")") else {
				for (i in 0...nargs) expr("chk |= TKIND[t->fun->args[" + i + "]->kind] << " + ((i + 1) * 3));
				line("switch( chk ) {");
				funByArgs.get(nargs).iter((_, s) -> expr("case " + signatureChk(s.args, s.t) + ": return wrap_" + makeWrapName(s.args, s.t)));
				line("}");
				expr("break");
			}
			unblock(ctx);
		}
		line("}");
		expr("return NULL");
		unblock(ctx);
		line("}");
		line("");
	}

	// ---- make_modules (hl2c.ml 1256-1385) ----

	// mk_name: a type path as a module file name, without extension.
	static function mkName(path:String):String {
		var parts = nsplit(path, ".");
		var p:Array<String>;
		if (parts.length == 0) p = ["hl", "enums"] else {
			var name = parts.pop();
			if (StringTools.startsWith(name, "$")) name = name.substr(1);
			p = parts.concat([name]);
		}
		p = [for (n in p) Bytes.ofString(n).length > 128 ? HlcOcaml.md5Hex(Bytes.ofString(n)) : n];
		if (p.length == 1) p = ["_std", p[0]];
		return p.join("/");
	}

	static function makeModules(ctx:HlcContext, allTypes:Array<HlType>):Array<CodeModule> {
		var modules = new Map<String, CodeModule>();
		// all_modules: an OCaml list, head first
		var allModules:Array<CodeModule> = [];
		function getModule(name:String):CodeModule {
			var m = modules.get(name);
			if (m != null) return m;
			m = new CodeModule(name);
			modules.set(name, m);
			allModules.unshift(m);
			return m;
		}
		function add(m:CodeModule, fid:Int) {
			var f = ctx.ftable[fid];
			if (f.module != null) throw "hl2c: make_modules: " + f.name + " is in two modules";
			f.module = m;
			m.functions.unshift(f);
		}
		function addType(m:CodeModule, t:HlType) {
			m.types.unshift(t);
			ctx.typeModule.set(typeIndex(ctx, t), m);
		}
		// all_contexts, in all_types order (List.rev of the list it was built as)
		var allContexts:Array<HlType> = [];
		for (t in allTypes) {
			switch t {
				case HObj(o) | HStruct(o):
					var m = getModule(mkName(o.pname));
					for (p in o.pproto) add(m, p.fmethod);
					for (b in o.pbindings) add(m, b.fidx);
					addType(m, t);
				case HEnum(e) if (e.ename == ""):
					allContexts.push(t);
				case HEnum(e):
					addType(getModule(mkName(e.ename)), t);
				default:
			}
		}
		var ep = ctx.hlcode.entrypoint;
		if (ep >= 0) {
			add(getModule("hl/init"), ep);
			ctx.ftable[ep].name = "fun$init";
		}
		// get_deps: each function of the module, then (depth first, through fe_calling in call order) the
		// functions only it calls, named after it. The accumulator is threaded through every call, so one
		// array that conses at its end stands for it.
		for (m in allModules.copy()) {
			var acc:Array<FunctionEntry> = [];
			for (fm in m.functions) {
				var counter = 1;
				function append(f:FunctionEntry):Void {
					acc.push(f);
					var calling = f.calling.copy();
					calling.reverse();
					for (f2 in calling) {
						if (f2.module == null && f2.calledBy.length == 1 && f2.decl != null) {
							f2.name = fm.name + "__$" + counter;
							counter++;
							f2.module = m;
							append(f2);
						}
					}
				}
				append(fm);
			}
			acc.reverse();
			m.functions = acc;
		}
		// contexts: an unnamed enum's type index -> the module of the functions taking it first, or null when
		// they are in more than one
		var contexts = new Map<Int, {m:Null<CodeModule>}>();
		for (f in ctx.ftable) {
			if (f.module == null && StringTools.startsWith(f.name, "fun$")) {
				if (f.decl == null) throw "hl2c: make_modules: native " + f.name;
				f.name = "wrap" + typeName(ctx, f.decl.ftype);
			}
			if (f.args.length > 0) switch f.args[0] {
				case HEnum(e) if (e.ename == ""):
					var i = typeIndex(ctx, f.args[0]);
					var r = contexts.get(i);
					if (r == null) contexts.set(i, {m: f.module}) else if (r.m != null && r.m != f.module) contexts.set(i, {m: null});
				default:
			}
		}
		for (t in allContexts) {
			var r = contexts.get(typeIndex(ctx, t));
			var m = r == null ? null : r.m;
			if (m == null) {
				var tname = typeName(ctx, t);
				m = getModule("hl/ctx/" + tname.substr(8));
			}
			addType(m, t);
		}
		return allModules;
	}

	// ---- generate_module_types (hl2c.ml 1386-1458) ----

	static function generateModuleTypes(ctx:HlcContext, m:CodeModule):Void {
		var defName = "INC_" + nsplitConcat(m.name, "/", "__");
		function sortName(t:HlType):String {
			return switch t {
				case HObj(o) | HStruct(o): o.pname;
				case HEnum(e): e.ename;
				default: "";
			}
		}
		var types = m.types.copy();
		haxe.ds.ArraySort.sort(types, (t1, t2) -> compareStrings(sortName(t1), sortName(t2)));
		define(ctx, "#ifndef " + defName);
		define(ctx, "#define " + defName);
		for (t in types) {
			switch t {
				case HObj(o) | HStruct(o):
					var name = HlcNames.tname(o.pname);
					ctx.definedTypes.set(typeIndex(ctx, t), true);
					define(ctx, "typedef struct _" + name + " *" + name + ";");
				default:
			}
		}
		line(ctx, "");
		for (t in types) {
			switch t {
				case HObj(op) | HStruct(op):
					var isStruct = t.match(HStruct(_));
					var name = HlcNames.tname(op.pname);
					line(ctx, "struct _" + name + " {");
					block(ctx);
					function loop(o:HlClassProto) {
						if (o.psuper == null) {
							if (!isStruct) expr(ctx, "hl_type *$type");
						} else {
							defineType(ctx, isStruct ? HStruct(o.psuper) : HObj(o.psuper));
							loop(o.psuper);
						}
						var base = 0;
						var p = o.psuper;
						while (p != null) {
							base += p.pfields.length;
							p = p.psuper;
						}
						for (i in 0...o.pfields.length) {
							var f = o.pfields[i];
							defineType(ctx, f.t);
							expr(ctx, HlcNames.varType(f.name == "" ? unamedField(base + i) : f.name, f.t));
						}
					}
					loop(op);
					unblock(ctx);
					expr(ctx, "}");
				case HEnum(e):
					for (i in 0...e.efields.length) {
						var pl = e.efields[i].t;
						if (pl.length == 0) continue;
						line(ctx, "typedef struct {");
						block(ctx);
						line(ctx, "HL__ENUM_CONSTRUCT__");
						for (j in 0...pl.length) {
							defineType(ctx, pl[j]);
							expr(ctx, HlcNames.varType("p" + j, pl[j]));
						}
						unblock(ctx);
						expr(ctx, "} " + enumConstrType(ctx, e, i));
					}
				default:
			}
		}
		line(ctx, "#endif");
		line(ctx, "");
	}

	// ---- write_c (hl2c.ml 1460-1833) ----

	// output_bytes: comma-separated decimal bytes, a backslash-newline-tab before every 128th.
	static function outputBytes(f:String->Void, b:Bytes):Void {
		for (i in 0...b.length) {
			if ((i + 1) % 0x80 == 0) f("\\\n\t");
			if (i > 0) f(",");
			f(Std.string(b.get(i)));
		}
	}

	// `defines` is the compiler's define store in PMap key order (byte order of the keys).
	public static function writeC(file:String, code:HlCodeData, gnames:Array<String>, defines:Array<{key:String, value:String}>, version:Int):Void {
		HlcOcaml.resetMemo();
		var table = new HlTypeTable(code);
		var allTypes = table.types;
		var typesIds = HlcNames.makeTypesIdents(table);
		var gnames = HlcNames.makeGlobalNames(code, gnames);
		var bnames = [for (b in code.bytes) "bytes$" + HlcNames.shortDigest(HlcOcaml.md5Hex(b))];
		var sourceHeader = "";
		for (d in defines) if (d.key == "source_header") sourceHeader = d.value;
		var dir = dirname(file);
		if (dir == "") dir = ".";
		dir = dir.split("\\").join("/");
		var ctx = new HlcContext(version, code, dir, HlcNames.makeFunctionTable(code), typesIds, gnames, bnames, sourceHeader);
		var modules = makeModules(ctx, allTypes);

		inline function line(s:String) HlcWriter.line(ctx, s);
		inline function expr(s:String) HlcWriter.expr(ctx, s);
		inline function define(s:String) HlcWriter.define(ctx, s);

		openFile(ctx, "hl/natives.h");
		define("#ifndef HL_NATIVES_H");
		define("#define HL_NATIVES_H");
		define("// Abstract decls");
		var abstracts = [];
		for (t in allTypes)
			switch t {
				case HAbstract("hl_tls" | "hl_mutex" | "hl_thread", _): // defined in hl.h already
				case HAbstract(name, _): abstracts.push(name);
				default:
			}
		haxe.ds.ArraySort.sort(abstracts, compareStrings);
		for (name in abstracts) define("typedef struct _" + name + " " + name + ";");
		define("");
		line("// Natives functions");
		var nativeLibs = new CamlHashtbl<String>();
		var sortedNatives = code.natives.copy();
		HlcOcaml.arraySort(sortedNatives, (n1, n2) -> {
			var d = compareStrings(code.strings[n1.lib], code.strings[n2.lib]);
			d != 0 ? d : compareStrings(code.strings[n1.name], code.strings[n2.name]);
		});
		for (n in sortedNatives) {
			var name = code.strings[n.lib];
			if (StringTools.startsWith(name, "?")) name = name.substr(1);
			nativeLibs.replace(OStr(new OString(name)), name);
			var ft = ctx.ftable[n.findex];
			defineType(ctx, HFun(ft.args, ft.ret));
			switch ft.name {
				case "hl_tls_get_w":
					define("#define hl_tls_get_w(tls) ((vdynamic*)hl_tls_get(tls))");
				case "hl_tls_set": // don't redefine
				default:
					expr("HL_API " + HlcNames.ctype(ft.ret) + " " + ft.name + "(" + HlcNames.argsRepr(ft.args) + ")");
			}
		}
		line("#endif");
		line("");

		openFile(ctx, "hl/globals.c");
		define("#define HLC_BOOT");
		define("#include <hlc.h>");
		line("// Globals");
		for (i in 0...code.globals.length) {
			var t = code.globals[i];
			defineType(ctx, t);
			expr(HlcNames.varType(gnames[i], t) + " = 0");
		}
		for (c in code.constants) {
			var t = code.globals[c.global];
			var name = "const_" + gnames[c.global];
			function fieldValue(t:HlType, idx:Int):String {
				return switch t {
					case HI32: Std.string(code.ints[idx]);
					case HBytes: "(vbyte*)" + string(ctx, idx);
					default: throw "hl2c: constant field of type " + HlDump.tstr(t);
				}
			}
			var fields = switch t {
				case HObj(o) | HStruct(o):
					if (o.pfields.length != c.fields.length) throw "hl2c: constant " + name + " has " + c.fields.length + " fields";
					var fields = [for (i in 0...o.pfields.length) fieldValue(o.pfields[i].t, c.fields[i])];
					if (!t.match(HStruct(_))) fields.unshift(typeValue(ctx, t));
					fields;
				default: throw "hl2c: constant of type " + HlDump.tstr(t);
			}
			expr("static struct _" + HlcNames.ctype(t) + " " + name + " = {" + fields.join(",") + "}");
		}
		line("");
		line("void hl_init_roots() {");
		block(ctx);
		var isConst = new Map<Int, Bool>();
		for (c in code.constants) {
			expr(gnames[c.global] + " = &const_" + gnames[c.global]);
			isConst.set(c.global, true);
		}
		for (i in 0...code.globals.length)
			if (HlcNames.isPtr(code.globals[i]) && !isConst.exists(i)) expr("hl_add_root((void**)&" + gnames[i] + ")");
		unblock(ctx);
		line("}");

		for (str in code.strings) {
			var b = Bytes.ofString(str);
			if (b.length >= STRING_DATA_LIMIT) {
				var s = utf8ToUtf16(b);
				line("// " + HlDump.escapedBytes(b.sub(0, STRING_DATA_LIMIT - 4)) + "...");
				output(ctx, "vbyte string$" + HlcNames.shortDigest(str) + "[] = {");
				outputBytes(s -> output(ctx, s), s);
				expr("}");
			}
		}
		for (i in 0...code.bytes.length) {
			var bytes = code.bytes[i];
			if (bytes.length > 1000) {
				var bytesFile = "hl/bytes_" + HlcOcaml.md5Hex(bytes) + ".h";
				var absFile = ctx.dir + "/" + bytesFile;
				if (!sys.FileSystem.exists(absFile)) {
					var buf = new StringBuf();
					outputBytes(s -> buf.add(s), bytes);
					sys.io.File.saveContent(absFile, buf.toString());
				}
				line("vbyte " + ctx.bytesNames[i] + "[] = {");
				output(ctx, "#" + ctx.tabs + "  include \"" + bytesFile + "\"\n");
				expr("}");
			} else {
				output(ctx, "vbyte " + ctx.bytesNames[i] + "[] = {");
				outputBytes(s -> output(ctx, s), bytes);
				expr("}");
			}
		}

		// types.c's type_value doesn't declare the type ("no auto import")
		function localTypeValue(t:HlType):String
			return "&" + typeName(ctx, t);
		openFile(ctx, "hl/types.c");
		define("#define HLC_BOOT");
		define("#include <hlc.h>");
		line("// Types values");
		for (t in allTypes) {
			switch t {
				case HMethod(_, _) | HFun(_, _) | HVirtual(_):
					expr("hl_type " + typeName(ctx, t) + " = { " + HlcNames.typeId(t) + " } /* " + HlDump.tstr(t) + " */");
				default:
					expr("hl_type " + typeName(ctx, t) + " = { " + HlcNames.typeId(t) + " }");
			}
		}
		line("");
		line("// Types values data");
		// field_value: sprintf's arguments are evaluated right to left, so the hash comes first
		function fieldValue(f:HlField):String {
			var h = hash(ctx, f.nameIndex);
			var tv = localTypeValue(f.t);
			return "{(const uchar*)" + string(ctx, f.nameIndex) + ", " + tv + ", " + h + "}";
		}
		for (t in allTypes) {
			switch t {
				case HObj(o) | HStruct(o):
					var name = typeName(ctx, t);
					function protoValue(p:HlFieldProto):String {
						var h = hash(ctx, p.fid);
						return "{(const uchar*)" + string(ctx, p.fid) + ", " + p.fmethod + ", " + (p.fvirtual == null ? -1 : p.fvirtual) + ", " + h + "}";
					}
					var fields = if (o.pfields.length == 0) "NULL" else {
						var n = "fields" + name;
						expr("static hl_obj_field " + n + "[] = {" + [for (f in o.pfields) fieldValue(f)].join(",") + "}");
						n;
					}
					var proto = if (o.pproto.length == 0) "NULL" else {
						var n = "proto" + name;
						expr("static hl_obj_proto " + n + "[] = {" + [for (p in o.pproto) protoValue(p)].join(",") + "}");
						n;
					}
					var bindings = if (o.pbindings.length == 0) "NULL" else {
						var n = "bindings" + name;
						expr("static int " + n + "[] = {" + [for (b in o.pbindings) b.fid + "," + b.fidx].join(",") + "}");
						n;
					}
					var ofields = [
						Std.string(o.pfields.length),
						Std.string(o.pproto.length),
						Std.string(o.pbindings.length),
						"(const uchar*)" + string(ctx, o.pid),
						o.psuper == null ? "NULL" : localTypeValue(t.match(HObj(_)) ? HObj(o.psuper) : HStruct(o.psuper)),
						fields,
						proto,
						bindings
					];
					expr("static hl_type_obj obj" + name + " = {" + ofields.join(",") + "}");
				case HEnum(e):
					var ename = typeName(ctx, t);
					function constrValue(cid:Int):String {
						var c = e.efields[cid];
						var tl = c.t;
						var tval = if (tl.length == 0) "NULL" else {
							var n = "econstruct" + ename + "_" + cid;
							expr("static hl_type *" + n + "[] = {" + [for (t in tl) localTypeValue(t)].join(",") + "}");
							n;
						}
						var size = tl.length == 0 ? "0" : "sizeof(" + enumConstrType(ctx, e, cid) + ")";
						var offsets = if (tl.length == 0) "NULL" else {
							var n = "eoffsets" + ename + "_" + cid;
							expr("static int " + n + "[] = {" + [for (_ in tl) "0"].join(",") + "}");
							n;
						}
						var hasPtr = Lambda.exists(tl, HlcNames.isGcPtr);
						return "{(const uchar*)" + string(ctx, c.nameIndex) + ", " + tl.length + ", " + tval + ", " + size + ", " + (hasPtr ? "true" : "false")
							+ ", " + offsets + "}";
					}
					var constrName = if (e.efields.length == 0) "NULL" else {
						var n = "econstruct" + ename;
						expr("static hl_enum_construct " + n + "[] = {" + [for (i in 0...e.efields.length) constrValue(i)].join(",") + "}");
						n;
					}
					var efields = [
						e.eid == 0 ? "NULL" : "(const uchar*)" + string(ctx, e.eid),
						Std.string(e.efields.length),
						constrName
					];
					expr("static hl_type_enum enum" + ename + " = {" + efields.join(",") + "}");
				case HVirtual(v):
					var vname = typeName(ctx, t);
					var fieldsName = if (v.vfields.length == 0) "NULL" else {
						var n = "vfields" + vname;
						expr("static hl_obj_field " + n + "[] = {" + [for (f in v.vfields) fieldValue(f)].join(",") + "}");
						n;
					}
					expr("static hl_type_virtual virt" + vname + " = {" + fieldsName + "," + v.vfields.length + "}");
				case HFun(args, ret) | HMethod(args, ret):
					var fname = typeName(ctx, t);
					var aname = if (args.length == 0) "NULL" else {
						var n = "fargs" + fname;
						expr("static hl_type *" + n + "[] = {" + [for (a in args) localTypeValue(a)].join(",") + "}");
						n;
					}
					expr("static hl_type_fun tfun" + fname + " = {" + aname + "," + localTypeValue(ret) + "," + args.length + "}");
				default:
			}
		}
		line("");
		line("void hl_init_types( hl_module_context *ctx ) {");
		block(ctx);
		for (t in allTypes) {
			switch t {
				case HObj(o) | HStruct(o):
					var name = typeName(ctx, t);
					expr("obj" + name + ".m = ctx");
					if (o.pclassglobal != null) {
						defineGlobal(ctx, o.pclassglobal);
						expr("obj" + name + ".global_value = (void**)&" + gnames[o.pclassglobal]);
					}
					expr(name + ".obj = &obj" + name);
				case HNull(r) | HRef(r) | HPacked(r):
					expr(typeName(ctx, t) + ".tparam = " + localTypeValue(r));
				case HEnum(e):
					var name = typeName(ctx, t);
					expr(name + ".tenum = &enum" + name);
					if (e.eglobal != null) {
						defineGlobal(ctx, e.eglobal);
						expr("enum" + name + ".global_value = (void**)&" + gnames[e.eglobal]);
					}
					expr("hl_init_enum(&" + name + ",ctx)");
				case HVirtual(_):
					var name = typeName(ctx, t);
					expr(name + ".virt = &virt" + name);
					expr("hl_init_virtual(&" + name + ",ctx)");
				case HFun(_, _) | HMethod(_, _):
					var name = typeName(ctx, t);
					expr(name + ".fun = &tfun" + name);
				default:
			}
		}
		unblock(ctx);
		line("}");

		openFile(ctx, "hl/reflect.c");
		define("#define HLC_BOOT");
		define("#include <hlc.h>");
		line("// Reflection helpers");
		generateReflection(ctx);

		for (m in modules) {
			var definedTypes = new Map<Int, Bool>();
			if (m.types.length > 0) {
				openFile(ctx, m.name + ".h");
				generateModuleTypes(ctx, m);
				definedTypes = ctx.definedTypes;
			}
			if (m.functions.length > 0) {
				openFile(ctx, m.name + ".c");
				ctx.definedTypes = definedTypes;
				define("#define HLC_BOOT");
				define("#include <hlc.h>");
				if (m.types.length > 0) define("#include <" + m.name + ".h>");
				function filePos(f:FunctionEntry):{file:String, line:Int} {
					var d = f.decl;
					if (d != null && d.debug.length > 0) {
						var last = d.debug[d.debug.length - 1];
						// hl2c takes the debug file index into code.strings
						if (last.file < 0 || last.file >= code.strings.length) throw "hl2c: file_pos: string index " + last.file;
						return {file: code.strings[last.file], line: last.line};
					}
					return {file: "", line: 0};
				}
				var funcs = m.functions.copy();
				haxe.ds.ArraySort.sort(funcs, (f1, f2) -> {
					var p1 = filePos(f1), p2 = filePos(f2);
					var d = compareStrings(p1.file, p2.file);
					d != 0 ? d : (p1.line < p2.line ? -1 : (p1.line > p2.line ? 1 : 0));
				});
				for (fe in funcs) if (fe.decl != null) generateFunction(ctx, fe.decl);
			}
		}

		openFile(ctx, "hl/functions.c");
		define("#define HLC_BOOT");
		define("#include <hlc.h>");
		var ptrs = [
			for (f in ctx.ftable) {
				var name = defineFunction(ctx, f.index);
				name == "hl_tls_get_w" ? "hl_tls_get" : name;
			}
		];
		expr("void *hl_functions_ptrs[] = {" + ptrs.join(",\\\n\t") + "}");
		var ftypes = [
			for (ft in ctx.ftable) {
				var n = typeName(ctx, HFun(ft.args, ft.ret));
				define("extern hl_type " + n + ";");
				"&" + n;
			}
		];
		expr("hl_type *hl_functions_types[] = {" + ftypes.join(",\\\n\t") + "}");
		line("");
		for (f in ctx.ftable)
			if (f.module == null && f.decl != null) generateFunction(ctx, f.decl);

		openFile(ctx, "hl/hashes.c");
		define("#define HLC_BOOT");
		define("#include <hlc.h>");
		line("");
		line("void hl_init_hashes() {");
		block(ctx);
		for (i in ctx.hashes.order.copy()) expr("hl_hash((vbyte*)" + string(ctx, i) + ")");
		unblock(ctx);
		line("}");

		openFile(ctx, basename(file));
		define("#define HLC_BOOT");
		define("#include <hlc.h>");
		line("#include <hlc_main.c>");
		line("");
		line("#ifndef HL_MAKE");
		for (f in ctx.cfiles) line("#  include <" + f + ">");
		line("#endif");
		line("");
		expr("void hl_init_hashes()");
		expr("void hl_init_roots()");
		expr("void hl_init_types( hl_module_context *ctx )");
		expr("extern void *hl_functions_ptrs[]");
		expr("extern hl_type *hl_functions_types[]");
		line("");
		line("// Entry point");
		line("void hl_entry_point() {");
		block(ctx);
		expr("hl_module_context ctx");
		expr("hl_alloc_init(&ctx.alloc)");
		expr("ctx.functions_ptrs = hl_functions_ptrs");
		expr("ctx.functions_types = hl_functions_types");
		expr("hl_init_types(&ctx)");
		expr("hl_init_hashes()");
		expr("hl_init_roots()");
		if (code.entrypoint >= 0) expr(defineFunction(ctx, code.entrypoint) + "()");
		unblock(ctx);
		line("}");
		line("");

		openFile(ctx, "hlc.json");
		line("{");
		block(ctx);
		line("\"version\" : " + ctx.version + ",");
		line("\"libs\" : [" + nativeLibs.fold((_, k, acc:Array<String>) -> {
			acc.unshift("\"" + k + "\"");
			acc;
		}, []).join(",") + "],");
		var defs = new StringBuf();
		for (d in defines) defs.add("\n\t\t\"" + HlcNames.ocamlEscaped(d.key) + "\" : \"" + HlcNames.ocamlEscaped(d.value) + "\",");
		var defsText = defs.toString();
		if (defsText.length == 0) throw "hl2c: no defines";
		line("\"defines\" : {" + defsText.substr(0, defsText.length - 1) + "\n\t},");
		line("\"files\" : [" + [for (f in ctx.cfiles) "\n\t\t\"" + f + "\""].join(",") + "\n\t]");
		unblock(ctx);
		line("}");

		closeFile(ctx);
		HlcOcaml.resetMemo();
	}

	// ---- helpers ----

	// Common.utf8_to_utf16 with a terminating zero. Malformed UTF-8 ends the text where it starts, as
	// UTF8.iter's Invalid_argument does there.
	static function utf8ToUtf16(b:Bytes):Bytes {
		var out = new BytesBuffer();
		function add(c:Int) {
			out.addByte(c & 0xFF);
			out.addByte((c >> 8) & 0xFF);
		}
		function utf16Add(c:Int) {
			if (c >= 0 && c < 0x10000) {
				if (c >= 0xD800 && c <= 0xDFFF) throw "Invalid unicode char " + c;
				add(c);
			} else if (c < 0x110000) {
				c -= 0x10000;
				add((c >> 10) + 0xD800);
				add((c & 1023) + 0xDC00);
			} else throw "Invalid unicode char " + c;
		}
		var i = 0;
		var n = b.length;
		while (i < n) {
			var c = b.get(i);
			var len = c < 0x80 ? 1 : c < 0xC0 ? 0 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : c < 0xF8 ? 4 : 0;
			if (len == 0 || i + len > n) break;
			var code = len == 1 ? c : len == 2 ? c & 0x1F : len == 3 ? c & 0x0F : c & 0x07;
			for (k in 1...len) code = (code << 6) | (b.get(i + k) & 0x3F);
			utf16Add(code);
			i += len;
		}
		utf16Add(0);
		return out.getBytes();
	}

	// OCaml's compare on strings: byte order.
	public static function compareStrings(a:String, b:String):Int {
		if (a == b) return 0;
		var x = Bytes.ofString(a), y = Bytes.ofString(b);
		var n = x.length < y.length ? x.length : y.length;
		for (i in 0...n) {
			var d = x.get(i) - y.get(i);
			if (d != 0) return d < 0 ? -1 : 1;
		}
		return x.length < y.length ? -1 : (x.length > y.length ? 1 : 0);
	}

	// ExtString.String.nsplit: no parts for "".
	static function nsplit(s:String, sep:String):Array<String>
		return s == "" ? [] : s.split(sep);

	static function nsplitConcat(s:String, sep:String, by:String):String
		return nsplit(s, sep).join(by);

	static function isDirSep(s:String, i:Int):Bool {
		var c = s.charCodeAt(i);
		return c == "/".code || (isWindows && (c == "\\".code || c == ":".code));
	}

	static final isWindows = Sys.systemName() == "Windows";

	// Filename's drive_and_path (Win32): a leading letter and colon.
	static function splitDrive(s:String):{drive:String, path:String} {
		if (isWindows && s.length >= 2 && s.charCodeAt(1) == ":".code) {
			var c = s.charCodeAt(0);
			if ((c >= "a".code && c <= "z".code) || (c >= "A".code && c <= "Z".code)) return {drive: s.substr(0, 2), path: s.substr(2)};
		}
		return {drive: "", path: s};
	}

	// Filename.dirname (generic_dirname, with the drive kept on Win32)
	static function dirname(s:String):String {
		var dp = splitDrive(s);
		var name = dp.path;
		if (name == "") return dp.drive + ".";
		var n = name.length - 1;
		while (n >= 0 && isDirSep(name, n)) n--;
		if (n < 0) return dp.drive + name.substr(0, 1);
		while (n >= 0 && !isDirSep(name, n)) n--;
		if (n < 0) return dp.drive + ".";
		while (n >= 0 && isDirSep(name, n)) n--;
		if (n < 0) return dp.drive + name.substr(0, 1);
		return dp.drive + name.substr(0, n + 1);
	}

	// Filename.basename (generic_basename on the path without its drive)
	static function basename(s:String):String {
		var name = splitDrive(s).path;
		if (name == "") return ".";
		var n = name.length - 1;
		while (n >= 0 && isDirSep(name, n)) n--;
		if (n < 0) return name.substr(0, 1);
		var p = n + 1;
		while (n >= 0 && !isDirSep(name, n)) n--;
		return name.substring(n + 1, p);
	}
}
