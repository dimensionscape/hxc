/*
	The mbedtls binding's C stubs, over the mbedtls hxcpp builds (project/thirdparty/mbedtls-2.28.2).
	hxc.eval.Mbedtls calls these and builds the option and array results on its side, and untags the
	results the pk stubs return unwrapped.

	The objects are malloc'd and *_init'ed, never freed here: hxc keeps no finalizer, so a context
	lives on.
*/
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#include <wincrypt.h>
#endif

#ifdef __APPLE__
#include <Security/Security.h>
#endif

#include "mbedtls/version.h"
#include "mbedtls/error.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/oid.h"
#include "mbedtls/threading.h"

/*
 * Hxcpp builds mbedtls with MBEDTLS_THREADING_ALT on Windows (its mbedtls_config.h), whose mutex
 * hooks must be installed before a context locks one; hxcpp's own _hx_ssl_init
 * (src/hx/libs/ssl/SSL.cpp:994) installs the same four.
 */
#if defined(MBEDTLS_THREADING_ALT) && (defined(_MSC_VER) || defined(_WIN32))
static void hxc_mutex_init(mbedtls_threading_mutex_t *mutex) {
	if (mutex == NULL) return;
	InitializeCriticalSection(&mutex->cs);
	mutex->is_valid = 1;
}
static void hxc_mutex_free(mbedtls_threading_mutex_t *mutex) {
	if (mutex == NULL || !mutex->is_valid) return;
	DeleteCriticalSection(&mutex->cs);
	mutex->is_valid = 0;
}
static int hxc_mutex_lock(mbedtls_threading_mutex_t *mutex) {
	if (mutex == NULL || !mutex->is_valid) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
	EnterCriticalSection(&mutex->cs);
	return 0;
}
static int hxc_mutex_unlock(mbedtls_threading_mutex_t *mutex) {
	if (mutex == NULL || !mutex->is_valid) return MBEDTLS_ERR_THREADING_BAD_INPUT_DATA;
	LeaveCriticalSection(&mutex->cs);
	return 0;
}
#endif

void hxc_mbedtls_init(void) {
#if defined(MBEDTLS_THREADING_ALT) && (defined(_MSC_VER) || defined(_WIN32))
	mbedtls_threading_set_alt(hxc_mutex_init, hxc_mutex_free, hxc_mutex_lock, hxc_mutex_unlock);
#endif
}

/*
   A string's bytes are followed by a NUL, and the stubs pass the length plus one so mbedtls sees
   PEM text terminated: the copy gives these bytes the same NUL.
*/
static unsigned char* nul_copy(const unsigned char* buf, int len) {
	unsigned char* r = (unsigned char*)malloc((size_t)len + 1);
	if (len > 0) memcpy(r, buf, (size_t)len);
	r[len] = 0;
	return r;
}

void hxc_mbedtls_strerror(int code, char* buf, int buflen) {
	mbedtls_strerror(code, buf, (size_t)buflen);
}

/* CtrDrbg. The seed's custom string is not passed on. */
void* hxc_mbedtls_ctr_drbg_init(void) {
	mbedtls_ctr_drbg_context* ctr_drbg = malloc(sizeof(mbedtls_ctr_drbg_context));
	mbedtls_ctr_drbg_init(ctr_drbg);
	return ctr_drbg;
}

int hxc_mbedtls_ctr_drbg_random(void* p_rng, unsigned char* output, int output_len) {
	return mbedtls_ctr_drbg_random(p_rng, output, (size_t)output_len);
}

int hxc_mbedtls_ctr_drbg_seed(void* ctx, void* p_entropy) {
	return mbedtls_ctr_drbg_seed((mbedtls_ctr_drbg_context*)ctx, mbedtls_entropy_func, p_entropy, NULL, 0);
}

void* hxc_mbedtls_entropy_init(void) {
	mbedtls_entropy_context* entropy = malloc(sizeof(mbedtls_entropy_context));
	mbedtls_entropy_init(entropy);
	return entropy;
}

void* hxc_mbedtls_x509_crt_init(void) {
	mbedtls_x509_crt* x509_crt = malloc(sizeof(mbedtls_x509_crt));
	mbedtls_x509_crt_init(x509_crt);
	return x509_crt;
}

void* hxc_mbedtls_x509_next(void* chain) {
	return ((mbedtls_x509_crt*)chain)->next;
}

int hxc_mbedtls_x509_crt_parse(void* chain, const unsigned char* buf, int len) {
	unsigned char* copy = nul_copy(buf, len);
	int r = mbedtls_x509_crt_parse((mbedtls_x509_crt*)chain, copy, (size_t)len + 1);
	free(copy);
	return r;
}

int hxc_mbedtls_x509_crt_parse_file(void* chain, const char* path) {
	return mbedtls_x509_crt_parse_file((mbedtls_x509_crt*)chain, path);
}

int hxc_mbedtls_x509_crt_parse_path(void* chain, const char* path) {
	return mbedtls_x509_crt_parse_path((mbedtls_x509_crt*)chain, path);
}

/*
   Certificate Haxe API. The alt names: -1 when the extension is absent (the empty array),
   else how many entries the sequence has - its first node counted whatever it holds.
*/
int hxc_cert_alt_names_count(void* chain) {
	mbedtls_x509_crt* cert = (mbedtls_x509_crt*)chain;
#if MBEDTLS_VERSION_MAJOR >= 3
	if (!mbedtls_x509_crt_has_ext_type(cert, MBEDTLS_X509_EXT_SUBJECT_ALT_NAME)) {
#else
	if ((cert->ext_types & MBEDTLS_X509_EXT_SUBJECT_ALT_NAME) == 0) {
#endif
		return -1;
	}
	int i = 0;
	mbedtls_asn1_sequence* cur = &cert->subject_alt_names;
	while (cur != NULL) {
		++i;
		cur = cur->next;
	}
	return i;
}

const unsigned char* hxc_cert_alt_name(void* chain, int index, int* len) {
	mbedtls_asn1_sequence* cur = &((mbedtls_x509_crt*)chain)->subject_alt_names;
	while (index-- > 0) cur = cur->next;
	*len = (int)cur->buf.len;
	return cur->buf.p;
}

/* The first attribute of the name whose OID's short name is `field`, or none. */
static const unsigned char* name_attr(mbedtls_x509_name* obj, const char* rname, int* len) {
	const char* oname;
	while (obj != NULL) {
		int r = mbedtls_oid_get_attr_short_name(&obj->oid, &oname);
		if (r == 0 && strcmp(oname, rname) == 0) {
			*len = (int)obj->val.len;
			return obj->val.p;
		}
		obj = obj->next;
	}
	return NULL;
}

const unsigned char* hxc_cert_get_subject(void* chain, const char* field, int* len) {
	return name_attr(&((mbedtls_x509_crt*)chain)->subject, field, len);
}

const unsigned char* hxc_cert_get_issuer(void* chain, const char* field, int* len) {
	return name_attr(&((mbedtls_x509_crt*)chain)->issuer, field, len);
}

/*
   time_to_time_t: mktime over the fields set here; the rest of the struct tm is zero.
*/
static double time_to_time_t(mbedtls_x509_time* t) {
	struct tm info;
	memset(&info, 0, sizeof(info));
	info.tm_year = t->year - 1900;
	info.tm_mon = t->mon - 1;
	info.tm_mday = t->day;
	info.tm_hour = t->hour;
	info.tm_min = t->min;
	info.tm_sec = t->sec;
	return (double)mktime(&info);
}

double hxc_cert_get_notafter(void* chain) {
	return time_to_time_t(&((mbedtls_x509_crt*)chain)->valid_to);
}

double hxc_cert_get_notbefore(void* chain) {
	return time_to_time_t(&((mbedtls_x509_crt*)chain)->valid_from);
}

/* Config. On Windows a config verifies a chain against the system's. */
#ifdef _WIN32
static int verify_callback(void* param, mbedtls_x509_crt *crt, int depth, uint32_t *flags) {
	if (*flags == 0 || *flags & MBEDTLS_X509_BADCERT_CN_MISMATCH) {
		return 0;
	}

	HCERTSTORE store = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, CERT_STORE_DEFER_CLOSE_UNTIL_LAST_FREE_FLAG, NULL);
	if (store == NULL) {
		return MBEDTLS_ERR_X509_FATAL_ERROR;
	}
	PCCERT_CONTEXT primary_context = {0};
	if (!CertAddEncodedCertificateToStore(store, X509_ASN_ENCODING, crt->raw.p, crt->raw.len, CERT_STORE_ADD_REPLACE_EXISTING, &primary_context)) {
		CertCloseStore(store, 0);
		return MBEDTLS_ERR_X509_FATAL_ERROR;
	}
	PCCERT_CHAIN_CONTEXT chain_context = {0};
	CERT_CHAIN_PARA parameters = {0};
	if (!CertGetCertificateChain(NULL, primary_context, NULL, store, &parameters, 0, NULL, &chain_context)) {
		CertFreeCertificateContext(primary_context);
		CertCloseStore(store, 0);
		return MBEDTLS_ERR_X509_FATAL_ERROR;
	}
	CERT_CHAIN_POLICY_PARA policy_parameters = {0};
	CERT_CHAIN_POLICY_STATUS policy_status = {0};
	if (!CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, chain_context, &policy_parameters, &policy_status)) {
		CertFreeCertificateChain(chain_context);
		CertFreeCertificateContext(primary_context);
		CertCloseStore(store, 0);
		return MBEDTLS_ERR_X509_FATAL_ERROR;
	}
	if (policy_status.dwError == 0) {
		*flags = 0;
	} else {
		// If we ever want to read the verification result, we need to properly map dwError to flags
		*flags |= MBEDTLS_X509_BADCERT_OTHER;
	}
	CertFreeCertificateChain(chain_context);
	CertFreeCertificateContext(primary_context);
	CertCloseStore(store, 0);
	return 0;
}
#endif

void* hxc_mbedtls_ssl_config_init(void) {
	mbedtls_ssl_config* ssl_config = malloc(sizeof(mbedtls_ssl_config));
	mbedtls_ssl_config_init(ssl_config);
#ifdef _WIN32
	mbedtls_ssl_conf_verify(ssl_config, verify_callback, NULL);
#endif
	return ssl_config;
}

void hxc_mbedtls_ssl_conf_authmode(void* conf, int authmode) {
	mbedtls_ssl_conf_authmode((mbedtls_ssl_config*)conf, authmode);
}

void hxc_mbedtls_ssl_conf_ca_chain(void* conf, void* ca_chain) {
	mbedtls_ssl_conf_ca_chain((mbedtls_ssl_config*)conf, (mbedtls_x509_crt*)ca_chain, NULL);
}

int hxc_mbedtls_ssl_config_defaults(void* conf, int endpoint, int transport, int preset) {
	return mbedtls_ssl_config_defaults((mbedtls_ssl_config*)conf, endpoint, transport, preset);
}

void hxc_mbedtls_ssl_conf_rng(void* conf, void* p_rng) {
	mbedtls_ssl_conf_rng((mbedtls_ssl_config*)conf, mbedtls_ctr_drbg_random, p_rng);
}

/* Pk. The key buffers carry the NUL too (+1), and the password is its bytes and length. */
void* hxc_mbedtls_pk_init(void) {
	mbedtls_pk_context* pk_context = malloc(sizeof(mbedtls_pk_context));
	mbedtls_pk_init(pk_context);
	return pk_context;
}

int hxc_mbedtls_pk_parse_key(void* ctx, const unsigned char* key, int keylen, const unsigned char* pwd, int pwdlen, void* rng) {
	unsigned char* copy = nul_copy(key, keylen);
#if MBEDTLS_VERSION_MAJOR >= 3
	int r = mbedtls_pk_parse_key((mbedtls_pk_context*)ctx, copy, (size_t)keylen + 1, pwd, (size_t)pwdlen, mbedtls_ctr_drbg_random, NULL);
#else
	int r = mbedtls_pk_parse_key((mbedtls_pk_context*)ctx, copy, (size_t)keylen + 1, pwd, (size_t)pwdlen);
#endif
	free(copy);
	return r;
}

int hxc_mbedtls_pk_parse_keyfile(void* ctx, const char* path, const char* pwd, void* rng) {
#if MBEDTLS_VERSION_MAJOR >= 3
	return mbedtls_pk_parse_keyfile((mbedtls_pk_context*)ctx, path, pwd, mbedtls_ctr_drbg_random, rng);
#else
	return mbedtls_pk_parse_keyfile((mbedtls_pk_context*)ctx, path, pwd);
#endif
}

int hxc_mbedtls_pk_parse_public_key(void* ctx, const unsigned char* key, int keylen) {
	unsigned char* copy = nul_copy(key, keylen);
	int r = mbedtls_pk_parse_public_key((mbedtls_pk_context*)ctx, copy, (size_t)keylen + 1);
	free(copy);
	return r;
}

int hxc_mbedtls_pk_parse_public_keyfile(void* ctx, const char* path) {
	return mbedtls_pk_parse_public_keyfile((mbedtls_pk_context*)ctx, path);
}

void* hxc_mbedtls_ssl_init(void) {
	mbedtls_ssl_context* ssl_context = malloc(sizeof(mbedtls_ssl_context));
	mbedtls_ssl_init(ssl_context);
	return ssl_context;
}

void* hxc_mbedtls_ssl_get_peer_cert(void* ssl) {
	return (void*)mbedtls_ssl_get_peer_cert((mbedtls_ssl_context*)ssl);
}

int hxc_mbedtls_ssl_handshake(void* ssl) {
	return mbedtls_ssl_handshake((mbedtls_ssl_context*)ssl);
}

int hxc_mbedtls_ssl_read(void* ssl, unsigned char* buf, int len) {
	return mbedtls_ssl_read((mbedtls_ssl_context*)ssl, buf, (size_t)len);
}

int hxc_mbedtls_ssl_write(void* ssl, const unsigned char* buf, int len) {
	return mbedtls_ssl_write((mbedtls_ssl_context*)ssl, buf, (size_t)len);
}

/*
   The bio callbacks go back to the interpreter, which the context names by an id
   (hxc.eval.Mbedtls.bioSend / bioRecv). The read callback copies the whole buffer back,
   whatever the interpreter's receive answered.
*/
static int (*hxc_bio_send)(int id, const unsigned char* buf, int len) = NULL;
static int (*hxc_bio_recv)(int id, unsigned char* buf, int len) = NULL;

void hxc_mbedtls_set_bio_callbacks(int (*send)(int, const unsigned char*, int), int (*recv)(int, unsigned char*, int)) {
	hxc_bio_send = send;
	hxc_bio_recv = recv;
}

static int bio_write_cb(void* ctx, const unsigned char* buf, size_t len) {
	return hxc_bio_send((int)(intptr_t)ctx, buf, (int)len);
}

static int bio_read_cb(void* ctx, unsigned char* buf, size_t len) {
	return hxc_bio_recv((int)(intptr_t)ctx, buf, (int)len);
}

void hxc_mbedtls_ssl_set_bio(void* ssl, int id) {
	mbedtls_ssl_set_bio((mbedtls_ssl_context*)ssl, (void*)(intptr_t)id, bio_write_cb, bio_read_cb, NULL);
}

int hxc_mbedtls_ssl_set_hostname(void* ssl, const char* hostname) {
	return mbedtls_ssl_set_hostname((mbedtls_ssl_context*)ssl, hostname);
}

int hxc_mbedtls_ssl_setup(void* ssl, void* conf) {
	return mbedtls_ssl_setup((mbedtls_ssl_context*)ssl, (mbedtls_ssl_config*)conf);
}

/* The system's root certificates, 1 where there are none to load. */
int hxc_cert_load_defaults(void* certificate) {
	int r = 1;

	mbedtls_x509_crt *chain = (mbedtls_x509_crt*)certificate;

#ifdef _WIN32
	HCERTSTORE store;
	PCCERT_CONTEXT cert;

	if (store = CertOpenSystemStoreA(0, "Root")) {
		cert = NULL;
		while (cert = CertEnumCertificatesInStore(store, cert)) {
			r = mbedtls_x509_crt_parse_der(chain, (unsigned char *)cert->pbCertEncoded, cert->cbCertEncoded);
			if (r != 0) {
				return r;
			}
		}
		CertCloseStore(store, 0);
	}
#endif

#ifdef __APPLE__
	CFArrayRef certs;
	if (SecTrustCopyAnchorCertificates(&certs) == errSecSuccess) {
		CFIndex count = CFArrayGetCount(certs);
		for(CFIndex i = 0; i < count; i++) {
			SecCertificateRef item = (SecCertificateRef)CFArrayGetValueAtIndex(certs, i);

			// Get certificate in DER format
			CFDataRef data = SecCertificateCopyData(item);
			if(data) {
				r = mbedtls_x509_crt_parse_der(chain, (unsigned char *)CFDataGetBytePtr(data), CFDataGetLength(data));
				CFRelease(data);
				if (r != 0) {
					return r;
				}
			}
		}
		CFRelease(certs);
	}
#endif

	return r;
}

/*
   The flag tables: group 0 authmode, 1 endpoint, 2 preset, 3 transport; the name of entry i,
   or NULL past the last, and its value.
*/
static const char* authmode_names[] = {"SSL_VERIFY_NONE", "SSL_VERIFY_OPTIONAL", "SSL_VERIFY_REQUIRED", NULL};
static const int authmode_values[] = {MBEDTLS_SSL_VERIFY_NONE, MBEDTLS_SSL_VERIFY_OPTIONAL, MBEDTLS_SSL_VERIFY_REQUIRED};
static const char* endpoint_names[] = {"SSL_IS_CLIENT", "SSL_IS_SERVER", NULL};
static const int endpoint_values[] = {MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_IS_SERVER};
static const char* preset_names[] = {"SSL_PRESET_DEFAULT", "SSL_PRESET_SUITEB", NULL};
static const int preset_values[] = {MBEDTLS_SSL_PRESET_DEFAULT, MBEDTLS_SSL_PRESET_SUITEB};
static const char* transport_names[] = {"SSL_TRANSPORT_STREAM", "SSL_TRANSPORT_DATAGRAM", NULL};
static const int transport_values[] = {MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_TRANSPORT_DATAGRAM};

const char* hxc_mbedtls_flag_name(int group, int i) {
	switch (group) {
		case 0: return authmode_names[i];
		case 1: return endpoint_names[i];
		case 2: return preset_names[i];
		default: return transport_names[i];
	}
}

int hxc_mbedtls_flag_value(int group, int i) {
	switch (group) {
		case 0: return authmode_values[i];
		case 1: return endpoint_values[i];
		case 2: return preset_values[i];
		default: return transport_values[i];
	}
}
