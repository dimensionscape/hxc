package hxc.typing;

import hxc.ast.Position;
import hxc.core.NotFound;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification.UnifyError;
import hxc.context.Context;
import hxc.filters.InterfaceCheck;

// Checks class method redefinitions.
class TypeloadCheck {
	public static function checkOverriding(ctx:Context, c:TClass, f:TClassField):Void {
		var sup = c.superClass;
		if (sup == null) {
			if (TypeFunctions.hasClassFieldFlag(f, CfOverride))
				ctx.addDiagnostic("Field " + f.name + " is declared 'override' but doesn't override any field", f.pos);
			return;
		}

		var parent = try TypeFunctions.rawClassField(function(cf) return cf.type, sup.c, sup.params, f.name) catch (_:NotFound) null;
		if (parent == null) {
			if (TypeFunctions.hasClassFieldFlag(f, CfOverride))
				ctx.addDiagnostic("Field " + f.name + " is declared 'override' but doesn't override any field", f.namePos);
			return;
		}

		var f2 = parent.f;
		var fHasOverride = TypeFunctions.hasClassFieldFlag(f, CfOverride);
		var f2Abstract = TypeFunctions.hasClassFieldFlag(f2, CfAbstract);
		if (f2Abstract) {
			if (fHasOverride)
				ctx.addDiagnostic("Field " + f.name + " is declared 'override' but parent field " + f.name + " is 'abstract' and does not provide any implementation to override", f.namePos);
			else
				TypeFunctions.addClassFieldFlag(f, CfOverride);
		}
		if (TypeFunctions.hasClassFieldFlag(f2, CfOverload) && !TypeFunctions.hasClassFieldFlag(f, CfOverload)) {
			ctx.addDiagnostic("Field " + f.name + " should be declared with overload since it was already declared as overload in superclass", f.namePos);
		} else if (!fHasOverride && !f2Abstract) {
			if (TypeFunctions.hasClassFlag(c, CExtern))
				TypeFunctions.addClassFieldFlag(f, CfOverride);
			else
				ctx.addDiagnostic("Field " + f.name + " should be declared with 'override' since it is inherited from superclass " + hxc.context.Context.sTypePath(sup.c.path), f.namePos);
		} else if (!TypeFunctions.hasClassFieldFlag(f, CfPublic) && TypeFunctions.hasClassFieldFlag(f2, CfPublic)) {
			ctx.addDiagnostic("Field " + f.name + " has less visibility (public/private) than superclass one", f.namePos);
		} else {
			switch [f.kind, f2.kind] {
				case [_, Method(MethInline)]:
					ctx.addDiagnostic("Field " + f.name + " is inlined and cannot be overridden", f.namePos);
				case [a, b] if (a.match(Method(_)) && b.match(Method(_))):
				case [Method(MethInline), Method(MethNormal)]:
				case _:
					ctx.addDiagnostic("Field " + f.name + " has different property access than in superclass", f.namePos);
			}
		}
		if (TypeFunctions.hasClassFieldFlag(f2, CfFinal))
			ctx.addDiagnostic("Cannot override final method " + f.name, f.namePos);

		var parentType = switch (parent.c2) {
			case null: parent.t;
			case c2: TypeFunctions.applyParams(c2.c.params, c2.params, parent.t);
		};
		try {
			InterfaceCheck.validRedefinition(function(t) return t, function(t) return t, f, f.type, f2, parentType);
		} catch (e:UnifyError) {
			ctx.addDiagnostic("Field " + f.name + " overrides parent class with different or incomplete type", f.namePos);
			ctx.addDiagnostic("... Base field is defined here", f2.namePos, 1);
			ctx.addDiagnostic("... " + hxc.core.TPrinting.betterErrorMessage(e.errors), f.namePos, 1);
		}
	}
}
