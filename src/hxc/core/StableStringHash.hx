package hxc.core;

/**
	A string's hash that is the same in every run.

	For a .NET-hosted hxc: .NET seeds String.GetHashCode afresh in each process, and haxe.ds.StringMap walks
	its keys in hash order, so anything that follows that order (a list of suggestions, say) would change
	from one run to the next. tools/dotnet-host/build.sh builds the compiler with a StringMap that hashes
	with this instead (FNV-1a over the UTF-16 code units).
**/
class StableStringHash {
	public static function hash(s:String):Int {
		var h = 0x811C9DC5;
		for (i in 0...s.length) h = (h ^ StringTools.fastCodeAt(s, i)) * 0x01000193;
		return h;
	}
}
