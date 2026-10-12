package hxc.debug;

// HXC_DBG_LIVEMARK=<file>: a full collection, then the live heap in KB, at named points inside a
// request, appended to the file as `<label> <kb>`. HXC_DBG_LIVEMEM measures what a request leaves
// behind; this measures what it holds while it runs, phase by phase. DEBUG only: every mark is a
// full collection.
class LiveMark {
	static var file:Null<String> = Sys.getEnv("HXC_DBG_LIVEMARK");

	public static function mark(label:String):Void {
		if (file == null) return;
		cpp.vm.Gc.run(true);
		var out = sys.io.File.append(file, false);
		out.writeString(label + " " + Std.int(cpp.vm.Gc.memInfo64(cpp.vm.Gc.MEM_INFO_USAGE) / 1024) + "\n");
		out.close();
	}
}
