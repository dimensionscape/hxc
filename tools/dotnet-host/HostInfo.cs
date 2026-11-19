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
	}
}
