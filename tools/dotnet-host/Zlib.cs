// The zlib streams of a .NET-hosted hxc (src/hxc/eval/HostZip.hx). The native library is hxczlib, zlib
// 1.3.1 from the hxcpp checkout behind the flat calls of hxczlib.c: the zlib the native compiler links, so
// a macro compresses to the same bytes on either.
using System;
using System.Runtime.InteropServices;

namespace hxchost {
	public sealed unsafe class Zlib {
		const string Lib = "hxczlib";

		[DllImport(Lib)] static extern IntPtr hxz_deflate_new(int level, int* error);
		[DllImport(Lib)] static extern IntPtr hxz_inflate_new(int windowBits, int* error);
		[DllImport(Lib)] static extern int hxz_run(IntPtr handle, byte* src, int srcLen, byte* dst, int dstLen, int flush, int* read, int* written);
		[DllImport(Lib)] static extern int hxz_bound(IntPtr handle, int length);
		[DllImport(Lib)] static extern byte* hxz_message(IntPtr handle);
		[DllImport(Lib)] static extern void hxz_free(IntPtr handle);

		IntPtr handle;

		// zlib's flush argument for the next Run: Z_NO_FLUSH until it is set.
		public int Flush;

		Zlib(IntPtr handle) {
			this.handle = handle;
		}

		~Zlib() {
			Close();
		}

		public bool Closed {
			get { return handle == IntPtr.Zero; }
		}

		// A deflate stream of that level. Null when zlib refuses: error[0] is then its code.
		public static Zlib Deflate(int level, int[] error) {
			int e = 0;
			IntPtr h = hxz_deflate_new(level, &e);
			error[0] = e;
			return h == IntPtr.Zero ? null : new Zlib(h);
		}

		// An inflate stream of that window. Null when zlib refuses: error[0] is then its code.
		public static Zlib Inflate(int windowBits, int[] error) {
			int e = 0;
			IntPtr h = hxz_inflate_new(windowBits, &e);
			error[0] = e;
			return h == IntPtr.Zero ? null : new Zlib(h);
		}

		// One deflate or inflate call from src at srcPos into dst at dstPos, with the Flush that is set.
		// Answers zlib's code; counts[0] is what this call read and counts[1] what it wrote. A position past
		// its array leaves that side empty.
		public int Run(byte[] src, int srcPos, byte[] dst, int dstPos, int[] counts) {
			int srcLen = srcPos < 0 || srcPos > src.Length ? 0 : src.Length - srcPos;
			int dstLen = dstPos < 0 || dstPos > dst.Length ? 0 : dst.Length - dstPos;
			int read = 0, written = 0, code;
			byte none = 0;
			fixed (byte* s = src, d = dst) {
				byte* sp = srcLen == 0 || s == null ? &none : s + srcPos;
				byte* dp = dstLen == 0 || d == null ? &none : d + dstPos;
				code = hxz_run(handle, sp, srcLen, dp, dstLen, Flush, &read, &written);
			}
			counts[0] = read;
			counts[1] = written;
			GC.KeepAlive(this);
			return code;
		}

		// The most a deflate of `length` bytes can write, or -1 when that is past an int.
		public int Bound(int length) {
			int n = hxz_bound(handle, length);
			GC.KeepAlive(this);
			return n;
		}

		// zlib's message for the last error, as its bytes; empty when it has none.
		public byte[] Message() {
			byte* m = hxz_message(handle);
			if (m == null) return new byte[0];
			int n = 0;
			while (m[n] != 0) n++;
			byte[] r = new byte[n];
			Marshal.Copy((IntPtr)m, r, 0, n);
			GC.KeepAlive(this);
			return r;
		}

		public void Close() {
			IntPtr h = handle;
			handle = IntPtr.Zero;
			if (h != IntPtr.Zero) hxz_free(h);
		}
	}
}
