// A library whose native libraries are beside it in runtimes/<rid>/native, as a NuGet package's are after a
// dotnet build. net10.0 for NativeLibrary; only hxc reads it.
using System.Runtime.InteropServices;
namespace NativeProbe {
	public static class Probe {
		// Looks for the native library as a DllImport of it would: in the program's folder, in what deps.json lists, or
		// where a self-contained program unpacked it.
		public static string Load(string name) {
			return NativeLibrary.TryLoad(name, typeof(Probe).Assembly, null, out _) ? "loaded " + name : "missing " + name;
		}
	}
}
