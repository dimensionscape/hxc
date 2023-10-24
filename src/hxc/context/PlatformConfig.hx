package hxc.context;

import hxc.core.Globals.Platform;

@:structInit
class PlatformConfig {
	public var isStatic:Bool;                          // Statically-typed output (cpp/hl) vs dynamic (js)
	public var sys:Bool;                             // Has a `Sys`/`sys.*` runtime
	public var supportsOverload:Bool;                        // Native overload resolution (cpp) vs first-success (js)
	public var capturePolicy:CapturePolicy;
	public var padNulls:Bool;
	public var addFinalReturn:Bool;
	public var canSkipNonNullableArgument:Bool;
	public var supportsRestArgs:Bool;              // `haxe.Rest` at call sites
	public var usesUtf16:Bool;
	public var supportsUnicode:Bool;
	public var supportsThreads:Bool;                // Per-thread event loops

	public function new(isStatic:Bool, sys:Bool, supportsOverload:Bool, capturePolicy:CapturePolicy,
			padNulls:Bool, addFinalReturn:Bool, canSkipNonNullableArgument:Bool,
			supportsRestArgs:Bool, usesUtf16:Bool, supportsUnicode:Bool,
			supportsThreads:Bool = false) {
		this.isStatic = isStatic;
		this.sys = sys;
		this.supportsOverload = supportsOverload;
		this.capturePolicy = capturePolicy;
		this.padNulls = padNulls;
		this.addFinalReturn = addFinalReturn;
		this.canSkipNonNullableArgument = canSkipNonNullableArgument;
		this.supportsRestArgs = supportsRestArgs;
		this.usesUtf16 = usesUtf16;
		this.supportsUnicode = supportsUnicode;
		this.supportsThreads = supportsThreads;
	}

	public static function defaults():PlatformConfig {
		return {
			isStatic: true, sys: true, supportsOverload: false, capturePolicy: CPNone,
			padNulls: false, addFinalReturn: false, canSkipNonNullableArgument: true,
			supportsRestArgs: false, usesUtf16: true, supportsUnicode: true,
		};
	}

	public static function js():PlatformConfig {
		return {
			isStatic: false, sys: false, supportsOverload: false, capturePolicy: CPLoopVars,
			padNulls: false, addFinalReturn: false, canSkipNonNullableArgument: true,
			supportsRestArgs: true, usesUtf16: true, supportsUnicode: true,
		};
	}

	public static function cpp():PlatformConfig {
		return {
			isStatic: true, sys: true, supportsOverload: false, capturePolicy: CPWrapRef,
			padNulls: true, addFinalReturn: true, canSkipNonNullableArgument: true,
			supportsRestArgs: false, usesUtf16: true, supportsUnicode: true,
			supportsThreads: true,
		};
	}

	public static function eval():PlatformConfig {
		return {
			isStatic: false, sys: true, supportsOverload: false, capturePolicy: CPWrapRef,
			padNulls: true, addFinalReturn: false, canSkipNonNullableArgument: true,
			supportsRestArgs: false, usesUtf16: false, supportsUnicode: true,
			supportsThreads: true,
		};
	}

	public static function get(p:Platform):PlatformConfig {
		return switch (p) {
			case Js: js();
			case Cpp: cpp();
			case Eval: eval();
			// Cross + the not-yet-targeted platforms use the base config until their backend
			case _: defaults();
		}
	}
}
