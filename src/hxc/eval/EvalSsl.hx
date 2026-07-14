package hxc.eval;

#if (cpp && !emscripten)
import hxc.ast.Position;
import hxc.eval.EvalString.ByteString;
import hxc.eval.EvalString.EvalString;
import hxc.eval.EvalValue;
import hxc.eval.Mbedtls.MbedtlsObject;

/**
	The constructors and fields of sys.ssl's Certificate and Mbedtls and of the mbedtls externs, over
	hxc.eval.Mbedtls. A native decodes its arguments in a fixed order: a call's arguments right to
	left, a value bound before the call first.
**/
@:access(hxc.eval.EvalStdLib)
class EvalSsl {
	static inline function vfn(f:VFunc):EvalValue return VFunction(f, true);

	static inline function vmethod(f:VFunc):EvalValue return VFunction(f, false);

	static inline function arg(a:Array<EvalValue>, i:Int):EvalValue return i < a.length ? a[i] : VNull;

	static function encodeInstance(ctx:EvalContext, path:String, kind:EvalInstanceKind):EvalValue {
		var proto = EvalContext.getInstancePrototype(ctx, EvalHash.hash(path), Position.nullPos);
		return VInstance(new VInstance(proto.pinstanceFields.copy(), proto, kind));
	}

	static inline function encodeString(s:ByteString):EvalValue return EvalString.createUnknown(s);

	// The decoders of each kind; anything else is unexpectedValue with the kind's name.
	static function asX509Crt(ctx:EvalContext, v:EvalValue):MbedtlsObject {
		return switch (v) {
			case VInstance({ikind: IMbedtlsX509Crt(o)}): o;
			case _: EvalExceptions.unexpectedValue(ctx, v, "X509Crt");
		};
	}

	static function asConfig(ctx:EvalContext, v:EvalValue):MbedtlsObject {
		return switch (v) {
			case VInstance({ikind: IMbedtlsConfig(o)}): o;
			case _: EvalExceptions.unexpectedValue(ctx, v, "Config");
		};
	}

	// A NativeSocket, which hxc keeps beside the instance (EvalStdLib.nativeSockets).
	static function asSocket(ctx:EvalContext, v:EvalValue):sys.net.Socket {
		return switch (v) {
			case VInstance(vi) if (EvalStdLib.nativeSockets.exists(vi)): EvalStdLib.nativeSockets.get(vi);
			case _: EvalExceptions.unexpectedValue(ctx, v, "NativeSocket");
		};
	}

	static function asCtrDrbg(ctx:EvalContext, v:EvalValue):MbedtlsObject {
		return switch (v) {
			case VInstance({ikind: IMbedtlsCtrDrbg(o)}): o;
			case _: EvalExceptions.unexpectedValue(ctx, v, "CtrDrbg");
		};
	}

	static function asEntropy(ctx:EvalContext, v:EvalValue):MbedtlsObject {
		return switch (v) {
			case VInstance({ikind: IMbedtlsEntropy(o)}): o;
			case _: EvalExceptions.unexpectedValue(ctx, v, "Entropy");
		};
	}

	static function asPkContext(ctx:EvalContext, v:EvalValue):MbedtlsObject {
		return switch (v) {
			case VInstance({ikind: IMbedtlsPkContext(o)}): o;
			case _: EvalExceptions.unexpectedValue(ctx, v, "PkContext");
		};
	}

	static function asSsl(ctx:EvalContext, v:EvalValue):MbedtlsObject {
		return switch (v) {
			case VInstance({ikind: IMbedtlsSsl(o)}): o;
			case _: EvalExceptions.unexpectedValue(ctx, v, "Ssl");
		};
	}

	// A null password is none; anything else is decoded as a string.
	static function optionalString(ctx:EvalContext, v:EvalValue):Null<ByteString>
		return v == VNull ? null : EvalStdLib.decodeString(ctx, v);

	// Every constructor ignores its arguments.
	public static function initConstructors(ctx:EvalContext):Void {
		Mbedtls.init();
		var ctors = ctx.builtins.constructorBuiltins;
		ctors.set(EvalHash.hash("mbedtls.Config"), a -> encodeInstance(ctx, "mbedtls.Config", IMbedtlsConfig(Mbedtls.sslConfigInit())));
		ctors.set(EvalHash.hash("mbedtls.CtrDrbg"), a -> encodeInstance(ctx, "mbedtls.CtrDrbg", IMbedtlsCtrDrbg(Mbedtls.ctrDrbgInit())));
		ctors.set(EvalHash.hash("mbedtls.Entropy"), a -> encodeInstance(ctx, "mbedtls.Entropy", IMbedtlsEntropy(Mbedtls.entropyInit())));
		ctors.set(EvalHash.hash("mbedtls.PkContext"), a -> encodeInstance(ctx, "mbedtls.PkContext", IMbedtlsPkContext(Mbedtls.pkInit())));
		ctors.set(EvalHash.hash("mbedtls.Ssl"), a -> encodeInstance(ctx, "mbedtls.Ssl", IMbedtlsSsl(Mbedtls.sslInit())));
		ctors.set(EvalHash.hash("mbedtls.X509Crt"), a -> encodeInstance(ctx, "mbedtls.X509Crt", IMbedtlsX509Crt(Mbedtls.x509CrtInit())));
	}

	public static function initFields(ctx:EvalContext):Void {
		var s = ctx.builtins.staticBuiltins;
		var inst = ctx.builtins.instanceBuiltins;
		inline function stat(typeName:String, fieldName:String, v:EvalValue) EvalStdLib.reg(s, typeName, fieldName, v);
		inline function meth(typeName:String, fieldName:String, v:EvalValue) EvalStdLib.reg(inst, typeName, fieldName, v);
		var keyNative = EvalHash.hash("native");
		// The X509Crt behind a certificate's native field.
		function nativeCert(thisv:EvalValue):MbedtlsObject return asX509Crt(ctx, EvalField.field(ctx, thisv, keyNative));

		var certificate = "sys.ssl.Certificate";
		meth(certificate, "get_altNames", vmethod(a -> {
			var x509Crt = nativeCert(arg(a, 0));
			var names = Mbedtls.certGetAltNames(x509Crt);
			VArray(new VArray([for (n in names) encodeString(n)], names.length));
		}));
		meth(certificate, "get_notAfter", vmethod(a -> {
			var x509Crt = nativeCert(arg(a, 0));
			EvalStdLib.mkDate(ctx, Mbedtls.certGetNotAfter(x509Crt) * 1000);
		}));
		meth(certificate, "get_notBefore", vmethod(a -> {
			var x509Crt = nativeCert(arg(a, 0));
			EvalStdLib.mkDate(ctx, Mbedtls.certGetNotBefore(x509Crt) * 1000);
		}));
		meth(certificate, "issuer", vmethod(a -> {
			var x509Crt = nativeCert(arg(a, 0));
			var r = Mbedtls.certGetIssuer(x509Crt, EvalStdLib.decodeString(ctx, arg(a, 1)));
			r == null ? VNull : encodeString(r);
		}));
		meth(certificate, "subject", vmethod(a -> {
			var x509Crt = nativeCert(arg(a, 0));
			var r = Mbedtls.certGetSubject(x509Crt, EvalStdLib.decodeString(ctx, arg(a, 1)));
			r == null ? VNull : encodeString(r);
		}));

		stat("sys.ssl.Mbedtls", "loadDefaults", vfn(a -> VInt(Mbedtls.certLoadDefaults(asX509Crt(ctx, arg(a, 0))))));
		stat("sys.ssl.Mbedtls", "setSocket", vfn(a -> {
			var ssl = asSsl(ctx, arg(a, 0));
			var socket = asSocket(ctx, arg(a, 1));
			Mbedtls.sslSetBio(ssl, socket);
			VNull;
		}));

		meth("mbedtls.X509Crt", "next", vmethod(a -> {
			var next = Mbedtls.x509Next(asX509Crt(ctx, arg(a, 0)));
			next == null ? VNull : encodeInstance(ctx, "mbedtls.X509Crt", IMbedtlsX509Crt(next));
		}));
		meth("mbedtls.X509Crt", "parse", vmethod(a -> {
			var bytes = EvalStdLib.decodeBytes(arg(a, 1));
			VInt(Mbedtls.x509CrtParse(asX509Crt(ctx, arg(a, 0)), bytes));
		}));
		meth("mbedtls.X509Crt", "parse_file", vmethod(a -> {
			var path = EvalStdLib.decodeString(ctx, arg(a, 1));
			VInt(Mbedtls.x509CrtParseFile(asX509Crt(ctx, arg(a, 0)), path));
		}));
		meth("mbedtls.X509Crt", "parse_path", vmethod(a -> {
			var path = EvalStdLib.decodeString(ctx, arg(a, 1));
			VInt(Mbedtls.x509CrtParsePath(asX509Crt(ctx, arg(a, 0)), path));
		}));

		meth("mbedtls.Config", "authmode", vmethod(a -> {
			var authmode = EvalStdLib.decodeInt(ctx, arg(a, 1));
			Mbedtls.sslConfAuthmode(asConfig(ctx, arg(a, 0)), authmode);
			VNull;
		}));
		meth("mbedtls.Config", "ca_chain", vmethod(a -> {
			var caChain = asX509Crt(ctx, arg(a, 1));
			Mbedtls.sslConfCaChain(asConfig(ctx, arg(a, 0)), caChain);
			VNull;
		}));
		meth("mbedtls.Config", "defaults", vmethod(a -> {
			var preset = EvalStdLib.decodeInt(ctx, arg(a, 3));
			var transport = EvalStdLib.decodeInt(ctx, arg(a, 2));
			var endpoint = EvalStdLib.decodeInt(ctx, arg(a, 1));
			VInt(Mbedtls.sslConfigDefaults(asConfig(ctx, arg(a, 0)), endpoint, transport, preset));
		}));
		meth("mbedtls.Config", "rng", vmethod(a -> {
			var rng = asCtrDrbg(ctx, arg(a, 1));
			Mbedtls.sslConfRng(asConfig(ctx, arg(a, 0)), rng);
			VNull;
		}));

		// mbedtls.CtrDrbg; seed's custom string is read and not passed on (the stub drops it).
		meth("mbedtls.CtrDrbg", "random", vmethod(a -> {
			var outputLen = EvalStdLib.decodeInt(ctx, arg(a, 2));
			var output = EvalStdLib.decodeBytes(arg(a, 1));
			VInt(Mbedtls.ctrDrbgRandom(asCtrDrbg(ctx, arg(a, 0)), output, outputLen));
		}));
		meth("mbedtls.CtrDrbg", "seed", vmethod(a -> {
			var entropy = asEntropy(ctx, arg(a, 1));
			VInt(Mbedtls.ctrDrbgSeed(asCtrDrbg(ctx, arg(a, 0)), entropy));
		}));

		stat("mbedtls.Error", "strerror", vfn(a -> encodeString(Mbedtls.strerror(EvalStdLib.decodeInt(ctx, arg(a, 0))))));

		meth("mbedtls.PkContext", "parse_key", vmethod(a -> {
			var rng = asCtrDrbg(ctx, arg(a, 3));
			var password = optionalString(ctx, arg(a, 2));
			var key = EvalStdLib.decodeBytes(arg(a, 1));
			VInt(Mbedtls.pkParseKey(asPkContext(ctx, arg(a, 0)), key, password, rng));
		}));
		meth("mbedtls.PkContext", "parse_keyfile", vmethod(a -> {
			var rng = asCtrDrbg(ctx, arg(a, 3));
			var password = optionalString(ctx, arg(a, 2));
			var path = EvalStdLib.decodeString(ctx, arg(a, 1));
			VInt(Mbedtls.pkParseKeyfile(asPkContext(ctx, arg(a, 0)), path, password, rng));
		}));
		meth("mbedtls.PkContext", "parse_public_key", vmethod(a -> {
			var key = EvalStdLib.decodeBytes(arg(a, 1));
			VInt(Mbedtls.pkParsePublicKey(asPkContext(ctx, arg(a, 0)), key));
		}));
		meth("mbedtls.PkContext", "parse_public_keyfile", vmethod(a -> {
			var path = EvalStdLib.decodeString(ctx, arg(a, 1));
			VInt(Mbedtls.pkParsePublicKeyfile(asPkContext(ctx, arg(a, 0)), path));
		}));

		meth("mbedtls.Ssl", "get_peer_cert", vmethod(a -> {
			var cert = Mbedtls.sslGetPeerCert(asSsl(ctx, arg(a, 0)));
			cert == null ? VNull : encodeInstance(ctx, "mbedtls.X509Crt", IMbedtlsX509Crt(cert));
		}));
		meth("mbedtls.Ssl", "handshake", vmethod(a -> VInt(Mbedtls.sslHandshake(asSsl(ctx, arg(a, 0))))));
		meth("mbedtls.Ssl", "read", vmethod(a -> {
			var len = EvalStdLib.decodeInt(ctx, arg(a, 3));
			var pos = EvalStdLib.decodeInt(ctx, arg(a, 2));
			var buf = EvalStdLib.decodeBytes(arg(a, 1));
			VInt(Mbedtls.sslRead(asSsl(ctx, arg(a, 0)), buf, pos, len));
		}));
		meth("mbedtls.Ssl", "set_hostname", vmethod(a -> {
			var hostname = EvalStdLib.decodeString(ctx, arg(a, 1));
			VInt(Mbedtls.sslSetHostname(asSsl(ctx, arg(a, 0)), hostname));
		}));
		meth("mbedtls.Ssl", "setup", vmethod(a -> {
			var conf = asConfig(ctx, arg(a, 1));
			VInt(Mbedtls.sslSetup(asSsl(ctx, arg(a, 0)), conf));
		}));
		meth("mbedtls.Ssl", "write", vmethod(a -> {
			var len = EvalStdLib.decodeInt(ctx, arg(a, 3));
			var pos = EvalStdLib.decodeInt(ctx, arg(a, 2));
			var buf = EvalStdLib.decodeBytes(arg(a, 1));
			VInt(Mbedtls.sslWrite(asSsl(ctx, arg(a, 0)), buf, pos, len));
		}));

		for (t in [{path: "mbedtls.SslAuthmode", group: 0}, {path: "mbedtls.SslEndpoint", group: 1},
				{path: "mbedtls.SslPreset", group: 2}, {path: "mbedtls.SslTransport", group: 3}])
			for (f in Mbedtls.flags(t.group)) stat(t.path, f.name, VInt(f.value));
	}
}
#end
