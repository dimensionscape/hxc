package hxc.core;

// File-system calls that cost much more on one host than on the others when written the plain way.
class HostFile {
	// A directory's entries, or null when it cannot be listed. On .NET a missing directory is asked for
	// first: the exception a failed listing raises there costs several times what the listing does.
	public static function readDirectoryOpt(dir:String):Null<Array<String>> {
		#if cs
		if (!cs.system.io.Directory.Exists(dir)) return null;
		#end
		return try sys.FileSystem.readDirectory(dir) catch (_:Dynamic) null;
	}
}
