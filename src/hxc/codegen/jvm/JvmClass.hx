package hxc.codegen.jvm;

import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmData;
import hxc.codegen.jvm.JvmSignature;
import hxc.codegen.jvm.JvmAttribute;
import hxc.codegen.jvm.JvmBuilder;
import hxc.codegen.jvm.JvmMethod;

// the class being assembled. Methods and fields are spawned from it and exported when the class is.

class ClassBuilder extends BaseBuilder {
	var pool:JvmConstantPool = new JvmConstantPool();
	var pathThis:JPath;
	var pathSuper:JPath;
	var jsig:JSignature;
	var offsetThis = 0;
	var offsetSuper = 0;
	var typeParameters:Array<{name:String, constraints:Array<JSignature>}> = [];
	var superTypeParameters:Array<JTypeArgument> = [];
	var interfaces:Array<{path:JPath, params:Array<JTypeArgument>}> = [];
	var interfaceOffsets:Array<Int> = [];
	var fields:Array<JvmFieldData> = [];
	var methods:Array<JvmFieldData> = [];
	var methodSigs:Map<String, MethodBuilder> = new Map();
	var innerClasses:Map<Int, ClassBuilder> = new Map();
	var closureIdsPerName:Map<String, Int> = new Map();
	var spawnedMethods:Array<{jm:MethodBuilder, popScope:Null<Void->Void>}> = [];
	var staticInitMethod:Null<MethodBuilder> = null;
	var sourceFile:Null<String> = null;

	public function new(pathThis:JPath, pathSuper:JPath) {
		super();
		this.pathThis = pathThis;
		this.pathSuper = pathSuper;
		this.jsig = TObject(pathThis, []);
		offsetThis = pool.addPath(pathThis);
		offsetSuper = pool.addPath(pathSuper);
	}

	public function addInterface(path:JPath, params:Array<JTypeArgument>):Void {
		interfaceOffsets.unshift(pool.addPath(path));
		interfaces.unshift({path: path, params: params});
	}

	public function setTypeParameters(sl:Array<{name:String, constraints:Array<JSignature>}>):Void {
		typeParameters = sl;
	}

	public function setSuperParameters(params:Array<JTypeArgument>):Void {
		superTypeParameters = params;
	}

	public function addField(f:JvmFieldData):Void fields.push(f);

	public function getPool():JvmConstantPool return pool;
	public function getThisPath():JPath return pathThis;
	public function getSuperPath():JPath return pathSuper;
	public function getJsig():JSignature return jsig;
	public function getOffsetThis():Int return offsetThis;
	public function getAccessFlags():Int return accessFlags;

	public function setSourceFile(file:String):Void sourceFile = file;

	public function getStaticInitMethod():MethodBuilder {
		if (staticInitMethod == null)
			staticInitMethod = spawnMethod("<clinit>", NativeSignatures.methodSig([], null), [MethodAccessFlags.MStatic]);
		return staticInitMethod;
	}

	public function hasMethod(name:String, jsig:JSignature):Bool {
		return methodSigs.exists(name + " " + JvmSignature.generateMethodSignature(false, jsig));
	}

	public function getNextClosureId(name:String):Int {
		var r = closureIdsPerName.get(name);
		if (r == null) {
			closureIdsPerName.set(name, 0);
			return 0;
		}
		r++;
		closureIdsPerName.set(name, r);
		return r;
	}

	// an unnamed inner class is numbered by how many there already are.
	public function spawnInnerClass(jm:Null<MethodBuilder>, pathSuper:JPath, name:Null<String>):ClassBuilder {
		var path:JPath = name == null
			? {pack: pathThis.pack, name: pathThis.name + "$" + Lambda.count(innerClasses)}
			: {pack: pathThis.pack, name: pathThis.name + "$" + name};
		var jc = new ClassBuilder(path, pathSuper);
		jc.addAccessFlag(0x01);
		if (jm != null) {
			var p = jc.getPool();
			var offsetClass = p.addPath(pathThis);
			var offsetName = p.addString(jm.getName());
			var offsetDesc = p.addString(JvmSignature.generateSignature(false, jm.getJsig()));
			var offsetInfo = p.add(ConstNameAndType(offsetName, offsetDesc));
			jc.addAttribute(AttributeEnclosingMethod(offsetClass, offsetInfo));
		}
		innerClasses.set(pool.addPath(path), jc);
		if (sourceFile != null) jc.setSourceFile(sourceFile);
		return jc;
	}

	// a non-static method declares `this` as its first local, uninitialized while the constructor has not
	// called its super yet.
	public function spawnMethod(name:String, jsigMethod:JSignature, flags:Array<Int>):MethodBuilder {
		var jm = new MethodBuilder(this, name, jsigMethod);
		var ssigMethod = JvmSignature.generateMethodSignature(false, jsigMethod);
		var key = name + " " + ssigMethod;
		if (methodSigs.exists(key))
			JvmGlobals.jerror("Duplicate field on class " + sPath(pathThis) + ": " + name + " " + ssigMethod);
		methodSigs.set(key, jm);
		for (flag in flags) jm.addAccessFlag(flag);
		var popScope = jm.pushScope();
		if (!jm.hasMethodFlag(MethodAccessFlags.MStatic))
			jm.addLocal("this", jm.getName() == "<init>" ? TUninitialized(null) : jsig, VarArgument);
		spawnedMethods.unshift({jm: jm, popScope: popScope});
		return jm;
	}

	public function spawnField(name:String, jsigMethod:JSignature, flags:Array<Int>):MethodBuilder {
		var jm = new MethodBuilder(this, name, jsigMethod);
		for (flag in flags) jm.addAccessFlag(flag);
		spawnedMethods.unshift({jm: jm, popScope: null});
		return jm;
	}

	static function sPath(p:JPath):String {
		return p.pack.length == 0 ? p.name : p.pack.join(".") + "." + p.name;
	}

	function commitInnerClasses():Void {
		var inner = pool.getInnerClasses();
		// The entries follow the reversed hash-table bucket order of the pool's inner-class table, not
		// insertion order. The order reaches beyond this attribute: committing an entry INTERNS its name,
		// so it also decides the layout of the constant pool.
		var keys = pool.getInnerClassOrder();
		keys.reverse();
		if (keys.length == 0) return;
		var l:Array<JvmInnerClass> = [];
		for (k in keys) {
			var e = inner.get(k);
			var offsetName = pool.addString(e.name);
			var jc = innerClasses.get(e.offset);
			var flags = jc == null ? 9 : jc.getAccessFlags();
			l.push({
				icInnerClassInfoIndex: e.offset,
				icOuterClassInfoIndex: pool.addPath(e.outer),
				icInnerNameIndex: offsetName,
				icInnerClassAccessFlags: flags
			});
		}
		addAttribute(AttributeInnerClasses(l));
	}

	// the generic signature of the class itself, written in full form.
	function generateSignatureAttribute():Void {
		var stl = if (typeParameters.length == 0) "" else {
			var parts = [
				for (tp in typeParameters) {
					var jsigs = tp.constraints.length == 0 ? [NativeSignatures.objectSig] : tp.constraints;
					tp.name + [for (js in jsigs) ":" + JvmSignature.generateSignature(true, js)].join("");
				}
			];
			"<" + parts.join("") + ">";
		};
		var ssuper = JvmSignature.generateMethodSignature(true, TObject(pathSuper, superTypeParameters));
		var sinterfaces = [
			for (i in interfaces) JvmSignature.generateMethodSignature(true, TObject(i.path, i.params))
		].join("");
		addAttribute(AttributeSignature(pool.addString(stl + ssuper + sinterfaces)));
	}

	public function exportClass(config:ExportConfig):JvmClassData {
		if (wasExported) JvmGlobals.jerror("class was already exported");
		if (sourceFile != null) addAttribute(AttributeSourceFile(pool.addString(sourceFile)));
		if (staticInitMethod != null && !staticInitMethod.isTerminated()) staticInitMethod.returnOp();
		generateSignatureAttribute();
		wasExported = true;
		var spawned = spawnedMethods.copy();
		spawned.reverse();
		for (e in spawned) {
			if (e.popScope != null) {
				e.popScope();
				methods.push(e.jm.exportMethod(config));
			} else
				addField(e.jm.exportField());
		}
		commitInnerClasses();
		commitAnnotations(pool);
		var attributes = exportAttributes(pool);
		return {
			classMinorVersion: 0,
			classMajorVersion: 0x34,
			classConstantPool: pool.close(),
			classAccessFlags: accessFlags,
			classThisClass: offsetThis,
			classSuperClass: offsetSuper,
			classInterfaces: interfaceOffsets,
			classFields: fields,
			classMethods: methods,
			classAttributes: attributes
		};
	}
}
