package hxia;

enum BudgetKind {
	Fuel;
	CallDepth;
	AllocBytes;
}

// Every failure names its cause in data, not prose. All extend haxe.Exception.
class LoadError extends haxe.Exception {
	public function new(message:String) super(message);
}

// Thrown before LinkError: `load` checks permission before linkage.
class PermissionError extends LoadError {
	public var missing:Array<String>;

	public function new(missing:Array<String>) {
		super("missing capabilities: " + missing.join(", "));
		this.missing = missing;
	}
}

// The module was built against a different version of the host's SDK surface. Both hashes
// are carried so a build system can say which side is stale.
class SurfaceError extends LoadError {
	public var expected:String;
	public var found:String;

	public function new(expected:String, found:String) {
		super("sdk surface mismatch: host " + expected + ", module " + found);
		this.expected = expected;
		this.found = found;
	}
}

class LinkError extends LoadError {
	public var unresolved:Array<String>;

	public function new(unresolved:Array<String>) {
		super("unresolved: " + unresolved.join(", "));
		this.unresolved = unresolved;
	}
}

class BudgetError extends haxe.Exception {
	public var kind:BudgetKind;
	public var module:String;
	public var at:ScriptPos;

	public function new(kind:BudgetKind, module:String, at:ScriptPos) {
		super("budget exceeded: " + kind);
		this.kind = kind;
		this.module = module;
		this.at = at;
	}
}

class ScriptError extends haxe.Exception {
	public var scriptStack:Array<ScriptPos>;

	public function new(inner:Dynamic, scriptStack:Array<ScriptPos>) {
		super(Std.string(inner));
		this.scriptStack = scriptStack;
	}
}
