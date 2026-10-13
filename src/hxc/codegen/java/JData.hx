package hxc.codegen.java;

import hxc.core.Globals.Path;

// The class-file data model and the JVM signature grammar, used to read the classes of a Java library.

enum JWildcard {
	WExtends; // +
	WSuper;   // -
	WNone;
}

enum JTypeArgument {
	TType(w:JWildcard, s:JSignature);
	TAny; // *
}

enum JSignature {
	TByte;   // B
	TChar;   // C
	TDouble; // D
	TFloat;  // F
	TInt;    // I
	TLong;   // J
	TShort;  // S
	TBool;   // Z
	TObject(path:Path, params:Array<JTypeArgument>);            // L Classname
	TObjectInner(pack:Array<String>, inners:Array<JInnerName>); // L Classname ClassTypeSignatureSuffix
	TArray(s:JSignature, size:Null<Int>);                       // [
	TMethod(m:JMethodSignature);                                // (
	TTypeParameter(name:String);                                // T
}

typedef JInnerName = {name:String, params:Array<JTypeArgument>};

// ( args ) ReturnDescriptor, where the return descriptor is V (ret is null) or a signature
typedef JMethodSignature = {args:Array<JSignature>, ret:Null<JSignature>};

typedef JTypes = Array<JTypeParam>;
typedef JTypeParam = {name:String, ext:Null<JSignature>, ifaces:Array<JSignature>};

typedef JAnnotation = {annType:JSignature, annElements:Array<JAnnotationElement>};
typedef JAnnotationElement = {name:String, value:JAnnotationValue};

enum JAnnotationValue {
	ValConst(s:JSignature, i:Int);
	ValEnum(s:JSignature, name:String); // e
	ValClass(s:JSignature);             // c, V -> Void
	ValAnnotation(a:JAnnotation);       // @
	ValArray(vals:Array<JAnnotationValue>); // [
}

class AccessFlags {
	public static inline var MPublic = 0x1;
	public static inline var MPrivate = 0x2;
	public static inline var MProtected = 0x4;
	public static inline var MStatic = 0x8;
	public static inline var MFinal = 0x10;
	public static inline var MSynchronized = 0x20;
	public static inline var MBridge = 0x40;
	public static inline var MVarargs = 0x80;
	public static inline var MNative = 0x100;
	public static inline var MInterface = 0x200;
	public static inline var MAbstract = 0x400;
	public static inline var MStrict = 0x800;
	public static inline var MSynthetic = 0x1000;
	public static inline var MEnum = 0x4000;

	public static inline function hasFlag(b:Int, flag:Int):Bool {
		return (b & flag) != 0;
	}
}

class SigExit {
	public function new() {}
}

// Each parse function returns the value it read together with the number of characters it consumed.
class JSignatureReader {
	static inline function at(s:String, i:Int):Int {
		var c = s.charCodeAt(i);
		if (c == null) throw new SigExit();
		return c;
	}

	public static function parseTypeParameterPart(s:String):{arg:JTypeArgument, len:Int} {
		var c = at(s, 0);
		if (c == "*".code) return {arg: TAny, len: 1};
		var wildcard = WNone;
		var i = 0;
		if (c == "+".code) { wildcard = WExtends; i = 1; }
		else if (c == "-".code) { wildcard = WSuper; i = 1; }
		// The length is the string's length minus one, not minus i, so without a wildcard the last
		// character is
		// cut off; the signature parser stops at its own terminator, so the cut-off character is never
		// read.
		var r = parseSignaturePart(s.substr(i, s.length - 1));
		return {arg: TType(wildcard, r.sig), len: r.len + i};
	}

	public static function parseSignaturePart(s:String):{sig:JSignature, len:Int} {
		var len = s.length;
		if (len == 0) throw new SigExit();
		switch (at(s, 0)) {
			case "B".code: return {sig: TByte, len: 1};
			case "C".code: return {sig: TChar, len: 1};
			case "D".code: return {sig: TDouble, len: 1};
			case "F".code: return {sig: TFloat, len: 1};
			case "I".code: return {sig: TInt, len: 1};
			case "J".code: return {sig: TLong, len: 1};
			case "S".code: return {sig: TShort, len: 1};
			case "Z".code: return {sig: TBool, len: 1};
			case "L".code:
				var origS = s;
				// Reads pack/name/params starting at `start`, answering where it stopped.
				function loop(start:Int, i:Int, acc:Array<String>):{pack:Array<String>, name:String, params:Array<JTypeArgument>, end:Int} {
					while (true) {
						var c = at(s, i);
						if (c == "/".code) {
							acc.push(s.substr(start, i - start));
							start = i + 1;
							i = i + 1;
						} else if (c == ";".code || c == ".".code) {
							return {pack: acc, name: s.substr(start, i - start), params: [], end: i};
						} else if (c == "<".code) {
							var name = s.substr(start, i - start);
							var params:Array<JTypeArgument> = [];
							var j = i + 1;
							while (true) {
								var sub = s.substr(j, len - j);
								if (at(sub, 0) == ">".code) { j = j + 1; break; }
								var tp = parseTypeParameterPart(sub);
								params.push(tp.arg);
								j = tp.len + j;
							}
							return {pack: acc, name: name, params: params, end: j};
						} else {
							i = i + 1;
						}
					}
				}
				var head = loop(1, 1, []);
				var inners:Array<JInnerName> = [];
				var end = head.end;
				while (true) {
					var c = at(s, end);
					if (c == ".".code) {
						var inner = loop(end + 1, end + 1, []);
						if (inner.pack.length != 0)
							throw "Inner types must not define packages. For '" + origS + "'.";
						inners.push({name: inner.name, params: inner.params});
						end = inner.end;
					} else if (c == ";".code) {
						end = end + 1;
						break;
					} else {
						throw "End of complex type signature expected after type parameter. Got '"
							+ String.fromCharCode(c) + "' for '" + origS + "'.";
					}
				}
				if (inners.length == 0)
					return {sig: TObject(new Path(head.pack, head.name), head.params), len: end};
				var all = [{name: head.name, params: head.params}].concat(inners);
				return {sig: TObjectInner(head.pack, all), len: end};
			case "[".code:
				var p = 1;
				while (p < s.length && at(s, p) >= "0".code && at(s, p) <= "9".code) p++;
				var size:Null<Int> = p > 1 ? Std.parseInt(s.substr(1, p - 1)) : null;
				var r = parseSignaturePart(s.substr(p, s.length - p));
				return {sig: TArray(r.sig, size), len: r.len + p};
			case "(".code:
				var p = 1;
				var args:Array<JSignature> = [];
				while (p < s.length && at(s, p) != ")".code) {
					var r = parseSignaturePart(s.substr(p, s.length - p));
					args.push(r.sig);
					p = p + r.len;
				}
				p++;
				if (p >= s.length) throw new SigExit();
				var ret:Null<JSignature> = null;
				var l = 1;
				if (at(s, p) != "V".code) {
					var r = parseSignaturePart(s.substr(p, s.length - p));
					ret = r.sig;
					l = r.len;
				}
				return {sig: TMethod({args: args, ret: ret}), len: p + l};
			case "T".code:
				var idx = s.indexOf(";");
				if (idx < 0) throw new SigExit();
				var s1 = s.substr(0, idx);
				var l = s1.length;
				return {sig: TTypeParameter(s1.substr(1, l - 1)), len: l + 1};
			case _:
				throw new SigExit();
		}
	}

	public static function parseSignature(s:String):JSignature {
		try {
			var r = parseSignaturePart(s);
			if (s.length != r.len) throw new SigExit();
			return r.sig;
		} catch (_:SigExit) {
			throw "Invalid signature '" + s + "'";
		}
	}

	public static function parseMethodSignature(s:String):JMethodSignature {
		return switch (parseSignature(s)) {
			case TMethod(m): m;
			case _: throw "Unexpected signature '" + s + "'. Expecting method";
		}
	}

	public static function parseFormalTypeParams(s:String):{types:JTypes, len:Int} {
		if (at(s, 0) != "<".code) return {types: [], len: 0};
		var len = s.length;
		function readId(i:Int):Int {
			while (true) {
				var c = at(s, i);
				if (c == ":".code || c == ">".code) return i;
				i++;
			}
		}
		var acc:JTypes = [];
		var idx = 0;
		while (true) {
			var idi = readId(idx + 1);
			var id = s.substr(idx + 1, idi - idx - 1);
			if (at(s, idi) != ":".code)
				throw "Invalid formal type signature character: " + String.fromCharCode(at(s, idi)) + " ; from " + s;
			var ext:Null<JSignature> = null;
			var l = idi + 1;
			var nc = at(s, idi + 1);
			if (nc != ":".code && nc != ">".code) {
				var r = parseSignaturePart(s.substr(idi + 1, len - idi - 1));
				ext = r.sig;
				l = r.len + idi + 1;
			}
			// Interface bounds are prepended and never reversed, so a bound with several interfaces comes
			// out back to
			// front; the converter reads them in that order.
			var ifaces:Array<JSignature> = [];
			while (at(s, l) == ":".code) {
				var r = parseSignaturePart(s.substr(l + 1, len - l - 1));
				ifaces.unshift(r.sig);
				l = l + r.len + 1;
			}
			acc.push({name: id, ext: ext, ifaces: ifaces});
			if (at(s, l) == ">".code) return {types: acc, len: l + 1};
			idx = l - 1;
		}
	}

	public static function parseThrows(s:String):{throws:Array<JSignature>, len:Int} {
		var len = s.length;
		var acc:Array<JSignature> = [];
		var idx = 0;
		while (true) {
			if (idx > len) throw new SigExit();
			if (idx == len) return {throws: acc, len: idx};
			if (at(s, idx) != "^".code) return {throws: acc, len: idx};
			var r = parseSignaturePart(s.substr(idx + 1, len - idx - 1));
			// Prepended and never reversed, like the interface bounds above.
			acc.unshift(r.sig);
			idx = idx + r.len + 1;
		}
	}

	public static function parseCompleteMethodSignature(s:String):{tparams:JTypes, msig:JMethodSignature, throws:Array<JSignature>} {
		try {
			var len = s.length;
			var tp = parseFormalTypeParams(s);
			var r = parseSignaturePart(s.substr(tp.len, len - tp.len));
			var th = parseThrows(s.substr(tp.len + r.len, len - tp.len - r.len));
			if ((tp.len + r.len + th.len) != len) throw new SigExit();
			return switch (r.sig) {
				case TMethod(m): {tparams: tp.types, msig: m, throws: th.throws};
				case _: throw new SigExit();
			}
		} catch (_:SigExit) {
			throw "Invalid method extended signature '" + s + "'";
		}
	}
}
