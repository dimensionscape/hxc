package hxc.codegen.jvm;

import haxe.ds.StringMap;
import hxc.ast.Ast;
import hxc.context.Context;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.codegen.GenShared;
import hxc.codegen.jvm.JvmSignature;
import hxc.codegen.jvm.JvmSignature.JSignature;
import hxc.codegen.jvm.JvmSignature.JPath;
import hxc.codegen.jvm.JvmSignature.JWildcard;
import hxc.codegen.jvm.JvmSignature.JTypeArgument;
import hxc.codegen.jvm.JvmSignature.NativeSignatures;
import hxc.codegen.jvm.JvmMethod;
import hxc.codegen.jvm.JvmMethod.MethodBuilder;
import hxc.codegen.jvm.JvmClass.ClassBuilder;
import hxc.codegen.jvm.JvmFunctions.TypedFunction;
import hxc.codegen.jvm.JvmGlobals.MethodAccessFlags;
import hxc.codegen.jvm.JvmBuilder;
import hxc.codegen.jvm.JvmFunctions;
import hxc.codegen.jvm.JvmWriter;
import hxc.codegen.jvm.JvmClass;
import hxc.codegen.jvm.JvmCode;
import hxc.codegen.jvm.JvmData;
import hxc.codegen.jvm.JvmData.JCmp;
import hxc.codegen.jvm.JvmBuilder.AnnotationKind;
import hxc.codegen.jvm.JvmBuilder.Annotation;
import hxc.core.TypingError;
import hxc.filters.Exceptions;

// GenJvm, GenerateJvm, TclassToJvm and TexprToJvm bridge Haxe structures and JVM structures. The Jvm*
// modules (class builder, code, constant pool, signatures) never use a Haxe-specific type.

enum Ret {
	RValue(jsig:Null<JSignature>, name:Null<String>);
	RVoid;
	RReturn;
}

enum AccessKind {
	AKPost;
	AKPre;
	AKNone;
}

class GenerationContext {
	public var com:Context;
	public var out:JvmOutput;
	public var runtimeException:T;
	public var entryPoint:Null<{c:TClass, e:TExpr}>;
	public var exception:T;
	public var throwable:T;
	public var anonIdentification:TanonIdentification;
	public var preprocessor:Preprocessor;
	public var defaultExportConfig:JvmBuilder.ExportConfig;
	public var typedefInterfaces:TypedefInterfaces;
	public var typedFunctions:JvmFunctions.TypedFunctions;
	public var closurePaths:StringMap<JPath>;
	public var enumPaths:StringMap<Bool>;
	public var detailTimes:Bool;
	public var jarCompressionLevel:Int;
	public var dynamicLevel:Int;

	public function new() {}
}

class GenJvm {
	public static function isReallyInt(t:T):Bool {
		return !TypeFunctions.isNullable(t) && isIntT(TypeFunctions.follow(t));
	}

	static function isIntT(t:T):Bool {
		return switch (t) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Int";
			case _: false;
		}
	}

	// Due to @:native, the usual String path doesn't match
	public static function isString(t:T):Bool {
		return switch (t) {
			case TInst(c, _):
				(c.path.pack.length == 0 && c.path.name == "String")
				|| (c.path.pack.length == 2 && c.path.pack[0] == "java"
					&& c.path.pack[1] == "lang" && c.path.name == "String");
			case _: false;
		}
	}

	public static function getConstructionMode(c:TClass, cf:TClassField):JvmMethod.ConstructionKind {
		return TypeFunctions.hasMeta(":hxGen", cf.meta) ? ConstructInitPlusNew : ConstructInit;
	}

	public static function needVal(ret:Ret):Bool {
		return switch (ret) {
			case RValue(_, _): true;
			case _: false;
		}
	}

	// The stack breaks recursive types: a type already being converted becomes Object rather than recursing
	// forever.
	static function jsignatureOfTypeStack(gctx:GenerationContext, stack:Array<T>, t:T):JSignature {
		for (t2 in stack) if (TypeUnification.fastEq(t, t2)) return NativeSignatures.objectSig;
		var stack2 = [t].concat(stack);
		function rec(t:T) return jsignatureOfTypeStack(gctx, stack2, t);
		function arg(t:T) return jtypeArgumentOfType(gctx, stack, t);
		return switch (t) {
			case TAbstract(a, tl):
				var pack = a.path.pack;
				var name = a.path.name;
				var p1 = pack.length == 1 ? pack[0] : null;
				if (pack.length == 0) switch (name) {
					case "Bool": TBool;
					case "Int": TInt;
					case "Single": TFloat;
					case "Float": TDouble;
					case "Void": NativeSignatures.voidSig;
					case "Null":
						switch (tl) {
							case [t]: NativeSignatures.getBoxedType(rec(t));
							case _: throw "die";
						}
					case "Dynamic": NativeSignatures.objectSig;
					case "Class" | "Enum":
						switch (tl) {
							case [t]: TObject(NativeSignatures.javaClassPath, [TType(WNone, rec(t))]);
							case _: NativeSignatures.javaClassSig;
						}
					case "EnumValue": NativeSignatures.javaEnumSig(NativeSignatures.objectSig);
					case _: abstractFallback(gctx, stack, a, tl, rec);
				} else if (p1 == "java") switch (name) {
					case "Int8": TByte;
					case "Int16": TShort;
					case "Int64": TLong;
					case "Char16": TChar;
					case _: abstractFallback(gctx, stack, a, tl, rec);
				} else if (p1 == "haxe") switch (name) {
					case "Int32": TInt;
					case "Int64": TLong;
					case _: abstractFallback(gctx, stack, a, tl, rec);
				} else if (pack.length == 2 && pack[0] == "haxe" && pack[1] == "ds" && name == "Vector") {
					switch (tl) {
						case [t]: TArray(rec(t), null);
						case _: throw "die";
					}
				} else abstractFallback(gctx, stack, a, tl, rec);
			case TDynamic(_):
				NativeSignatures.objectSig;
			case TMono(r):
				r.type != null ? rec(r.type) : NativeSignatures.objectSig;
			case TInst(c, tl):
				var pack = c.path.pack;
				var name = c.path.name;
				var isHaxeRoot = pack.length == 2 && pack[0] == "haxe" && pack[1] == "root";
				if (isHaxeRoot && name == "String" && tl.length == 0) NativeSignatures.stringSig;
				else if (isHaxeRoot && name == "Array" && tl.length == 1)
					TObject({pack: ["haxe", "root"], name: "Array"},
						[TType(WNone, NativeSignatures.getBoxedType(rec(tl[0])))]);
				else if (pack.length == 1 && pack[0] == "java" && name == "NativeArray" && tl.length == 1)
					TArray(rec(tl[0]), null);
				else switch (c.kind) {
					case KTypeParameter([t2]) if (t2 != TypeFunctions.tDynamic):
						rec(t2);
					case KTypeParameter(_):
						TTypeParameter(name);
					case _:
						if (pack.length == 1 && pack[0] == "_Class" && name == "Class_Impl_")
							NativeSignatures.javaClassSig;
						else if (pack.length == 1 && pack[0] == "_Enum" && name == "Enum_Impl_")
							NativeSignatures.javaClassSig;
						else
							TObject(c.path, [for (t in tl) arg(t)]);
				}
			case TEnum(en, tl):
				gctx.enumPaths.set(Globals.sTypePath(en.path), true);
				TObject(en.path, [for (t in tl) arg(t)]);
			case TFun(sig):
				NativeSignatures.methodSig([
					for (a in sig.args) {
						var jsig = rec(a.t);
						a.opt ? NativeSignatures.getBoxedType(jsig) : jsig;
					}
				], returnOfTypeStack(gctx, stack, sig.ret));
			case TAnon(_):
				NativeSignatures.objectSig;
			case TType(td, tl):
				switch (gctx.typedefInterfaces.getInterfaceClass(td.path)) {
					case null: rec(TypeFunctions.applyTypedef(td, tl));
					case c: TObject(c.path, []);
				}
			case TLazy(f):
				rec(TypeFunctions.lazyType(f));
		}
	}

	// a non-coreType abstract converts as its underlying type
	static function abstractFallback(gctx:GenerationContext, stack:Array<T>, a:TAbstract, tl:TParams,
			rec:T->JSignature):JSignature {
		if (TypeFunctions.hasMeta(":coreType", a.meta))
			return TObject(a.path, [for (t in tl) jtypeArgumentOfType(gctx, stack, t)]);
		return rec(TypeFunctions.getUnderlyingType(a, tl));
	}

	static function jtypeArgumentOfType(gctx:GenerationContext, stack:Array<T>, t:T):JTypeArgument {
		return TType(WNone, NativeSignatures.getBoxedType(jsignatureOfTypeStack(gctx, stack, t)));
	}

	static function returnOfTypeStack(gctx:GenerationContext, stack:Array<T>, t:T):Null<JSignature> {
		return isVoidT(TypeFunctions.follow(t)) ? null : jsignatureOfTypeStack(gctx, stack, t);
	}

	static function isVoidT(t:T):Bool {
		return switch (t) {
			case TAbstract(a, _): a.path.pack.length == 0 && a.path.name == "Void";
			case _: false;
		}
	}

	public static function jtypeArgumentOfTypeTop(gctx:GenerationContext, t:T):JTypeArgument {
		return jtypeArgumentOfType(gctx, [], t);
	}

	public static function jsignatureOfType(gctx:GenerationContext, t:T):JSignature {
		return jsignatureOfTypeStack(gctx, [], t);
	}

	public static function returnOfType(gctx:GenerationContext, t:T):Null<JSignature> {
		return returnOfTypeStack(gctx, [], t);
	}

	public static function convertFields(gctx:GenerationContext, pfm:PathFieldMapping):Array<{name:String, sig:Dynamic}> {
		if (pfm.pfmConverted != null) return pfm.pfmConverted;
		var l = [for (s in pfm.pfmFields.keys()) s];
		l.sort(Reflect.compare);
		var conv = [for (s in l) {name: s, sig: (jsignatureOfType(gctx, pfm.pfmFields.get(s).type) : Dynamic)}];
		pfm.pfmConverted = conv;
		return conv;
	}

	public static function resolveClass(com:Context, path:Path):TClass {
		for (mt in com.types) switch (mt) {
			case TClassDecl(c) if (Globals.sTypePath(c.path) == Globals.sTypePath(path)): return c;
			case _:
		}
		throw "Could not resolve " + Globals.sTypePath(path);
	}

	public static function convertCmpOp(op:Binop):JCmp {
		return switch (op) {
			case OpEq: CmpEq;
			case OpNotEq: CmpNe;
			case OpLt: CmpLt;
			case OpLte: CmpLe;
			case OpGt: CmpGt;
			case OpGte: CmpGe;
			case _: throw "die";
		}
	}

	public static function flipCmpOp(op:JCmp):JCmp {
		return switch (op) {
			case CmpEq: CmpNe;
			case CmpNe: CmpEq;
			case CmpLt: CmpGe;
			case CmpLe: CmpGt;
			case CmpGt: CmpLe;
			case CmpGe: CmpLt;
		}
	}

	public static function writeClass(gctx:GenerationContext, path:JPath, jc:JvmData.JvmClassData):Void {
		var dir = path.pack.length == 0 ? path.name : path.pack.join("/") + "/" + path.name;
		var ch = new haxe.io.BytesOutput();
		JvmWriter.writeJvmClass(ch, jc);
		gctx.out.addEntry(ch.getBytes(), dir + ".class");
	}

	public static function isConstIntPattern(el:Array<TExpr>):Bool {
		for (e in el) switch (e.expr) {
			case TConst(TInt(_)):
			case _: return false;
		}
		return true;
	}

	public static function isConstStringPattern(el:Array<TExpr>):Bool {
		for (e in el) switch (e.expr) {
			case TConst(TString(_)):
			case _: return false;
		}
		return true;
	}

	public static function isInterfaceVarAccess(c:TClass, cf:TClassField):Bool {
		if (!TypeFunctions.hasClassFlag(c, CInterface)) return false;
		return switch (cf.kind) {
			case Var(_) | Method(MethDynamic): true;
			case _: false;
		}
	}

	// unlike TypeFunctions.follow, the JVM generator's follow also goes through abstracts
	public static function follow(t:T):T {
		return TypeFunctions.followWithAbstracts(t);
	}
}

class AnnotationHandler {
	static function parsePath(e:Expr):JPath {
		var sl = try Ast.stringListOfExprPathRaise(e) catch (_:Dynamic) {
			throw new TypingError("Field expression expected", e.pos);
		};
		// stringListOfExprPathRaise returns the path last segment first: the head is the type name and the
		// tail is the pack reversed, so it is reversed back
		return switch (sl) {
			case []: throw new TypingError("Field expression expected", e.pos);
			case _:
				var pack = sl.slice(1);
				pack.reverse();
				{pack: pack, name: sl[0]};
		}
	}

	static function parseValue(e:Expr):AnnotationKind {
		return switch (e.expr) {
			case EConst(CInt(s, _)): AInt(Std.parseInt(StringTools.replace(s, "_", "")));
			case EConst(CFloat(s, _)): ADouble(hxc.core.Numeric.parseFloatLit(s));
			case EConst(CString(s, _)): AString(s);
			case EConst(CIdent("true")): ABool(true);
			case EConst(CIdent("false")): ABool(false);
			case EArrayDecl(el): AArray([for (e in el) parseValue(e)]);
			case EField(e1, s, _):
				AEnum(NativeSignatures.objectPathSig(parsePath(e1)), s);
			case ECall(e1, el):
				var path = parsePath(e1);
				AAnnotation(TObject({pack: path.pack, name: path.name.split(".").join("$")}, []),
					[for (e in el) parseValuePair(e)]);
			case _:
				throw new TypingError("Expected value expression", e.pos);
		}
	}

	static function parseValuePair(e:Expr):{name:String, kind:AnnotationKind} {
		return switch (e.expr) {
			case EBinop(OpAssign, {expr: EConst(CIdent(s))}, e1): {name: s, kind: parseValue(e1)};
			case _: throw new TypingError("Assignment expression expected", e.pos);
		}
	}

	static function parseExpr(e:Expr):{path:JPath, values:Annotation} {
		return switch (e.expr) {
			case ECall(e1, el):
				var path = parsePath(e1);
				{
					path: {pack: path.pack, name: path.name.split(".").join("$")},
					values: [for (e in el) parseValuePair(e)]
				};
			case _:
				throw new TypingError("Call expression expected", e.pos);
		}
	}

	public static function convertAnnotations(meta:Metadata):Array<{path:JPath, a:Annotation}> {
		var acc = [];
		for (m in meta) {
			if (m.name != ":meta") continue;
			switch (m.params) {
				case [e]:
					var r = parseExpr(e);
					var path = r.path.pack.length == 0 ? {pack: ["haxe", "root"], name: r.path.name} : r.path;
					acc.push({path: path, a: r.values});
				case _:
			}
		}
		return acc;
	}

	public static function generateAnnotations(builder:JvmBuilder.BaseBuilder, meta:Metadata):Void {
		for (a in convertAnnotations(meta)) builder.addAnnotation(a.path, a.a);
	}
}

class HaxeException {
	var t:T;

	public var isHaxeException(default, null):Bool;
	public var nativeType(default, null):JSignature;
	public var nativePath(default, null):JPath;

	public function new(gctx:GenerationContext, t:T) {
		this.t = t;
		isHaxeException = Exceptions.isHaxeException(t);
		nativeType = GenJvm.jsignatureOfType(gctx, t);
		nativePath = switch (nativeType) {
			case TObject(path, _): path;
			case _: throw "die";
		};
	}

	public function getType():T return t;

	public function isAssignableTo(exc2:HaxeException):Bool {
		if (isHaxeException == exc2.isHaxeException)
			return TypeUnification.doesUnify(t, exc2.getType());
		// `haxe.Exception` is assignable to java.lang.RuntimeException/Exception/Throwable
		if (!isHaxeException && exc2.isHaxeException) {
			for (jsig in [NativeSignatures.throwableSig, NativeSignatures.exceptionSig,
				NativeSignatures.runtimeExceptionSig])
				if (JvmSignature.eq(exc2.nativeType, jsig)) return true;
			return false;
		}
		return false;
	}
}

class FieldClosure {
	// the equals(Object) skeleton every closure and anon shares: bail out false unless the
	// argument is an instance of this very class, then hand back a load of it already cast
	public static function generateEqualsFunction(jc:ClassBuilder, jsigArg:JSignature):{jm:MethodBuilder, load:Void->Void} {
		var jmEquals = jc.spawnMethod("equals", NativeSignatures.methodSig([jsigArg], TBool),
			[MethodAccessFlags.MPublic]);
		var code = jmEquals.getCode();
		var v = jmEquals.addLocal("other", jsigArg, VarArgument);
		jmEquals.finalizeArguments();
		v.load();
		code.instanceof(jc.getThisPath());
		jmEquals.ifThen(function(r) code.if_(CmpNe, r), function() {
			code.bconst(false);
			jmEquals.returnOp();
		});
		v.load();
		var v2 = jmEquals.addLocal("other", jc.getJsig(), VarWillInit);
		jmEquals.castTo(jc.getJsig());
		v2.store();
		return {jm: jmEquals, load: v2.load};
	}

	// a closure over `this` for a member method, generated once per (class, name, signature) and cached on
	// the context
	static function create(gctx:GenerationContext, jc:ClassBuilder, pathThis:JPath, jm:MethodBuilder,
			name:String, jsig:JSignature):JPath {
		var jsigThis = NativeSignatures.objectPathSig(pathThis);
		var context = [{name: "this", jsig: jsigThis}];
		var wf = new TypedFunction(gctx.typedFunctions, FuncMember(pathThis, name), jc, jm, context);
		var jcClosure = wf.getClassBuilder();
		wf.generateConstructor(true);
		var args, ret;
		switch (jsig) {
			case TMethod(a, r):
				args = [for (i in 0...a.length) {name: "arg" + i, jsig: a[i]}];
				ret = r;
			case _:
				throw "die";
		}
		var jmInvoke = wf.generateInvoke(args, ret, []);
		var vars = [for (a in args) jmInvoke.addLocal(a.name, a.jsig, VarArgument)];
		jmInvoke.finalizeArguments();
		jmInvoke.loadThis();
		jmInvoke.getfield(jcClosure.getThisPath(), "this", jsigThis);
		for (v in vars) v.load();
		jmInvoke.invokevirtual(pathThis, name, NativeSignatures.methodSig([for (a in args) a.jsig], ret));
		jmInvoke.returnOp();
		// equals: two closures over the same receiver are equal
		{
			var r = generateEqualsFunction(jcClosure, NativeSignatures.objectSig);
			var code = r.jm.getCode();
			r.jm.loadThis();
			r.jm.getfield(jcClosure.getThisPath(), "this", jsigThis);
			r.load();
			r.jm.getfield(jcClosure.getThisPath(), "this", jsigThis);
			r.jm.ifThen(function(rf) code.ifAcmpEq(jcClosure.getJsig(), jcClosure.getJsig(), rf), function() {
				code.bconst(false);
				r.jm.returnOp();
			});
			code.bconst(true);
			r.jm.returnOp();
		}
		GenJvm.writeClass(gctx, jcClosure.getThisPath(), jcClosure.exportClass(gctx.defaultExportConfig));
		return jcClosure.getThisPath();
	}

	public static function createFieldClosure(gctx:GenerationContext, jc:ClassBuilder, pathThis:JPath,
			jm:MethodBuilder, name:String, jsig:JSignature, f:Void->Void):Void {
		var jsigThis = NativeSignatures.objectPathSig(pathThis);
		var key = pathThis.pack.join("/") + "/" + pathThis.name + "|" + name + "|"
			+ JvmSignature.generateSignature(false, jsig);
		var closurePath = gctx.closurePaths.get(key);
		if (closurePath == null) {
			closurePath = create(gctx, jc, pathThis, jm, name, jsig);
			gctx.closurePaths.set(key, closurePath);
		}
		jm.construct(ConstructInit, closurePath, function() {
			f();
			return [jsigThis];
		});
	}
}

class JvmPreprocessor {
	// a type in the root package moves into haxe.root, which is why the emitted entries read
	// haxe/root/Main.class
	static function makeRoot(path:Path):Path {
		return new Path(["haxe", "root"], path.name);
	}

	static function hasPrimaryType(m:ModuleDef):Bool {
		for (mt in m.types) if (TypeFunctions.tInfos(mt).path.name == m.path.name) return true;
		return false;
	}

	static function checkPath(mt:ModuleType):Void {
		var infos = TypeFunctions.tInfos(mt);
		var path = if (infos.isPrivate && hasPrimaryType(infos.module)
			&& !TypeFunctions.hasMeta(":native", infos.meta)) {
			var m = infos.module;
			var pack = m.path.pack.length == 0 ? ["haxe", "root"] : m.path.pack;
			new Path(pack, m.path.name + "$" + infos.path.name);
		} else if (infos.path.pack.length == 0) {
			makeRoot(infos.path);
		} else {
			return;
		}
		switch (mt) {
			case TClassDecl(c): c.path = path;
			case TEnumDecl(e): e.path = path;
			case TTypeDecl(t): t.path = path;
			case TAbstractDecl(a): a.path = path;
		}
	}

	// an interface with exactly one non-default method is a functional interface, so a Haxe closure of that
	// shape can be handed to java code expecting it
	static function checkSingleMethodInterface(gctx:GenerationContext, c:TClass):Void {
		var m:TClassField = null;
		var ambiguous = false;
		for (cf in c.orderedFields) {
			if (TypeFunctions.hasClassFieldFlag(cf, CfDefault)) continue;
			if (m == null) m = cf;
			else {
				ambiguous = true;
				break;
			}
		}
		if (ambiguous || m == null) return;
		switch (GenJvm.jsignatureOfType(gctx, m.type)) {
			case TMethod(args, ret):
				JavaFunctionalInterfaces.add(args, ret, c.path, m.name,
					[for (tp in c.params.concat(m.params)) TypeFunctions.extractParamName(tp)]);
			case _:
		}
	}

	static function hasRuntimeMeta(ml:Metadata):Bool {
		for (m in ml) if (m.name.length > 0 && m.name.charAt(0) != ":") return true;
		return false;
	}

	public static function preprocess(gctx:GenerationContext):Void {
		// go through com.modules so we can also pick up private typedefs
		for (m in gctx.com.modules) for (mt in m.types) switch (mt) {
			case TClassDecl(c) if (hasRuntimeMeta(c.meta) && TypeFunctions.hasClassFlag(c, CInterface)):
				// TODO: run-time metadata on an interface is an open problem; such an interface skips
				// checkPath
			case TClassDecl(_) | TEnumDecl(_):
				checkPath(mt);
			case TTypeDecl(td):
				checkPath(mt);
				gctx.anonIdentification.identifyTypedef(td);
			case _:
		}
		for (mt in gctx.com.types) switch (mt) {
			case TClassDecl(c):
				if (!TypeFunctions.hasClassFlag(c, CInterface)) gctx.preprocessor.preprocessClass(c);
				else checkSingleMethodInterface(gctx, c);
			case _:
		}
		// find typedef-interface implementations
		for (mt in gctx.com.types) switch (mt) {
			case TClassDecl(c) if (!TypeFunctions.hasClassFlag(c, CInterface)
				&& !TypeFunctions.hasClassFlag(c, CExtern)):
				gctx.typedefInterfaces.processClass(c);
			case _:
		}
	}
}
