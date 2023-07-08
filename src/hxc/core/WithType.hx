package hxc.core;

import hxc.core.Type;

typedef WithTypeSourceInformation = {
	name:String,
	doc:Null<String>,
};

enum WithTypeSource {
	FunctionArgument(si:WithTypeSourceInformation);
	StructureField(si:WithTypeSourceInformation);
	ImplicitReturn;
}

enum WithType {
	NoValue;
	Value(s:Null<WithTypeSource>);
	WithType(t:T, s:Null<WithTypeSource>);
}

class WithTypeTools {
	public static function makeSourceInfo(name:String, ?doc:String):WithTypeSourceInformation {
		return {name: name, doc: doc};
	}

	public static inline function withType(t:T):WithType return WithType(t, null);
	public static inline function ofImplicitReturn(t:T):WithType return WithType(t, ImplicitReturn);
	public static function withArgument(t:T, name:String):WithType return WithType(t, FunctionArgument(makeSourceInfo(name)));
	public static function withArgumentAndDoc(t:T, name:String, doc:String):WithType return WithType(t, FunctionArgument(makeSourceInfo(name, doc)));
	public static function withStructureField(t:T, name:String):WithType return WithType(t, StructureField(makeSourceInfo(name)));

	public static var value(default, null):WithType = Value(null);
	public static function namedArgument(name:String):WithType return Value(FunctionArgument(makeSourceInfo(name)));
	public static function namedStructureField(name:String):WithType return Value(StructureField(makeSourceInfo(name)));
	public static var noValue(default, null):WithType = NoValue;

	// The WithType case omits the s_type rendering of `t` (TPrinting
	// is a later port); it is a non-load-bearing diagnostic helper.
	public static function toString(w:WithType):String {
		return switch (w) {
			case NoValue: "NoValue";
			case Value(null) | Value(ImplicitReturn): "Value";
			case Value(FunctionArgument(si)) | Value(StructureField(si)): "Value " + si.name;
			case WithType(_, s):
				var name = switch (s) {
					case FunctionArgument(si) | StructureField(si): si.name;
					case _: "None";
				};
				"WithType(" + name + ")";
		};
	}
}
