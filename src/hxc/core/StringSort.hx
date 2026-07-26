package hxc.core;

// Strings into increasing order, the order Reflect.compare gives them. Array.sort calls its comparator
// through Dynamic, which on hxcpp boxes both strings at every comparison; this compares them directly.
// Equal strings are interchangeable, so stability does not matter.
class StringSort {
	public static inline function compare(x:String, y:String):Int {
		return x < y ? -1 : (x > y ? 1 : 0);
	}

	public static function sort(a:Array<String>):Void {
		var n = a.length;
		if (n < 2) return;
		var lo = 0;
		while (lo < n) {
			var hi = lo + RUN;
			if (hi > n) hi = n;
			insertion(a, lo, hi);
			lo = hi;
		}
		if (n <= RUN) return;
		var src = a;
		var dst = a.copy();
		var width = RUN;
		while (width < n) {
			var lo = 0;
			while (lo < n) {
				var mid = lo + width;
				if (mid > n) mid = n;
				var hi = mid + width;
				if (hi > n) hi = n;
				var l = lo, r = mid, k = lo;
				while (l < mid && r < hi) {
					if (src[r] < src[l]) dst[k++] = src[r++];
					else dst[k++] = src[l++];
				}
				while (l < mid) dst[k++] = src[l++];
				while (r < hi) dst[k++] = src[r++];
				lo = hi;
			}
			var t = src;
			src = dst;
			dst = t;
			width <<= 1;
		}
		if (src != a) for (i in 0...n) a[i] = src[i];
	}

	public static function sortDescending(a:Array<String>):Void {
		sort(a);
		a.reverse();
	}

	static inline var RUN = 12;

	static function insertion(a:Array<String>, lo:Int, hi:Int):Void {
		for (i in lo + 1...hi) {
			var x = a[i];
			var j = i;
			while (j > lo && x < a[j - 1]) {
				a[j] = a[j - 1];
				j--;
			}
			a[j] = x;
		}
	}
}
