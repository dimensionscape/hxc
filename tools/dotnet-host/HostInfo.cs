// What a .NET-hosted hxc asks the operating system directly.
using System;
using System.Runtime.InteropServices;

namespace hxchost {
	public static unsafe class HostInfo {
		[DllImport("kernel32", EntryPoint = "GetCommandLineW")] static extern char* GetCommandLine();
		[DllImport("shell32", EntryPoint = "CommandLineToArgvW")] static extern char** CommandLineToArgv(char* line, int* count);
		[DllImport("kernel32", EntryPoint = "LocalFree")] static extern IntPtr LocalFree(IntPtr p);

		[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
		struct FindData {
			public uint attributes;
			public uint creationLow, creationHigh, accessLow, accessHigh, writeLow, writeHigh;
			public uint sizeHigh, sizeLow, reserved0, reserved1;
			[MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string fileName;
			[MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string alternate;
		}

		[DllImport("kernel32", CharSet = CharSet.Unicode)] static extern IntPtr FindFirstFileW(string name, out FindData data);
		[DllImport("kernel32")] static extern bool FindClose(IntPtr handle);

		// On Windows the full path with the drive letter upper-cased and each component that exists spelled the
		// way FindFirstFile answers it (a short `~` name expands); a component that does not exist keeps the
		// spelling it was given. Elsewhere the full path. The path itself where that fails, or where the full
		// path is 260 characters or more.
		public static string RealPath(string path) {
			string full;
			try { full = System.IO.Path.GetFullPath(path); } catch (Exception) { return path; }
			if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return full;
			if (full.Length == 0 || full.Length >= 260) return path;
			var o = new System.Text.StringBuilder(full);
			int i = 0;
			if (o.Length >= 2 && o[1] == ':') {
				if (o[0] >= 'a' && o[0] <= 'z') o[0] = (char)(o[0] - 'a' + 'A');
				i = o.Length >= 3 && o[2] == '\\' ? 3 : 2;
			}
			int last = i;
			while (i < o.Length) {
				while (i < o.Length && o[i] != '\\') i++;
				FindData data;
				IntPtr h = FindFirstFileW(o.ToString(0, i), out data);
				if (h != new IntPtr(-1)) {
					FindClose(h);
					string real = data.fileName;
					if (o.Length + real.Length - (i - last) >= 260) return path;
					o.Remove(last, i - last).Insert(last, real);
					i = last + real.Length;
				}
				i++;
				last = i;
			}
			return o.ToString();
		}

		// The program's name exactly as the command line gave it (C's argv[0]). .NET's own answers are the
		// resolved path of the executable or of the assembly, which differ whenever the program was started
		// through a relative path.
		public static string ProgramName() {
			if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return Environment.GetCommandLineArgs()[0];
			int n = 0;
			char** argv = CommandLineToArgv(GetCommandLine(), &n);
			if (argv == null) return Environment.ProcessPath ?? "";
			string name = n > 0 ? new string(argv[0]) : (Environment.ProcessPath ?? "");
			LocalFree((IntPtr)argv);
			return name;
		}

		// The C library's time calls, so that a macro's Date agrees with the native host's: the same range
		// (Windows' mktime refuses years before 1969 and after 3001, and any result before the epoch), the
		// same carrying of out-of-range fields, and the same local time zone. A struct tm is nine ints
		// (sec, min, hour, mday, mon, year, wday, yday, isdst), followed elsewhere by tm_gmtoff and tm_zone,
		// so each call gets 64 bytes.
		[DllImport("ucrtbase", EntryPoint = "_mktime64")] static extern long WinMktime(int* tm);
		[DllImport("ucrtbase", EntryPoint = "_localtime64_s")] static extern int WinLocaltime(int* tm, long* time);
		[DllImport("ucrtbase", EntryPoint = "_gmtime64_s")] static extern int WinGmtime(int* tm, long* time);
		[DllImport("libc", EntryPoint = "mktime")] static extern long PosixMktime(int* tm);
		[DllImport("libc", EntryPoint = "localtime_r")] static extern IntPtr PosixLocaltime(long* time, int* tm);
		[DllImport("libc", EntryPoint = "gmtime_r")] static extern IntPtr PosixGmtime(long* time, int* tm);

		static readonly bool windows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
		// Cleared when the C library cannot be loaded; the framework's own dates answer from then on.
		static bool useLibc = true;

		static long CMktime(int* tm) => windows ? WinMktime(tm) : PosixMktime(tm);

		static bool CBrokenDown(long time, bool utc, int* tm) {
			if (windows) return (utc ? WinGmtime(tm, &time) : WinLocaltime(tm, &time)) == 0;
			return (utc ? PosixGmtime(&time, tm) : PosixLocaltime(&time, tm)) != IntPtr.Zero;
		}

		// mktime over the fields with tm_isdst -1: the clock in seconds, or -1 where mktime fails.
		public static double Mktime(int year, int month, int day, int hour, int minute, int second) {
			if (useLibc) try {
				int* tm = stackalloc int[16];
				tm[0] = second; tm[1] = minute; tm[2] = hour; tm[3] = day; tm[4] = month; tm[5] = year - 1900; tm[8] = -1;
				return CMktime(tm);
			} catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException) {
				useLibc = false;
			}
			try {
				var local = new DateTime(year, 1, 1, 0, 0, 0, DateTimeKind.Unspecified).AddMonths(month).AddDays(day - 1)
					.AddHours(hour).AddMinutes(minute).AddSeconds(second);
				var utc = local - TimeZoneInfo.Local.GetUtcOffset(local);
				return Math.Floor((utc - DateTime.UnixEpoch).TotalSeconds);
			} catch (ArgumentException) {
				return -1;
			}
		}

		// One field of localtime (or gmtime) of a clock in seconds: 0 sec, 1 min, 2 hour, 3 mday, 4 mon,
		// 5 year, 6 wday. int.MinValue where the C library answers no tm (Windows' does before 1970).
		public static int TmField(double seconds, bool utc, int field) {
			if (useLibc) try {
				int* tm = stackalloc int[16];
				if (!CBrokenDown((long)seconds, utc, tm)) return int.MinValue;
				return tm[field];
			} catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException) {
				useLibc = false;
			}
			DateTime dt;
			try {
				var u = DateTime.UnixEpoch.AddSeconds(Math.Floor(seconds));
				dt = utc ? u : TimeZoneInfo.ConvertTimeFromUtc(u, TimeZoneInfo.Local);
			} catch (ArgumentException) {
				return int.MinValue;
			}
			switch (field) {
				case 0: return dt.Second;
				case 1: return dt.Minute;
				case 2: return dt.Hour;
				case 3: return dt.Day;
				case 4: return dt.Month - 1;
				case 5: return dt.Year - 1900;
				default: return (int)dt.DayOfWeek;
			}
		}

		// Date.getTimezoneOffset as the native host works it out: localtime and gmtime of the clock, each back
		// through mktime with tm_isdst -1, and their difference in minutes. 1e300 when localtime fails, 2e300
		// when gmtime does, 3e300 when either mktime does.
		public static double TimezoneOffset(double seconds) {
			if (useLibc) try {
				int* lt = stackalloc int[16];
				int* gt = stackalloc int[16];
				if (!CBrokenDown((long)seconds, false, lt)) return 1e300;
				if (!CBrokenDown((long)seconds, true, gt)) return 2e300;
				lt[8] = -1; gt[8] = -1;
				long a = CMktime(lt);
				if (a == -1) return 3e300;
				long b = CMktime(gt);
				if (b == -1) return 3e300;
				return ((double)b - (double)a) / 60.0;
			} catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException) {
				useLibc = false;
			}
			try {
				var u = DateTime.UnixEpoch.AddSeconds(Math.Floor(seconds));
				return -TimeZoneInfo.Local.GetUtcOffset(u).TotalMinutes;
			} catch (ArgumentException) {
				return 1e300;
			}
		}
	}
}
