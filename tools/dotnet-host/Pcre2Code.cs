// The PCRE2 calls of a .NET-hosted hxc (src/hxc/eval/Pcre2.hx, HostRegex). hxc's .NET target writes no
// DllImport methods, so they live here, in C#. The native library is pcre2-8, built from the same
// PCRE2 10.42 source hxcpp links into the native compiler.
using System;
using System.Runtime.InteropServices;

namespace hxchost {
	public sealed unsafe class Pcre2Code {
		const string Lib = "pcre2-8";
		const uint InfoCaptureCount = 4;

		[DllImport(Lib)] static extern IntPtr pcre2_compile_8(byte* pattern, UIntPtr length, uint options, int* errorcode, UIntPtr* erroroffset, IntPtr ccontext);
		[DllImport(Lib)] static extern void pcre2_code_free_8(IntPtr code);
		[DllImport(Lib)] static extern int pcre2_pattern_info_8(IntPtr code, uint what, void* where);
		[DllImport(Lib)] static extern IntPtr pcre2_match_data_create_from_pattern_8(IntPtr code, IntPtr gcontext);
		[DllImport(Lib)] static extern int pcre2_match_8(IntPtr code, byte* subject, UIntPtr length, UIntPtr startoffset, uint options, IntPtr matchData, IntPtr mcontext);
		[DllImport(Lib)] static extern UIntPtr* pcre2_get_ovector_pointer_8(IntPtr matchData);
		[DllImport(Lib)] static extern void pcre2_match_data_free_8(IntPtr matchData);
		[DllImport(Lib)] static extern int pcre2_get_error_message_8(int errorcode, byte* buffer, UIntPtr bufflen);

		IntPtr code;
		public readonly int CaptureCount;

		Pcre2Code(IntPtr code) {
			this.code = code;
			uint n = 0;
			pcre2_pattern_info_8(code, InfoCaptureCount, &n);
			CaptureCount = (int)n;
		}

		~Pcre2Code() {
			if (code != IntPtr.Zero) pcre2_code_free_8(code);
			code = IntPtr.Zero;
		}

		// The first `length` bytes of `pattern` compiled under `options`, with no character tables. Null when
		// the pattern is bad: error[0] is then PCRE2's error code and error[1] the offset it stopped at.
		public static Pcre2Code Compile(byte[] pattern, int length, int options, int[] error) {
			int err = 0;
			UIntPtr off = UIntPtr.Zero;
			byte empty = 0;
			IntPtr code;
			fixed (byte* p = pattern)
				code = pcre2_compile_8(length > 0 ? p : &empty, (UIntPtr)(uint)length, (uint)options, &err, &off, IntPtr.Zero);
			if (code == IntPtr.Zero) {
				error[0] = err;
				error[1] = (int)(uint)off;
				return null;
			}
			return new Pcre2Code(code);
		}

		// pcre2_match with no callout over the first `length` bytes of `subject`, from byte `pos`. Answers
		// what pcre2_match does: the number of pairs set (0 when the vector was too small for all), or a
		// negative error code. On success `ovector` takes the start and end of each pair set, -1 for a group
		// that took no part.
		public int Match(byte[] subject, int length, int pos, int options, int[] ovector, int pairs) {
			byte empty = 0;
			IntPtr md = pcre2_match_data_create_from_pattern_8(code, IntPtr.Zero);
			int r;
			fixed (byte* s = subject)
				r = pcre2_match_8(code, length > 0 ? s : &empty, (UIntPtr)(uint)length, (UIntPtr)(uint)pos, (uint)options, md, IntPtr.Zero);
			if (r >= 0) {
				UIntPtr* ov = pcre2_get_ovector_pointer_8(md);
				int k = r == 0 ? pairs : r;
				for (int i = 0; i < k * 2; i++) ovector[i] = ov[i] == UIntPtr.MaxValue ? -1 : (int)(uint)ov[i];
			}
			pcre2_match_data_free_8(md);
			GC.KeepAlive(this);
			return r;
		}

		// PCRE2's message for an error code, in a 128-byte buffer: the text, then zeros.
		public static byte[] ErrorMessage(int errorcode) {
			byte[] buf = new byte[128];
			fixed (byte* b = buf) pcre2_get_error_message_8(errorcode, b, (UIntPtr)128);
			return buf;
		}
	}
}
