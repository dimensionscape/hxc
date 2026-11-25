// A dependency of LibA that a case does not pass with --net-lib: hxc must find it beside LibA.dll.
namespace LibB {
	public class Thing {
		public int V = 5;
		public string Name() { return "thing"; }
	}
	public class BaseCtl {
		public bool Visible = true;
		public string Kind() { return "base"; }
		public virtual string Who() { return "BaseCtl"; }
	}
}
