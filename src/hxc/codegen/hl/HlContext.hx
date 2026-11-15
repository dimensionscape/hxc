package hxc.codegen.hl;

import haxe.ds.ObjectMap;
import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.Type;
import hxc.codegen.hl.HlCode;

// A port of genhl.ml's lookup tables, its context and method_context records, the register allocator and
// the op helpers (genhl.ml lines 32-121 and 205-1019, minus the type layer in HlTypes).

// genhl.ml: lookup. Keys are strings the caller builds so that they compare as OCaml's structural compare
// does; the index is the insertion order.
class HlLookup<V> {
	public var arr:Array<V> = [];
	public var map:Map<String, Int> = new Map();

	public function new() {}
}

// genhl.ml: method_capture
typedef HlMethodCapture = {
	cMap:Map<Int, Int>,
	cVars:Array<TVar>,
	cType:HlType,
	cGroup:Bool
}

// genhl.ml: allocator
typedef HlAllocator = {
	aAll:Array<Int>,
	aHold:Array<Int>
}

// genhl.ml: array_impl
typedef HlArrayImpl = {
	aall:TClass,
	abase:TClass,
	adyn:TClass,
	aobj:TClass,
	aui16:TClass,
	ai32:TClass,
	af32:TClass,
	af64:TClass
}

// genhl.ml: method_context
class HlMethodContext {
	public var mid:Int;
	public var mregs:HlLookup<HlType> = new HlLookup();
	public var mops:Array<HlOp> = [];
	public var mret:HlType;
	public var mdebug:Array<Position> = [];
	public var mvars:Map<Int, Int> = new Map();
	public var mhasthis:Bool;
	// a list in OCaml; only membership and iteration matter
	public var mdeclared:Array<Int> = [];
	// A PMap under OCaml's polymorphic compare in genhl.ml: keyed as HlTypeTable keys the type table (the
	// unfolding cut at a fixed depth), the types under one key told apart by HlTypeTable.same. So a
	// recursive virtual finds the allocator of any other virtual it unfolds the same as.
	public var mallocs:Map<String, Array<{t:HlType, a:HlAllocator}>> = new Map();
	// The type values `mallocs` was last asked about, with the allocator each found: asking again with the
	// very same value skips building its key.
	public var mallocSeenT:Array<HlType> = [];
	public var mallocSeenA:Array<HlAllocator> = [];
	public var mcaptured:HlMethodCapture;
	// prepended lists in OCaml, kept here in the order they were added
	public var mcontinues:Array<Int->Void> = [];
	public var mbreaks:Array<Int->Void> = [];
	public var mtrys = 0;
	public var mloopTrys = 0;
	public var mcaptreg = 0;
	public var mcurpos:Position = Position.nullPos;
	// List.rev of the OCaml list: in the order the assigns were made
	public var massign:Array<{name:Int, reg:Int}> = [];

	// genhl.ml: method_context
	public function new(id:Int, t:HlType, captured:HlMethodCapture, hasthis:Bool) {
		mid = id;
		mret = t;
		mcaptured = captured;
		mhasthis = hasthis;
	}
}

// genhl.ml: context (the record).
class HlContext {
	public var com:Context;
	public var cglobals:HlLookup<HlType> = new HlLookup();
	public var cstrings:HlLookup<String> = new HlLookup();
	public var cbytes:HlLookup<haxe.io.Bytes> = new HlLookup();
	public var cfloats:HlLookup<Float> = new HlLookup();
	public var cints:HlLookup<Int> = new HlLookup();
	public var cnatives:HlLookup<{lib:Int, name:Int, t:HlType, findex:Int}> = new HlLookup();
	public var cfids:HlLookup<Bool> = new HlLookup();
	public var cfunctions:Array<HlFunction> = [];
	public var cconstants:HlLookup<{global:Int, fields:Array<Int>}> = new HlLookup();
	public var optimize:Bool;
	// genhl.ml: dump_out, dump/hlopt.txt opened in create_context and written as each function is optimised;
	// set when -D dump is
	public var dumpOut:Null<sys.io.FileOutput>;
	// (name, path) of each overridden field
	public var overrides:Map<String, Bool> = new Map();
	public var definedFuns:Map<Int, Bool> = new Map();
	public var isMacro:Bool;
	// Whether class protos keep genhl's PMap.add calls (HlClassProto.pindexAdds, pfunctionsAdds): only the
	// type digests of HL/C (`--hl x.c`) read them.
	public var recordPMapAdds = false;
	public var cachedTypes:Map<String, HlType> = new Map();
	public var m:HlMethodContext;
	// A PMap under OCaml's polymorphic compare in genhl.ml, so an anon finds any structurally equal one, not
	// only itself: every apply_typedef makes a fresh anon, and a recursive generic typedef (Node<T> with a
	// field of type Node<T>) is only stopped by its second instance finding the first. Keyed by
	// HlTypes.anonKey, which encodes what that compare looks at.
	public var anonsCache:Map<String, HlType> = new Map();
	// anonKey's numbering of the declarations, monos and lazies it keys by identity
	public var anonKeyIds:ObjectMap<{}, Int> = new ObjectMap();
	public var anonKeyNext = 0;
	// Whether the last anonKey met nothing that can still change: no unbound monomorph and no lazy type
	// still to type. Such a key stays the anon's key, so its result is remembered by identity (anonTypes) and
	// a typedef expanding to it too (typedefTypes): genhl turns the same type objects into HL types over and
	// over, and building the key was a sixth of its time.
	public var anonKeyPure = false;
	// TAnon -> its HL type and the status it had (a status change makes a new key). hxc has no open anon
	// (Haxe 4.3 has no AOpened), but a Const one (an object literal's) still takes an optional field it is
	// unified with (TypeUnification.unifyAnons) and keeps its status, so for one of those the number of
	// fields it had is kept too, and a hit needs the same number; `fields` is -1 for any other anon.
	public var anonTypes:ObjectMap<{}, {status:AnonStatus, fields:Int, t:HlType}> = new ObjectMap();
	// TType value -> the HL type of its expansion, when that is an anon remembered in anonTypes and not a
	// Const one (a typedef hit looks at nothing else)
	public var typedefTypes:ObjectMap<{}, HlType> = new ObjectMap();
	// HAbstract by the hl.Abstract<"name"> constant class it comes from. genhl takes the name from that class's
	// expression, so every use of one declaration shares one OCaml string and HL/C's t$fun_ digests see a
	// back-reference; one HlType object per class gives HlcOcaml.ttypeValue that sharing.
	public var abstractTypes:ObjectMap<{}, HlType> = new ObjectMap();
	public var methodWrappers:Map<String, Int> = new Map();
	// a list in OCaml (head first); here the head is the last element
	public var recCache:Array<{t:T, r:{v:Null<HlType>}}> = [];
	public var cachedTuples:Map<String, HlType> = new Map();
	public var tstring:HlType = HVoid;
	public var macroTypedefs:Map<String, HlType> = new Map();
	public var arrayImpl:HlArrayImpl;
	public var baseClass:TClass;
	public var baseType:TClass;
	public var baseEnum:TClass;
	public var coreType:TClass;
	public var coreEnum:TClass;
	public var refAbstract:TAbstract;
	public var cdebugFiles:HlLookup<String> = new HlLookup();
	// a prepended list in OCaml, run head first: here run from the last element
	public var ctDelayed:Array<Void->Void> = [];
	public var ctDepth = 0;

	public function new(com:Context) {
		this.com = com;
	}

	// genhl.ml: new_lookup is `new HlLookup()`.

	// genhl.ml: null_capture
	public static function nullCapture():HlMethodCapture {
		return {cVars: [], cMap: new Map(), cType: HVoid, cGroup: false};
	}

	// genhl.ml: lookup
	public static function lookup<V>(l:HlLookup<V>, key:String, make:Void->V):Int {
		var id = l.map.get(key);
		if (id != null) return id;
		var id = l.arr.length;
		l.arr.push(null);
		l.map.set(key, id);
		l.arr[id] = make();
		return id;
	}

	// genhl.ml: lookup_alloc
	public static function lookupAlloc<V>(l:HlLookup<V>, value:V):Int {
		var id = l.arr.length;
		l.arr.push(value);
		return id;
	}

	// genhl.ml: abort. Reported as an error at the position by HlGenerate.generate.
	public static function abort(msg:String, p:Position):Dynamic {
		throw new hxc.core.TypingError(msg, p);
	}

	// genhl.ml: die
	public static function die(?where:String, ?pos:haxe.PosInfos):Dynamic {
		throw "hl: internal error (" + pos.fileName + ":" + pos.lineNumber + ")" + (where == null ? "" : " " + where);
	}

	// genhl.ml: global_type
	public static function globalType(ctx:HlContext, g:Int):HlType {
		return ctx.cglobals.arr[g];
	}

	// genhl.ml: is_overridden
	public static function isOverridden(ctx:HlContext, c:TClass, f:TClassField):Bool {
		return ctx.isMacro || ctx.overrides.exists(overrideKey(f.name, c.path));
	}

	public static function overrideKey(name:String, path:hxc.core.Globals.Path):String {
		return name + "@" + path.pack.join(".") + ":" + path.name;
	}

	// genhl.ml: alloc_float. OCaml's compare makes 0. and -0. one key, and nan one key.
	public static function allocFloat(ctx:HlContext, f:Float):Int {
		var key = if (f == 0) "0" else if (Math.isNaN(f)) "nan" else {
			var b = haxe.io.FPHelper.doubleToI64(f);
			b.high + ":" + b.low;
		}
		return lookup(ctx.cfloats, key, () -> f);
	}

	// genhl.ml: alloc_i32
	public static function allocI32(ctx:HlContext, i:Int):Int {
		return lookup(ctx.cints, Std.string(i), () -> i);
	}

	// genhl.ml: alloc_string
	public static function allocString(ctx:HlContext, s:String):Int {
		return lookup(ctx.cstrings, s, () -> s);
	}

	// genhl.ml: alloc_bytes
	public static function allocBytes(ctx:HlContext, s:haxe.io.Bytes):Int {
		return lookup(ctx.cbytes, s.toHex(), () -> s);
	}

	// genhl.ml: set_curpos
	public static inline function setCurpos(ctx:HlContext, p:Position):Void {
		ctx.m.mcurpos = p;
	}

	// genhl.ml: alloc_fresh
	public static function allocFresh(ctx:HlContext, t:HlType):Int {
		var rid = ctx.m.mregs.arr.length;
		ctx.m.mregs.arr.push(t);
		return rid;
	}

	// `PMap.find t ctx.m.mallocs`: null for Not_found; with `create`, adds an empty allocator for t then.
	static function findAllocator(ctx:HlContext, t:HlType, create:Bool):Null<HlAllocator> {
		var seenT = ctx.m.mallocSeenT;
		for (i in 0...seenT.length) if (seenT[i] == t) return ctx.m.mallocSeenA[i];
		var k = HlTypeTable.key(t, 0);
		var bucket = ctx.m.mallocs.get(k);
		if (bucket == null) {
			if (!create) return null;
			ctx.m.mallocs.set(k, bucket = []);
		}
		var found:Null<HlAllocator> = null;
		for (e in bucket) if (HlTypeTable.same(e.t, t, [])) {
			found = e.a;
			break;
		}
		if (found == null) {
			if (!create) return null;
			found = {aAll: [], aHold: []};
			bucket.push({t: t, a: found});
		}
		if (seenT.length < MALLOC_SEEN_MAX) {
			seenT.push(t);
			ctx.m.mallocSeenA.push(found);
		}
		return found;
	}

	static inline var MALLOC_SEEN_MAX = 48;

	// genhl.ml: alloc_tmp
	public static function allocTmp(ctx:HlContext, t:HlType):Int {
		if (!ctx.optimize) return allocFresh(ctx, t);
		var a = findAllocator(ctx, t, true);
		if (a.aAll.length == 0) {
			var r = allocFresh(ctx, t);
			a.aAll = [r];
			return r;
		}
		return a.aAll[0];
	}

	// genhl.ml: current_pos
	public static inline function currentPos(ctx:HlContext):Int {
		return ctx.m.mops.length;
	}

	// genhl.ml: rtype
	public static inline function rtype(ctx:HlContext, r:Int):HlType {
		return ctx.m.mregs.arr[r];
	}

	// genhl.ml: hold
	public static function hold(ctx:HlContext, r:Int):Void {
		if (!ctx.optimize) return;
		var a = findAllocator(ctx, rtype(ctx, r), false);
		if (a == null) die();
		var i = a.aAll.indexOf(r);
		if (i >= 0) a.aAll.splice(i, 1) else if (a.aHold.indexOf(r) < 0) die();
		a.aHold.unshift(r);
	}

	// genhl.ml: free
	public static function free(ctx:HlContext, r:Int):Void {
		if (!ctx.optimize) return;
		var a = findAllocator(ctx, rtype(ctx, r), false);
		if (a == null) die();
		var i = a.aHold.indexOf(r);
		if (i < 0) die();
		a.aHold.splice(i, 1);
		var last = a.aHold.indexOf(r, i) < 0;
		// insert sorted
		if (last) {
			var j = 0;
			while (j < a.aAll.length && a.aAll[j] <= r) j++;
			a.aAll.insert(j, r);
		}
	}

	// genhl.ml: decl_var
	public static function declVar(ctx:HlContext, v:TVar):Void {
		ctx.m.mdeclared.push(v.id);
	}

	// genhl.ml: alloc_var
	public static function allocVar(ctx:HlContext, v:TVar, newVar:Bool):Int {
		if (newVar) declVar(ctx, v);
		var r = ctx.m.mvars.get(v.id);
		if (r != null) return r;
		var r = allocTmp(ctx, HlTypes.toType(ctx, v.type));
		hold(ctx, r);
		ctx.m.mvars.set(v.id, r);
		return r;
	}

	// genhl.ml: push_op
	public static function pushOp(ctx:HlContext, o:HlOp):Void {
		ctx.m.mdebug.push(ctx.m.mcurpos);
		ctx.m.mops.push(o);
	}

	// genhl.ml: op
	public static function op(ctx:HlContext, o:HlOp):Void {
		switch o {
			case OMov(a, b) if (a == b):
			case _: pushOp(ctx, o);
		}
	}

	// genhl.ml: set_op
	public static inline function setOp(ctx:HlContext, pos:Int, o:HlOp):Void {
		ctx.m.mops[pos] = o;
	}

	// genhl.ml: jump
	public static function jump(ctx:HlContext, f:Int->HlOp):Void->Void {
		var pos = currentPos(ctx);
		op(ctx, OJAlways(-1)); // loop
		return () -> setOp(ctx, pos, f(currentPos(ctx) - pos - 1));
	}

	// genhl.ml: jump_back
	public static function jumpBack(ctx:HlContext):Void->Void {
		var pos = currentPos(ctx);
		op(ctx, OLabel(0));
		return () -> op(ctx, OJAlways(pos - currentPos(ctx) - 1));
	}

	// genhl.ml: reg_int
	public static function regInt(ctx:HlContext, v:Int):Int {
		var r = allocTmp(ctx, HI32);
		op(ctx, OInt(r, allocI32(ctx, v)));
		return r;
	}

	// genhl.ml: shl
	public static function shl(ctx:HlContext, idx:Int, v:Int):Int {
		if (v == 0) return idx;
		hold(ctx, idx);
		var rv = regInt(ctx, v);
		var idx2 = allocTmp(ctx, HI32);
		op(ctx, OShl(idx2, idx, rv));
		free(ctx, idx);
		return idx2;
	}

	// genhl.ml: set_default
	public static function setDefault(ctx:HlContext, r:Int):Void {
		switch rtype(ctx, r) {
			case HUI8 | HUI16 | HI32 | HI64:
				op(ctx, OInt(r, allocI32(ctx, 0)));
			case HF32 | HF64:
				op(ctx, OFloat(r, allocFloat(ctx, 0.)));
			case HBool:
				op(ctx, OBool(r, false));
			case HType:
				op(ctx, OType(r, HVoid));
			case _:
				op(ctx, ONull(r));
		}
	}

	// genhl.ml: read_mem
	public static function readMem(ctx:HlContext, rdst:Int, bytes:Int, index:Int, t:HlType):Void {
		switch t {
			case HUI8: op(ctx, OGetUI8(rdst, bytes, index));
			case HUI16: op(ctx, OGetUI16(rdst, bytes, index));
			case HI32 | HI64 | HF32 | HF64: op(ctx, OGetMem(rdst, bytes, index));
			case _: die();
		}
	}

	// genhl.ml: write_mem
	public static function writeMem(ctx:HlContext, bytes:Int, index:Int, t:HlType, r:Int):Void {
		switch t {
			case HUI8: op(ctx, OSetUI8(bytes, index, r));
			case HUI16: op(ctx, OSetUI16(bytes, index, r));
			case HI32 | HI64 | HF32 | HF64: op(ctx, OSetMem(bytes, index, r));
			case _: die();
		}
	}

	// genhl.ml: captured_index
	public static function capturedIndex(ctx:HlContext, v:TVar):Null<Int> {
		if (!hxc.core.TypeFunctions.hasVarFlag(v, VCaptured)) return null;
		return ctx.m.mcaptured.cMap.get(v.id);
	}

	// genhl.ml: real_name
	public static function realName(v:TVar):String {
		var name = v.name;
		for (m in v.meta) {
			if (m.name == ":realPath") {
				if (m.params.length == 1) switch m.params[0].expr {
					case EConst(CString(s, _)):
						name = s;
						break;
					case _:
				}
			}
		}
		return name == "_gthis" ? "this" : name;
	}

	// genhl.ml: is_gen_local
	public static function isGenLocal(ctx:HlContext, v:TVar):Bool {
		return switch v.kind {
			case VUser(_): false;
			case _: true;
		}
	}

	// genhl.ml: add_assign
	public static function addAssign(ctx:HlContext, v:TVar):Void {
		if (isGenLocal(ctx, v)) return;
		var name = realName(v);
		ctx.m.massign.push({name: allocString(ctx, name), reg: currentPos(ctx) - 1});
	}

	// genhl.ml: add_capture
	public static function addCapture(ctx:HlContext, r:Int):Void {
		for (v in ctx.m.mcaptured.cVars) {
			var name = realName(v);
			ctx.m.massign.push({name: allocString(ctx, name), reg: -(r + 2)});
		}
	}

	// genhl.ml: before_return
	public static function beforeReturn(ctx:HlContext):Void {
		for (_ in 0...ctx.m.mtrys) op(ctx, OEndTrap(false));
	}

	// genhl.ml: before_break_continue
	public static function beforeBreakContinue(ctx:HlContext):Void {
		for (_ in 0...ctx.m.mtrys - ctx.m.mloopTrys) op(ctx, OEndTrap(false));
	}
}

