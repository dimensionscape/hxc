package hxc.eval;

#if (cpp && !emscripten)
import hxc.eval.EvalString.ByteString;

/**
	The mbedtls binding eval's SSL natives call, over its C stubs (mbedtls_stubs.c beside this file)
	and the mbedtls hxcpp builds (2.28.2). The results are converted here: an option is a nullable
	object, a string array a Haxe array, and the four pk stubs' results are read as tagged ints
	(see untag).
**/
@:build(hxc.eval.MbedtlsBuild.build())
@:cppFileCode('
extern "C" {
	void hxc_mbedtls_init(void);
	void hxc_mbedtls_strerror(int code, char* buf, int buflen);
	void* hxc_mbedtls_ctr_drbg_init(void);
	int hxc_mbedtls_ctr_drbg_random(void* p_rng, unsigned char* output, int output_len);
	int hxc_mbedtls_ctr_drbg_seed(void* ctx, void* p_entropy);
	void* hxc_mbedtls_entropy_init(void);
	void* hxc_mbedtls_x509_crt_init(void);
	void* hxc_mbedtls_x509_next(void* chain);
	int hxc_mbedtls_x509_crt_parse(void* chain, const unsigned char* buf, int len);
	int hxc_mbedtls_x509_crt_parse_file(void* chain, const char* path);
	int hxc_mbedtls_x509_crt_parse_path(void* chain, const char* path);
	int hxc_cert_alt_names_count(void* chain);
	const unsigned char* hxc_cert_alt_name(void* chain, int index, int* len);
	const unsigned char* hxc_cert_get_subject(void* chain, const char* field, int* len);
	const unsigned char* hxc_cert_get_issuer(void* chain, const char* field, int* len);
	double hxc_cert_get_notafter(void* chain);
	double hxc_cert_get_notbefore(void* chain);
	void* hxc_mbedtls_ssl_config_init(void);
	void hxc_mbedtls_ssl_conf_authmode(void* conf, int authmode);
	void hxc_mbedtls_ssl_conf_ca_chain(void* conf, void* ca_chain);
	int hxc_mbedtls_ssl_config_defaults(void* conf, int endpoint, int transport, int preset);
	void hxc_mbedtls_ssl_conf_rng(void* conf, void* p_rng);
	void* hxc_mbedtls_pk_init(void);
	int hxc_mbedtls_pk_parse_key(void* ctx, const unsigned char* key, int keylen, const unsigned char* pwd, int pwdlen, void* rng);
	int hxc_mbedtls_pk_parse_keyfile(void* ctx, const char* path, const char* pwd, void* rng);
	int hxc_mbedtls_pk_parse_public_key(void* ctx, const unsigned char* key, int keylen);
	int hxc_mbedtls_pk_parse_public_keyfile(void* ctx, const char* path);
	void* hxc_mbedtls_ssl_init(void);
	void* hxc_mbedtls_ssl_get_peer_cert(void* ssl);
	int hxc_mbedtls_ssl_handshake(void* ssl);
	int hxc_mbedtls_ssl_read(void* ssl, unsigned char* buf, int len);
	int hxc_mbedtls_ssl_write(void* ssl, const unsigned char* buf, int len);
	void hxc_mbedtls_set_bio_callbacks(int (*send)(int, const unsigned char*, int), int (*recv)(int, unsigned char*, int));
	void hxc_mbedtls_ssl_set_bio(void* ssl, int id);
	int hxc_mbedtls_ssl_set_hostname(void* ssl, const char* hostname);
	int hxc_mbedtls_ssl_setup(void* ssl, void* conf);
	int hxc_cert_load_defaults(void* certificate);
	const char* hxc_mbedtls_flag_name(int group, int i);
	int hxc_mbedtls_flag_value(int group, int i);
}
static int hxc_mbedtls_bio_send(int id, const unsigned char* buf, int len) {
	return ::hxc::eval::Mbedtls_obj::bioSend(id, buf, len);
}
static int hxc_mbedtls_bio_recv(int id, unsigned char* buf, int len) {
	return ::hxc::eval::Mbedtls_obj::bioRecv(id, buf, len);
}
')
class Mbedtls {
	static var inited = false;

	// The mutex hooks of hxcpp's mbedtls build and the way back from the bio callbacks
	// (mbedtls_ssl_set_bio).
	public static function init():Void {
		if (inited) return;
		inited = true;
		untyped __cpp__("hxc_mbedtls_init()");
		untyped __cpp__("hxc_mbedtls_set_bio_callbacks(hxc_mbedtls_bio_send, hxc_mbedtls_bio_recv)");
	}

	// The string's bytes followed by a NUL, as a stub that takes a C string expects.
	static function cstring(s:ByteString):haxe.io.Bytes {
		var b = s.toBytes();
		var r = haxe.io.Bytes.alloc(b.length + 1);
		r.blit(0, b, 0, b.length);
		r.set(b.length, 0);
		return r;
	}

	static inline function base(b:haxe.io.Bytes):cpp.RawPointer<cpp.UInt8>
		return untyped __cpp__("(unsigned char*){0}->b->GetBase()", b);

	// The text of a C string the stubs answer, copied as bytes.
	static function bytesOf(p:cpp.RawConstPointer<cpp.UInt8>, len:Int):ByteString {
		var b = haxe.io.Bytes.alloc(len);
		if (len > 0) untyped __cpp__("memcpy({0}->b->GetBase(), {1}, {2})", b, p, len);
		return ByteString.ofBytes(b, 0, len);
	}

	// A stub result read as a tagged int: the value shifted right by one.
	static inline function untag(r:Int):Int return r >> 1;

	// mbedtls_strerror, into a 128-byte buffer
	public static function strerror(code:Int):ByteString {
		var buf = haxe.io.Bytes.alloc(128);
		untyped __cpp__("hxc_mbedtls_strerror({0}, (char*){1}->b->GetBase(), 128)", code, buf);
		var n = 0;
		while (n < 128 && buf.get(n) != 0) n++;
		return ByteString.ofBytes(buf, 0, n);
	}

	public static function ctrDrbgInit():MbedtlsObject
		return new MbedtlsObject(untyped __cpp__("hxc_mbedtls_ctr_drbg_init()"));

	public static function ctrDrbgRandom(p:MbedtlsObject, output:haxe.io.Bytes, outputLen:Int):Int
		return untyped __cpp__("hxc_mbedtls_ctr_drbg_random({0}, (unsigned char*){1}->b->GetBase(), {2})", p.ptr, output, outputLen);

	public static function ctrDrbgSeed(ctx:MbedtlsObject, entropy:MbedtlsObject):Int
		return untyped __cpp__("hxc_mbedtls_ctr_drbg_seed({0}, {1})", ctx.ptr, entropy.ptr);

	public static function entropyInit():MbedtlsObject
		return new MbedtlsObject(untyped __cpp__("hxc_mbedtls_entropy_init()"));

	public static function sslConfigInit():MbedtlsObject
		return new MbedtlsObject(untyped __cpp__("hxc_mbedtls_ssl_config_init()"));

	public static function sslConfAuthmode(conf:MbedtlsObject, authmode:Int):Void
		untyped __cpp__("hxc_mbedtls_ssl_conf_authmode({0}, {1})", conf.ptr, authmode);

	public static function sslConfCaChain(conf:MbedtlsObject, caChain:MbedtlsObject):Void
		untyped __cpp__("hxc_mbedtls_ssl_conf_ca_chain({0}, {1})", conf.ptr, caChain.ptr);

	public static function sslConfigDefaults(conf:MbedtlsObject, endpoint:Int, transport:Int, preset:Int):Int
		return untyped __cpp__("hxc_mbedtls_ssl_config_defaults({0}, {1}, {2}, {3})", conf.ptr, endpoint, transport, preset);

	public static function sslConfRng(conf:MbedtlsObject, rng:MbedtlsObject):Void
		untyped __cpp__("hxc_mbedtls_ssl_conf_rng({0}, {1})", conf.ptr, rng.ptr);

	public static function sslInit():MbedtlsObject
		return new MbedtlsObject(untyped __cpp__("hxc_mbedtls_ssl_init()"));

	public static function sslGetPeerCert(ssl:MbedtlsObject):Null<MbedtlsObject> {
		var p:cpp.RawPointer<cpp.Void> = untyped __cpp__("hxc_mbedtls_ssl_get_peer_cert({0})", ssl.ptr);
		return p == null ? null : new MbedtlsObject(p);
	}

	public static function sslHandshake(ssl:MbedtlsObject):Int {
		var r:Int = untyped __cpp__("hxc_mbedtls_ssl_handshake({0})", ssl.ptr);
		rethrowBio(ssl);
		return r;
	}

	// Stubs :503/:552: the buffer from pos, unchecked.
	public static function sslRead(ssl:MbedtlsObject, buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		var r:Int = untyped __cpp__("hxc_mbedtls_ssl_read({0}, (unsigned char*){1}->b->GetBase() + {2}, {3})", ssl.ptr, buf, pos, len);
		rethrowBio(ssl);
		return r;
	}

	public static function sslWrite(ssl:MbedtlsObject, buf:haxe.io.Bytes, pos:Int, len:Int):Int {
		var r:Int = untyped __cpp__("hxc_mbedtls_ssl_write({0}, (const unsigned char*){1}->b->GetBase() + {2}, {3})", ssl.ptr, buf, pos, len);
		rethrowBio(ssl);
		return r;
	}

	public static function sslSetHostname(ssl:MbedtlsObject, hostname:ByteString):Int {
		var c = cstring(hostname);
		return untyped __cpp__("hxc_mbedtls_ssl_set_hostname({0}, (const char*){1}->b->GetBase())", ssl.ptr, c);
	}

	public static function sslSetup(ssl:MbedtlsObject, conf:MbedtlsObject):Int
		return untyped __cpp__("hxc_mbedtls_ssl_setup({0}, {1})", ssl.ptr, conf.ptr);

	/**
		mbedtls_ssl_set_bio over a send and a receive on the socket: here the NativeSocket's host
		socket, sent to and received from once per call. The socket layer's failure is held while mbedtls
		unwinds and raised from the native that drove it, so it leaves as if thrown from the stub's
		callback.
	**/
	public static function sslSetBio(ssl:MbedtlsObject, socket:sys.net.Socket):Void {
		var id = bios.length;
		bios.push({socket: socket, pending: null});
		ssl.bio = id;
		untyped __cpp__("hxc_mbedtls_ssl_set_bio({0}, {1})", ssl.ptr, id);
	}

	static var bios:Array<{socket:sys.net.Socket, pending:Null<Dynamic>}> = [];

	static function rethrowBio(ssl:MbedtlsObject):Void {
		if (ssl.bio < 0) return;
		var bio = bios[ssl.bio];
		var p = bio.pending;
		if (p == null) return;
		bio.pending = null;
		throw p;
	}

	// Mbedtls net_sockets.h: MBEDTLS_ERR_NET_SEND_FAILED and MBEDTLS_ERR_NET_RECV_FAILED, what the
	// callbacks give mbedtls when the socket failed (the exception is what the native raises).
	static inline var ERR_NET_SEND_FAILED = -0x004E;
	static inline var ERR_NET_RECV_FAILED = -0x004C;

	// Unix.send and Unix.recv let go of the runtime lock while they wait (unix's blocking sections), so
	// another thread of the interpreter runs meanwhile - the peer of this very handshake, for one.
	@:keep static function bioSend(id:Int, buf:cpp.RawConstPointer<cpp.UInt8>, len:Int):Int {
		var bio = bios[id];
		var b = haxe.io.Bytes.alloc(len);
		if (len > 0) untyped __cpp__("memcpy({0}->b->GetBase(), {1}, {2})", b, buf, len);
		var released = EvalStdLib.gilRelease();
		var r = try bio.socket.output.writeBytes(b, 0, len) catch (e:Dynamic) {
			if (released) EvalStdLib.gilReacquire();
			bio.pending = e;
			return ERR_NET_SEND_FAILED;
		}
		if (released) EvalStdLib.gilReacquire();
		return r;
	}

	// A receive answers 0 at the end of the stream, where the host socket raises Eof. Every byte of the
	// buffer goes back, as the stub copies all of it.
	@:keep static function bioRecv(id:Int, buf:cpp.RawPointer<cpp.UInt8>, len:Int):Int {
		var bio = bios[id];
		var b = haxe.io.Bytes.alloc(len);
		var released = EvalStdLib.gilRelease();
		var r = try bio.socket.input.readBytes(b, 0, len) catch (_:haxe.io.Eof) 0 catch (e:Dynamic) {
			if (released) EvalStdLib.gilReacquire();
			bio.pending = e;
			return ERR_NET_RECV_FAILED;
		}
		if (released) EvalStdLib.gilReacquire();
		if (len > 0) untyped __cpp__("memcpy({0}, {1}->b->GetBase(), {2})", buf, b, len);
		return r;
	}

	// Pk; each answer is read untagged.
	public static function pkInit():MbedtlsObject
		return new MbedtlsObject(untyped __cpp__("hxc_mbedtls_pk_init()"));

	// A password is its bytes and its length - an empty one still a pointer, which
	// mbedtls tells apart from none.
	public static function pkParseKey(ctx:MbedtlsObject, key:haxe.io.Bytes, password:Null<ByteString>, rng:MbedtlsObject):Int {
		var r:Int = if (password == null) untyped __cpp__("hxc_mbedtls_pk_parse_key({0}, (const unsigned char*){1}->b->GetBase(), {2}, NULL, 0, {3})", ctx.ptr, key, key.length, rng.ptr)
			else {
				var pwd = cstring(password);
				untyped __cpp__("hxc_mbedtls_pk_parse_key({0}, (const unsigned char*){1}->b->GetBase(), {2}, (const unsigned char*){3}->b->GetBase(), {4}, {5})", ctx.ptr, key, key.length, pwd, pwd.length - 1, rng.ptr);
			}
		return untag(r);
	}

	public static function pkParseKeyfile(ctx:MbedtlsObject, path:ByteString, password:Null<ByteString>, rng:MbedtlsObject):Int {
		var p = cstring(path);
		var r:Int = if (password == null) untyped __cpp__("hxc_mbedtls_pk_parse_keyfile({0}, (const char*){1}->b->GetBase(), NULL, {2})", ctx.ptr, p, rng.ptr)
			else untyped __cpp__("hxc_mbedtls_pk_parse_keyfile({0}, (const char*){1}->b->GetBase(), (const char*){2}->b->GetBase(), {3})", ctx.ptr, p, cstring(password), rng.ptr);
		return untag(r);
	}

	public static function pkParsePublicKey(ctx:MbedtlsObject, key:haxe.io.Bytes):Int {
		var r:Int = untyped __cpp__("hxc_mbedtls_pk_parse_public_key({0}, (const unsigned char*){1}->b->GetBase(), {2})", ctx.ptr, key, key.length);
		return untag(r);
	}

	public static function pkParsePublicKeyfile(ctx:MbedtlsObject, path:ByteString):Int {
		var p = cstring(path);
		var r:Int = untyped __cpp__("hxc_mbedtls_pk_parse_public_keyfile({0}, (const char*){1}->b->GetBase())", ctx.ptr, p);
		return untag(r);
	}

	public static function x509CrtInit():MbedtlsObject
		return new MbedtlsObject(untyped __cpp__("hxc_mbedtls_x509_crt_init()"));

	public static function x509Next(chain:MbedtlsObject):Null<MbedtlsObject> {
		var p:cpp.RawPointer<cpp.Void> = untyped __cpp__("hxc_mbedtls_x509_next({0})", chain.ptr);
		return p == null ? null : new MbedtlsObject(p);
	}

	public static function x509CrtParse(chain:MbedtlsObject, bytes:haxe.io.Bytes):Int
		return untyped __cpp__("hxc_mbedtls_x509_crt_parse({0}, (const unsigned char*){1}->b->GetBase(), {2})", chain.ptr, bytes, bytes.length);

	public static function x509CrtParseFile(chain:MbedtlsObject, path:ByteString):Int {
		var p = cstring(path);
		return untyped __cpp__("hxc_mbedtls_x509_crt_parse_file({0}, (const char*){1}->b->GetBase())", chain.ptr, p);
	}

	public static function x509CrtParsePath(chain:MbedtlsObject, path:ByteString):Int {
		var p = cstring(path);
		return untyped __cpp__("hxc_mbedtls_x509_crt_parse_path({0}, (const char*){1}->b->GetBase())", chain.ptr, p);
	}

	public static function certGetAltNames(chain:MbedtlsObject):Array<ByteString> {
		var n:Int = untyped __cpp__("hxc_cert_alt_names_count({0})", chain.ptr);
		var out = [];
		for (i in 0...(n < 0 ? 0 : n)) {
			var len = 0;
			var p:cpp.RawConstPointer<cpp.UInt8> = untyped __cpp__("hxc_cert_alt_name({0}, {1}, &{2})", chain.ptr, i, len);
			out.push(bytesOf(p, len));
		}
		return out;
	}

	public static function certGetIssuer(chain:MbedtlsObject, field:ByteString):Null<ByteString> {
		var f = cstring(field);
		var len = 0;
		var p:cpp.RawConstPointer<cpp.UInt8> = untyped __cpp__("hxc_cert_get_issuer({0}, (const char*){1}->b->GetBase(), &{2})", chain.ptr, f, len);
		return p == null ? null : bytesOf(p, len);
	}

	public static function certGetSubject(chain:MbedtlsObject, field:ByteString):Null<ByteString> {
		var f = cstring(field);
		var len = 0;
		var p:cpp.RawConstPointer<cpp.UInt8> = untyped __cpp__("hxc_cert_get_subject({0}, (const char*){1}->b->GetBase(), &{2})", chain.ptr, f, len);
		return p == null ? null : bytesOf(p, len);
	}

	public static function certGetNotAfter(chain:MbedtlsObject):Float
		return untyped __cpp__("hxc_cert_get_notafter({0})", chain.ptr);

	public static function certGetNotBefore(chain:MbedtlsObject):Float
		return untyped __cpp__("hxc_cert_get_notbefore({0})", chain.ptr);

	public static function certLoadDefaults(certificate:MbedtlsObject):Int
		return untyped __cpp__("hxc_cert_load_defaults({0})", certificate.ptr);

	// The flag tables: 0 authmode, 1 endpoint, 2 preset, 3 transport.
	public static function flags(group:Int):Array<{name:String, value:Int}> {
		var out = [];
		var i = 0;
		while (true) {
			var name:cpp.ConstCharStar = untyped __cpp__("hxc_mbedtls_flag_name({0}, {1})", group, i);
			if (untyped __cpp__("{0} == NULL", name)) break;
			out.push({name: name.toString(), value: untyped __cpp__("hxc_mbedtls_flag_value({0}, {1})", group, i)});
			i++;
		}
		return out;
	}
}

/**
	An mbedtls context; `bio` names its bio callbacks' socket, -1 before mbedtls_ssl_set_bio.
**/
class MbedtlsObject {
	public var ptr:cpp.RawPointer<cpp.Void>;
	public var bio:Int = -1;

	public function new(ptr:cpp.RawPointer<cpp.Void>) {
		this.ptr = ptr;
	}
}
#end
