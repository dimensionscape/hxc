// EvLib: .NET events for Haxe classes to define, implement and override (milestone 4c events).
using System;
using System.Reflection;
namespace ev {
	public delegate void Note(string s);
	// An interface event: a Haxe class implementing INotify must define the event.
	public interface INotify { event Note Noted; }
	public interface INotifyStatic { }
	// A base class with a virtual event, an abstract one and a plain one.
	public abstract class Base {
		Note v, p;
		public virtual event Note Virt { add { Console.WriteLine("Base.add_Virt"); v += value; } remove { Console.WriteLine("Base.remove_Virt"); v -= value; } }
		public abstract event Note Abs;
		public event Note Plain { add { p += value; } remove { p -= value; } }
		public void FireVirt(string s) { if (v != null) v(s); else Console.WriteLine("no Virt handler for " + s); }
	}
	// .NET events for Haxe code to consume: static, generic EventHandler<T>, and through an interface.
	public class NoteArgs : EventArgs { public string Text; public NoteArgs(string t) { Text = t; } }
	public class Source : INotify {
		Note n;
		public event Note Noted { add { Console.WriteLine("Source.add_Noted"); n += value; } remove { Console.WriteLine("Source.remove_Noted"); n -= value; } }
		public event EventHandler<NoteArgs> Generic;
		public static event Note StaticNoted;
		public void Fire(string s) { if (n != null) n(s); Generic?.Invoke(this, new NoteArgs(s)); }
		public static void FireStatic(string s) { if (StaticNoted != null) StaticNoted(s); else Console.WriteLine("no static handler for " + s); }
	}
	// What C# code does with an event of a Haxe-built object.
	public static class Use {
		// `+=` through the interface: callvirt INotify::add_Noted.
		public static void Subscribe(INotify n, string tag) { n.Noted += s => Console.WriteLine(tag + " got " + s); }
		public static void Unsubscribe(INotify n, Note d) { n.Noted -= d; }
		public static void SubscribeAbs(Base b, string tag) { b.Abs += s => Console.WriteLine(tag + " abs got " + s); }
		public static void SubscribeVirt(Base b, string tag) { b.Virt += s => Console.WriteLine(tag + " virt got " + s); }
		// `+=` through reflection, as a C# caller of a Haxe class that only metadata describes would bind it.
		public static string Reflect(object o, string name) {
			var t = o as Type ?? o.GetType();
			var target = o is Type ? null : o;
			var e = t.GetEvent(name, BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static);
			if (e == null) return "no event " + name + " on " + t.FullName;
			var add = e.GetAddMethod(true); var rem = e.GetRemoveMethod(true);
			var info = "event " + e.Name + " : " + e.EventHandlerType.Name + " attrs=" + e.Attributes
				+ " add=" + add.Name + "(" + add.Attributes + ") remove=" + rem.Name + "(" + rem.Attributes + ") multicast=" + e.IsMulticast;
			Delegate d = Delegate.CreateDelegate(e.EventHandlerType, typeof(Use).GetMethod("Got", BindingFlags.NonPublic | BindingFlags.Static));
			e.AddEventHandler(target, d);
			return info;
		}
		// What C# does for `target.m(flag)` where m takes a Haxe ?b:Bool (a haxe.lang.Null<bool>): the compiler
		// converts the bool through Null<bool>'s op_Implicit(T); an expression tree binds that conversion the same way.
		public static object CallWithBool(object target, string method, bool flag) {
			var mi = target.GetType().GetMethod(method);
			var arg = System.Linq.Expressions.Expression.Convert(System.Linq.Expressions.Expression.Constant(flag), mi.GetParameters()[0].ParameterType);
			var call = System.Linq.Expressions.Expression.Convert(System.Linq.Expressions.Expression.Call(System.Linq.Expressions.Expression.Constant(target), mi, arg), typeof(object));
			return System.Linq.Expressions.Expression.Lambda<System.Func<object>>(call).Compile()();
		}
		// C#'s `o.Name += handler` on an object only known at run time (a Type stands for its static event): subscribes a
		// handler that prints `tag got <text>` and returns it, for Detach's `-=`.
		public static Note Attach(object o, string name, string tag) {
			var t = o as Type ?? o.GetType();
			var target = o is Type ? null : o;
			var e = t.GetEvent(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static);
			Note d = s => Console.WriteLine(tag + " got " + s);
			e.AddEventHandler(target, d);
			return d;
		}
		public static void Detach(object o, string name, Note d) {
			var t = o as Type ?? o.GetType();
			var target = o is Type ? null : o;
			t.GetEvent(name, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static).RemoveEventHandler(target, d);
		}
		static void Got(string s) { Console.WriteLine("reflected handler got " + s); }
		public static string Events(Type t) {
			var r = "";
			foreach (var e in t.GetEvents(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly))
				r += (r == "" ? "" : "; ") + e.Name + ":" + e.EventHandlerType.Name;
			return t.Name + " events [" + r + "]";
		}
	}
}
namespace res {
	// C# reading an assembly's manifest resources (milestone 4c resources).
	public static class Reader {
		public static string Dump(System.Reflection.Assembly a) {
			var names = a.GetManifestResourceNames();
			System.Array.Sort(names, System.StringComparer.Ordinal);
			var sb = new System.Text.StringBuilder();
			foreach (var n in names) {
				using var s = a.GetManifestResourceStream(n);
				var ms = new System.IO.MemoryStream();
				s.CopyTo(ms);
				var b = ms.ToArray();
				var info = a.GetManifestResourceInfo(n);
				sb.Append(n).Append(' ').Append(b.Length).Append(' ').Append(System.BitConverter.ToString(System.Security.Cryptography.MD5.Create().ComputeHash(b)).Replace("-", "").ToLowerInvariant())
					.Append(' ').Append(info.ResourceLocation).Append('\n');
			}
			return sb.ToString();
		}
	}
}
