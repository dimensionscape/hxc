package hxc.typing;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.core.TypeUnification;
import hxc.core.WithType;
import hxc.context.Context;

/**
	`@:strict(Ann(...))` is the Java/C# way of writing a NATIVE annotation. It is rewritten into a `@:meta`
	entry here, in the PTypeField pass, and `@:meta` is what the JVM generator reads when it emits
	RuntimeVisibleAnnotations.
**/
class StrictMeta {
	// Thrown when an entry cannot be built; the caller drops that entry.
	static var exit = new hxc.core.NotFound();

	/**
		Reads a dotted expression back into a type path; the CASE of each part decides whether it is a
		package part, the type name, or a subtype.
	**/
	static function fieldToTypePath(ctx:TyperContext, e:Expr):TypePath {
		var pack:Array<String> = [];
		var name:Array<String> = [];
		var cur = e;
		while (true) {
			switch (cur.expr) {
				case EField(e1, f, _) if (f.length > 0 && f.charAt(0).toLowerCase() != f.charAt(0)):
					if (name.length > 1) {
						ctx.com.addDiagnostic("Unexpected " + f, cur.pos);
						throw exit;
					}
					name.unshift(f);
					cur = e1;
				case EField(e1, f, _):
					pack.unshift(f);
					cur = e1;
				case EConst(CIdent(f)):
					switch (name.length) {
						case 0:
							if (f.length == 0 || f.charAt(0).toUpperCase() != f.charAt(0)) {
								ctx.com.addDiagnostic("A class name must start with an uppercase letter", cur.pos);
								throw exit;
							}
							return {tpackage: pack, tname: f, tparams: [], tsub: null};
						case 1:
							pack.unshift(f);
							return {tpackage: pack, tname: name[0], tparams: [], tsub: null};
						case 2:
							pack.unshift(f);
							return {tpackage: pack, tname: name[0], tparams: [], tsub: name[1]};
						case _:
							throw exit;
					}
				case _:
					ctx.com.addDiagnostic("Unexpected expression when building strict meta", cur.pos);
					throw exit;
			}
		}
	}

	static inline function mk(def:ExprDef, p:Position):Expr return {expr: def, pos: p};

	/**
		The NATIVE name of a type, as a dotted expression. `@:javaCanonical` answers outright; `@:native`
		replaces the path and the walk continues.
	**/
	static function getNativeRepr(md:ModuleType, pos:Position):Expr {
		var info = TypeFunctions.tInfos(md);
		var pack = info.path.pack;
		var name = info.path.name;
		for (m in info.meta) {
			if (m.name == ":javaCanonical") {
				switch (m.params) {
					case [{expr: EConst(CString(p1, _))}, {expr: EConst(CString(n1, _))}]:
						pack = p1.split(".");
						name = n1;
						break;
					case _:
				}
			} else if (m.name == ":native") {
				switch (m.params) {
					case [{expr: EConst(CString(n1, _))}]:
						var p2 = Ast.parsePath(n1);
						pack = p2.pack;
						name = p2.name;
					case _:
				}
			}
		}
		if (pack.length == 0) return mk(EConst(CIdent(name)), pos);
		var e = mk(EConst(CIdent(pack[0])), pos);
		for (i in 1...pack.length) e = mk(Ast.efield(e, pack[i]), pos);
		return mk(Ast.efield(e, name), pos);
	}

	/**
		Turns a TYPED argument back into the syntax the JVM generator's AnnotationHandler reads. `toplevel`
		is what tells a type used as a VALUE, which becomes `Foo.class` on Java, from one nested inside (an
		enum constant's owner, say).
	**/
	static function processMetaArgument(ctx:TyperContext, expr:TExpr, toplevel = true):Expr {
		return switch (expr.expr) {
			case TField(e1, f):
				mk(Ast.efield(processMetaArgument(ctx, e1, false), TypeFunctions.fieldName(f)), expr.pos);
			case TConst(TInt(i)): mk(EConst(CInt(Std.string(i), null)), expr.pos);
			case TConst(TFloat(f)): mk(EConst(CFloat(f, null)), expr.pos);
			case TConst(TString(s)): mk(EConst(CString(s, SDoubleQuotes)), expr.pos);
			case TConst(TNull): mk(EConst(CIdent("null")), expr.pos);
			case TConst(TBool(b)): mk(EConst(CIdent(b ? "true" : "false")), expr.pos);
			case TCast(e1, _) | TMeta(_, e1) | TParenthesis(e1): processMetaArgument(ctx, e1, toplevel);
			case TTypeExpr(md) if (toplevel):
				if (ctx.com.platform == Cs)
					mk(ECall(mk(EConst(CIdent("typeof")), expr.pos), [getNativeRepr(md, expr.pos)]), expr.pos);
				else
					mk(Ast.efield(getNativeRepr(md, expr.pos), "class"), expr.pos);
			case TTypeExpr(md): getNativeRepr(md, expr.pos);
			case _:
				ctx.com.addDiagnostic("This expression is too complex to be a strict metadata argument", expr.pos);
				mk(EConst(CIdent("null")), expr.pos);
		}
	}

	static function unify(ctx:TyperContext, a:T, b:T, p:Position):Void {
		try TypeUnification.unifyDefault(a, b)
		catch (e:hxc.core.TypeUnification.UnifyError) {
			if (ctx.untypedMode) return;
			ctx.com.addDiagnostic(hxc.core.TPrinting.betterErrorMessage(e.errors), p);
		}
	}

	/**
		Each `name: value` of the object declaration is typed against the ANNOTATION MEMBER of that name, so
		the value is checked before it is written back out. On Java the member is read as a CALL
		(`x.name()`), which is what an annotation member is.
	**/
	static function handleFields(ctx:TyperContext, fields:Array<ObjectField>, withTypeExpr:Expr):Array<Expr> {
		return [
			for (of in fields) {
				var pos = of.expr.pos;
				var field = mk(Ast.efield(withTypeExpr, of.name), pos);
				var fieldExpr = mk(EConst(CIdent(of.name)), pos);
				var leftSide = switch (ctx.com.platform) {
					case Cs: field;
					case Java: mk(ECall(field, []), pos);
					case _: throw exit;
				};
				var left = Typer.typeExpr(ctx, leftSide, NoValue);
				var right = Typer.typeExpr(ctx, of.expr, WithTypeTools.withType(left.type));
				unify(ctx, left.type, right.type, of.expr.pos);
				mk(EBinop(OpAssign, fieldExpr, processMetaArgument(ctx, right)), pos);
			}
		];
	}

	/**
		Always a CALL, even for an annotation with no members, because the JVM generator's AnnotationHandler
		accepts nothing else.
	**/
	static function makeMeta(ctx:TyperContext, texpr:TExpr, extra:Array<Expr>):Expr {
		return switch (texpr.expr) {
			case TNew(c, _, el):
				mk(ECall(getNativeRepr(TClassDecl(c), texpr.pos),
					[for (e in el) processMetaArgument(ctx, e)].concat(extra)), texpr.pos);
			case TTypeExpr(md):
				mk(ECall(getNativeRepr(md, texpr.pos), extra), texpr.pos);
			case _:
				ctx.com.addDiagnostic("Unexpected expression", texpr.pos);
				throw exit;
		}
	}

	static function getStrictMeta(ctx:TyperContext, meta:String, params:Array<Expr>, pos:Position):MetadataEntry {
		var pf = ctx.com.platform;
		var changedExpr:Expr;
		var fieldsToCheck:Array<ObjectField>;
		var ctype:ComplexType;
		switch (params) {
			case [{expr: ECall(ef, el), pos: p}]:
				var tpath = fieldToTypePath(ctx, ef);
				switch (pf) {
					case Cs:
						// The trailing object declaration, when there is one, is the NAMED members;
						// the rest stay positional constructor arguments.
						var fields:Array<ObjectField> = [];
						var rest = el;
						if (el.length > 0) switch (el[el.length - 1].expr) {
							case EObjectDecl(decl):
								fields = decl;
								rest = el.slice(0, el.length - 1);
							case _:
						}
						changedExpr = mk(ENew({path: tpath, pos: ef.pos}, rest), p);
						fieldsToCheck = fields;
					case Java:
						fieldsToCheck = switch (el) {
							case [{expr: EObjectDecl(fields)}]: fields;
							case []: [];
							case _:
								ctx.com.addDiagnostic("Object declaration expected", el[0].pos);
								[];
						};
						changedExpr = ef;
					case _:
						throw new hxc.core.TypingError("@:strict is not supported on this target", p);
				}
				ctype = CTPath(tpath);
			case [one]:
				// The bare-path forms: `@:strict(Foo)` and `@:strict(pack.Foo)`. On C# they become a
				// construction; everywhere else the path itself is typed, and makeMeta's TTypeExpr
				// arm is what turns the result back into the CALL the JVM generator expects.
				var p = one.pos;
				var tpath = switch (one.expr) {
					case EConst(CIdent(i)): ({tpackage: [], tname: i, tparams: [], tsub: null} : TypePath);
					case EField(_, _, _): fieldToTypePath(ctx, one);
					case _:
						ctx.com.addDiagnostic("A @:strict metadata must contain exactly one parameter. Please check the documentation for more information", pos);
						throw exit;
				};
				changedExpr = pf == Cs ? mk(ENew({path: tpath, pos: p}, []), p) : one;
				fieldsToCheck = [];
				ctype = CTPath(tpath);
			case _:
				ctx.com.addDiagnostic("A @:strict metadata must contain exactly one parameter. Please check the documentation for more information", pos);
				throw exit;
		}
		var texpr = Typer.typeExpr(ctx, changedExpr, NoValue);
		var withTypeExpr = mk(ECheckType(mk(EConst(CIdent("null")), pos), {ct: ctype, pos: Position.nullPos}), pos);
		var extra = handleFields(ctx, fieldsToCheck, withTypeExpr);
		return {name: meta, params: [makeMeta(ctx, texpr, extra)], pos: pos};
	}

	/**
		Returns the entries to PREPEND to the metadata.
	**/
	public static function checkStrictMeta(ctx:TyperContext, metas:Metadata):Array<MetadataEntry> {
		switch (ctx.com.platform) {
			case Cs | Java:
			case _: return [];
		}
		var ret:Array<MetadataEntry> = [];
		for (m in metas) {
			var target = switch (m.name) {
				case ":assemblyStrict": ":assemblyMeta";
				case ":strict": ":meta";
				case _: null;
			};
			if (target == null) continue;
			try ret.unshift(getStrictMeta(ctx, target, m.params, m.pos))
			catch (_:hxc.core.NotFound) {}
		}
		return ret;
	}

	/**
		Rewrites the @:strict entries of the class, every static, every member with its overloads, and the
		constructor.
	**/
	public static function checkClass(com:Context, c:TClass):Void {
		// The module loader hands over only a Context, so a typer is built here the way
		// TypeFields.forceFieldBody builds one before typing anything.
		var ctx = new TyperContext(com);
		ctx.curclass = c;
		ctx.typeParams = c.params;
		ctx.tthis = TInst(c, TypeFunctions.extractParamTypes(c.params));
		// The annotation is resolved with the DECLARING module's imports in scope, since its type is often
		// visible only through an import: `@:strict(MyClass_ParameterLessAnnotation)` names a type that
		// `import haxe.test.MyClass` brings in.
		var savedMod = com.currentModule;
		com.currentModule = c.module;
		var metas = checkStrictMeta(ctx, c.meta);
		if (metas.length > 0) c.meta = metas.concat(c.meta);
		function runField(cf:TClassField):Void {
			var fmetas = checkStrictMeta(ctx, cf.meta);
			if (fmetas.length > 0) cf.meta = fmetas.concat(cf.meta);
			for (cf2 in cf.overloads) runField(cf2);
		}
		for (cf in c.orderedStatics) runField(cf);
		for (cf in c.orderedFields) runField(cf);
		if (c.constructor != null) runField(c.constructor);
		com.currentModule = savedMod;
	}

	public static function checkEnum(com:Context, e:TEnum):Void {
		var ctx = new TyperContext(com);
		ctx.typeParams = e.params;
		var savedMod = com.currentModule;
		com.currentModule = e.module;
		e.meta = checkStrictMeta(ctx, e.meta).concat(e.meta);
		for (name in e.constrs.keys()) {
			var ef = e.constrs.get(name);
			var metas = checkStrictMeta(ctx, ef.meta);
			if (metas.length > 0) ef.meta = metas.concat(ef.meta);
		}
		com.currentModule = savedMod;
	}
}
