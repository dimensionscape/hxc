package hxc.core;

/**
	A value kept once per thread.

	sys.thread.Tls everywhere but on .NET: there every Tls shares one named slot (`__hx__Tls`), so two of
	them read each other's value. Each of these has a slot of its own.
**/
#if cs
class HostTls<T> {
	public var value(get, set):T;

	final slot:cs.system.LocalDataStoreSlot;

	public function new() {
		slot = cs.system.threading.Thread.AllocateDataSlot();
	}

	function get_value():T {
		return cs.system.threading.Thread.GetData(slot);
	}

	function set_value(v:T):T {
		cs.system.threading.Thread.SetData(slot, v);
		return v;
	}
}
#else
typedef HostTls<T> = sys.thread.Tls<T>;
#end
