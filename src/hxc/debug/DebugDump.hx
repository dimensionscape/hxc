package hxc.debug;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;

class DebugDump {
	static var enabledKinds:Null<Map<String, Bool>> = null;
	static var targetPos:Null<String> = null;

	static function init():Void {
		if (enabledKinds != null) return;
		enabledKinds = new Map();
		var raw = Sys.getEnv("HXC_DUMP");
		if (raw != null) {
			for (part in raw.split(",")) {
				part = StringTools.trim(part).toLowerCase();
				if (part != "") enabledKinds.set(part, true);
			}
		}
		targetPos = Sys.getEnv("HXC_DUMP_POS");
	}

	public static function enabled(kind:String, p:Position):Bool {
		init();
		if (!enabledKinds.exists("all") && !enabledKinds.exists(kind)) return false;
		return matchesPos(p);
	}

	static function matchesPos(p:Position):Bool {
		if (targetPos == null || targetPos == "") return true;
		if (p == null) return false;
		var infos = Position.getInfos(p);
		var file = p.file == null ? "?" : p.file;
		var full = file + ":" + infos.line + ":" + infos.column;
		return full.indexOf(targetPos) >= 0 || file.indexOf(targetPos) >= 0 || Std.string(infos.line) == targetPos;
	}

	static function where(p:Position):String {
		if (p == null) return "?:0:0";
		var infos = Position.getInfos(p);
		return p.file + ":" + infos.line + ":" + infos.column + "-" + infos.endColumn;
	}

	public static function emit(kind:String, p:Position, msg:String):Void {
		if (!enabled(kind, p)) return;
		Sys.stderr().writeString("[hxc-dump:" + kind + "] " + where(p) + " " + msg + "\n");
	}

	public static function typed(label:String, e:TExpr):Void {
		emit("typed", e.pos, label + " " + exprName(e) + " : " + typeString(e.type));
	}

	public static function unify(kind:String, a:T, b:T, p:Position):Void {
		emit("unify", p, kind + " " + typeString(a) + " <-> " + typeString(b));
	}

	public static function selected(kind:String, p:Position, msg:String):Void {
		emit("select", p, msg);
	}

	public static function exprName(e:TExpr):String {
		return switch (e.expr) {
			case TConst(c): "TConst(" + Std.string(c) + ")";
			case TLocal(v): "TLocal(" + v.name + ")";
			case TArray(_, _): "TArray";
			case TBinop(op, _, _): "TBinop(" + Std.string(op) + ")";
			case TField(_, fa): "TField(" + fieldAccessName(fa) + ")";
			case TTypeExpr(_): "TTypeExpr";
			case TParenthesis(_): "TParenthesis";
			case TObjectDecl(_): "TObjectDecl";
			case TArrayDecl(_): "TArrayDecl";
			case TCall(_, _): "TCall";
			case TNew(c, _, _): "TNew(" + pathString(c.path) + ")";
			case TUnop(op, _, _): "TUnop(" + Std.string(op) + ")";
			case TFunction(_): "TFunction";
			case TVarExpr(v, _): "TVar(" + v.name + ")";
			case TBlock(_): "TBlock";
			case TFor(v, _, _): "TFor(" + v.name + ")";
			case TIf(_, _, _): "TIf";
			case TWhile(_, _, _): "TWhile";
			case TSwitch(_, _, _): "TSwitch";
			case TTry(_, _): "TTry";
			case TReturn(_): "TReturn";
			case TBreak: "TBreak";
			case TContinue: "TContinue";
			case TThrow(_): "TThrow";
			case TCast(_, _): "TCast";
			case TMeta(m, _): "TMeta(" + m.name + ")";
			case TEnumParameter(_, ef, _): "TEnumParameter(" + ef.name + ")";
			case TEnumIndex(_): "TEnumIndex";
			case TIdent(s): "TIdent(" + s + ")";
		};
	}

	public static function typeString(t:T):String {
		return switch (TypeFunctions.follow(t)) {
			case TMono(r): r.type == null ? "Unknown" : typeString(r.type);
			case TEnum(e, tl): pathString(e.path) + paramsString(tl);
			case TInst(c, tl): pathString(c.path) + paramsString(tl);
			case TType(td, tl): pathString(td.path) + paramsString(tl);
			case TFun(sig):
				"(" + [for (a in sig.args) (a.opt ? "?" : "") + a.name + ":" + typeString(a.t)].join(", ") + ") -> " + typeString(sig.ret);
			case TAnon(a):
				var fields = [for (name in a.fields.keys()) name + ":" + typeString(a.fields.get(name).type)];
				"{" + fields.join(", ") + "}";
			case TDynamic(t2): t2 == null ? "Dynamic" : "Dynamic<" + typeString(t2) + ">";
			case TLazy(f): typeString(TypeFunctions.lazyType(f));
			case TAbstract(a, tl): pathString(a.path) + paramsString(tl);
		};
	}

	static function paramsString(tl:Array<T>):String {
		return tl.length == 0 ? "" : "<" + [for (t in tl) typeString(t)].join(", ") + ">";
	}

	static function pathString(path:hxc.core.Globals.Path):String {
		return path.pack.length == 0 ? path.name : path.pack.join(".") + "." + path.name;
	}

	static function fieldAccessName(fa:TFieldAccess):String {
		return switch (fa) {
			case FInstance(c, _, cf): pathString(c.path) + "." + cf.name;
			case FStatic(c, cf): pathString(c.path) + "." + cf.name;
			case FAnon(cf): cf.name;
			case FClosure(c, cf): (c == null ? "" : pathString(c.c.path) + ".") + cf.name;
			case FEnum(en, ef): pathString(en.path) + "." + ef.name;
			case FDynamic(s): s;
		};
	}
}
