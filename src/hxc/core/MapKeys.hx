package hxc.core;

import haxe.ds.IntMap;
import haxe.ds.StringMap;

// A map's keys as a typed array, in the order keys() visits them. keys() hands them out through
// Iterator<T>, an anonymous structure, so on hxcpp a loop over it looks hasNext and next up by name
// at every step; a loop over the array is indexed. Each call returns a new array. Takes
// IntMap/StringMap only: a Map<K, V> converts to them through @:multiType casts that build an empty
// map, so pass the concrete map.
class MapKeys {
	public static inline function ofInt<T>(m:IntMap<T>):Array<Int> {
		#if cpp
		return untyped __global__.__int_hash_keys(@:privateAccess m.h);
		#else
		return [for (k in m.keys()) k];
		#end
	}

	public static inline function ofString<T>(m:StringMap<T>):Array<String> {
		#if cpp
		return untyped __global__.__string_hash_keys(@:privateAccess m.h);
		#else
		return [for (k in m.keys()) k];
		#end
	}
}
