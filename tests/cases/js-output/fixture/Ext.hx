class Ext {
	public static inline function notNull<T>(it:Iterable<T>):Array<T> {
		return [for (x in it) if (null != x) x];
	}
}
