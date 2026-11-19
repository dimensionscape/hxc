package hxc.codegen.dotnet;

import haxe.ds.ObjectMap;
import hxc.ast.Position;
import hxc.context.Context;
import hxc.core.Globals;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.codegen.dotnet.CompanionToIl;
import hxc.codegen.dotnet.DotnetTypes;
import hxc.codegen.dotnet.EnumToIl;
import hxc.codegen.dotnet.EventToIl.EventPlan;
import hxc.codegen.dotnet.IlData;
import hxc.codegen.dotnet.IlMeta.IlConstant;
import hxc.codegen.dotnet.IlMeta.TableIdx;
import hxc.codegen.dotnet.TclassToIl;

// AttributesToIl's targets, written AttrTarget.TField: imported, its constructors would hide hxc.core.Type's
// TType and TField.
private typedef AttrTarget = AttributesToIl.AttrTarget;

// The state of one generation: the module being built, member tokens keyed by field identity, and
// what the stub rule recorded.
class DotnetCtx {
	public final ctx:Context;
	public final mb:ModuleBuilder;
	// The PDB, under -debug.
	public final pdb:Null<PdbBuilder>;
	public final types:DotnetTypes;
	public final sigs:SigWriter;
	public final externs:ExternMembers;
	public final methodTokens = new ObjectMap<TClassField, Int>();
	public final methodPlans = new ObjectMap<TClassField, MethodPlan>();
	public final methodSigs = new ObjectMap<TClassField, {ret:IlSigNorm, args:Array<IlSigNorm>}>();
	public final fieldTokens = new ObjectMap<TClassField, Int>();
	public final fieldSigs = new ObjectMap<TClassField, IlSigNorm>();
	public final planOf = new ObjectMap<TClass, ClassPlan>();
	// The plan of the class declaring each Haxe field and method.
	public final ownerOf = new ObjectMap<TClassField, ClassPlan>();
	// The CLR property each physical @:property var is (TclassToIl.planVarProperty), whose accessors every
	// access calls; such a var has no entry in fieldTokens.
	public final varProperties = new ObjectMap<TClassField, PropertyPlan>();
	// The CLR event each @:event var of a Haxe class or interface is (EventToIl), which says whether a read or
	// assignment of the var is the backing field (a field-like event inside its own class) or an error.
	public final eventVars = new ObjectMap<TClassField, EventPlan>();
	// What each hxgen enum became (EnumToIl).
	public final enumPlans = new ObjectMap<TEnum, EnumPlan>();
	public var plans:Array<ClassPlan> = [];
	// "skipped", "stubbed" and "ignored" lines for -D dotnet-stub-report.
	public final records:Array<String> = [];
	public var mainClass:Null<TClass> = null;
	public var entryPoint = 0;
	// AttributesToIl's state, made on first use.
	public var attributes:Null<AttributesToIl> = null;
	// NullableToIl's state, when -D dotnet-nullable names packages.
	public var nullable:Null<NullableToIl> = null;
	public var diagnostics = 0;
	// gencommon's mk_temp counter, which numbers FixOverrides's `__temp_` parameters across the program.
	public var tempCount = 0;
	// What ClosuresToClass made of the program: a field's body or initializer and a class's __init__
	// with each local function replaced by a closure class, and those classes with the class whose code
	// they come from.
	public final closureExprs = new ObjectMap<TClassField, TExpr>();
	public final closureInits = new ObjectMap<TClass, TExpr>();
	public final closureOwners = new ObjectMap<TClass, TClass>();
	// The invoker class of each method used as a value that has one (MethodInvokers).
	public final methodInvokers = new ObjectMap<TClassField, TClass>();
	// What HxGeneric found for each generic class it analysed.
	public final hxGenericClasses = new ObjectMap<TClass, Bool>();
	// CompanionToIl's plans: each hxgeneric class's or interface's companion interface, an interface's
	// `__Statics_` class, and the classes with a companion in the order they were declared.
	public final companionPlans = new ObjectMap<TClass, ClassPlan>();
	public final staticsPlans = new ObjectMap<TClass, ClassPlan>();
	public var companionOrder:Array<TClass> = [];
	// CompanionToIl's parent casts and cast names of each class, remembered for the round.
	public final castParents = new ObjectMap<TClass, Array<{c:TClass, params:Array<T>}>>();
	public final castNames = new ObjectMap<TClass, Array<String>>();
	// TclassToIl's overloads that erased interfaces give each class, remembered for the round.
	public final interfaceOverloads = new ObjectMap<TClass, Array<InterfaceBridge>>();
	// The final or inline methods a subclass's interface maps to (TclassToIl.findImplementation), which Roslyn
	// makes `virtual final newslot` in their own class; collected over the round, applied after it
	// (TclassToIl.openInheritedFinals).
	public final inheritedFinals = new ObjectMap<TClassField, Bool>();
	final closureClasses:Array<TClass> = [];

	final stdRoots:Array<String>;

	public function new(ctx:Context, mb:ModuleBuilder) {
		this.ctx = ctx;
		this.mb = mb;
		pdb = ctx.debug ? new PdbBuilder(newPaths()) : null;
		types = new DotnetTypes(ctx, mb);
		types.g = this;
		sigs = new SigWriter(mb.typeToken);
		externs = new ExternMembers(ctx, types);
		// hxc's own copy of the hxcs runtime is standard library too.
		stdRoots = [for (p in ctx.stdPath) normalizePath(p)].concat([normalizePath(RuntimeSources.ROOT)]);
	}

	// The PDB's Document names (PdbPaths), with -D dotnet-pathmap=<from>=<to>[,<from>=<to>...] applied.
	function newPaths():PdbPaths {
		var cwd = Sys.getCwd();
		var pathmap = [];
		if (ctx.defines.rawDefined("dotnet_pathmap")) {
			var s = ctx.defines.rawDefinedValueSafe("dotnet_pathmap");
			var parsed = PdbPaths.parsePathmap(s, cwd);
			if (parsed == null)
				error("-D dotnet-pathmap must be <from>=<to> pairs separated by commas, like C:/work/=src/ (not " + s + ")", Position.nullPos);
			else
				pathmap = parsed;
		}
		return new PdbPaths(cwd, ctx.stdPath, ctx.libraryClassPaths, pathmap, ctx.defines.rawDefined("dotnet_debug_jit"),
			s -> ctx.warning(hxc.core.WarningList.Warning.WUser, [], s, Position.nullPos));
	}

	static function normalizePath(p:String):String {
		var s = p.split("\\").join("/");
		return Sys.systemName() == "Windows" ? s.toLowerCase() : s;
	}

	// Code from a file under one of the std directories, or from the embedded runtime.
	public function isStd(pos:Position):Bool {
		var f = normalizePath(pos.file);
		for (r in stdRoots) if (r != "" && StringTools.startsWith(f, r)) return true;
		return false;
	}

	public function report(u:Unsupported):Void {
		var msg = u.isBug || u.isError ? u.what : u.what + " " + u.verb() + " not supported yet";
		if (u.isHaxe) {
			ctx.addDiagnostic(msg, u.pos == null ? Position.nullPos : u.pos);
			diagnostics++;
			return;
		}
		error(msg, u.pos == null ? Position.nullPos : u.pos);
	}

	public function error(msg:String, pos:Position):Void {
		ctx.addDiagnostic("dotnet: " + msg, pos);
		diagnostics++;
	}

	// The metadata token box, unbox.any, castclass and member references take for a type.
	public function typeTokenOf(s:IlSigNorm):Int {
		return switch (s) {
			case LClass(p, []): ModuleBuilder.typeDefOrRefToken(mb.typeToken(p, false));
			case LValueType(p, []): ModuleBuilder.typeDefOrRefToken(mb.typeToken(p, true));
			case _:
				var p = DotnetTypes.primitivePath(s);
				if (p != null) ModuleBuilder.typeDefOrRefToken(mb.typeToken(p, DotnetTypes.isValueType(s)));
				else mb.typeSpec(sigs.typeSpec(s));
		}
	}

	// A field's body or initializer as code is generated from it, its local functions lowered.
	public function exprOf(cf:TClassField):Null<TExpr> {
		var e = closureExprs.get(cf);
		return e != null ? e : cf.expr;
	}

	// A class's __init__ as code is generated from it.
	public function initOf(c:TClass):Null<TExpr> {
		var e = closureInits.get(c);
		return e != null ? e : c.init;
	}

	public function addClosureClass(c:TClass, owner:TClass):Void {
		closureClasses.push(c);
		closureOwners.set(c, owner);
		classes = null;
	}

	var classes:Null<Map<String, TClass>> = null;

	// The Haxe class, extern or not, that a .NET path names.
	public function classAt(p:IlPath):Null<TClass> {
		if (classes == null) {
			classes = new Map();
			for (mt in ctx.types.concat([for (c in closureClasses) TClassDecl(c)])) switch (mt) {
				case TClassDecl(c):
					var path = if (!TypeFunctions.hasClassFlag(c, CExtern)) DotnetNames.typePath(mt) else try types.externPath(c) catch (_:Unsupported) null;
					if (path != null && !classes.exists(IlPaths.key(path))) classes.set(IlPaths.key(path), c);
				case _:
			}
		}
		return classes.get(IlPaths.key(p));
	}

	// companionClass's index, built on first use; a leave-out round clears it, since a class left out has
	// no companion.
	public var companions:Null<Map<String, TClass>> = null;

	// The hxgeneric class or interface whose companion interface `s` is, or null (CompanionToIl).
	public function companionClass(s:IlSigNorm):Null<TClass> {
		var p = switch (s) {
			case LClass(p, []) if (p.nested.length == 0 && p.name.indexOf("`") < 0): p;
			case _: return null;
		}
		if (companions == null) {
			companions = new Map();
			for (mt in ctx.types) switch (mt) {
				case TClassDecl(c) if (c.params.length > 0 && CompanionToIl.hasCompanion(this, c)):
					companions.set(IlPaths.key(CompanionToIl.companionPath(c)), c);
				case _:
			}
		}
		return companions.get(IlPaths.key(p));
	}

	// The token code uses for a Haxe member of `plan`'s class reached through `owner`, the class's type
	// as the access sees it: the definition's own, or for a generic class a MemberRef on that
	// instantiation, with the definition's signature.
	public function memberOf(plan:ClassPlan, owner:IlSigNorm, cf:TClassField):Int {
		var m = methodPlans.get(cf);
		if (m != null) return methodOf(plan, owner, m);
		var token = fieldTokens.get(cf);
		if (token == null) throw "internal error: no member " + plan.hxPath + "." + cf.name;
		if (plan.classParams.length == 0) return token;
		return mb.memberRef(typeTokenOf(owner), DotnetNames.fieldName(plan.c, cf.name), sigs.field(fieldSigs.get(cf)));
	}

	// The token code uses for the method `m` of `plan`'s class reached through `owner`, as memberOf.
	public function methodOf(plan:ClassPlan, owner:IlSigNorm, m:MethodPlan):Int {
		if (plan.classParams.length == 0) return m.token;
		return mb.memberRef(typeTokenOf(owner), m.name, sigs.method(m.hasThis, m.ret, m.args, m.generics.length));
	}

	// Whether the hxgeneric class or interface `c` has a companion interface: not a struct, nor a local
	// function's class (CompanionToIl).
	public function hasCompanion(c:TClass):Bool {
		return CompanionToIl.hasCompanion(this, c);
	}

	// The companion interface of the hxgeneric class or interface `c`; Unsupported when it has none.
	public function companionOf(c:TClass):IlSigNorm {
		return CompanionToIl.companionOf(this, c);
	}

	// The token of the hxgeneric class's or interface's static `__hx_cast<T_c_c…>(X me):object`, on the
	// class's instantiation with object for each parameter, or for an interface on its `__Statics_`
	// class; a MethodSpec of it gives the type arguments.
	public function castHelperOf(c:TClass):Int {
		return CompanionToIl.castHelperOf(this, c);
	}

	// The type of `plan`'s class with these type arguments.
	public static function instanceOf(plan:ClassPlan, args:Array<IlSigNorm>):IlSigNorm {
		if (plan.classParams.length == 0) return plan.thisSig;
		return plan.isStruct ? LValueType(plan.path, args) : LClass(plan.path, args);
	}

	// The Haxe path of the class a signature names, for messages.
	public function haxePathOf(s:IlSigNorm):String {
		var c = switch (s) {
			case LClass(p, _) | LValueType(p, _): classAt(p);
			case _: null;
		}
		if (c == null) c = companionClass(s);
		return c == null ? Std.string(s) : DotnetTypes.haxePath(TClassDecl(c));
	}

	// The Haxe type a signature stands for, as messages print it: haxe.ds.StringMap<Dynamic>.
	public function haxeTypeOf(s:IlSigNorm):String {
		var companion = companionClass(s);
		if (companion != null) return DotnetTypes.haxePath(TClassDecl(companion)) + "<" + [for (_ in companion.params) "Dynamic"].join(", ") + ">";
		return switch (s) {
			case LObject: "Dynamic";
			case LString: "String";
			case LBool: "Bool";
			case LInt32: "Int";
			case LUInt32: "UInt";
			case LFloat64: "Float";
			case LClass(_, args) | LValueType(_, args) if (args.length > 0):
				haxePathOf(s) + "<" + [for (a in args) haxeTypeOf(a)].join(", ") + ">";
			case _: haxePathOf(s);
		}
	}

	// A class defined by Haxe code (not an extern) with type arguments.
	public function isGenericHaxeClass(s:IlSigNorm):Bool {
		return switch (s) {
			case LClass(p, args) | LValueType(p, args) if (args.length > 0):
				var c = classAt(p);
				c != null && !TypeFunctions.hasClassFlag(c, CExtern);
			case _: false;
		}
	}

	// Whether a value of the class `from` already is a `to`, through its superclasses and interfaces as
	// Haxe declares them.
	public function isUpcast(from:IlSigNorm, to:IlSigNorm):Bool {
		// A companion extends its generic superclasses' companions (CompanionToIl), not its interfaces'.
		var companion = companionClass(from);
		while (companion != null) {
			if (CompanionToIl.hasCompanion(this, companion) && IlPaths.sigEq(CompanionToIl.companionSig(companion), to)) return true;
			companion = companion.superClass == null ? null : companion.superClass.c;
		}
		var c = null, args = [];
		switch (from) {
			case LClass(p, l) | LValueType(p, l):
				c = classAt(p);
				args = l;
			case _:
		}
		if (c == null) return false;
		// haxe.lang.HxObject is the root's base without a Haxe declaration saying so.
		switch (to) {
			case LClass(p, []) if (HxGen.derivesFromHxObject(c) && classAt(p) == runtimeClass("cs.internal.HxObject")):
				return true;
			case _:
		}
		// Each class's type in terms of its own type parameters, then with `args` for them.
		function open(c:TClass, sup:TClass, params:Array<T>):Null<IlSigNorm> {
			return try types.withParams(c.params, [], () -> types.classSig(sup, params)) catch (_:Unsupported) null;
		}
		function reaches(c:TClass, args:Array<IlSigNorm>):Bool {
			// Every instantiation of an hxgeneric class or interface is its companion.
			if (CompanionToIl.hasCompanion(this, c) && IlPaths.sigEq(CompanionToIl.companionSig(c), to)) return true;
			var s = open(c, c, TypeFunctions.extractParamTypes(c.params));
			if (s == null) return false;
			if (IlPaths.sigEq(DotnetTypes.substitute(s, args, []), to)) return true;
			var supers = c.interfaces.copy();
			if (c.superClass != null) supers.push(c.superClass);
			for (sup in supers) {
				var supSig = open(c, sup.c, sup.params);
				switch (supSig == null ? null : DotnetTypes.substitute(supSig, args, [])) {
					case LClass(_, l) | LValueType(_, l):
						if (reaches(sup.c, l)) return true;
					case _:
				}
			}
			return false;
		}
		return reaches(c, args);
	}

	// The Haxe-declared types a value of the class `from` is, through its superclasses and interfaces as
	// Haxe declares them: `from` itself first. .NET types are left out: a variant .NET interface
	// (IEnumerable_1<T>) can hold other instantiations.
	function ancestors(from:IlSigNorm):Array<IlSigNorm> {
		var r:Array<IlSigNorm> = [];
		function visit(s:IlSigNorm, depth:Int) {
			var c = switch (s) {
				case LClass(p, _) | LValueType(p, _): classAt(p);
				case _: null;
			}
			if (c == null || TypeFunctions.hasClassFlag(c, CExtern) || depth > 50) return;
			var args = switch (s) {
				case LClass(_, l) | LValueType(_, l): l;
				case _: [];
			}
			r.push(s);
			var supers = c.interfaces.copy();
			if (c.superClass != null) supers.push(c.superClass);
			for (sup in supers) {
				var supSig = try types.withParams(c.params, [], () -> types.classSig(sup.c, sup.params)) catch (_:Unsupported) null;
				if (supSig != null) visit(DotnetTypes.substitute(supSig, args, []), depth + 1);
			}
		}
		visit(from, 0);
		return r;
	}

	// Whether `to`, an instantiation of a generic Haxe class, is the only instantiation of its class that
	// is a `from`: its class reaches `from` with each of its type parameters among the type arguments.
	// A castclass from `from` to `to` then succeeds exactly where gencs's __hx_cast gives the object
	// itself, as for the Map abstract's downcast of an IMap<String, V> to its StringMap<V>.
	public function isExactDowncast(from:IlSigNorm, to:IlSigNorm):Bool {
		if (!isGenericHaxeClass(to)) return false;
		var open = switch (to) {
			case LClass(p, l): LClass(p, [for (i in 0...l.length) LTypeParam(i)]);
			case LValueType(p, l): LValueType(p, [for (i in 0...l.length) LTypeParam(i)]);
			case _: return false;
		}
		var toArgs = switch (to) {
			case LClass(_, l) | LValueType(_, l): l;
			case _: [];
		}
		for (a in ancestors(open)) {
			if (!IlPaths.sigEq(DotnetTypes.substitute(a, toArgs, []), from)) continue;
			var args = switch (a) {
				case LClass(_, l) | LValueType(_, l): l;
				case _: [];
			}
			var all = true;
			for (i in 0...toArgs.length) {
				var found = false;
				for (x in args) if (x.match(LTypeParam(_)) && IlPaths.sigEq(x, LTypeParam(i))) found = true;
				if (!found) all = false;
			}
			if (all) return true;
		}
		return false;
	}

	// A class of hxc's runtime copy (haxe.lang.HxObject, IHxObject, ...) by its Haxe path, or null.
	public function runtimeClass(hxPath:String):Null<TClass> {
		return switch (types.typeNamed(hxPath)) {
			case TClassDecl(c): c;
			case _: null;
		}
	}

	public static inline final hxObjectPath = "cs.internal.HxObject";

	// haxe.lang.EmptyObject, the type of the argument of an hxgen class's empty constructor.
	public function emptyObjectSig():IlSigNorm {
		return LValueType(types.stdClassPath("cs.internal.EmptyObject", "haxe.lang.EmptyObject", false), []);
	}

	// cs.Boot.init's token when cs.Boot is one of the program's types, as gencs calls it. A cs.Boot
	// that was left out throws, so the entry point reports it.
	public function bootInit():Null<Int> {
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c) if (DotnetTypes.haxePath(mt) == "cs.Boot"):
				types.checkKept(mt);
				var init = c.statics.get("init");
				var token = init == null ? null : methodTokens.get(init);
				if (token == null) throw "internal error: cs.Boot has no init method";
				return token;
			case _:
		}
		return null;
	}
}

// The entry point of the .NET IL generator (--cs <dir> -D dotnet): writes <name>.dll into the output
// directory, plus <name>.runtimeconfig.json for a program with a main.

class GenerateDotnet {
	// The .NET a program is built for unless -D dotnet-version says otherwise, and the oldest it can be.
	public static inline final defaultVersion = 10;

	// -D dotnet-no-exception-stack: haxe.Exception's constructor (cs/_std) takes `new StackTrace(1, true)`, the
	// whole call stack with its file names, for every exception made. A program that throws as a way of
	// working pays for it each time, so the two captures become null here: `stack` is then empty, which the
	// std allows for (NativeStackTrace.toHaxe). The trace of a caught .NET exception, `new StackTrace(e, true)`,
	// has one argument fewer and stays.
	static function dropExceptionStack(ctx:Context):Void {
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c) if (c.path.name == "Exception" && c.path.pack.length == 1 && c.path.pack[0] == "haxe" && c.constructor != null && c.constructor.expr != null):
				function loop(e:TExpr):TExpr {
					return switch (e.expr) {
						case TNew(sc, _, [{expr: TConst(TInt(_))}, {expr: TConst(TBool(_))}]) if (sc.path.name == "StackTrace"):
							TypeFunctions.mk(TConst(TNull), e.type, e.pos);
						case _:
							hxc.core.TexprTools.mapExpr(loop, e);
					}
				}
				c.constructor.expr = loop(c.constructor.expr);
			case _:
		}
	}

	// The runtimeconfig.json of a program for .NET `version`. Joined with "\n" so the file is the same
	// whatever line endings this source was checked out with.
	static function runtimeConfig(version:Int):String {
		return [
			'{',
			'  "runtimeOptions": {',
			'    "tfm": "net' + version + '.0",',
			'    "framework": {',
			'      "name": "Microsoft.NETCore.App",',
			'      "version": "' + version + '.0.0"',
			'    }',
			'  }',
			'}',
			''
		].join("\n");
	}

	// The output directory, with `/` separators and no trailing one.
	public static function outputDir(ctx:Context):String {
		var dir = ctx.file.split("\\").join("/");
		while (dir.length > 1 && StringTools.endsWith(dir, "/")) dir = dir.substr(0, dir.length - 1);
		return dir;
	}

	// The assembly is named by -D dll-name, else by the output directory's last segment.
	public static function assemblyName(ctx:Context, dir:String):String {
		return ctx.defines.rawDefined("dll_name") ? ctx.defines.rawDefinedValueSafe("dll_name") : dir.substr(dir.lastIndexOf("/") + 1);
	}

	public static function generate(ctx:Context):Void {
		var dir = outputDir(ctx);
		var name = assemblyName(ctx, dir);
		var isDll = ctx.main == null;
		var mb = new ModuleBuilder(name, isDll);
		var g = new DotnetCtx(ctx, mb);
		var version = defaultVersion;
		if (ctx.defines.rawDefined("dotnet_version")) {
			var s = ctx.defines.rawDefinedValueSafe("dotnet_version");
			var v = NetSetup.parseInt(s);
			if (v == null || v < defaultVersion)
				g.error("-D dotnet-version must be a whole number, " + defaultVersion + " or later, like 11 (not " + s + ")", Position.nullPos);
			else
				version = v;
		}
		// -D dotnet-nullable=<package>[,<package>...]: Roslyn's nullable metadata for those packages' modules.
		if (ctx.defines.rawDefined("dotnet_nullable")) {
			var s = ctx.defines.rawDefinedValueSafe("dotnet_nullable");
			var packages = NullableToIl.parsePackages(s);
			if (packages == null)
				g.error("-D dotnet-nullable must name packages, separated by commas, like ai.tools or ai.tools,ai.models (not " + s + ")",
					Position.nullPos);
			else
				g.nullable = new NullableToIl(packages);
		}
		// -D dotnet-debug-jit asks the JIT to keep what the PDB's .hx lines step through; without -debug there is none.
		if (ctx.defines.rawDefined("dotnet_debug_jit") && !ctx.debug)
			g.error("-D dotnet-debug-jit needs -debug: without the PDB there are no .hx lines to step through", Position.nullPos);
		Publish.check(ctx, g, isDll);
		// Resources (-resource files, or a macro's Context.addResource) are manifest resources, and
		// haxe.Resource.content lists them; before planning, so the class gets its static constructor.
		ResourcesToIl.fillContent(ctx);
		ResourcesToIl.embed(g);
		if (ctx.defines.rawDefined("dotnet_trim_root")) ResourcesToIl.embedTrimRoot(g, name);
		var identities = new Map<String, ModuleBuilder.AssemblyIdentity>();
		// The identity of the file that defines the type, a reference-only one too.
		mb.externScope = function(path:IlPath) {
			var lib = NetRefs.of(ctx).definer(path);
			if (lib == null) throw Unsupported.error(NetRefs.of(ctx).missing(path));
			var id = identities.get(lib.filePath);
			if (id == null) {
				id = lib.identity();
				identities.set(lib.filePath, id);
			}
			return id;
		}
		DotnetNames.noRoot = ctx.defines.rawDefined("no_root");
		FieldHashes.reset();
		if (ctx.defines.rawDefined("dotnet_no_exception_stack")) dropExceptionStack(ctx);

		var candidates:Array<TClass> = [];
		var enums:Array<TEnum> = [];
		var hxEnums:Array<TEnum> = [];
		for (mt in ctx.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CExtern)):
				candidates.push(c);
				if (ctx.mainClass != null && Globals.sTypePath(c.path) == Globals.sTypePath(ctx.mainClass)) g.mainClass = c;
			case TEnumDecl(e) if (HxGen.isClrEnum(e)):
				enums.push(e);
			case TEnumDecl(e) if (EnumToIl.isHxGenEnum(e)):
				hxEnums.push(e);
			case TEnumDecl(e) if (!e.isExtern):
				leaveOut(g, mt, e.pos, new Unsupported("@:nativeGen enums with type parameters", true, e.pos));
			case _:
		}
		if (ctx.main != null && g.mainClass == null) {
			// The main class is found by its expression when the path differs, e.g. through @:native.
			switch (ctx.main.expr) {
				case TCall({expr: TField(_, FStatic(c, _))}, _): g.mainClass = c;
				case _:
			}
		}
		for (c in candidates) addAbstractParams(c);
		// Local functions become classes of their own, declared like any other.
		for (c in ClosuresToClass.run(g, candidates)) candidates.push(c);

		// Two classes with one CLR name, through @:native, would be two TypeDefs of that name: the second
		// is left out. A name one of an hxgen enum's classes takes that is taken already is an error, as
		// gencs's C# would not compile either; the type that comes second is left out without a further
		// report. `named` maps each name to what an enum's class is, for messages, or "" for another type.
		var named = new Map<String, String>();
		for (e in enums) named.set(IlPaths.key(DotnetNames.typePath(TEnumDecl(e))), "");
		// True when the class `mt` (`what` null) takes the name of another class or a CLR enum.
		function clash(mt:ModuleType, path:IlPath, what:Null<String>, pos:Position):Bool {
			var other = named.get(IlPaths.key(path));
			if (other == null) {
				named.set(IlPaths.key(path), what == null ? "" : what);
				return false;
			}
			if (what == null && other == "") return true;
			g.error((what == null ? "the class " + DotnetTypes.haxePath(mt) : what) + " has the CLR name " + NetConverter.ilpathS(path) + " of "
				+ (other == "" ? "another type" : other), pos);
			g.types.leftOut.set(DotnetTypes.haxePath(mt), "a CLR name that is taken");
			return false;
		}
		for (e in hxEnums) {
			var mt = TEnumDecl(e);
			var hxPath = DotnetTypes.haxePath(mt);
			clash(mt, DotnetNames.typePath(mt), "the enum " + hxPath, e.pos);
			for (ef in EnumToIl.constructors(e)) if (!g.types.leftOut.exists(hxPath))
				clash(mt, EnumToIl.ctorPath(e, ef), "the class of " + hxPath + "." + ef.name, ef.pos);
		}
		for (c in candidates) {
			var mt = TClassDecl(c);
			var path = DotnetNames.typePath(mt);
			if (clash(mt, path, null, c.pos))
				leaveOut(g, mt, c.pos, new Unsupported("a second class with the CLR name " + NetConverter.ilpathS(path), false));
		}

		// A class that cannot be declared is left out, and so is every class that refers to it; this
		// runs until nothing more is left out.
		var changed = true;
		while (changed) {
			changed = false;
			g.plans = [];
			// A class left out in the last round must not stay planned for the classes that refer to it.
			g.planOf.clear();
			g.enumPlans.clear();
			g.companionPlans.clear();
			g.staticsPlans.clear();
			g.companionOrder = [];
			g.castParents.clear();
			g.castNames.clear();
			g.interfaceOverloads.clear();
			g.inheritedFinals.clear();
			g.companions = null;
			// Enums first, so the classes that refer to one see whether it was left out.
			for (e in hxEnums) {
				var mt = TEnumDecl(e);
				if (g.types.leftOut.exists(DotnetTypes.haxePath(mt))) continue;
				try {
					EnumToIl.declare(g, e);
				} catch (u:Unsupported) {
					leaveOut(g, mt, e.pos, u);
					changed = true;
				}
			}
			for (c in candidates) {
				var mt = TClassDecl(c);
				if (g.types.leftOut.exists(DotnetTypes.haxePath(mt))) continue;
				try {
					TclassToIl.declare(g, c);
					CompanionToIl.declare(g, c);
				} catch (u:Unsupported) {
					leaveOut(g, mt, c.pos, u);
					changed = true;
				}
			}
		}
		TclassToIl.openInheritedFinals(g);
		var plans = [];
		for (p in g.plans) {
			plans.push(p);
			if (p.c != null && p.c == g.mainClass && p.c.path.name == "Main") plans.push(TclassToIl.entryPointClass(g, p.c));
		}
		g.plans = plans;

		for (p in plans) p.token = mb.typeDef(p.flags, p.path);
		// CLR enums come after the classes, their fields after the classes' fields.
		var enumTokens = [
			for (e in enums) {
				var path = DotnetNames.typePath(TEnumDecl(e));
				var pseudo = AttributesToIl.pseudo(g, e.meta, AttrTarget.TClrEnum, e.pos, {name: e.path.name, ns: path.ns});
				mb.typeDef(TypeAttrs.PUBLIC | TypeAttrs.SEALED | pseudo.typeFlags, path);
			}
		];
		for (p in plans) TclassToIl.write(g, p);
		for (c in g.companionOrder) CompanionToIl.emit(g, c);
		EnumToIl.written(g);
		for (i in 0...enums.length) writeEnum(g, enums[i], enumTokens[i]);
		// The attribute rows, now that every constructor they name has its token.
		for (p in plans) TclassToIl.writeAttributes(g, p);
		for (i in 0...enums.length) {
			var e = enums[i];
			AttributesToIl.forMember(g, enumTokens[i], e.meta, AttrTarget.TClrEnum, e.pos, {name: e.path.name, ns: DotnetNames.typePath(TEnumDecl(e)).ns});
		}
		AttributesToIl.forAssembly(g, [for (p in plans) if (p.c != null) p.c], version);
		// GenericParam rows go in owner order, a TypeDef's before its methods'.
		var generics = [];
		for (p in plans) {
			for (i in 0...p.classParams.length) generics.push({owner: p.token, number: i, name: p.classParams[i].name});
			for (m in p.methods) for (i in 0...m.generics.length) generics.push({owner: m.token, number: i, name: m.generics[i]});
		}
		inline function key(owner:Int) return ModuleBuilder.coded(TableIdx.ITypeOrMethodDef, owner);
		haxe.ds.ArraySort.sort(generics, (a, b) -> key(a.owner) != key(b.owner) ? key(a.owner) - key(b.owner) : a.number - b.number);
		for (gp in generics) NullableToIl.genericParam(g, gp.owner, gp.number, mb.genericParam(gp.owner, gp.number, gp.name));
		// FieldLookup last: its table holds every name the other methods hashed.
		var fieldLookup = null;
		for (p in plans) if (p.hxPath == TclassToIl.fieldLookupPath) fieldLookup = p else TclassToIl.emitPlan(g, p);
		if (fieldLookup != null) TclassToIl.emitPlan(g, fieldLookup);

		if (ctx.defines.rawDefined("dotnet_stub_report")) {
			var lines = g.records.copy();
			lines.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
			for (l in lines) ctx.info(l, Position.nullPos);
		}
		if (g.diagnostics > 0) return;
		if (!isDll && g.entryPoint == 0) throw "internal error: the program has no entry point";
		var out = mb.finish(g.entryPoint, g.pdb, name + ".pdb");
		sys.io.File.saveBytes(dir + "/" + name + ".dll", out.dll);
		if (out.pdb != null) sys.io.File.saveBytes(dir + "/" + name + ".pdb", out.pdb);
		if (!isDll) sys.io.File.saveContent(dir + "/" + name + ".runtimeconfig.json", runtimeConfig(version));
	}

	// gencs's C# enum for a @:nativeGen flat enum: `value__`, then a literal per constructor, numbered in
	// declaration order.
	static function writeEnum(g:DotnetCtx, e:TEnum, token:Int):Void {
		var mb = g.mb;
		mb.setExtends(token, mb.typeToken({ns: ["System"], nested: [], name: "Enum"}, false));
		mb.field(token, FieldAttrs.PUBLIC | FieldAttrs.SPECIAL_NAME | FieldAttrs.RT_SPECIAL_NAME, "value__", g.sigs.field(LInt32));
		var self = g.sigs.field(LValueType(DotnetNames.typePath(TEnumDecl(e)), []));
		for (name in e.names) {
			var ef = e.constrs.get(name);
			var f = mb.field(token, FieldAttrs.PUBLIC | FieldAttrs.STATIC | FieldAttrs.LITERAL | FieldAttrs.HAS_DEFAULT, name, self);
			mb.constant(f, IInt(ef.index));
		}
	}

	// gencommon's AbstractImplementationFix: an abstract's constructor and its member methods are generic
	// over the abstract's type parameters as well, after their own: `Pr<T>`'s `then<R>` is
	// `Pr_Impl_.then<R,T>(Th<T> this1, …)`. Its static methods are left as they are. The check that they
	// are not there already is defensive: the compilation server's saveClassState snapshot, taken before
	// generation, restores each field's params, so a later generation over the same types starts without them.
	static function addAbstractParams(c:TClass):Void {
		var a = switch (c.kind) {
			case KAbstractImpl(a) if (a.params.length > 0): a;
			case _: return;
		}
		for (cf in c.orderedStatics)
			if ((cf.name == "_new" || isAbstractMember(cf)) && cf.params.indexOf(a.params[0]) < 0) cf.params = cf.params.concat(a.params);
	}

	// Whether `cf`, a static of an abstract's implementation class, is one of the abstract's member
	// methods: it takes `this` first.
	public static function isAbstractMember(cf:TClassField):Bool {
		if (!TypeFunctions.hasClassFieldFlag(cf, CfImpl)) return false;
		return switch (cf.expr) {
			case {expr: TFunction(tf)} if (tf.args.length > 0): TypeFunctions.hasMeta(":this", tf.args[0].v.meta);
			case _: false;
		}
	}

	// A standard-library type is left out and recorded; a user type is an error.
	static function leaveOut(g:DotnetCtx, mt:ModuleType, pos:Position, u:Unsupported):Void {
		var path = DotnetTypes.haxePath(mt);
		g.types.leftOut.set(path, u.what);
		// A closure class whose own class was left out fails with it, which was reported.
		var owner = switch (mt) {
			case TClassDecl(c): g.closureOwners.get(c);
			case _: null;
		}
		if (owner != null && g.types.leftOut.exists(DotnetTypes.haxePath(TClassDecl(owner)))) {
			g.records.push("skipped " + path + ": " + u.what);
			return;
		}
		if (g.isStd(pos)) {
			g.records.push("skipped " + path + ": " + u.what);
		} else {
			if (u.pos == null) u.pos = pos;
			g.report(u);
		}
	}
}
