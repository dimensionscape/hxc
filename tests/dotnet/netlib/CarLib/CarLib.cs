// Fixture for the carried-items probes (4c research, area "carried").
using System;
using System.Collections.Generic;
namespace car {
	// c. a non-virtual base member implementing an interface member of a Haxe subclass
	public interface INamed { string Name { get; } }
	public class BaseN { public string Name => "base"; }
	public static class Names { public static string Read(INamed n) => n.Name; }
	public interface IGreet { string Greet(string who); }
	public class BaseGN { public string Greet(string who) => "basegn " + who; }
	public static class Greets { public static string Call(IGreet g) => g.Greet("x"); }
	public interface IRW { int V { get; set; } }
	public class BaseRW { int v; public int V { get => v; set => v = value * 10; } }
	public static class RWs { public static int Bump(IRW r) { r.V = r.V + 1; return r.V; } }
	// e. .NET methods as method groups
	public delegate int IntFn(int x);
	public delegate string StrFn(string s);
	public static class Ext {
		public static int Twice(int x) => x * 2;
		public static int Ov(int x) => x + 1;
		public static string Ov(string s) => s + "!";
		public static int Apply(IntFn f, int v) => f(v);
		public static string ApplyS(StrFn f, string v) => f(v);
	}
	public class Inst { public int k = 3; public int Add(int x) => x + k; public virtual int Mul(int x) => x * k; }
	public class InstD : Inst { public override int Mul(int x) => -x; }
	public struct SVal { public int k; public SVal(int k) { this.k = k; } public int Add(int x) => x + k; }
	// f. a type-parameter-typed argument to overloaded .NET methods
	public static class Ovl {
		public static string F(object o) => "F(object)";
		public static string F(int i) => "F(int)";
		public static string F(string s) => "F(string)";
		public static string G<T>(T x) => "G<" + typeof(T).Name + ">";
		public static string H(object o) => "H(object)";
		public static string H(IComparable o) => "H(IComparable)";
		public static string Only(object o) => "Only(object)";
		public static string P(object o) => "P(object)";
		public static string P<T>(T x) => "P<" + typeof(T).Name + ">";
		public static string Q(object o, string s) => "Q(object,string)";
		public static string Q<T>(T x, string s) => "Q<" + typeof(T).Name + ">";
		public static string R(object a, object b) => "R(object,object)";
		public static string R<T>(T a, object b) => "R1<" + typeof(T).Name + ">";
		public static string R<T>(object a, T b) => "R2<" + typeof(T).Name + ">";
	}
	// g. converts refinements
	public static class Conv {
		public static string N(int? x) => "N(int?)";
		public static string N(long? x) => "N(long?)";
		public static string M(long? x) => "M(long?)";
		public static string M(string x) => "M(string)";
		public static string A(object[] a) => "A(object[])";
		public static string A(string[] a) => "A(string[])";
		public static string B(object[] a) => "B(object[])";
		public static string B(int x) => "B(int)";
		public static string C(params string[] a) => "C(params string[])";
		public static string C(params object[] a) => "C(params object[])";
	}
}
namespace car {
	// l. hiding across member kinds
	public class HBase { public virtual int P { get { return 1; } } public int F = 5; public int M() { return 7; } public int Q { get { return 11; } } }
	public class HDer : HBase { public new int P = 2; public new int F() { return 9; } public new int M = 8; public new int Q = 12; }
}
