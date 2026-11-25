/*
 * Copyright (C)2005-2019 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

package cs.internal;

import cs.Lib;
import cs.Lib.*;
import cs.NativeArray;
import cs.StdTypes;
import cs.system.Activator;
import cs.system.IConvertible;
import cs.system.IComparable;
import cs.system.reflection.MethodBase;
import cs.system.reflection.MethodInfo;
import cs.system.reflection.*;
import cs.system.Type;
import cs.system.Object;

/**
	This class is meant for internal compiler use only. It provides the Haxe runtime
	compatibility to the host language.
**/
@:nativeGen
@:native('haxe.lang.Runtime')
@:access(String)
@:access(Array)
@:keep class Runtime {
	@:readOnly public static var undefined(default, never):Dynamic = new cs.system.Object();

	// hxc: these overloads, for a receiver known to be an HxObject, are C# class code in hxcs.
	@:overload public static function getField(obj:HxObject, field:String, fieldHash:Int, throwErrors:Bool):Dynamic {
		if (obj == null && !throwErrors)
			return null;
		return obj.__hx_getField(field, (fieldHash == 0) ? FieldLookup.hash(field) : fieldHash, throwErrors, false, false);
	}

	@:overload public static function getField_f(obj:HxObject, field:String, fieldHash:Int, throwErrors:Bool):Float {
		if (obj == null && !throwErrors)
			return 0.0;
		return obj.__hx_getField_f(field, (fieldHash == 0) ? FieldLookup.hash(field) : fieldHash, throwErrors, false);
	}

	@:overload public static function setField(obj:HxObject, field:String, fieldHash:Int, value:Dynamic):Dynamic {
		return obj.__hx_setField(field, (fieldHash == 0) ? FieldLookup.hash(field) : fieldHash, value, false);
	}

	@:overload public static function setField_f(obj:HxObject, field:String, fieldHash:Int, value:Float):Float {
		return obj.__hx_setField_f(field, (fieldHash == 0) ? FieldLookup.hash(field) : fieldHash, value, false);
	}

	@:overload public static function callField(obj:HxObject, field:String, fieldHash:Int, args:cs.NativeArray<Dynamic>):Dynamic {
		return obj.__hx_invokeField(field, (fieldHash == 0) ? FieldLookup.hash(field) : fieldHash, args);
	}

	public static function closure(obj:Dynamic, hash:Int, field:String):Dynamic {
		return new cs.internal.Function.Closure(obj, field, hash);
	}

	public static function eq(v1:Dynamic, v2:Dynamic):Bool {
		if (Object.ReferenceEquals(v1, v2))
			return true;
		if (Object.ReferenceEquals(v1, null) || Object.ReferenceEquals(v2, null))
			return false;

		var v1c = Lib.as(v1, IConvertible);
		if (v1c != null) {
			var v2c = Lib.as(v2, IConvertible);
			if (v2c == null) {
				return false;
			}

			var t1 = v1c.GetTypeCode(), t2 = v2c.GetTypeCode();
			if (t1 == t2)
				return Object._Equals(v1c, v2c);

			if (t1 == cs.system.TypeCode.String || t2 == cs.system.TypeCode.String)
				return false;

			switch [t1, t2] {
				case [Decimal, _] | [_, Decimal]:
					return v1c.ToDecimal(null) == v2c.ToDecimal(null);
				case [Int64, _] | [_, Int64]:
					return v1c.ToInt64(null) == v2c.ToInt64(null);
				case [UInt64 | DateTime, _] | [_, UInt64 | DateTime]:
					return v1c.ToUInt64(null) == v2c.ToUInt64(null);
				case [Double | Single, _] | [_, Double | Single]:
					return v1c.ToDouble(null) == v2c.ToDouble(null);
				case _:
					return v1c.ToInt32(null) == v2c.ToInt32(null);
			}
		}

		var v1v = Lib.as(v1, cs.system.ValueType);
		if (v1v != null) {
			return v1.Equals(v2);
		#if !erase_generics
		}
		else {
			var v1t = Lib.as(v1, Type);
			if (v1t != null) {
				var v2t = Lib.as(v2, Type);
				if (v2t != null)
					return typeEq(v1t, v2t);
				return false;
			}
		#end
		}

		// hxc: an Array and its #8314 forward are one array (casts notes §2.6). Neither is IConvertible, a
		// value type or a Type, so resolving here, last, is resolving first.
		return Object.ReferenceEquals(Array.__hx_resolveOf(v1), Array.__hx_resolveOf(v2));
	}

	public static function refEq(v1:{}, v2:{}):Bool {
		#if !erase_generics
		if (Std.isOfType(v1, Type))
			return typeEq(Lib.as(v1, Type), Lib.as(v2, Type));
		#end
		// hxc: an Array and its #8314 forward are one array, as in eq.
		return Object.ReferenceEquals(v1, v2) || Object.ReferenceEquals(Array.__hx_resolveOf(v1), Array.__hx_resolveOf(v2));
	}

	public static function toDouble(obj:Dynamic):Float {
		return (obj == null) ? .0 : Std.isOfType(obj, Float) ? cast obj : Lib.as(obj, IConvertible).ToDouble(null);
	}

	public static function toInt(obj:Dynamic):Int {
		return (obj == null) ? 0 : Std.isOfType(obj, Int) ? cast obj : Lib.as(obj, IConvertible).ToInt32(null);
	}

	#if erase_generics
	public static function toLong(obj:Dynamic):Int64 {
		return (obj == null) ? 0 : Std.isOfType(obj, Int64) ? cast obj : Lib.as(obj, IConvertible).ToInt64(null);
	}
	#end

	public static function isInt(obj:Dynamic):Bool {
		var cv1 = Lib.as(obj, IConvertible);
		if (cv1 != null) {
			switch (cv1.GetTypeCode()) {
				case Double:
					var d:Float = cast obj;
					return d >= cs.system.Int32.MinValue && d <= cs.system.Int32.MaxValue && d == (cast(d, Int));
				case UInt32, Int32:
					return true;
				default:
					return false;
			}
		}
		return false;
	}

	public static function isUInt(obj:Dynamic):Bool {
		var cv1 = Lib.as(obj, IConvertible);
		if (cv1 != null) {
			switch (cv1.GetTypeCode()) {
				case Double:
					var d:Float = cast obj;
					return d >= cs.system.UInt32.MinValue && d <= cs.system.UInt32.MaxValue && d == (cast(d, UInt));
				case UInt32:
					return true;
				default:
					return false;
			}
		}
		return false;
	}

	public static function compare(v1:Dynamic, v2:Dynamic):Int {
		if (Object.ReferenceEquals(v1, v2))
			return 0;
		if (Object.ReferenceEquals(v1, null))
			return -1;
		if (Object.ReferenceEquals(v2, null))
			return 1;

		var cv1 = Lib.as(v1, IConvertible);
		if (cv1 != null) {
			var cv2 = Lib.as(v2, IConvertible);

			if (cv2 == null) {
				throw new cs.system.ArgumentException("Cannot compare " + getNativeType(v1).ToString() + " and " + getNativeType(v2).ToString());
			}

			switch (cv1.GetTypeCode()) {
				case cs.system.TypeCode.String:
					if (cv2.GetTypeCode() != cs.system.TypeCode.String)
						throw new cs.system.ArgumentException("Cannot compare " + getNativeType(v1).ToString() + " and " + getNativeType(v2).ToString());
					var s1 = Lib.as(v1, String);
					var s2 = Lib.as(v2, String);
					return String.Compare(s1, s2, cs.system.StringComparison.Ordinal);
				case cs.system.TypeCode.Double:
					var d1:Float = cast v1, d2:Float = cv2.ToDouble(null);
					return (d1 < d2) ? -1 : (d1 > d2) ? 1 : 0;
				default:
					var d1d = cv1.ToDouble(null);
					var d2d = cv2.ToDouble(null);
					return (d1d < d2d) ? -1 : (d1d > d2d) ? 1 : 0;
			}
		}

		var c1 = Lib.as(v1, IComparable);
		var c2 = Lib.as(v2, IComparable);

		if (c1 == null || c2 == null) {
			throw new cs.system.ArgumentException("Cannot compare " + getNativeType(v1).ToString() + " and " + getNativeType(v2).ToString());
		}

		return c1.CompareTo(c2);
	}

	public static function plus(v1:Dynamic, v2:Dynamic):Dynamic {
		if (Std.isOfType(v1, String) || Std.isOfType(v2, String))
			return Std.string(v1) + Std.string(v2);

		if (v1 == null) {
			if (v2 == null)
				return null;
			v1 = 0;
		} else if (v2 == null)
			v2 = 0;

		var cv1 = Lib.as(v1, IConvertible);
		if (cv1 != null) {
			var cv2 = Lib.as(v2, IConvertible);
			if (cv2 == null) {
				throw new cs.system.ArgumentException("Cannot dynamically add " + cs.Lib.getNativeType(v1).ToString() + " and "
					+ cs.Lib.getNativeType(v2).ToString());
			}
			return cv1.ToDouble(null) + cv2.ToDouble(null);
		}

		throw new cs.system.ArgumentException("Cannot dynamically add " + v1 + " and " + v2);
	}

	// hxc: hxcs builds these with cs.Flags, whose constructor takes the enum as an optional argument, a
	// Null<T> of it; the flags are the same values joined with C#'s `|`.
	extern static inline function instanceFlags():BindingFlags {
		return cast((cast BindingFlags.Instance : Int) | (cast BindingFlags.Public : Int) | (cast BindingFlags.FlattenHierarchy : Int));
	}

	extern static inline function staticFlags():BindingFlags {
		return cast((cast BindingFlags.Static : Int) | (cast BindingFlags.Public : Int));
	}

	public static function slowGetField(obj:Dynamic, field:String, throwErrors:Bool):Dynamic {
		if (obj == null)
			if (throwErrors)
				throw new cs.system.NullReferenceException("Cannot access field \'" + field + "\' of null.");
			else
				return null;

		var t = Lib.as(obj, cs.system.Type);
		var bf = if (t == null) {
			var s = Lib.as(obj, String);
			if (s != null)
				return cs.internal.StringExt.StringRefl.handleGetField(s, field, throwErrors);
			t = obj.GetType();
			instanceFlags();
		} else {
			if (t == Lib.toNativeType(String) && field == "fromCharCode")
				return new cs.internal.Function.Closure(StringExt, field, 0);

			obj = null;
			staticFlags();
		}

		var f = t.GetField(field, bf);
		if (f != null) {
			return unbox(f.GetValue(obj));
		} else {
			var prop = t.GetProperty(field, bf);
			if (prop == null) {
				var m = t.GetMember(field, bf);
				if (m.length == 0 && (field == "__get" || field == "__set"))
					m = t.GetMember(field == "__get" ? "get_Item" : "set_Item", bf);

				if (m.Length > 0) {
					return new cs.internal.Function.Closure(obj != null ? obj : t, field, 0);
				} else {
					// COM object handling
					if (t.IsCOMObject) {
						try {
							return t.InvokeMember(field, BindingFlags.GetProperty, null, obj, new cs.NativeArray(0));
						} catch (e:cs.system.Exception) {
							// Closures of COM objects not supported currently
						}
					}

					if (throwErrors)
						throw "Cannot access field \'" + field + "\'.";
					else
						return null;
				}
			}
			return unbox(prop.GetValue(obj, null));
		}
	}

	public static function slowHasField(obj:Dynamic, field:String):Bool {
		if (obj == null)
			return false;
		var t = Lib.as(obj, cs.system.Type);
		var bf = if (t == null) {
			var s = Lib.as(obj, String);
			if (s != null)
				return cs.internal.StringExt.StringRefl.handleGetField(s, field, false) != null;
			t = obj.GetType();
			instanceFlags();
		} else {
			if (t == Lib.toNativeType(String))
				return field == "fromCharCode";
			obj = null;
			staticFlags();
		}
		var mi = t.GetMember(field, bf);
		return mi != null && mi.length > 0;
	}

	public static function slowSetField(obj:Dynamic, field:String, value:Dynamic):Dynamic {
		if (obj == null)
			throw new cs.system.NullReferenceException("Cannot access field \'" + field + "\' of null.");

		var t = Lib.as(obj, cs.system.Type);
		var bf = if (t == null) {
			t = obj.GetType();
			instanceFlags();
		} else {
			obj = null;
			staticFlags();
		}

		var f = t.GetField(field, bf);
		if (f != null) {
			if (f.FieldType.ToString().StartsWith("haxe.lang.Null")) {
				value = mkNullable(value, f.FieldType);
			}
			if (value != null
				&& Object.ReferenceEquals(Lib.toNativeType(cs.system.Double), Lib.getNativeType(value))
				&& !Object.ReferenceEquals(t, f.FieldType)) {
				var ic = Lib.as(value, IConvertible);
				value = ic.ToType(f.FieldType, null);
			}

			f.SetValue(obj, value);
			return value;
		} else {
			var prop = t.GetProperty(field, bf);
			if (prop == null) {
				// COM object handling
				if (t.IsCOMObject) {
					try {
						return t.InvokeMember(field, BindingFlags.SetProperty, null, obj, cs.NativeArray.make(value));
					} catch (e:cs.system.Exception) {
						// Closures of COM objects not supported currently
					}
				}
				throw "Field \'" + field + "\' not found for writing from Class " + t;
			}

			if (prop.PropertyType.ToString().StartsWith("haxe.lang.Null")) {
				value = mkNullable(value, prop.PropertyType);
			}
			if (Object.ReferenceEquals(Lib.toNativeType(cs.system.Double), Lib.getNativeType(value))
				&& !Object.ReferenceEquals(t, prop.PropertyType)) {
				var ic = Lib.as(value, IConvertible);
				value = ic.ToType(prop.PropertyType, null);
			}
			prop.SetValue(obj, value, null);

			return value;
		}
	}

	public static function callMethod(obj:Dynamic, methods:NativeArray<MethodBase>, methodLength:Int, args:cs.NativeArray<Dynamic>):Dynamic {
		return callMethodCasting(obj, methods, methodLength, args, true);
	}

	// hxc: callMethod, which casts an argument that is another instantiation of a generic Haxe class only
	// when `castInstances` is true; otherwise the call throws ArgumentException, as hxcs's does.
	static function callMethodCasting(obj:Dynamic, methods:NativeArray<MethodBase>, methodLength:Int, args:cs.NativeArray<Dynamic>, castInstances:Bool):Dynamic {
		if (methodLength == 0)
			throw "No available methods";
		var length = args.length;
		var oargs:NativeArray<Dynamic> = new NativeArray(length);
		var ts:NativeArray<Type> = new NativeArray(length);
		var rates:NativeArray<Int> = new NativeArray(methods.Length);

		for (i in 0...length) {
			oargs[i] = args[i];
			if (args[i] != null)
				ts[i] = Lib.getNativeType(args[i]);
		}

		var last = 0;

		// first filter by number of parameters and if it is assignable
		if (methodLength > 1) {
			for (i in 0...methodLength) {
				var params = methods[i].GetParameters();
				if (params.Length != length) {
					continue;
				} else {
					var fits = true, crate = 0;
					for (i in 0...params.Length) {
						var param = params[i].ParameterType;
						var strParam = param + "";
						if (param.IsAssignableFrom(ts[i]) || (ts[i] == null && !param.IsValueType)) {
							// if it is directly assignable, we'll give it top rate
							continue;
						} else if (untyped strParam.StartsWith("haxe.lang.Null")
							|| ((oargs[i] == null || Std.isOfType(oargs[i], IConvertible))
								&& cast(untyped __typeof__(IConvertible), Type).IsAssignableFrom(param))) {
							// if it needs conversion, give a penalty. TODO rate penalty
							crate++;
							continue;
						} else if (!param.ContainsGenericParameters) { // generics don't appear as assignable, but may be in the end. no rate there.
							fits = false;
							break;
						}
					}

					if (fits) {
						rates[last] = crate;
						methods[last++] = methods[i];
					}
				}
			}

			methodLength = last;
		} else if (methodLength == 1 && methods[0].GetParameters().Length != length) {
			methodLength = 0;
		}

		// At this time, we should be left with only one method.
		// Of course, realistically, we can be left with plenty of methods, if there are lots of variants with IConvertible
		// But at this time we still aren't rating the best methods
		// FIXME rate best methods

		if (methodLength == 0)
			throw "Invalid calling parameters for method " + methods[0].Name;

		var best = cs.system.Double.PositiveInfinity;
		var bestMethod = 0;
		for (i in 0...methodLength) {
			if (rates[i] < best) {
				bestMethod = i;
				best = rates[i];
			}
		}

		methods[0] = methods[bestMethod];
		var params = methods[0].GetParameters();
		for (i in 0...params.Length) {
			var param = params[i].ParameterType;
			var strParam = param + "", arg = oargs[i];
			if (StringTools.startsWith(strParam, "haxe.lang.Null")) {
				oargs[i] = mkNullable(arg, param);
			} else if (cast(untyped __typeof__(IConvertible), Type).IsAssignableFrom(param)) {
				if (arg == null) {
					if (param.IsValueType)
						oargs[i] = Activator.CreateInstance(param);
				} else if (!cs.Lib.getNativeType(arg).IsAssignableFrom(param)) {
					oargs[i] = cast(arg, IConvertible).ToType(param, null);
				}
			} else if (castInstances && arg != null && param.IsGenericType && !param.ContainsGenericParameters && Std.isOfType(arg, cs.internal.HxObject.IGenericObject) && !param.IsAssignableFrom(cs.Lib.getNativeType(arg))) {
				// hxc: another instantiation of a generic Haxe class goes through __hx_cast, as a typed call
				// converts it; hxcs's reflection call throws ArgumentException (plan 3c, decision 4). A
				// parameter with an open type parameter (a generic method's definition) has no instantiation.
				oargs[i] = instanceCast(arg, param);
			}
		}

		if (methods[0].ContainsGenericParameters && Std.isOfType(methods[0], cs.system.reflection.MethodInfo)) {
			var m:MethodInfo = cast methods[0];
			var tgs = m.GetGenericArguments();
			for (i in 0...tgs.Length) {
				tgs[i] = untyped __typeof__(Dynamic);
			}
			m = m.MakeGenericMethod(tgs);
			var retg = try
				m.Invoke(obj, oargs)
			catch(e:TargetInvocationException)
				throw e.InnerException;
			return cs.internal.Runtime.unbox(retg);
		}

		var m = methods[0];
		if (obj == null && Std.isOfType(m, cs.system.reflection.ConstructorInfo)) {
			var ret = try
				cast(m, cs.system.reflection.ConstructorInfo).Invoke(oargs)
			catch(e:TargetInvocationException)
				throw e.InnerException;
			return unbox(ret);
		}

		var ret = try
			m.Invoke(obj, oargs)
		catch(e:TargetInvocationException)
			throw e.InnerException;
		return unbox(ret);
	}

	// hxc: `arg` as the instantiation `t` of a generic Haxe class or interface, through the class's
	// `X<object…>.__hx_cast<…>` or the interface's `X__Statics_.__hx_cast<…>`, as hxc's typed casts go
	// (InstantiationCasts); `arg` itself when `t` has no such helper.
	static function instanceCast(arg:Dynamic, t:Type):Dynamic {
		var def = t.GetGenericTypeDefinition();
		var holder:Type = null;
		if (def.IsInterface) {
			var name = def.FullName;
			var tick = name.indexOf("`");
			holder = def.Assembly.GetType((tick < 0 ? name : name.substr(0, tick)) + "__Statics_");
		} else {
			var objects = new NativeArray<Type>(def.GetGenericArguments().Length);
			for (i in 0...objects.Length)
				objects[i] = untyped __typeof__(Dynamic);
			holder = def.MakeGenericType(objects);
		}
		var m = holder == null ? null : holder.GetMethod("__hx_cast");
		if (m == null)
			return arg;
		var args = new NativeArray<Dynamic>(1);
		args[0] = arg;
		return try m.MakeGenericMethod(t.GetGenericArguments()).Invoke(null, args) catch (e:TargetInvocationException) throw e.InnerException;
	}

	public static function unbox(dyn:Dynamic):Dynamic {
		if (dyn != null && untyped (Lib.getNativeType(dyn) + "").StartsWith("haxe.lang.Null")) {
			return dyn.toDynamic();
		} else {
			return dyn;
		}
	}

	#if !erase_generics
	// hxc: hxcs's C# called Null<object>.ofDynamic<object> for an open type and the closed type's
	// _ofDynamic otherwise. A closed type's generic ofDynamic, given the type's own argument, is what
	// _ofDynamic was.
	public static function mkNullable(obj:Dynamic, nullableType:Type):Dynamic {
		var t = nullableType;
		if (t.ContainsGenericParameters) {
			var objectArg = new cs.NativeArray<Type>(1);
			objectArg[0] = untyped __typeof__(Dynamic);
			t = t.GetGenericTypeDefinition().MakeGenericType(objectArg);
		}
		var args = new cs.NativeArray<Dynamic>(1);
		args[0] = obj;
		return t.GetMethod("ofDynamic").MakeGenericMethod(t.GetGenericArguments()).Invoke(null, args);
	}
	#else
	public static function mkNullable(obj:Dynamic, nullable:Type):Dynamic {
		return obj; // do nothing
	}
	#end

	public static function slowCallField(obj:Dynamic, field:String, args:cs.NativeArray<Dynamic>):Dynamic {
		return slowCallFieldCasting(obj, field, args, true);
	}

	// hxc: slowCallField, with callMethodCasting's `castInstances`.
	static function slowCallFieldCasting(obj:Dynamic, field:String, args:cs.NativeArray<Dynamic>, castInstances:Bool):Dynamic {
		if (field == "toString" && (args == null || args.length == 0)) {
			return obj.ToString();
		}
		if (args == null)
			args = new cs.NativeArray(0);

		var bf:BindingFlags;
		var t = Lib.as(obj, cs.system.Type);
		if (t == null) {
			var s = Lib.as(obj, String);
			if (s != null)
				return cs.internal.StringExt.StringRefl.handleCallField(untyped s, untyped field, args);
			t = untyped obj.GetType();
			bf = instanceFlags();
		} else {
			if (t == Lib.toNativeType(String) && field == 'fromCharCode')
				return cs.internal.StringExt.fromCharCode(toInt(args[0]));
			obj = null;
			bf = staticFlags();
		}

		var mis:NativeArray<MethodBase> = untyped t.GetMethods(bf);
		var last = 0;
		for (i in 0...mis.Length) {
			var name = mis[i].Name;
			if (name == field)
				mis[last++] = mis[i];
		}

		if (last == 0 && (field == "__get" || field == "__set")) {
			field = field == "__get" ? "get_Item" : "set_Item";
			for (i in 0...mis.Length) {
				var name = mis[i].Name;
				if (name == field) {
					mis[last++] = mis[i];
				}
			}
		}

		if (last == 0 && t.IsCOMObject)
			return t.InvokeMember(field, BindingFlags.InvokeMethod, null, obj, args);

		if (last == 0) {
			throw 'Method "$field" not found on type $t';
		}

		return Runtime.callMethodCasting(obj, mis, last, args, castInstances);
	}

	@:overload public static function callField(obj:Dynamic, field:String, fieldHash:Int, args:cs.NativeArray<Dynamic>):Dynamic {
		var hxObj = Lib.as(obj, HxObject);
		if (hxObj != null)
			return untyped hxObj.__hx_invokeField(field, (fieldHash == 0) ? FieldLookup.hash(field) : fieldHash, args);
		return slowCallField(obj, field, args);
	}

	@:overload public static function getField(obj:Dynamic, field:String, fieldHash:Int, throwErrors:Bool):Dynamic {
		var hxObj = Lib.as(obj, HxObject);
		if (hxObj != null)
			return untyped hxObj.__hx_getField(field, (fieldHash == 0) ? FieldLookup.hash(field) : fieldHash, throwErrors, false, false);

		return slowGetField(obj, field, throwErrors);
	}

	@:overload public static function getField_f(obj:Dynamic, field:String, fieldHash:Int, throwErrors:Bool):Float {
		var hxObj = Lib.as(obj, HxObject);
		if (hxObj != null)
			return untyped hxObj.__hx_getField_f(field, (fieldHash == 0) ? FieldLookup.hash(field) : fieldHash, throwErrors, false);

		return toDouble(slowGetField(obj, field, throwErrors));
	}

	@:overload public static function setField(obj:Dynamic, field:String, fieldHash:Int, value:Dynamic):Dynamic {
		var hxObj = Lib.as(obj, HxObject);
		if (hxObj != null)
			return untyped hxObj.__hx_setField(field, (fieldHash == 0) ? FieldLookup.hash(field) : fieldHash, value, false);

		return slowSetField(obj, field, value);
	}

	@:overload public static function setField_f(obj:Dynamic, field:String, fieldHash:Int, value:Float):Float {
		var hxObj = Lib.as(obj, HxObject);
		if (hxObj != null)
			return untyped hxObj.__hx_setField_f(field, (fieldHash == 0) ? FieldLookup.hash(field) : fieldHash, value, false);

		return toDouble(slowSetField(obj, field, value));
	}

	public static function toString(obj:Dynamic):String {
		if (obj == null)
			return null;
		if (Std.isOfType(obj, Bool))
			if (obj)
				return "true";
			else
				return "false";

		return untyped obj.ToString();
	}

	#if erase_generics
	inline
	#end
	public static function typeEq(t1:Type, t2:Type):Bool {
		if (t1 == null || t2 == null)
			return t1 == t2;
		#if !erase_generics
		var t1i = t1.IsInterface, t2i = t2.IsInterface;
		if (t1i != t2i) {
			if (t1i) {
				var g = getGenericAttr(t1);
				if (g != null)
					t1 = g.generic;
			} else {
				var g = getGenericAttr(t2);
				if (g != null)
					t2 = g.generic;
			}
		}
		#end
		if (t1.GetGenericArguments().Length > 0)
			t1 = t1.GetGenericTypeDefinition();
		if (t2.GetGenericArguments().Length > 0)
			t2 = t2.GetGenericTypeDefinition();
		return Object.ReferenceEquals(t1, t2);
	}

	#if !erase_generics
	public static function getGenericAttr(t:cs.system.Type):cs.internal.HxObject.GenericInterface {
		for (attr in t.GetCustomAttributes(true))
			if (Std.isOfType(attr, cs.internal.HxObject.GenericInterface))
				return cast attr;
		return null;
	}
	#end

	#if !erase_generics
	// hxc: hxcs's C#, in Haxe.
	public static function genericCast<To>(obj:Dynamic):To {
		if (untyped __is__(obj, To))
			return cast obj;
		else if (obj == null)
			return cast null;
		var to:Type = untyped __typeof__(To);
		var tDouble:Type = untyped __typeof__(Float), tInt:Type = untyped __typeof__(Int);
		var tSingle:Type = untyped __typeof__(Single), tLong:Type = untyped __typeof__(cs.StdTypes.Int64);
		if (to == tDouble)
			return cast toDouble(obj);
		else if (to == tInt)
			return cast toInt(obj);
		else if (to == tSingle)
			return cast(toDouble(obj) : Single);
		else if (to == tLong)
			return cast(cast toDouble(obj) : cs.StdTypes.Int64);
		else
			return cast obj;
	}
	#end

	// hxc: C#'s cast of an object to a type parameter, `(T)obj`, an unbox.any. Type.createEmptyInstance
	// writes it in C# in hxcs; outside this class a cast from Dynamic to a type parameter is genericCast.
	public static function __hx_unboxAny<T>(obj:Dynamic):T {
		return cast obj;
	}

	public static function concat(s1:String, s2:String):String {
		return (s1 == null ? "null" : s1) + (s2 == null ? "null" : s2);
	}

	public static function toBool(dyn:Dynamic):Bool {
		// hxc: hxcs's C# cast `(bool)dyn`, an unbox.
		return if (dyn == null) false else (untyped __as__(dyn) : Bool);
	}
}

@:nativeGen
@:keep @:native("haxe.lang.EmptyObject") enum EmptyObject {
	EMPTY;
}
