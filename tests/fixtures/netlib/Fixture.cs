// Rebuild: dotnet build -c Release, then copy bin/Release/netstandard2.0/Fixture.dll to tests/cases/net-lib/fixture/.
// tests/cases/net-lib/fixture/stdB/net-40/Fixture.dll is an older build of this file (from commit 57ca212c). The
// two-std-dirs-in-command-line-order case only needs it to define fixture.Plain, so a current build can replace it.
namespace Fixture {
	public class Plain {
		public Plain() {} public Plain(int x) {}
		public int Count; public readonly double Ratio; public static string Name = "p"; public const int Max = 10;
		public int Add(int a, int b) => a + b; public static long Wide(long v) => v;
		public byte[] Bytes() => null; public uint Unsigned() => 0; public object Any() => null;
	}
	internal class Hidden {}
	public class UsesLambda { public System.Func<int, int> F() => x => x + 1; }
	public class Box<T> { public T Value; public U Map<U>(System.Func<T, U> f) => default; public class Nested { public T Item; } }
	public class Pair<A, B> where A : class where B : struct { public A First; public B Second; }
	public class Outer { public class Inner { public int V; } }
	public class Outer_Inner { public string W; }
	public class lowerName { public int X; }
	public class UsesNames { public Box<int>.Nested N; public Box<string> G; public Pair<string, int> P; public lowerName L; public Box<int>.Nested[] NA; }
	public class UsesInner { public Outer.Inner I; }
	public class UsesOuterInner { public Outer_Inner O; }
	public class Outer2<T> { public class Mid<U> { public class Leaf { public T A; public U B; } } }
	public class Derived : Box<string> { public string D; }
	public interface IGen<T> { T Get(); }
	public delegate R Fn<A, R>(A a);
	public class GenStatics { public static T Id<T>(T x) => x; public static void Two<A, B>(A a, B b) {} }
	public class WithEnum { public enum Kind { A, B } public Kind K; }
	public class Uses2 { public Outer2<int>.Mid<string>.Leaf L; public IGen<Box<int>> G; public Fn<int, string> F; public WithEnum.Kind K; }
	public class Keywords { public int @in; public void @cast() {} public int @var; }
	public interface IShape { double Area(); }
	public interface INamed { string Name(); }
	public class Square : IShape, INamed { public double Area() => 0; string INamed.Name() => "sq"; }
	public enum Color { Red, Green = 5 }
	[System.Flags] public enum Perm { None = 0, Read = 1, Write = 2 }
	public delegate int Op(int a, int b);
	public class Events { public event Op Fired; public int Size { get; set; } public int ReadOnly { get { return 1; } } public string this[int i] { get => null; set {} } }
	public class Overloads { public void F(int a) {} public void F(string a) {} public void F(int a, int b) {} }
	public struct Point { public int X; public Point(int x) { X = x; } }
	public class Ops { public static Ops operator +(Ops a, Ops b) => a; public static bool operator ==(Ops a, Ops b) => true; public static bool operator !=(Ops a, Ops b) => false; public override bool Equals(object o) => true; public override int GetHashCode() => 0; }
	public class ByRef { public void Fill(ref int a, out string b) { b = null; } }
	public class Nulls { public int? MaybeInt; public System.Nullable<double> MaybeDouble; }
	public class Ambiguous { public Ambiguous(string s) {} public Ambiguous(object o) {} public void A(string s) {} public void A(object o) {} }
	public class Guarded { public Guarded() {} protected Guarded(int a) {} }
}
namespace Fixture.Sub { public class Thing {} }
namespace Fixture.MixedCase.Deep { public class InDeep {} }
