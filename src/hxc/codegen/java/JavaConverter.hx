package hxc.codegen.java;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Globals;
import hxc.core.Globals.Path;
import hxc.codegen.java.JData;
import hxc.codegen.java.JData.AccessFlags as AF;
import hxc.codegen.java.JClassReader;

// the java class model turned into declarations the typer can load.

typedef HxName = {mname:Null<String>, name:String};

// The map is COPIED when a field adds its own parameters, so one method's type parameters cannot leak into
// the next.
typedef JavaLibCtx = {typeParams:Map<String, ComplexType>};

class PathConverter {
	public static function jnameToHx(name:String):HxName {
		if (name != "") {
			var c = name.charCodeAt(0);
			if (c < "A".code || c > "Z".code)
				name = name.charAt(0).toUpperCase() + name.substr(1);
		}
		name = name.split("_").join("__");
		var parts = name.split("$");
		if (parts.length == 1) return {mname: null, name: name};
		if (parts.length == 2 && parts[1] == "") return {mname: null, name: parts[0] + "_"}; // trailing $
		var joined = parts.join("_");
		if (parts[0] == "") return {mname: null, name: joined}; // leading $
		return {mname: parts[0], name: joined};
	}

	public static function normalizePack(pack:Array<String>):Array<String> {
		return [
			for (str in pack) {
				if (str == "") ""
				else if (str.charCodeAt(0) >= "A".code && str.charCodeAt(0) <= "Z".code) str.toLowerCase()
				else str;
			}
		];
	}

	public static function jpathToHx(path:Path):{pack:Array<String>, name:HxName} {
		var pack = path.pack;
		var name = path.name;
		if (pack.length == 2 && pack[0] == "haxe" && pack[1] == "root") {
			pack = [];
		} else if (isReservedVendorPack(pack)) {
			pack = ["java"].concat(pack);
		}
		return {pack: normalizePack(pack), name: jnameToHx(name)};
	}

	// the vendor trees move under java to keep the toplevel clean.
	static function isReservedVendorPack(pack:Array<String>):Bool {
		if (pack.length == 0) return false;
		return switch (pack[0]) {
			case "com": pack.length > 1 && (pack[1] == "oracle" || pack[1] == "sun");
			case "javax": true;
			case "org": pack.length > 1 && (pack[1] == "ietf" || pack[1] == "jcp" || pack[1] == "omg"
				|| pack[1] == "w3c" || pack[1] == "xml");
			case "sun" | "sunw": true;
			case _: false;
		}
	}

	public static function jpathToPath(pack:Array<String>, name:HxName):Path {
		return name.mname == null ? new Path(pack, name.name) : new Path(pack.concat([name.mname]), name.name);
	}

	public static function isHaxeKeyword(s:String):Bool {
		return switch (s) {
			case "cast" | "extern" | "function" | "in" | "typedef" | "using" | "var" | "untyped" | "inline": true;
			case _: false;
		}
	}
}

class SignatureConverter {
	public static function mkTypePath(path:Path, params:Array<TypeParamOrConst>):ComplexType {
		var r = PathConverter.jpathToHx(path);
		if (r.name.mname == null)
			return CTPath({tpackage: r.pack, tname: r.name.name, tparams: params, tsub: null});
		return CTPath({tpackage: r.pack, tname: r.name.mname, tparams: params, tsub: r.name.name});
	}

	static inline function ct(name:String):ComplexType {
		return CTPath({tpackage: [], tname: name, tparams: [], tsub: null});
	}

	public static function ctTypeParam(name:String):ComplexType return ct(name);
	public static function ctVoid():ComplexType return ct("Void");
	public static function ctDynamic():ComplexType return ct("Dynamic");
	public static function ctString():ComplexType return ct("String");

	public static function convertArg(ctx:JavaLibCtx, p:Position, arg:JTypeArgument):TypeParamOrConst {
		return switch (arg) {
			case TAny | TType(WSuper, _):
				TPType({ct: mkTypePath(new Path([], "Dynamic"), []), pos: p});
			case TType(_, jsig):
				TPType({ct: convertSignature(ctx, p, jsig), pos: p});
		}
	}

	public static function convertSignature(ctx:JavaLibCtx, p:Position, jsig:JSignature):ComplexType {
		function args(l:Array<JTypeArgument>):Array<TypeParamOrConst> return [for (a in l) convertArg(ctx, p, a)];
		return switch (jsig) {
			case TByte: mkTypePath(new Path(["java", "types"], "Int8"), []);
			case TChar: mkTypePath(new Path(["java", "types"], "Char16"), []);
			case TDouble: mkTypePath(new Path([], "Float"), []);
			case TFloat: mkTypePath(new Path([], "Single"), []);
			case TInt: mkTypePath(new Path([], "Int"), []);
			case TLong: mkTypePath(new Path(["haxe"], "Int64"), []);
			case TShort: mkTypePath(new Path(["java", "types"], "Int16"), []);
			case TBool: mkTypePath(new Path([], "Bool"), []);
			case TObject(path, params) if (path.pack.length == 2 && path.pack[0] == "haxe" && path.pack[1] == "root"):
				mkTypePath(new Path([], path.name), args(params));
			case TObject(path, []) if (isJavaLang(path, "Object")):
				mkTypePath(new Path([], "Dynamic"), []);
			case TObject(path, []) if (isJavaLang(path, "String")):
				mkTypePath(new Path([], "String"), []);
			case TObject(path, params) if (params.length == 1 && isJavaLang(path, "Enum")):
				mkTypePath(new Path([], "EnumValue"), []);
			case TObject(path, params):
				mkTypePath(path, params.length == 0 ? [] : args(params));
			case TObjectInner(pack, inners) if (inners.length > 0):
				// The parameters of the LAST inner name are the ones that survive.
				var actualParam = inners[inners.length - 1].params;
				var head = inners[0];
				var rest = inners.slice(1);
				var name = head.name + "$" + [for (i in rest) i.name].join("$");
				mkTypePath(new Path(pack, name), [for (param in actualParam) convertArg(ctx, p, param)]);
			case TObjectInner(_, _):
				throw "TObjectInner without names";
			case TArray(jsig1, _):
				mkTypePath(new Path(["java"], "NativeArray"), [TPType({ct: convertSignature(ctx, p, jsig1), pos: p})]);
			case TMethod(_):
				throw "TMethod cannot be converted directly into Complex Type";
			case TTypeParameter(s):
				var t = ctx.typeParams.get(s);
				t == null ? ctDynamic() : t;
		}
	}

	static inline function isJavaLang(path:Path, name:String):Bool {
		return path.name == name && path.pack.length == 2 && path.pack[0] == "java" && path.pack[1] == "lang";
	}
}

class Converter {
	static function getTypePath(ct:ComplexType):TypePath {
		return switch (ct) {
			case CTPath(p): p;
			case _: throw "Expected a type path";
		}
	}

	public static function convertTypeParameter(ctx:JavaLibCtx, tp:JTypeParam, p:Position):TypeParam {
		var jsigs = tp.ext != null ? [tp.ext].concat(tp.ifaces) : tp.ifaces;
		var constraints:Array<TypeHint> = [];
		for (jsig in jsigs) switch (jsig) {
			// A parameter constrained by itself carries no information.
			case TTypeParameter(n) if (n == tp.name):
			case _:
				constraints.push({ct: SignatureConverter.convertSignature(ctx, p, jsig), pos: p});
		}
		return {
			tpName: {name: tp.name, pos: p},
			tpParams: [],
			tpMeta: [],
			tpDefault: null,
			tpConstraints: constraints.length == 0 ? null : {ct: CTIntersection(constraints), pos: p}
		};
	}

	static function mkPos(file:String):Position return new Position(file, 0, 0);

	static function nativeMeta(s:String, p:Position):MetadataEntry {
		return {name: ":native", params: [new Expr(EConst(CString(s, SDoubleQuotes)), p)], pos: p};
	}

	public static function convertEnum(jc:JClass, file:String):TypeDecl {
		var p = mkPos(file);
		var meta:Metadata = [];
		var data:Array<EnumConstructor> = [];
		for (jf in jc.jcFields) switch (jf.jfDescriptor) {
			case TObject(path, []) if (samePath(path, jc.jcPath) && AF.hasFlag(jf.jfFlags, AF.MStatic)
					&& AF.hasFlag(jf.jfFlags, AF.MFinal)):
				data.push({
					ecName: {name: jf.jfName, pos: p}, ecDoc: null, ecMeta: [], ecArgs: [],
					ecPos: p, ecParams: [], ecType: null
				});
			case _:
		}
		var className = PathConverter.jnameToHx(jc.jcPath.name).name;
		meta.unshift(nativeMeta(Globals.sTypePath(jc.jcPath), p));
		var d:Definition<EnumFlag, Array<EnumConstructor>> = {
			dName: {name: className, pos: p},
			dDoc: null,
			dParams: [], // enums never have type parameters
			dMeta: meta,
			dFlags: [EExtern],
			dData: data
		};
		return {decl: EEnum(d), pos: p};
	}

	static inline function samePath(a:Path, b:Path):Bool {
		return a.name == b.name && a.pack.join(".") == b.pack.join(".");
	}

	// Returns a COPY so the caller's map is untouched.
	public static function typeParamLut(acc:Map<String, ComplexType>, params:JTypes):Map<String, ComplexType> {
		var out = acc.copy();
		for (tp in params) out.set(tp.name, SignatureConverter.ctTypeParam(tp.name));
		return out;
	}

	// haxe.Rest<T> boxes primitives, so an int vararg would become java.lang.Integer[] instead of int[].
	static function isEligibleForHaxeRestArgs(argType:JSignature):Bool {
		return switch (argType) {
			case TByte | TChar | TDouble | TFloat | TInt | TLong | TShort | TBool: false;
			case _: true;
		}
	}

	public static function convertField(ctx:JavaLibCtx, isMethod:Bool, jc:JClass, isInterface:Bool, jf:JField, p:Position):ClassField {
		ctx = {typeParams: typeParamLut(ctx.typeParams, jf.jfTypes)};
		p = new Position(p.file + "@" + jf.jfName, p.min, p.max);
		var isStatic = AF.hasFlag(jf.jfFlags, AF.MStatic);
		var access:Array<PlacedAccess> = [];
		var meta:Metadata = [];
		inline function addAccess(a:Access, ap:Position) access.unshift({access: a, pos: ap});
		if (isStatic) addAccess(AStatic, p);
		for (attr in jf.jfAttributes) switch (attr) {
			case AttrDeprecated if (!(jc.jcPath.name == "Date" && jc.jcPath.pack.join(".") == "java.util")):
				meta.unshift({name: ":deprecated", params: [], pos: p});
			case AttrVisibleAnnotations(anns):
				for (ann in anns) switch (ann.annType) {
					case TObject(path, []) if (path.name == "Override" && path.pack.join(".") == "java.lang"):
						addAccess(AOverride, Position.nullPos);
					case _:
				}
			case AttrCode(_) if (isInterface):
				meta.unshift({name: ":java.default", params: [], pos: p});
			case _:
		}
		inline function addNativeMeta() meta.unshift(nativeMeta(jf.jfName, p));
		var parts = jf.jfName.split("$");
		var name = if (parts.length == 1) {
			if (parts[0] == "<init>") "new";
			else if (PathConverter.isHaxeKeyword(parts[0])) { addNativeMeta(); "_" + parts[0]; }
			else parts[0];
		} else {
			addNativeMeta();
			parts.join("_");
		}
		if (isMethod) addAccess(AOverload, p);
		if (AF.hasFlag(jf.jfFlags, AF.MFinal)) addAccess(AFinal, p);
		if (!isInterface && AF.hasFlag(jf.jfFlags, AF.MAbstract)) addAccess(AAbstract, p);
		var kind:ClassFieldKind = if (!isMethod) {
			FVar({ct: SignatureConverter.convertSignature(ctx, p, jf.jfDescriptor), pos: p}, null);
		} else switch (jf.jfDescriptor) {
			case TMethod(m):
				var localNames = extractLocalNames(jf, isStatic);
				var argsCount = m.args.length;
				var isVarargs = AF.hasFlag(jf.jfFlags, AF.MVarargs);
				var fargs:Array<FunctionArg> = [];
				for (i in 0...m.args.length) {
					var jsig = m.args[i];
					var aname = localNames(i + 1);
					var hxSig = switch (jsig) {
						case TArray(jsig1, _) if (isVarargs && i + 1 == argsCount && isEligibleForHaxeRestArgs(jsig1)):
							SignatureConverter.mkTypePath(new Path(["haxe"], "Rest"),
								[TPType({ct: SignatureConverter.convertSignature(ctx, p, jsig1), pos: p})]);
						case _:
							SignatureConverter.convertSignature(ctx, p, jsig);
					};
					fargs.push({name: {name: aname, pos: p}, opt: false, meta: [], type: {ct: hxSig, pos: p}, value: null});
				}
				FFun({
					fParams: [for (tp in jf.jfTypes) convertTypeParameter(ctx, tp, p)],
					fArgs: fargs,
					fType: m.ret == null
						? {ct: SignatureConverter.ctVoid(), pos: p}
						: {ct: SignatureConverter.convertSignature(ctx, p, m.ret), pos: p},
					fExpr: null
				});
			case _:
				throw "Expected a method signature";
		}
		return new ClassField({name: name, pos: p}, null, p, meta, access, kind);
	}

	// the local variable table names the arguments; without one the method parameters attribute does, and
	// failing both they are param1..paramN.
	static function extractLocalNames(jf:JField, isStatic:Bool):Int->String {
		function def(i:Int):String return "param" + i;
		function loop(attribs:Array<JAttribute>):Null<Array<{index:Int, name:String}>> {
			for (attr in attribs) switch (attr) {
				case AttrLocalVariableTable(locals):
					var shift = isStatic ? 0 : -1;
					return [for (loc in locals) {index: loc.ldIndex + shift, name: loc.ldName}];
				case AttrMethodParameters(l):
					return [for (i in 0...l.length) {index: i, name: l[i].name}];
				case _:
			}
			return null;
		}
		function use(locals:Array<{index:Int, name:String}>):Int->String {
			var h = new Map<Int, String>();
			for (l in locals) h.set(l.index, l.name);
			return function(i:Int):String {
				// The table is 1-based against the argument list.
				var n = h.get(i - 1);
				return n == null ? "param" + i : n;
			};
		}
		var found = loop(jf.jfAttributes);
		if (found != null) return use(found);
		if (jf.jfCode == null) return def;
		found = loop(jf.jfCode);
		return found == null ? def : use(found);
	}

	public static function convertClass(ctx:JavaLibCtx, jc:JClass, file:String):TypeDecl {
		var p = mkPos(file);
		var flags:Array<ClassFlag> = [HExtern];
		var meta:Metadata = [];
		inline function addFlag(f:ClassFlag) flags.unshift(f);
		meta.unshift({name: ":libType", params: [], pos: p});
		var isInterface = AF.hasFlag(jc.jcFlags, AF.MInterface);
		if (isInterface) addFlag(HInterface);
		else if (AF.hasFlag(jc.jcFlags, AF.MAbstract)) addFlag(HAbstract);
		switch (jc.jcSuper) {
			case TObject(path, _) if (path.name == "" && path.pack.length == 0):
			case TObject(path, _) if (path.name == "Object" && path.pack.join(".") == "java.lang"):
			case jsig:
				addFlag(HExtends({path: getTypePath(SignatureConverter.convertSignature(ctx, p, jsig)), pos: p}));
		}
		for (jsig in jc.jcInterfaces) {
			var path = {path: getTypePath(SignatureConverter.convertSignature(ctx, p, jsig)), pos: p};
			addFlag(isInterface ? HExtends(path) : HImplements(path));
		}
		var fields:Array<ClassField> = [];
		var knownNames = new Map<String, Bool>();
		var knownSigs = new Map<String, Bool>();
		function shouldGenerate(jf:JField):Bool {
			return !AF.hasFlag(jf.jfFlags, AF.MPrivate)
				// Member synthetics can be needed for call resolution, static ones never are.
				&& (!AF.hasFlag(jf.jfFlags, AF.MSynthetic) || !AF.hasFlag(jf.jfFlags, AF.MStatic))
				&& jf.jfName != "<clinit>";
		}
		if (!(jc.jcPath.name == "CharSequence" && jc.jcPath.pack.join(".") == "java.lang")) {
			for (jf in jc.jcMethods) {
				if (!shouldGenerate(jf)) continue;
				knownNames.set(jf.jfName, true);
				// The return type is dropped from the key: java has no return type variance.
				var sigKey = switch (jf.jfDescriptor) {
					case TMethod(m): sSig(TMethod({args: m.args, ret: null}));
					case jsig: sSig(jsig);
				};
				var key = jf.jfName + " " + sigKey;
				if (!knownSigs.exists(key)) {
					knownSigs.set(key, true);
					fields.push(convertField(ctx, true, jc, isInterface, jf, p));
				}
			}
			for (jf in jc.jcFields) {
				if (!shouldGenerate(jf)) continue;
				if (!knownNames.exists(jf.jfName)) {
					knownNames.set(jf.jfName, true);
					fields.push(convertField(ctx, false, jc, isInterface, jf, p));
				}
			}
		}
		var className = PathConverter.jnameToHx(jc.jcPath.name).name;
		meta.unshift(nativeMeta(Globals.sTypePath(jc.jcPath), p));
		var d:Definition<ClassFlag, Array<ClassField>> = {
			dName: {name: className, pos: p},
			dDoc: null,
			dParams: [for (tp in jc.jcTypes) convertTypeParameter(ctx, tp, p)],
			dMeta: meta,
			dFlags: flags,
			dData: fields
		};
		return {decl: EClass(d), pos: p};
	}

	static function sSig(jsig:JSignature):String {
		return switch (jsig) {
			case TByte: "B"; case TChar: "C"; case TDouble: "D"; case TFloat: "F";
			case TInt: "I"; case TLong: "J"; case TShort: "S"; case TBool: "Z";
			case TObject(path, params): "L" + Globals.sTypePath(path) + sArgs(params) + ";";
			case TObjectInner(pack, inners):
				"L" + pack.join("/") + "|" + [for (i in inners) i.name + sArgs(i.params)].join("$") + ";";
			case TArray(s, size): "[" + (size == null ? "" : Std.string(size)) + sSig(s);
			case TMethod(m): "(" + [for (a in m.args) sSig(a)].join("") + ")" + (m.ret == null ? "V" : sSig(m.ret));
			case TTypeParameter(n): "T" + n + ";";
		}
	}

	static function sArgs(params:Array<JTypeArgument>):String {
		if (params.length == 0) return "";
		return "<" + [
			for (a in params) switch (a) {
				case TAny: "*";
				case TType(w, s): (switch (w) { case WExtends: "+"; case WSuper: "-"; case WNone: ""; }) + sSig(s);
			}
		].join("") + ">";
	}

	public static function convertType(ctx:JavaLibCtx, jc:JClass, file:String):TypeDecl {
		return AF.hasFlag(jc.jcFlags, AF.MEnum) ? convertEnum(jc, file) : convertClass(ctx, jc, file);
	}

	public static function convertModule(pack:Array<String>, jcs:Array<{jc:JClass, file:String}>):Package {
		var types = [
			for (e in jcs) {
				var ctx:JavaLibCtx = {typeParams: typeParamLut(new Map(), e.jc.jcTypes)};
				convertType(ctx, e.jc, e.file);
			}
		];
		return {pack: pack, decls: types};
	}
}
