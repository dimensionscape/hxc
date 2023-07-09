package hxc.typing;

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypingError;
import hxc.typing.AccessKind;
import hxc.typing.FieldAccess;

class Fields {
	public static function fieldAccess(ctx:TyperContext, mode:AccessMode, f:TClassField, fh:FieldHost, e:TExpr, pfield:Position):AccessKind {
		var pfull = Position.union(e.pos, pfield);
		var isSet = mode.match(MSet(_));
		function makeAccess(isInline:Bool):FieldAccess {
			return FieldAccessTools.create(e, f, fh, isInline, pfull);
		}
		return switch (f.kind) {
			case Method(m):
				if (isSet && !m.match(MethDynamic) && !ctx.untypedMode)
					throw new TypingError("Cannot rebind this method : please use 'dynamic' before method declaration", pfield);
				switch (fh) {
					case FHAbstract(a, tl, c):
						AKUsingField(FieldAccessTools.makeAbstractStaticExtensionAccess(a, tl, c, f, e, false, pfull));
					case _:
						AKField(makeAccess(false));
				}
			case Var(vk):
				var acc = isSet ? vk.write : vk.read;
				switch (acc) {
					case AccNormal | AccNo | AccNever | AccCtor:
						AKField(makeAccess(false));
					case AccInline:
						AKField(makeAccess(true));
					case AccCall:
						switch (fh) {
							case FHAbstract(a, tl, c):
								AKUsingAccessor(FieldAccessTools.makeAbstractStaticExtensionAccess(a, tl, c, f, e, false, pfull));
							case _:
								AKAccessor(makeAccess(false));
						}
					case AccRequire(r, msg):
						throw new TypingError(msg != null ? msg : ("Field " + f.name + " is not available"), pfield);
				}
		};
	}
}
