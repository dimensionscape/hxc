package hxc.hxia;

import hxc.core.Type;

// Under -D hxia, suppress inlining only for platform-specific standard-library implementations
// (docs/hxia/DESIGN.md section 7). Keep ordinary standard-library and user code inlineable.
// Identify target overrides by their module source path under _std, rather than a list of types.
// Inlining these bodies embeds platform internals, such as StringBuf's charBuf or Bytes' backing
// array, in the portable artifact. A global no-inline define would also penalize
// platform-independent code.
class NeutralInline {
	// A trailing separator is included so this cannot match a user directory merely ENDING
	// in "_std" (such a package is not an override directory).
	static inline var MARK_SLASH = "/_std/";
	static inline var MARK_BACK = "\\_std\\";

	public static function isPlatformStd(c:Null<TClass>):Bool {
		if (c == null || c.module == null || c.module.extra == null)
			return false;
		var file = c.module.extra.file;
		if (file == null)
			return false;
		return file.indexOf(MARK_SLASH) >= 0 || file.indexOf(MARK_BACK) >= 0;
	}
}
