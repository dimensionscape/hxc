package hxc.codegen.jvm;

import hxc.codegen.jvm.JvmGlobals;
import hxc.codegen.jvm.JvmData;
import hxc.codegen.jvm.JvmSignature;
import hxc.codegen.jvm.JvmAttribute;

// The annotation model the generator states its metadata in, and BaseBuilder: the access flags, attributes
// and annotations every builder carries.

enum AnnotationKind {
	AInt(i:Int);
	ADouble(f:Float);
	AString(s:String);
	ABool(b:Bool);
	AEnum(jsig:JSignature, name:String);
	AArray(l:Array<AnnotationKind>);
	AAnnotation(jsig:JSignature, a:Annotation);
}

typedef Annotation = Array<{name:String, kind:AnnotationKind}>;
typedef AnnotationDecl = {jsig:JSignature, a:Annotation};

typedef ExportConfig = {exportDebug:Bool};

class JvmBuilder {
	// The tag character is what the class file files each value under.
	public static function convertAnnotations(pool:JvmConstantPool, annotations:Array<AnnotationDecl>):Array<JAnnotation> {
		function processAnnotation(decl:AnnotationDecl):JAnnotation {
			var offset = pool.addString(JvmSignature.generateSignature(false, decl.jsig));
			var elements:Array<JAnnotationElement> = [];
			for (e in decl.a) {
				var nameOffset = pool.addString(e.name);
				function loop(ak:AnnotationKind):JAnnotationElementValue {
					return switch (ak) {
						case AInt(i): {tag: "I".code, value: ValConst(pool.add(ConstInt(i)))};
						case ADouble(f): {tag: "D".code, value: ValConst(pool.add(ConstDouble(f)))};
						case AString(s): {tag: "s".code, value: ValConst(pool.addString(s))};
						case ABool(b): {tag: "Z".code, value: ValConst(pool.add(ConstInt(b ? 1 : 0)))};
						case AEnum(jsig, name):
							var nameIndex = pool.addString(name);
							{tag: "e".code, value: ValEnum(pool.addString(JvmSignature.generateSignature(false, jsig)),
								nameIndex)};
						case AArray(l): {tag: "[".code, value: ValArray([for (x in l) loop(x)])};
						case AAnnotation(jsig, a): {tag: "@".code, value: ValAnnotation(processAnnotation({jsig: jsig, a: a}))};
					}
				}
				elements.push({index: nameOffset, value: loop(e.kind)});
			}
			return {annType: offset, annElements: elements};
		}
		return [for (decl in annotations) processAnnotation(decl)];
	}
}

class BaseBuilder {
	var accessFlags = 0;
	var attributes:Array<JAttribute> = [];
	var annotations:Array<AnnotationDecl> = [];
	var wasExported = false;

	public function new() {}

	public function addAccessFlag(i:Int):Void {
		accessFlags = i | accessFlags;
	}

	public function addAttribute(a:JAttribute):Void {
		attributes.push(a);
	}

	public function addAnnotation(path:JPath, a:Annotation):Void {
		annotations.push({jsig: TObject(path, []), a: a});
	}

	function commitAnnotations(pool:JvmConstantPool):Void {
		if (annotations.length > 0)
			addAttribute(AttributeRuntimeVisibleAnnotations(JvmBuilder.convertAnnotations(pool, annotations)));
	}

	public function exportAttributes(pool:JvmConstantPool):Array<JvmAttributeData> {
		return [for (a in attributes) JvmAttribute.writeAttribute(pool, a)];
	}
}
