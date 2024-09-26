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
	public var supportsAtomics:Bool;
	// A captured `this local declares at the top of the member (js es5, cpp, eval); es6 classes and
	// java/cs cannot touch `this` before super() so they insert it before its first use instead
	public var thisBeforeSuper:Bool = true;
	// Exception lowering config; set per target after construction since most targets share the
	// defaults
	public var nativeThrows:Array<String> = [];     // Dotted paths throwable without wrapping
	public var nativeCatches:Array<String> = [];    // Dotted paths catchable without wrapping
	public var wildcardCatch:String = "Dynamic";    // The native wildcard catch type
	public var baseThrow:String = "Dynamic";        // Wrapped throws cast to this
	public var avoidWrapping:Bool = true;           // Pass allowed values through as-is

	public function new(isStatic:Bool, sys:Bool, supportsOverload:Bool, capturePolicy:CapturePolicy,
			padNulls:Bool, addFinalReturn:Bool, canSkipNonNullableArgument:Bool,
			supportsRestArgs:Bool, usesUtf16:Bool, supportsUnicode:Bool,
			supportsThreads:Bool = false, supportsAtomics:Bool = false) {
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
		this.supportsAtomics = supportsAtomics;
	}

	public static function defaults():PlatformConfig {
		return {
			isStatic: true, sys: true, supportsOverload: false, capturePolicy: CPNone,
			padNulls: false, addFinalReturn: false, canSkipNonNullableArgument: true,
			supportsRestArgs: false, usesUtf16: true, supportsUnicode: true,
		};
	}

	public static function js():PlatformConfig {
		var c:PlatformConfig = {
			isStatic: false, sys: false, supportsOverload: false, capturePolicy: CPLoopVars,
			padNulls: false, addFinalReturn: false, canSkipNonNullableArgument: true,
			supportsRestArgs: true, usesUtf16: true, supportsUnicode: true, supportsAtomics: true,
		};
		c.nativeThrows = ["js.lib.Error", "haxe.Exception"];
		c.avoidWrapping = false;
		return c;
	}

	public static function cpp():PlatformConfig {
		return {
			isStatic: true, sys: true, supportsOverload: false, capturePolicy: CPWrapRef,
			padNulls: true, addFinalReturn: true, canSkipNonNullableArgument: true,
			supportsRestArgs: false, usesUtf16: true, supportsUnicode: true,
			supportsThreads: true, supportsAtomics: true,
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

	// Neko: the default config with isStatic/usesUtf16/supportsUnicode off, padNulls and
	// supportsThreads on. There is no neko GENERATOR here, but the platform still has to be set: it
	// decides std resolution, the filter pipeline and the analyzer, and left at Cross, anything compiled
	// with -neko would be accepted without a single check.
	public static function neko():PlatformConfig {
		return {
			isStatic: false, sys: true, supportsOverload: false, capturePolicy: CPNone,
			padNulls: true, addFinalReturn: false, canSkipNonNullableArgument: true,
			supportsRestArgs: false, usesUtf16: false, supportsUnicode: false,
			supportsThreads: true,
		};
	}

	public static function get(p:Platform):PlatformConfig {
		return switch (p) {
			case Js: js();
			case Cpp: cpp();
			case Eval: eval();
			case Neko: neko();
			// Cross + the not-yet-targeted platforms use the base config until their backend
			case _: defaults();
		}
	}
}
