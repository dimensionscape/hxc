package hxc.core;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Ref;
import hxc.core.Globals.Path;
import haxe.ds.StringMap;
import haxe.Int32;



enum FieldKind {
	Var(k:VarKind);
	Method(k:MethodKind);
}

@:structInit
class VarKind {
	public var read:VarAccess;
	public var write:VarAccess;
	public function new(read:VarAccess, write:VarAccess) {
		this.read = read;
		this.write = write;
	}
}

enum VarAccess {
	AccNormal;
	AccNo;
	AccNever;
	AccCtor;     // Can only be accessed from the constructor
	AccCall;     // Perform a method call when accessed
	AccInline;   // Similar to Normal but inline when accessed
	AccRequire(s:String, ?msg:String);
}

enum MethodKind {
	MethNormal;
	MethInline;
	MethDynamic;
	MethMacro;
}

enum ModuleCheckPolicy {
	NoCheckFileTimeModification;
	CheckFileContentModification;
	NoCheckDependencies;
	NoCheckShadowing;
	Retype;
}

enum ModuleSkipReason {
	DependencyDirty(p:Path, reason:ModuleSkipReason);
	Tainted(s:String);
	FileChanged(s:String);
	Shadowed(s:String);
	LibraryChanged;
}

enum ModuleCacheState {
	MSGood;
	MSBad(reason:ModuleSkipReason);
	MSUnknown;
}

enum T {
	TMono(m:TMono);
	TEnum(e:TEnum, params:TParams);
	TInst(c:TClass, params:TParams);
	TType(d:TDef, params:TParams);
	TFun(sig:TSignature);
	TAnon(a:TAnon);
	TDynamic(t:Null<T>);
	TLazy(f:Ref<TLazy>);
	TAbstract(a:TAbstract, params:TParams);
}

@:structInit
class TMono {
	public var type:Null<T>;
	public var downConstraints:Array<TMonoConstraint>;
	public var upConstraints:Array<TUpConstraint>;

	// These two start as one shared empty constant rather than a fresh Array per monomorph: an hxcpp
	// Array is an object plus its own backing store. Every write to these fields is a REASSIGNMENT
	// built with concat, never an in-place push, so the empty case can share one value. KEEP it that
	// WAY: pushing into either field would corrupt every monomorph at once.
	public static final NO_DOWN:Array<TMonoConstraint> = [];
	public static final NO_UP:Array<TUpConstraint> = [];

	public function new(?type:T, ?downConstraints:Array<TMonoConstraint>, ?upConstraints:Array<TUpConstraint>) {
		this.type = type;
		this.downConstraints = downConstraints == null ? NO_DOWN : downConstraints;
		this.upConstraints = upConstraints == null ? NO_UP : upConstraints;
	}
}

typedef TUpConstraint = {t:T, ?name:String};

enum TMonoConstraint {
	MMono(m:TMono, ?name:String);
	MField(cf:TClassField);
	MType(t:T, ?name:String);
	MOpenStructure;
	MEmptyStructure;
}

enum TMonoConstraintKind {
	CUnknown;
	CStructural(fields:StringMap<TClassField>, b:Bool);
	CMixed(kinds:Array<TMonoConstraintKind>);
	CTypes(types:Array<TUpConstraint>);
}

enum TLazy {
	LAvailable(t:T);
	LProcessing(f:Void->T);
	LWait(f:Void->T);
}

// Real CLASSES, not anonymous structures. hxcpp compiles every field read on an anon into a hashed
// __Field lookup; the generated call-typing code did ~170 such lookups per site on exactly these
// fields (args 45, t 37, ret 33, name 25, opt 15 in Calls.cpp), inside the unifyCallArgs machinery
// that runs 19k times per compile at 26us each. @:structInit keeps every {name: ..., opt: ..., t:
// ...} literal in the codebase working.
@:structInit
class TSignatureArg {
	public var name:String;
	public var opt:Bool;
	public var t:T;
	public function new(name:String, opt:Bool, t:T) {
		this.name = name;
		this.opt = opt;
		this.t = t;
	}
}

@:structInit
class TSignature {
	public var args:Array<TSignatureArg>;
	public var ret:T;
	public function new(args:Array<TSignatureArg>, ret:T) {
		this.args = args;
		this.ret = ret;
	}
}

typedef TParams = Array<T>;

@:structInit
class TypedTypeParam {
	public var name:String;
	public var type:T;
	public var defaultType:Null<T>;
	public function new(name:String, type:T, ?defaultType:T) {
		this.name = name;
		this.type = type;
		this.defaultType = defaultType;
	}
}

typedef TypeParams = Array<TypedTypeParam>;

enum TConstant {
	TInt(v:Int32);
	TFloat(s:String);
	TString(s:String);
	TBool(b:Bool);
	TNull;
	TThis;
	TSuper;
}

@:structInit
class TVarExtra {
	public var params:TypeParams;
	public var expr:Null<TExpr>;
	public function new(params:TypeParams, ?expr:TExpr) {
		this.params = params;
		this.expr = expr;
	}
}

enum TVarOrigin {
	TVOLocalVariable;
	TVOArgument;
	TVOForVariable;
	TVOPatternVariable;
	TVOCatchVariable;
	TVOLocalFunction;
}

enum TVarKind {
	VUser(origin:TVarOrigin);
	VGenerated;
	VInlined;
	VInlinedConstructorVariable;
	VExtractorVariable;
	VAbstractThis;
}

@:structInit
class TVar {
	public var id:Int;
	public var name:String;
	public var type:T;
	public var kind:TVarKind;
	public var extra:Null<TVarExtra>;
	public var meta:Metadata;
	public var flags:Int;
	public var pos:Position;
	public function new(id:Int, name:String, type:T, kind:TVarKind, extra:Null<TVarExtra>, meta:Metadata, flags:Int, pos:Position) {
		this.id = id;
		this.name = name;
		this.type = type;
		this.kind = kind;
		this.extra = extra;
		this.meta = meta;
		this.flags = flags;
		this.pos = pos;
	}
}

typedef TFuncArg = {v:TVar, ?c:TExpr};

@:structInit
class TFunc {
	public var args:Array<TFuncArg>;
	public var type:T;
	public var expr:TExpr;
	public function new(args:Array<TFuncArg>, type:T, expr:TExpr) {
		this.args = args;
		this.type = type;
		this.expr = expr;
	}
}

enum AnonStatus {
	Closed;
	Const;
	Extend(tl:Array<T>);
	Statics(c:TClass);
	EnumStatics(e:TEnum);
	AbstractStatics(a:TAbstract);
}

@:structInit
class TAnon {
	public var fields:StringMap<TClassField>;
	public var status:Ref<AnonStatus>;
	public function new(fields:StringMap<TClassField>, status:Ref<AnonStatus>) {
		this.fields = fields;
		this.status = status;
	}
}

typedef TObjectFieldKey = {name:String, pos:Position, quotes:QuoteStatus};
typedef TObjectField = {key:TObjectFieldKey, expr:TExpr};

typedef TSwitchCase = {values:Array<TExpr>, expr:TExpr};

typedef TCatch = {v:TVar, expr:TExpr};

enum TExprExpr {
	TConst(c:TConstant);
	TLocal(v:TVar);
	TArray(e1:TExpr, e2:TExpr);
	TBinop(op:Binop, e1:TExpr, e2:TExpr);
	TField(e:TExpr, fa:TFieldAccess);
	TTypeExpr(mt:ModuleType);
	TParenthesis(e:TExpr);
	TObjectDecl(fields:Array<TObjectField>);
	TArrayDecl(values:Array<TExpr>);
	TCall(e:TExpr, params:Array<TExpr>);
	TNew(c:TClass, params:TParams, args:Array<TExpr>);
	TUnop(op:Unop, flag:UnopFlag, e:TExpr);
	TFunction(f:TFunc);
	TVarExpr(v:TVar, ?e:TExpr);
	TBlock(exprs:Array<TExpr>);
	TFor(v:TVar, e1:TExpr, e2:TExpr);
	TIf(econd:TExpr, eif:TExpr, ?eelse:TExpr);
	TWhile(econd:TExpr, e:TExpr, flag:WhileFlag);
	TSwitch(e:TExpr, cases:Array<TSwitchCase>, ?edef:TExpr);
	TTry(e:TExpr, catches:Array<TCatch>);
	TReturn(?e:TExpr);
	TBreak;
	TContinue;
	TThrow(e:TExpr);
	TCast(e:TExpr, ?mt:ModuleType);
	TMeta(entry:MetadataEntry, e:TExpr);
	TEnumParameter(e:TExpr, ef:TEnumField, index:Int);
	TEnumIndex(e:TExpr);
	TIdent(s:String);
}

enum TFieldAccess {
	FInstance(c:TClass, params:TParams, cf:TClassField);
	FStatic(c:TClass, cf:TClassField);
	FAnon(cf:TClassField);
	FDynamic(s:String);
	FClosure(c:Null<TClassWithParams>, cf:TClassField);
	FEnum(e:TEnum, ef:TEnumField);
}

typedef TClassWithParams = {c:TClass, params:TParams};

@:structInit
class TExpr {
	public var expr:TExprExpr;
	public var type:T;
	public var pos:Position;
	public function new(expr:TExprExpr, type:T, pos:Position) {
		this.expr = expr;
		this.type = type;
		this.pos = pos;
	}
}

@:structInit
class TClassField {
	public var name:String;
	public var type:T;
	public var pos:Position;
	public var namePos:Position;
	public var doc:Documentation;
	public var meta:Metadata;
	public var kind:FieldKind;
	public var params:TypeParams;
	public var expr:Null<TExpr>;
	public var exprUnoptimized:Null<TExpr>;
	public var overloads:Array<TClassField>;
	public var flags:Int;
	public function new(name:String, type:T, pos:Position, namePos:Position, doc:Documentation,
			meta:Metadata, kind:FieldKind, params:TypeParams, expr:Null<TExpr>,
			exprUnoptimized:Null<TExpr>, overloads:Array<TClassField>, flags:Int) {
		this.name = name;
		this.type = type;
		this.pos = pos;
		this.namePos = namePos;
		this.doc = doc;
		this.meta = meta;
		this.kind = kind;
		this.params = params;
		this.expr = expr;
		this.exprUnoptimized = exprUnoptimized;
		this.overloads = overloads;
		this.flags = flags;
	}
}

enum TClassKind {
	KNormal;
	KTypeParameter(tl:Array<T>);
	KExpr(e:Expr);
	KGeneric;
	KGenericInstance(c:TClass, params:TParams);
	KMacroType;
	KGenericBuild(fields:Array<ClassField>);
	KAbstractImpl(a:TAbstract);
	KModuleFields(m:ModuleDef);
}

typedef TClassUsing = {c:TClass, pos:Position};

// The leading fields every module type shares, so any of them can be viewed as one.
@:structInit
class TInfos {
	public var path:Path;
	public var module:ModuleDef;
	public var pos:Position;
	public var namePos:Position;
	public var isPrivate:Bool;
	public var doc:Documentation;
	public var meta:Metadata;
	public var params:TypeParams;
	public var usings:Array<TClassUsing>;
	public var restore:Void->Void;
	public function new(path:Path, module:ModuleDef, pos:Position, namePos:Position, isPrivate:Bool,
			doc:Documentation, meta:Metadata, params:TypeParams, usings:Array<TClassUsing>, restore:Void->Void) {
		this.path = path;
		this.module = module;
		this.pos = pos;
		this.namePos = namePos;
		this.isPrivate = isPrivate;
		this.doc = doc;
		this.meta = meta;
		this.params = params;
		this.usings = usings;
		this.restore = restore;
	}
}

@:structInit
class TClass {
	public var path:Path;
	public var module:ModuleDef;
	public var pos:Position;
	public var namePos:Position;
	public var isPrivate:Bool;
	public var doc:Documentation;
	public var meta:Metadata;
	public var params:TypeParams;
	public var usings:Array<TClassUsing>;
	public var restore:Void->Void;
	public var kind:TClassKind;
	public var flags:Int;
	public var superClass:Null<TClassWithParams>;
	public var interfaces:Array<TClassWithParams>;
	public var fields:StringMap<TClassField>;
	public var statics:StringMap<TClassField>;
	public var orderedStatics:Array<TClassField>;
	public var orderedFields:Array<TClassField>;
	public var dynamicType:Null<T>;
	public var arrayAccess:Null<T>;
	public var constructor:Null<TClassField>;
	public var init:Null<TExpr>;
	public var build:Void->BuildState;
	public var descendants:Array<TClass>;
	public function new(path:Path, module:ModuleDef, pos:Position, namePos:Position, isPrivate:Bool,
			doc:Documentation, meta:Metadata, params:TypeParams, usings:Array<TClassUsing>, restore:Void->Void,
			kind:TClassKind, flags:Int, superClass:Null<TClassWithParams>, interfaces:Array<TClassWithParams>,
			fields:StringMap<TClassField>, statics:StringMap<TClassField>, orderedStatics:Array<TClassField>,
			orderedFields:Array<TClassField>, dynamicType:Null<T>, arrayAccess:Null<T>, constructor:Null<TClassField>,
			init:Null<TExpr>, build:Void->BuildState, descendants:Array<TClass>) {
		this.path = path;
		this.module = module;
		this.pos = pos;
		this.namePos = namePos;
		this.isPrivate = isPrivate;
		this.doc = doc;
		this.meta = meta;
		this.params = params;
		this.usings = usings;
		this.restore = restore;
		this.kind = kind;
		this.flags = flags;
		this.superClass = superClass;
		this.interfaces = interfaces;
		this.fields = fields;
		this.statics = statics;
		this.orderedStatics = orderedStatics;
		this.orderedFields = orderedFields;
		this.dynamicType = dynamicType;
		this.arrayAccess = arrayAccess;
		this.constructor = constructor;
		this.init = init;
		this.build = build;
		this.descendants = descendants;
	}
}

@:structInit
class TEnumField {
	public var name:String;
	public var type:T;
	public var pos:Position;
	public var namePos:Position;
	public var doc:Documentation;
	public var index:Int;
	public var params:TypeParams;
	public var meta:Metadata;
	public function new(name:String, type:T, pos:Position, namePos:Position, doc:Documentation,
			index:Int, params:TypeParams, meta:Metadata) {
		this.name = name;
		this.type = type;
		this.pos = pos;
		this.namePos = namePos;
		this.doc = doc;
		this.index = index;
		this.params = params;
		this.meta = meta;
	}
}

@:structInit
class TEnum {
	public var path:Path;
	public var module:ModuleDef;
	public var pos:Position;
	public var namePos:Position;
	public var isPrivate:Bool;
	public var doc:Documentation;
	public var meta:Metadata;
	public var params:TypeParams;
	public var usings:Array<TClassUsing>;
	public var restore:Void->Void;
	public var type:TDef;
	public var isExtern:Bool;
	public var constrs:StringMap<TEnumField>;
	public var names:Array<String>;
	public function new(path:Path, module:ModuleDef, pos:Position, namePos:Position, isPrivate:Bool,
			doc:Documentation, meta:Metadata, params:TypeParams, usings:Array<TClassUsing>, restore:Void->Void,
			type:TDef, isExtern:Bool, constrs:StringMap<TEnumField>, names:Array<String>) {
		this.path = path;
		this.module = module;
		this.pos = pos;
		this.namePos = namePos;
		this.isPrivate = isPrivate;
		this.doc = doc;
		this.meta = meta;
		this.params = params;
		this.usings = usings;
		this.restore = restore;
		this.type = type;
		this.isExtern = isExtern;
		this.constrs = constrs;
		this.names = names;
	}
}

@:structInit
class TDef {
	public var path:Path;
	public var module:ModuleDef;
	public var pos:Position;
	public var namePos:Position;
	public var isPrivate:Bool;
	public var doc:Documentation;
	public var meta:Metadata;
	public var params:TypeParams;
	public var usings:Array<TClassUsing>;
	public var restore:Void->Void;
	public var type:T;
	public function new(path:Path, module:ModuleDef, pos:Position, namePos:Position, isPrivate:Bool,
			doc:Documentation, meta:Metadata, params:TypeParams, usings:Array<TClassUsing>, restore:Void->Void, type:T) {
		this.path = path;
		this.module = module;
		this.pos = pos;
		this.namePos = namePos;
		this.isPrivate = isPrivate;
		this.doc = doc;
		this.meta = meta;
		this.params = params;
		this.usings = usings;
		this.restore = restore;
		this.type = type;
	}
}

typedef TAbstractOp = {op:Binop, cf:TClassField};
typedef TAbstractUnop = {op:Unop, flag:UnopFlag, cf:TClassField};
typedef TAbstractCast = {t:T, cf:TClassField};

@:structInit
class TAbstract {
	public var path:Path;
	public var module:ModuleDef;
	public var pos:Position;
	public var namePos:Position;
	public var isPrivate:Bool;
	public var doc:Documentation;
	public var meta:Metadata;
	public var params:TypeParams;
	public var usings:Array<TClassUsing>;
	public var restore:Void->Void;
	public var ops:Array<TAbstractOp>;
	public var unops:Array<TAbstractUnop>;
	public var impl:Null<TClass>;
	public var thisType:T;
	public var from:Array<T>;
	public var fromField:Array<TAbstractCast>;
	public var to:Array<T>;
	public var toField:Array<TAbstractCast>;
	public var array:Array<TClassField>;
	public var read:Null<TClassField>;
	public var write:Null<TClassField>;
	public var call:Null<TClassField>;
	public var isEnum:Bool;
	public function new(path:Path, module:ModuleDef, pos:Position, namePos:Position, isPrivate:Bool,
			doc:Documentation, meta:Metadata, params:TypeParams, usings:Array<TClassUsing>, restore:Void->Void,
			ops:Array<TAbstractOp>, unops:Array<TAbstractUnop>, impl:Null<TClass>, thisType:T, from:Array<T>,
			fromField:Array<TAbstractCast>, to:Array<T>, toField:Array<TAbstractCast>, array:Array<TClassField>,
			read:Null<TClassField>, write:Null<TClassField>, call:Null<TClassField>, isEnum:Bool) {
		this.path = path;
		this.module = module;
		this.pos = pos;
		this.namePos = namePos;
		this.isPrivate = isPrivate;
		this.doc = doc;
		this.meta = meta;
		this.params = params;
		this.usings = usings;
		this.restore = restore;
		this.ops = ops;
		this.unops = unops;
		this.impl = impl;
		this.thisType = thisType;
		this.from = from;
		this.fromField = fromField;
		this.to = to;
		this.toField = toField;
		this.array = array;
		this.read = read;
		this.write = write;
		this.call = call;
		this.isEnum = isEnum;
	}
}

enum ModuleType {
	TClassDecl(c:TClass);
	TEnumDecl(e:TEnum);
	TTypeDecl(d:TDef);
	TAbstractDecl(a:TAbstract);
}

@:structInit
class ModuleDef {
	public var id:Int;
	public var path:Path;
	public var types:Array<ModuleType>;
	public var statics:Null<TClass>;
	public var extra:ModuleDefExtra;
	public function new(id:Int, path:Path, types:Array<ModuleType>, statics:Null<TClass>, extra:ModuleDefExtra) {
		this.id = id;
		this.path = path;
		this.types = types;
		this.statics = statics;
		this.extra = extra;
	}
}

@:structInit
class ModuleDefDisplay {
	public var inlineCalls:Array<{p1:Position, p2:Position}>;
	public var typeHints:Array<{p1:Position, p2:Position}>;
	// importPositions: one entry per import declaration of this module, with the flag set when the
	// import is used. It lives on the module, so a module served back from the cache still reports its
	// unused imports (the diagnostics walk every module). hxc records a position before resolving
	// anything, so the entry also carries whether the import failed to load, and a failed entry counts
	// as never registered.
	public var importPositions:Array<{p:Position, used:Bool, ?failed:Bool}>;
	public function new(inlineCalls:Array<{p1:Position, p2:Position}>, typeHints:Array<{p1:Position, p2:Position}>,
			importPositions:Array<{p:Position, used:Bool, ?failed:Bool}>) {
		this.inlineCalls = inlineCalls;
		this.typeHints = typeHints;
		this.importPositions = importPositions;
	}
}

typedef MIfFeature = {name:String, cls:TClass, cf:TClassField, b:Bool};

@:structInit
class ModuleDefExtra {
	public var file:String;
	public var sign:String;
	public var display:ModuleDefDisplay;
	public var checkPolicy:Array<ModuleCheckPolicy>;
	public var time:Float;
	public var cacheState:ModuleCacheState;
	public var added:Int;
	public var checked:Int;
	public var processed:Int;
	// The resolveModule idempotence gate (0 = unresolved, 1 = resolved, 2 = synthesized module, never
	// resolve). Distinct from processed: the compilation step of the module's last class-state save (the
	// server cache-validity mark).
	public var resolved:Int = 0;
	public var deps:Map<Int, ModuleDef>;
	public var kind:ModuleKind;
	public var bindedRes:StringMap<String>;
	public var ifFeature:Array<MIfFeature>;
	public var features:StringMap<Bool>;
	public function new(file:String, sign:String, display:ModuleDefDisplay, checkPolicy:Array<ModuleCheckPolicy>,
			time:Float, cacheState:ModuleCacheState, added:Int, checked:Int, processed:Int,
			deps:Map<Int, ModuleDef>, kind:ModuleKind, bindedRes:StringMap<String>, ifFeature:Array<MIfFeature>,
			features:StringMap<Bool>) {
		this.file = file;
		this.sign = sign;
		this.display = display;
		this.checkPolicy = checkPolicy;
		this.time = time;
		this.cacheState = cacheState;
		this.added = added;
		this.checked = checked;
		this.processed = processed;
		this.deps = deps;
		this.kind = kind;
		this.bindedRes = bindedRes;
		this.ifFeature = ifFeature;
		this.features = features;
	}
}

enum ModuleKind {
	MCode;
	MMacro;
	MFake;
	MExtern;
	MImport;
}

enum BuildState {
	Built;
	Building(cl:Array<TClass>);
	BuildMacro(fns:Ref<Array<Void->Void>>);
}

@:structInit
class BasicTypes {
	public var tvoid:T;
	public var tint:T;
	public var tfloat:T;
	public var tbool:T;
	public var tnull:T->T;
	public var tstring:T;
	public var tarray:T->T;
	public function new(tvoid:T, tint:T, tfloat:T, tbool:T, tnull:T->T, tstring:T, tarray:T->T) {
		this.tvoid = tvoid;
		this.tint = tint;
		this.tfloat = tfloat;
		this.tbool = tbool;
		this.tnull = tnull;
		this.tstring = tstring;
		this.tarray = tarray;
	}
}

enum ClassFieldScope {
	CFSStatic;
	CFSMember;
	CFSConstructor;
}

enum FlagTClass {
	CExtern;
	CFinal;
	CInterface;
	CAbstract;
	CFunctionalInterface;
}

enum FlagTClassField {
	CfPublic;
	CfStatic;
	CfExtern;            // Set only if the field itself is extern, not just the class
	CfFinal;
	CfModifiesThis;      // Set for methods which reassign `this` (e.g. `this = value`)
	CfOverride;
	CfAbstract;
	CfOverload;
	CfImpl;
	CfEnum;
	CfGeneric;
	CfDefault;           // Interface field with default implementation (only valid on Java)
	CfPostProcessed;     // Marker that the field has been post-processed
	CfNoLookup;          // Field cannot be accessed by-name
}

enum FlagTVar {
	VCaptured;
	VFinal;
	VAnalyzed;
	VAssigned;
	VCaught;
	VStatic;
	VUsedByTyper;        // Set if the typer looked up this variable
}

class Flags {
	public static inline function hasFlag(flags:Int, bit:Int):Bool {
		return (flags & (1 << bit)) != 0;
	}
	public static inline function setFlag(flags:Int, bit:Int):Int {
		return flags | (1 << bit);
	}
	public static inline function unsetFlag(flags:Int, bit:Int):Int {
		return flags & ~(1 << bit);
	}
	public static final flagTClassFieldNames:Array<String> = [
		"CfPublic", "CfStatic", "CfExtern", "CfFinal", "CfModifiesThis", "CfOverride",
		"CfAbstract", "CfOverload", "CfImpl", "CfEnum", "CfGeneric", "CfDefault", "CfNoLookup"
	];
	public static final flagTVarNames:Array<String> = [
		"VCaptured", "VFinal", "VAnalyzed", "VAssigned", "VCaught", "VStatic", "VUsedByTyper"
	];
}
