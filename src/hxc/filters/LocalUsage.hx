package hxc.filters;


import hxc.core.Type;
import hxc.core.TexprTools;

enum Usage {
	UBlock(f:(Usage->Void)->Void);
	ULoop(f:(Usage->Void)->Void);
	UFunction(f:(Usage->Void)->Void);
	UDeclare(v:TVar);
	UUse(v:TVar);
	UAssign(v:TVar);
}

class LocalUsage {
	public static function localUsage(f:Usage->Void, e:TExpr):Void {
		switch (e.expr) {
			case TBinop(OpAssign | OpAssignOp(_), {expr: TLocal(v)}, e2):
				localUsage(f, e2);
				f(UAssign(v));
			case TUnop(Increment | Decrement, _, {expr: TLocal(v)}):
				f(UAssign(v));
			case TLocal(v):
				f(UUse(v));
			case TVarExpr(v, eo):
				if (eo != null) localUsage(f, eo);
				f(UDeclare(v));
			case TFunction(tf):
				f(UFunction(function(f) {
					for (a in tf.args) f(UDeclare(a.v));
					localUsage(f, tf.expr);
				}));
			case TBlock(l):
				f(UBlock(function(f) {
					for (x in l) localUsage(f, x);
				}));
			case TFor(v, it, body):
				localUsage(f, it);
				f(ULoop(function(f) {
					f(UDeclare(v));
					localUsage(f, body);
				}));
			case TWhile(_, _, _):
				f(ULoop(function(f) {
					TexprTools.iter(function(x) localUsage(f, x), e);
				}));
			case TTry(e1, catches):
				localUsage(f, e1);
				for (c in catches) {
					f(UBlock(function(f) {
						f(UDeclare(c.v));
						localUsage(f, c.expr);
					}));
				}
			case _:
				TexprTools.iter(function(x) localUsage(f, x), e);
		}
	}
}
