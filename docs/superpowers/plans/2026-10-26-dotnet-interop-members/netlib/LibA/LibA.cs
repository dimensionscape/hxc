using System.Collections.Generic;
namespace LibA {
	// Nested types, as the server app's Shared.ConfigSettings/DataPoolDef and Shared.AITools.ToolPlugin/ToolFunction.
	public class Outer {
		public class Inner {
			public int X;
			public Inner(int x) { X = x; }
			public static string Hello() { return "hello"; }
			public enum Mode { A, B = 5 }
			public Mode M = Mode.B;
			public class Deep { public string D = "deep"; }
		}
		public List<Inner> Items = new List<Inner> { new Inner(1), new Inner(2) };
		public static Inner Make(int x) { return new Inner(x); }
	}
	// Signatures naming LibB's types.
	public class Holder {
		public static LibB.Thing Get() { return new LibB.Thing(); }
		public static int Plain() { return 42; }
	}
	public class Panel : LibB.BaseCtl {
		public string Me() { return "panel"; }
		public override string Who() { return "Panel"; }
	}
}
