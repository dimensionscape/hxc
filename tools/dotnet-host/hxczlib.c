/* zlib for a .NET-hosted hxc (tools/dotnet-host/Zlib.cs): the deflate and inflate streams a macro's
   haxe.zip.Compress and haxe.zip.Uncompress run on. It is built with the zlib sources of the hxcpp
   checkout, the ones the native compiler links, so both compilers write the same bytes. */
#include <stdlib.h>
#include <limits.h>
#include "zlib.h"

#define HXZ_EXPORT __declspec(dllexport)

typedef struct {
	z_stream z;
	int inflating;
} hxz_stream;

/* A deflate stream of that level, or NULL with zlib's code in *error. */
HXZ_EXPORT void *hxz_deflate_new(int level, int *error) {
	hxz_stream *s = (hxz_stream *)calloc(1, sizeof(hxz_stream));
	if (!s) { *error = Z_MEM_ERROR; return NULL; }
	*error = deflateInit(&s->z, level);
	if (*error != Z_OK) { free(s); return NULL; }
	return s;
}

/* An inflate stream of that window, or NULL with zlib's code in *error. */
HXZ_EXPORT void *hxz_inflate_new(int windowBits, int *error) {
	hxz_stream *s = (hxz_stream *)calloc(1, sizeof(hxz_stream));
	if (!s) { *error = Z_MEM_ERROR; return NULL; }
	s->inflating = 1;
	*error = inflateInit2(&s->z, windowBits);
	if (*error != Z_OK) { free(s); return NULL; }
	return s;
}

/* One deflate or inflate call over src into dst: zlib's code, with the bytes this call read and wrote. */
HXZ_EXPORT int hxz_run(void *handle, const unsigned char *src, int srcLen, unsigned char *dst, int dstLen, int flush, int *read, int *written) {
	hxz_stream *s = (hxz_stream *)handle;
	int code;
	s->z.next_in = (Bytef *)src;
	s->z.avail_in = (uInt)srcLen;
	s->z.next_out = dst;
	s->z.avail_out = (uInt)dstLen;
	code = s->inflating ? inflate(&s->z, flush) : deflate(&s->z, flush);
	*read = srcLen - (int)s->z.avail_in;
	*written = dstLen - (int)s->z.avail_out;
	return code;
}

/* The most a deflate of `length` bytes can write, or -1 when that is past an int. */
HXZ_EXPORT int hxz_bound(void *handle, int length) {
	hxz_stream *s = (hxz_stream *)handle;
	uLong n = deflateBound(&s->z, (uLong)length);
	return n > (uLong)INT_MAX ? -1 : (int)n;
}

/* zlib's message for the stream's last error, or NULL. */
HXZ_EXPORT const char *hxz_message(void *handle) {
	return ((hxz_stream *)handle)->z.msg;
}

HXZ_EXPORT void hxz_free(void *handle) {
	hxz_stream *s = (hxz_stream *)handle;
	if (!s) return;
	if (s->inflating) inflateEnd(&s->z); else deflateEnd(&s->z);
	free(s);
}
