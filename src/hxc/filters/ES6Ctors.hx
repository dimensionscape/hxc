package hxc.filters;

// hxc.filters.ES6Ctors: ES6 classes cannot touch `this` before super() and cannot skip a parent
// constructor call, so constructors that need either get their body extracted into
// _hx_constructor plus a static skip flag on the root of the inheritance chain.

import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TexprTools;
import hxc.core.TypingError;
import hxc.core.ExitException;
import hxc.context.Context;
import haxe.ds.StringMap;

class ES6Ctors {
	// Name of the method to which the constructor is extracted
	static inline var ctorMethodName = "_hx_constructor";

	// Name of the static bool flag to skip constructor body execution
	static inline var skipCtorFlagName = "_hx_skip_constructor";

	// Replace super(a,b,c) with super._hx_constructor(a,b,c)
	static function replaceSuperCall(e:TExpr):TExpr {
		return switch (e.expr) {
			case TCall(eSuper = {expr: TConst(TSuper)}, args):
				var eSuperHxctor = TypeFunctions.mk(TField(eSuper, FDynamic(ctorMethodName)), eSuper.type, eSuper.pos);
				TypeFunctions.mk(TCall(eSuperHxctor, args), e.type, e.pos);
			case _:
				TexprTools.mapExpr(replaceSuperCall, e);
		};
	}

	static function removeDefaultArgValues(args:Array<TFuncArg>):Array<TFuncArg> {
		return [for (a in args) {v: a.v}];
	}

	// Return the `this` access happening before calling `super`, if any
	static function hasThisBeforeSuper(e:TExpr):Null<TExpr> {
		var accessedThis:Null<TExpr> = null;
		function loop(e:TExpr):Void {
			switch (e.expr) {
				case TCall({expr: TConst(TSuper)}, args):
					for (a in args) loop(a);
					throw new ExitException();
				case TConst(TThis):
					accessedThis = e;
					throw new ExitException();
				case _:
					TexprTools.iter(loop, e);
			}
		}
		return try {
			loop(e);
			null;
		} catch (_:ExitException) accessedThis;
	}

	static function getNumArgs(cf:TClassField):Int {
		return switch (TypeFunctions.follow(cf.type)) {
			case TFun(sig): sig.args.length;
			case _: throw new TypingError("Invalid constructor type", cf.pos);
		};
	}

	static function ctorFunc(cf:Null<TClassField>):Null<TFunc> {
		if (cf == null || cf.expr == null) return null;
		return switch (cf.expr.expr) {
			case TFunction(tf): tf;
			case _: null;
		};
	}

	/*
	 * The filter works in two passes:
	 * - mark classes whether they need to support constructor skipping and/or they skip parent's
	 * constructor
	 * - change the constructors of marked classes (extract body into method and/or add skipping super
	 * calls)
	 */
	public static function rewriteCtors(com:Context):Void {
		// We mark classes that need changing by storing them in these maps
		var needsCtorSkipping = new StringMap<TClass>();
		var doesCtorSkipping = new StringMap<TClass>();
		var injectSuper = new StringMap<TClass>();

		// The value is the root of the inheritance chain so we can easily generate
		// RootClass._hx_skip_constructor expressions
		function markDoesCtorSkipping(cl:TClass, clSuper:TClass, pThisAccess:Position):Void {
			function markNeedsCtorSkipping(cl:TClass):TClass {
				// For non haxe-generated extern classes we can't generate any valid code, so just fail
				if (TypeFunctions.hasClassFlag(cl, CExtern) && !TypeFunctions.hasMeta(":hxGen", cl.meta))
					throw new TypingError("Must call `super()` constructor before accessing `this` in classes derived from an extern class with constructor", pThisAccess);
				var found = needsCtorSkipping.get(Context.pathKey(cl.path));
				if (found != null) return found;
				var root:TClass;
				if (cl.superClass != null && cl.superClass.c.constructor != null) {
					var ctorSuper = cl.superClass.c.constructor;
					root = markNeedsCtorSkipping(cl.superClass.c);
					// If parent's constructor receives less arguments than needed for this - we need to override
					// the constructor
					if (cl.constructor != null && getNumArgs(cl.constructor) > getNumArgs(ctorSuper))
						doesCtorSkipping.set(Context.pathKey(cl.path), root);
				} else {
					root = cl;
				}
				needsCtorSkipping.set(Context.pathKey(cl.path), root);
				return root;
			}
			var rootCl = markNeedsCtorSkipping(clSuper);
			doesCtorSkipping.set(Context.pathKey(cl.path), rootCl);
		}

		var eEmptySuperCall = {
			var eSuper = TypeFunctions.mk(TConst(TSuper), TypeFunctions.tDynamic, Position.nullPos);
			TypeFunctions.mk(TCall(eSuper, []), com.basic.tvoid, Position.nullPos);
		};

		var activated = false;
		for (t in com.types) switch (t) {
			case TClassDecl(cl) if (ctorFunc(cl.constructor) != null && cl.superClass != null):
				var tf = ctorFunc(cl.constructor);
				if (TypeFunctions.hasConstructor(cl.superClass.c)) {
					// If parent class has a constructor, check for `this` accesses before calling `super()`
					var eThisAccess = hasThisBeforeSuper(tf.expr);
					if (eThisAccess != null) {
						activated = true;
						markDoesCtorSkipping(cl, cl.superClass.c, eThisAccess.pos);
					}
				} else {
					// If there was no ctor in the parent class, we still gotta call `super`
					injectSuper.set(Context.pathKey(cl.path), cl);
				}
			case _:
		}

		if (activated) {
			// Just some helper common exprs
			var eFalse = TexprTools.makeBool(com.basic, false, Position.nullPos);
			var eTrue = TexprTools.makeBool(com.basic, true, Position.nullPos);
			var eHxCtor = { // this._hx_constructor
				var eThis = TypeFunctions.mk(TConst(TThis), TypeFunctions.tDynamic, Position.nullPos);
				TypeFunctions.mk(TField(eThis, FDynamic(ctorMethodName)), TypeFunctions.tDynamic, Position.nullPos);
			};

			for (t in com.types) switch (t) {
				case TClassDecl(cl) if (ctorFunc(cl.constructor) != null):
					var cfCtor = cl.constructor;
					var ctorExpr = cfCtor.expr;
					var tfCtor = ctorFunc(cfCtor);
					var doesSkipping = doesCtorSkipping.get(Context.pathKey(cl.path));

					function addHxCtorMethod():Void {
						var cfFunCtor = TypeFunctions.mkField(ctorMethodName, cfCtor.type, cfCtor.pos, Position.nullPos);
						cfFunCtor.expr = replaceSuperCall(ctorExpr);
						cfFunCtor.kind = Method(MethNormal);
						cl.orderedFields.unshift(cfFunCtor);
						cl.fields.set(cfFunCtor.name, cfFunCtor);
					}

					function makeHxCtorCall(eSkipFlag:TExpr):TExpr { // this._hx_constructor(a,b,c)
						var hxctorCallArgs = [for (a in tfCtor.args) TexprTools.makeLocal(a.v, Position.nullPos)];
						var hxCtorCall = TypeFunctions.mk(TCall(eHxCtor, hxctorCallArgs), com.basic.tvoid, Position.nullPos);
						return if (doesSkipping != null)
							TypeFunctions.mk(TBlock([
								TypeFunctions.mk(TBinop(OpAssign, eSkipFlag, eTrue), com.basic.tbool, Position.nullPos),
								eEmptySuperCall,
								TypeFunctions.mk(TBinop(OpAssign, eSkipFlag, eFalse), com.basic.tbool, Position.nullPos),
								hxCtorCall
							]), com.basic.tvoid, Position.nullPos)
						else
							hxCtorCall;
					}

					function makeSkipFlag(rootCl:TClass):TExpr { // TopClass._hx_skip_constructor
						var eTop = TypeFunctions.mk(TTypeExpr(TClassDecl(rootCl)), TypeFunctions.tDynamic, Position.nullPos);
						return TypeFunctions.mk(TField(eTop, FDynamic(skipCtorFlagName)), com.basic.tbool, Position.nullPos);
					}

					var root = needsCtorSkipping.get(Context.pathKey(cl.path));
					if (root != null) {
						addHxCtorMethod();

						if (doesSkipping == null && cl != root) {
							// For intermediate classes that support skipping but don't do skipping themselves, we can
							// just remove the constructor altogether, because the skipping logic is implemented in the
							// parent constructor, and the actual constructor body is moved into _hx_constructor
							cfCtor.expr = null;
						} else {
							var eReturn = TypeFunctions.mk(TReturn(null), TypeFunctions.tDynamic, Position.nullPos);
							var eSkip = if (cl.superClass == null || injectSuper.exists(Context.pathKey(cl.path)))
								// Just `return`
								eReturn
							else
								TypeFunctions.mk(TBlock([
									eEmptySuperCall,
									eReturn
								]), com.basic.tvoid, Position.nullPos);

							var eSkipFlag = makeSkipFlag(root);

							var eCtorReplaced = TypeFunctions.mk(TBlock([
								TypeFunctions.mk(TIf(TexprTools.mkParent(eSkipFlag), eSkip, null), com.basic.tvoid, Position.nullPos),
								makeHxCtorCall(eSkipFlag)
							]), tfCtor.expr.type, tfCtor.expr.pos);

							cfCtor.expr = TypeFunctions.mk(TFunction(new TFunc(
								removeDefaultArgValues(tfCtor.args),
								tfCtor.type,
								eCtorReplaced
							)), ctorExpr.type, ctorExpr.pos);
						}

						if (cl == root) {
							var cfSkipCtor = TypeFunctions.mkField(skipCtorFlagName, com.basic.tbool, Position.nullPos, Position.nullPos, true, true);
							cfSkipCtor.expr = eFalse;
							cl.orderedStatics.unshift(cfSkipCtor);
							cl.statics.set(cfSkipCtor.name, cfSkipCtor);
						}
					} else if (doesSkipping != null) {
						addHxCtorMethod();

						var eSkipFlag = makeSkipFlag(doesSkipping);

						var eCtorReplaced = TypeFunctions.mk(TBlock([
							makeHxCtorCall(eSkipFlag)
						]), tfCtor.expr.type, tfCtor.expr.pos);
						cfCtor.expr = TypeFunctions.mk(TFunction(new TFunc(
							removeDefaultArgValues(tfCtor.args),
							tfCtor.type,
							eCtorReplaced
						)), ctorExpr.type, ctorExpr.pos);
					}
				case _:
			}
		}

		// Prepend super() to constructors whose parent class has none
		for (cl in injectSuper) {
			var cfCtor = cl.constructor;
			var tf = ctorFunc(cfCtor);
			if (tf == null || cl.superClass == null)
				throw new TypingError("Invalid class marked for super injection", cl.pos);
			var newBody = TypeFunctions.mk(TBlock([eEmptySuperCall, tf.expr]), tf.expr.type, tf.expr.pos);
			cfCtor.expr = TypeFunctions.mk(TFunction(new TFunc(tf.args, tf.type, newBody)), cfCtor.expr.type, cfCtor.expr.pos);
		}
	}
}
