// ModLib: .NET members whose signatures carry a required custom modifier (modreq), which hxc refuses to use for now:
// a volatile field (IsVolatile), an init-only setter (IsExternalInit) and the `in` parameter of a virtual method
// (InAttribute). Members of the same shapes without one are beside them, and work.
using System;
// netstandard2.0 has no IsExternalInit; the compiler takes this one by its name.
namespace System.Runtime.CompilerServices { internal static class IsExternalInit { } }
namespace modlib {
	public class Box {
		public volatile int V;
		public static volatile int S;
		public int Plain;
		public int I { get; init; }
		public virtual int M(in int x) { return x + 1; }
		// Not virtual: C# gives the `in` parameter no modreq, so it is an ordinary by-reference one.
		public int N(in int x) { return x + 2; }
		public ref readonly int R() { return ref Plain; }
		public Box() { I = 5; }
	}
}
