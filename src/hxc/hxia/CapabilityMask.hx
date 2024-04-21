package hxc.hxia;

import hxc.core.Type;
import hxc.core.Globals;
import hxc.ast.Position;
import hxc.typing.AccessKind;
import hxc.typing.TyperContext;

// The hxia capability mask: the single source mapping std MEMBERS to capability atoms. Under
// `--hxia core`, a script that touches a masked member without the granting atom is a compile
// error. Member-level (not class-level): Sys.println is unmasked core, but Sys.getEnv needs `env`;
// sys.io.File.getContent needs `fs.read` while saveContent needs
// `fs.write`. Both the compile-time mask and the test lane read this table (the lane via
// `--hxia-dump-atoms`).
class CapabilityMask {
	// Key = "<owner dotted path>.<member>", value = atom. Kept small and explicit for the first slice;
	// grows as the neutral surface is charted.
	public static final table:Array<{member:String, atom:String}> = [
		{member: "Sys.getEnv", atom: "env"},
		{member: "Sys.putEnv", atom: "env"},
		{member: "Sys.environment", atom: "env"},
		// Processes
		{member: "Sys.command", atom: "proc"},
		{member: "Sys.exit", atom: "proc"},
		{member: "sys.io.Process.new", atom: "proc"},
		// Filesystem reads
		{member: "sys.io.File.getContent", atom: "fs.read"},
		{member: "sys.io.File.getBytes", atom: "fs.read"},
		{member: "sys.io.File.read", atom: "fs.read"},
		{member: "sys.FileSystem.readDirectory", atom: "fs.read"},
		{member: "sys.FileSystem.exists", atom: "fs.read"},
		// Filesystem writes
		{member: "sys.io.File.saveContent", atom: "fs.write"},
		{member: "sys.io.File.saveBytes", atom: "fs.write"},
		{member: "sys.io.File.write", atom: "fs.write"},
		{member: "sys.io.File.append", atom: "fs.write"},
		{member: "sys.FileSystem.createDirectory", atom: "fs.write"},
		{member: "sys.FileSystem.deleteFile", atom: "fs.write"},
	];

	static var lut:Null<Map<String, String>> = null;

	static function map():Map<String, String> {
		if (lut == null) {
			lut = new Map();
			for (e in table) lut.set(e.member, e.atom);
		}
		return lut;
	}

	// The active profile: "" (off), "core" (masked), "sys" (unmasked full surface).
	static function profile(ctx:TyperContext):String
		return ctx.com.defines.rawDefinedValueSafe("hxia", "");

	static function grantedAtoms(ctx:TyperContext):Array<String> {
		var csv = ctx.com.defines.rawDefinedValueSafe("hxia_require", "");
		return csv == "" ? [] : csv.split(",");
	}

	static function ownerPath(fh:FieldHost):Null<String> {
		return switch (fh) {
			case FHStatic(c) | FHInstance(c, _): Globals.sTypePath(c.path);
			case FHAbstract(a, _, _): Globals.sTypePath(a.path);
			case FHAnon: null;
		};
	}

	// Called from field access typing. Records a diagnostic (batch-mode, so every
	// violation in a compile is reported) when a masked member is used without its atom.
	// The mask governs the SCRIPT'S source, not std implementation code: the std's own
	// sys.io.File internals legitimately reference File.write etc. Skip any access whose
	// site is under a std path.
	static function inStd(ctx:TyperContext, p:Position):Bool {
		var file = StringTools.replace(p.file, "\\", "/");
		for (s in ctx.com.stdPath)
			if (StringTools.startsWith(file, StringTools.replace(s, "\\", "/")))
				return true;
		return false;
	}

	public static function check(ctx:TyperContext, fh:FieldHost, member:String, p:Position):Void {
		var prof = profile(ctx);
		if (prof != "core")
			return; // Off, or sys = full surface
		if (inStd(ctx, p))
			return; // Std implementation code is not script source
		var owner = ownerPath(fh);
		if (owner == null)
			return;
		var atom = map().get(owner + "." + member);
		if (atom == null)
			return;
		if (grantedAtoms(ctx).indexOf(atom) >= 0)
			return;
		ctx.com.addDiagnostic("hxia: '" + owner + "." + member + "' requires capability '" + atom
			+ "' under profile '" + prof + "' (grant it with --require " + atom + ")", p);
	}

	// The `--hxia-dump-atoms` payload: one `member<TAB>atom` line per entry, so the test
	// lane derives its expectations from this same table.
	public static function dump():String {
		var sb = new StringBuf();
		for (e in table)
			sb.add(e.member + "\t" + e.atom + "\n");
		return sb.toString();
	}
}
