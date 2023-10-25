package hxc.context;


import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;
import hxc.core.TypingError;

enum Purity {
	Pure;
	Impure;
	MaybePure;
	InferredPure;
	ExpectPure(p:Position);
}

class PurityState {
	public static function getPurityFromMeta(meta:Metadata):Purity {
		for (m in meta) {
			if (m.name != ":pure") continue;
			if (m.params.length == 0) return Pure;
			if (m.params.length == 1) {
				switch (m.params[0].expr) {
					case EConst(CIdent(s)):
						return switch (s) {
							case "true" | "inferredPure": Pure;
							case "false": Impure;
							case "expect": ExpectPure(m.params[0].pos);
							case _: throw new TypingError("Unsupported purity value " + s + ", expected true or false", m.params[0].pos);
						}
					case _:
				}
			}
			throw new TypingError("Unsupported purity value", m.pos);
		}
		return MaybePure;
	}

	public static function getPurity(c:TClass, cf:TClassField):Purity {
		return switch (getPurityFromMeta(cf.meta)) {
			case Pure | InferredPure: Pure;
			case Impure: Impure;
			case ExpectPure(p): ExpectPure(p);
			case _: getPurityFromMeta(c.meta);
		};
	}

	public static function isPure(c:TClass, cf:TClassField):Bool {
		return getPurity(c, cf).match(Pure);
	}

	public static function isPureFieldAccess(fa:TFieldAccess):Bool {
		return switch (fa) {
			case FInstance(c, _, cf) | FStatic(c, cf): isPure(c, cf);
			case FClosure(cwp, cf): cwp != null ? isPure(cwp.c, cf) : getPurityFromMeta(cf.meta).match(Pure);
			case FAnon(cf): getPurityFromMeta(cf.meta).match(Pure);
			case FEnum(_, _): true;
			case FDynamic(_): false;
		};
	}

	public static function isExplicitlyImpure(fa:TFieldAccess):Bool {
		return switch (fa) {
			case FInstance(c, _, cf) | FStatic(c, cf):
				getPurityFromMeta(cf.meta).match(Impure) || getPurityFromMeta(c.meta).match(Impure);
			case FClosure(cwp, cf):
				if (cwp != null)
					getPurityFromMeta(cf.meta).match(Impure) || getPurityFromMeta(cwp.c.meta).match(Impure);
				else
					getPurityFromMeta(cf.meta).match(Impure);
			case FAnon(cf):
				getPurityFromMeta(cf.meta).match(Impure);
			case _:
				false;
		};
	}

	public static function toString(p:Purity):String {
		return switch (p) {
			case Pure: "pure";
			case Impure: "impure";
			case InferredPure: "inferredPure";
			case MaybePure: "maybe";
			case ExpectPure(_): "expect";
		};
	}
}
