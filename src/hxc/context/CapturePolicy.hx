package hxc.context;

// Closure-capture policy used by variable scoping and RenameVars.
enum CapturePolicy {
	CPNone;     // no wrapping (es6 / cpp by-value)
	CPWrapRef;                                                     
	CPLoopVars; // wrap only loop variables (the es5 JS policy)
}
