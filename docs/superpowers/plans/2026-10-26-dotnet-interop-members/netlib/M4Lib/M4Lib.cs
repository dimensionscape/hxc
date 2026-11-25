// Shapes for milestone 4a's members area (D:/_hxc4a/members). netstandard2.0 so Haxe 4.3.7's net-lib reads it.
using System;
using System.Collections.Generic;
namespace M4 {
	// 1. interface properties (IChatHandler's shape: get-only string properties, plus a method)
	public interface IHandler {
		string Guid { get; }
		string Prompt { get; }
		List<string> Plugins();
	}
	public interface ICounter {
		int Count { get; set; }
		string Label { get; }
	}
	public interface IWriteOnly { int Sink { set; } }
	public static class UseProps {
		public static string Read(IHandler h) => h.Guid + "/" + h.Prompt + "/" + h.Plugins().Count;
		public static string Bump(ICounter c) { c.Count = c.Count + 1; return c.Label + "=" + c.Count; }
		public static string Shape(Type t) {
			var s = new List<string>();
			foreach (var p in t.GetProperties(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.DeclaredOnly))
				s.Add("prop " + p.Name + (p.GetMethod != null ? " get" : "") + (p.SetMethod != null ? " set" : ""));
			return string.Join(", ", s);
		}
	}
	// 2. generic methods: overloads where a generic one precedes the non-generic one (NHibernate's ISession/IMultiQuery order)
	public interface ISess {
		string Make<T>() where T : class;
		string Make<T>(string alias) where T : class;
		string Make(Type t);
		string Make(string entityName);
		ICrit Crit(string entityName);
		T Get<T>(object id);
		IMulti Multi();
	}
	public interface ICrit {
		System.Collections.IList List();
		IList<T> List<T>();
		T Unique<T>();
		object Unique();
	}
	// two generic overloads
	public static class Picks {
		public static string Pick<T>(int id) => "Pick<" + Sess.Name(typeof(T)) + ">(int)";
		public static string Pick<T>(string s) => "Pick<" + Sess.Name(typeof(T)) + ">(string)";
		public static T Make<T>(T x, int n) => x;
		public static T Make<T>(T x, string s) => x;
	}
	// ICrit's overloads in the other metadata order
	public interface ICrit2 {
		IList<T> List<T>();
		System.Collections.IList List();
	}
	public class Crit2 : ICrit2 {
		public IList<T> List<T>() { Console.WriteLine("List<" + Sess.Name(typeof(T)) + ">()"); return new List<T>(); }
		public System.Collections.IList List() { Console.WriteLine("List()"); return new System.Collections.ArrayList { 1, 2 }; }
	}
	public interface IMulti {
		IMulti Add(Type t, string q);
		IMulti Add<T>(string q);
		IMulti Add<T>(string key, string q);
		IMulti Add(string q);
		int Count { get; }
	}
	public class Rec { public string Name; public Rec(string n) { Name = n; } public override string ToString() => "Rec(" + Name + ")"; }
	public class Sess : ISess, ICrit, IMulti {
		List<string> log = new List<string>();
		public string Make<T>() where T : class => "Make<" + typeof(T).Name + ">()";
		public string Make<T>(string alias) where T : class => "Make<" + typeof(T).Name + ">(" + alias + ")";
		public string Make(Type t) => "Make(Type " + t.Name + ")";
		public string Make(string entityName) => "Make(" + entityName + ")";
		public ICrit Crit(string entityName) => this;
		public T Get<T>(object id) { Console.WriteLine("Get<" + Name(typeof(T)) + ">(" + id + ")"); return default(T); }
		public IMulti Multi() => this;
		public System.Collections.IList List() { Console.WriteLine("List()"); return new System.Collections.ArrayList { 1, 2 }; }
		public IList<T> List<T>() { Console.WriteLine("List<" + Name(typeof(T)) + ">()"); return new List<T>(); }
		public T Unique<T>() { Console.WriteLine("Unique<" + Name(typeof(T)) + ">()"); return default(T); }
		public object Unique() { Console.WriteLine("Unique()"); return null; }
		public IMulti Add(Type t, string q) { log.Add("Add(Type,q)"); return this; }
		public IMulti Add<T>(string q) { log.Add("Add<" + Name(typeof(T)) + ">(" + q + ")"); return this; }
		public IMulti Add<T>(string key, string q) { log.Add("Add<" + Name(typeof(T)) + ">(key,q)"); return this; }
		public IMulti Add(string q) { log.Add("Add(" + q + ")"); return this; }
		public int Count => log.Count;
		public string Log => string.Join(" ", log);
		public static string Name(Type t) => t.IsGenericType ? t.Name + "[" + string.Join(",", Array.ConvertAll(t.GetGenericArguments(), Name)) + "]" : t.FullName ?? t.Name;
	}
	public static class Gen {
		public static T Id<T>(T x) { Console.WriteLine("Id<" + Sess.Name(typeof(T)) + ">"); return x; }
		public static List<T> Of<T>(T a, T b) { Console.WriteLine("Of<" + Sess.Name(typeof(T)) + ">"); return new List<T> { a, b }; }
		public static string Type<T>() => Sess.Name(typeof(T));
		public static T Make<T>() where T : new() => new T();
		public static string Apply<T, R>(Func<T, R> f, T x) => "Apply<" + Sess.Name(typeof(T)) + "," + Sess.Name(typeof(R)) + ">=" + f(x);
		public static int Count<T>(IEnumerable<T> e) { int n = 0; foreach (var _ in e) n++; Console.WriteLine("Count<" + Sess.Name(typeof(T)) + ">"); return n; }
		public static string First<T>(T[] a) => "First<" + Sess.Name(typeof(T)) + ">=" + a[0];
	}
	// 2b. generic interface methods implemented by Haxe; generic base class methods overridden by Haxe
	public interface IVisitor { string Visit<T>(T x); }
	public interface IBox<T> { T Get(); void Set(T v); }
	public static class UseGen {
		public static string Visit(IVisitor v) => v.Visit(1) + "," + v.Visit("s");
		public static string RoundTrip(IBox<string> b) { b.Set("x"); return b.Get(); }
		public static string Call(Base<string> b) => b.Show("v") + "|" + b.Name();
	}
	public class Base<T> {
		public virtual string Show(T x) => "Base.Show(" + x + ")";
		public virtual string Name() => "Base";
	}
	public class Vec<T> {
		public T X; public Vec(T x) { X = x; }
		public static Vec<T> operator +(Vec<T> a, Vec<T> b) => a;
		public static bool operator ==(Vec<T> a, Vec<T> b) => ReferenceEquals(a, b) || (!ReferenceEquals(a, null) && !ReferenceEquals(b, null) && Equals(a.X, b.X));
		public static bool operator !=(Vec<T> a, Vec<T> b) => !(a == b);
		public override bool Equals(object o) => o is Vec<T> v && Equals(v.X, X);
		public override int GetHashCode() => 0;
	}
	// 3. delegates and events
	public delegate bool Check(object sender, string cert, int errors);
	public delegate void Note(string s);
	public class Client {
		public Check Validate { get; set; }
		public Func<string, bool> Filter;
		public event Note Noted;
		public event EventHandler Changed;
		public string Run() => Validate == null ? "no validator" : "valid=" + Validate(this, "cert", 0) + "," + Validate(this, "bad", 2);
		public string RunFilter() => Filter == null ? "no filter" : "filter=" + Filter("a") + "," + Filter("bb");
		public void Fire(string s) { if (Noted != null) Noted(s); else Console.WriteLine("nobody noted " + s); Changed?.Invoke(this, EventArgs.Empty); }
	}
	public static class Lists {
		public static List<string> Names() => new List<string> { "ann", "bob", "cy" };
		public static int Sum(int[] a) { int s = 0; foreach (var x in a) s += x; return s; }
		public static string[] Split(string s) => s.Split(',');
		public static void Fill(int[] a) { for (int i = 0; i < a.Length; i++) a[i] = i * 10; }
		public static float[] Floats(int n) { var r = new float[n]; for (int i = 0; i < n; i++) r[i] = i + 0.5f; return r; }
		public static string Join(string[] a) => string.Join("|", a);
		public static int Len(object[] a) => a.Length;
	}
	public class Outer { public class Inner { public string Name = "inner"; } public System.Collections.Generic.List<Inner> Items = new System.Collections.Generic.List<Inner> { new Inner() }; }
	public interface IPing { string Ping(); }
	public interface IPingMore : IPing { string More(); }
	public interface IFiles { void OnFiles(string[] paths); }
	public static class Dialogs { public static void Open(IFiles l) { l.OnFiles(new[] { "a.txt", "b.txt" }); } }
}
