package hxc.codegen.java;

import haxe.io.BytesInput;
import hxc.core.Globals.Path;
import hxc.codegen.java.JData;
import hxc.codegen.java.JData.JSignatureReader as R;

// the .class file reader.

typedef ConstantPool = {
	strings:Array<String>,
	paths:Array<Path>,
	nameAndTypes:Array<JNameAndType>,
};

typedef JNameAndType = {name:String, t:String};

typedef JLocal = {
	ldStartPc:Int,
	ldLength:Int,
	ldName:String,
	ldDescriptor:String,
	ldIndex:Int,
};

enum JAttribute {
	AttrCode(attrs:Array<JAttribute>);
	AttrDeprecated;
	AttrLocalVariableTable(locals:Array<JLocal>);
	AttrMethodParameters(params:Array<JMethodParameter>);
	AttrSignature(s:String);
	AttrVisibleAnnotations(anns:Array<JAnnotation>);
	AttrOther;
}

typedef JMethodParameter = {name:String, flags:Int};

typedef JField = {
	jfName:String,
	jfFlags:Int,
	jfTypes:JTypes,
	jfDescriptor:JSignature,
	jfAttributes:Array<JAttribute>,
	jfCode:Null<Array<JAttribute>>,
};

typedef JClass = {
	jcPath:Path,
	jcFlags:Int,
	jcSuper:JSignature,
	jcInterfaces:Array<JSignature>,
	jcTypes:JTypes,
	jcFields:Array<JField>,
	jcMethods:Array<JField>,
	jcAttributes:Array<JAttribute>,
};

class JClassReader {
	static inline function skip(ch:BytesInput, n:Int):Void {
		ch.position += n;
	}

	// The class file stores names in modified UTF-8. Identifiers in a std jar are ASCII, where
	// the two encodings agree.
	static inline function readUtf8(ch:BytesInput, n:Int):String {
		return ch.readString(n, haxe.io.Encoding.UTF8);
	}

	public static function readConstantPool(ch:BytesInput):ConstantPool {
		var count = ch.readUInt16();
		var strings = [for (_ in 0...count) ""];
		var pathIndex = [for (_ in 0...count) 0];
		var natIndex = [for (_ in 0...count) {name: 0, t: 0}];
		var i = 1;
		while (i < count) {
			switch (ch.readByte()) {
				case 1:
					strings[i] = readUtf8(ch, ch.readUInt16());
				case 3:
					ch.readInt32();
				case 4:
					ch.readFloat();
				case 5:
					// A long takes two constant-pool slots.
					i++;
					skip(ch, 8);
				case 6:
					i++;
					ch.readDouble();
				case 7:
					pathIndex[i] = ch.readUInt16();
				case 8:
					ch.readUInt16();
				case 9 | 10 | 11:
					ch.readUInt16();
					ch.readUInt16();
				case 12:
					var name = ch.readUInt16();
					var t = ch.readUInt16();
					natIndex[i] = {name: name, t: t};
				case 15:
					ch.readByte();
					ch.readUInt16();
				case 16:
					ch.readUInt16();
				case 17 | 18:
					ch.readUInt16();
					ch.readUInt16();
				case 19 | 20:
					ch.readUInt16();
				case b:
					throw "Invalid constant pool byte: " + b;
			}
			i++;
		}
		function asPath(s:String):Path {
			var parts = s.split("/");
			var name = parts.pop();
			return new Path(parts, name == null ? "" : name);
		}
		var paths = [for (index in pathIndex) index > 0 ? asPath(strings[index]) : new Path([], "")];
		var nameAndTypes = [
			for (nt in natIndex) {
				name: nt.name > 0 ? strings[nt.name] : "",
				t: nt.t > 0 ? strings[nt.t] : ""
			}
		];
		return {strings: strings, paths: paths, nameAndTypes: nameAndTypes};
	}

	public static function parseElementValue(consts:ConstantPool, ch:BytesInput):JAnnotationValue {
		var tag = ch.readByte();
		switch (tag) {
			case "B".code | "C".code | "D".code | "F".code | "I".code | "J".code | "S".code | "Z".code | "s".code:
				var jsig = tag == "s".code
					? TObject(new Path(["java", "lang"], "String"), [])
					: R.parseSignaturePart(String.fromCharCode(tag)).sig;
				return ValConst(jsig, ch.readUInt16());
			case "e".code:
				var path = R.parseSignature(consts.strings[ch.readUInt16()]);
				var name = consts.strings[ch.readUInt16()];
				return ValEnum(path, name);
			case "c".code:
				var name = consts.strings[ch.readUInt16()];
				var jsig = name == "V" ? TObject(new Path([], "Void"), []) : R.parseSignature(name);
				return ValClass(jsig);
			case "@".code:
				return ValAnnotation(parseAnnotation(consts, ch));
			case "[".code:
				var numVals = ch.readUInt16();
				return ValArray([for (_ in 0...numVals) parseElementValue(consts, ch)]);
			case _:
				throw "Invalid element value: '" + String.fromCharCode(tag) + "'";
		}
	}

	static function parseAnnElement(consts:ConstantPool, ch:BytesInput):JAnnotationElement {
		var name = consts.strings[ch.readUInt16()];
		var value = parseElementValue(consts, ch);
		return {name: name, value: value};
	}

	public static function parseAnnotation(consts:ConstantPool, ch:BytesInput):JAnnotation {
		var annType = R.parseSignature(consts.strings[ch.readUInt16()]);
		var count = ch.readUInt16();
		return {annType: annType, annElements: [for (_ in 0...count) parseAnnElement(consts, ch)]};
	}

	// The declared length is consumed only by the default case; the known attributes are read by their own
	// shape.
	public static function parseAttribute(consts:ConstantPool, ch:BytesInput):JAttribute {
		var name = consts.strings[ch.readUInt16()];
		var length = ch.readInt32();
		switch (name) {
			case "Code":
				ch.readUInt16(); // max stack
				ch.readUInt16(); // max locals
				skip(ch, ch.readInt32()); // code
				var len = ch.readUInt16();
				skip(ch, len * 8); // exceptions
				return AttrCode(parseAttributes(consts, ch));
			case "Deprecated":
				return AttrDeprecated;
			case "LocalVariableTable":
				var len = ch.readUInt16();
				var locals = [
					for (_ in 0...len) {
						var startPc = ch.readUInt16();
						var length = ch.readUInt16();
						var lname = consts.strings[ch.readUInt16()];
						var descriptor = consts.strings[ch.readUInt16()];
						var index = ch.readUInt16();
						{ldStartPc: startPc, ldLength: length, ldName: lname, ldDescriptor: descriptor, ldIndex: index};
					}
				];
				return AttrLocalVariableTable(locals);
			case "MethodParameters":
				var len = ch.readByte();
				var parameters = [
					for (_ in 0...len) {
						var pname = consts.strings[ch.readUInt16()];
						var flags = ch.readUInt16();
						{name: pname, flags: flags};
					}
				];
				return AttrMethodParameters(parameters);
			case "RuntimeVisibleAnnotations":
				var count = ch.readUInt16();
				return AttrVisibleAnnotations([for (_ in 0...count) parseAnnotation(consts, ch)]);
			case "Signature":
				return AttrSignature(consts.strings[ch.readUInt16()]);
			case _:
				skip(ch, length);
				return AttrOther;
		}
	}

	public static function parseAttributes(consts:ConstantPool, ch:BytesInput):Array<JAttribute> {
		var count = ch.readUInt16();
		return [for (_ in 0...count) parseAttribute(consts, ch)];
	}

	public static function parseField(consts:ConstantPool, isMethod:Bool, ch:BytesInput):JField {
		var flags = ch.readUInt16();
		var name = consts.strings[ch.readUInt16()];
		var descriptor = consts.strings[ch.readUInt16()];
		var attributes = parseAttributes(consts, ch);
		var types:JTypes = [];
		var jsig:Null<JSignature> = null;
		var code:Null<Array<JAttribute>> = null;
		for (attr in attributes) switch (attr) {
			case AttrCode(c):
				code = c;
			case AttrSignature(s):
				if (isMethod) {
					var r = R.parseCompleteMethodSignature(s);
					types = r.tparams;
					jsig = TMethod(r.msig);
				} else
					jsig = R.parseSignature(s);
			case _:
		}
		return {
			jfName: name,
			jfFlags: flags,
			jfTypes: types,
			jfDescriptor: jsig == null ? R.parseSignature(descriptor) : jsig,
			jfAttributes: attributes,
			jfCode: code
		};
	}

	public static function parseClass(ch:BytesInput):JClass {
		ch.bigEndian = true;
		if (ch.readInt32() != 0xCAFEBABE) throw "Invalid header";
		ch.readUInt16(); // minor version
		ch.readUInt16(); // major version
		var consts = readConstantPool(ch);
		var flags = ch.readUInt16();
		var thisPath = consts.paths[ch.readUInt16()];
		var superSig:JSignature = TObject(consts.paths[ch.readUInt16()], []);
		var ifaceCount = ch.readUInt16();
		var interfaces:Array<JSignature> = [for (_ in 0...ifaceCount) TObject(consts.paths[ch.readUInt16()], [])];
		var fieldCount = ch.readUInt16();
		var fields = [for (_ in 0...fieldCount) parseField(consts, false, ch)];
		var methodCount = ch.readUInt16();
		var methods = [for (_ in 0...methodCount) parseField(consts, true, ch)];
		var attributes = parseAttributes(consts, ch);
		var types:JTypes = [];
		for (attr in attributes) switch (attr) {
			case AttrSignature(s):
				var tp = R.parseFormalTypeParams(s);
				types = tp.types;
				var rest = s.substr(tp.len, s.length - tp.len);
				var len = rest.length;
				var sup = R.parseSignaturePart(rest);
				var acc:Array<JSignature> = [];
				var idx = sup.len;
				while (idx != len) {
					var iface = R.parseSignaturePart(rest.substr(idx, len - idx));
					// Interfaces are prepended and never reversed, so they come out in reverse declaration
					// order, like the
					// type parameter bounds.
					acc.unshift(iface.sig);
					idx = idx + iface.len;
				}
				interfaces = acc;
				superSig = sup.sig;
			case _:
		}
		return {
			jcPath: thisPath,
			jcFlags: flags,
			jcSuper: superSig,
			jcInterfaces: interfaces,
			jcTypes: types,
			jcFields: fields,
			jcMethods: methods,
			jcAttributes: attributes
		};
	}
}
