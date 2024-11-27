package hxc.typing;

import hxc.ast.Ast;
import hxc.ast.Position;
import hxc.core.Type;
import hxc.core.TypeFunctions;
import hxc.context.Context;
import hxc.core.TypingError;

// @:inheritDoc fills a declaration's inherited list: with no argument from whatever it
// OVERRIDES (the super class, or the same-named field on it), and with arguments from each
// dot path named. The own doc stays first; the generated doc text joins the list with
// newlines.
class InheritDoc {
	// The path reads outside-in, so the parts are collected and reversed. A trailing uppercase name is
	// a sub-type, a lowercase one a field.
	static function exprToTarget(e:Expr):{path:hxc.core.Globals.Path, sub:Null<String>} {
		function loop(e:Expr):Array<String> {
			return switch (e.expr) {
				case EConst(CIdent(s)) if (s != ""): [s];
				case EField(e1, s, _): [s].concat(loop(e1));
				case _: throw new TypingError("Invalid target expression for @:inheritDoc", e.pos);
			}
		}
		var l = loop(e);
		if (l.length == 0) throw new TypingError("Invalid target path for @:inheritDoc", e.pos);
		if (l.length >= 2 && !Ast.isLowerIdent(l[1])) {
			var subName = l[0];
			var typeName = l[1];
			var pack = l.slice(2);
			pack.reverse();
			return {path: {pack: pack, name: typeName}, sub: subName};
		}
		var typeName = l[0];
		var pack = l.slice(1);
		pack.reverse();
		return {path: {pack: pack, name: typeName}, sub: null};
	}

	static function getConstructor(c:TClass):Null<{c:Null<TClass>, cf:TClassField}> {
		if (c.constructor != null) return {c: c, cf: c.constructor};
		if (c.superClass == null) return null;
		return getConstructor(c.superClass.c);
	}

	// Member fields first, then statics, then up the chain.
	static function getClassField(c:TClass, name:String):Null<{c:Null<TClass>, cf:TClassField}> {
		var cf = c.fields.get(name);
		if (cf == null) cf = c.statics.get(name);
		if (cf != null) return {c: c, cf: cf};
		if (c.superClass == null) return null;
		return getClassField(c.superClass.c, name);
	}

	// A target that does not resolve is simply no doc.
	static function findType(com:Context, path:hxc.core.Globals.Path, sub:Null<String>, p:Position):Null<T> {
		return try {
			var mt = hxc.typing.Typeload.resolveTypePath(com, path, sub, p);
			TypeFunctions.typeOfModuleType(mt);
		} catch (_:Dynamic) null;
	}

	// Each @:inheritDoc contributes; an argument-less one goes through the caller's own callback,
	// which is what knows where "inherited from" points.
	static function buildDoc(com:Context, doc:{d:Documentation}, meta:Metadata, noArgsCb:Null<(Null<Documentation>->Void)->Void>):Void {
		function add(d:Null<Documentation>):Void {
			if (d == null) return;
			var s = Ast.genDocText(d);
			if (s == "") return;
			if (doc.d == null) doc.d = new DocBlock(null, [s]);
			else doc.d.inherited.push(s);
		}
		for (m in meta) {
			if (m.name != ":inheritDoc") continue;
			if (m.params.length == 0) {
				if (noArgsCb != null) noArgsCb(add);
			} else {
				for (t in m.params) add(getTargetDoc(com, t));
			}
		}
	}

	public static function buildClassDoc(com:Context, c:TClass):Void {
		if (c.doc != null) c.doc.inherited = [];
		var doc = {d: c.doc};
		buildDoc(com, doc, c.meta, function(add) {
			if (c.superClass == null) return;
			var csup = c.superClass.c;
			buildClassDoc(com, csup);
			add(csup.doc);
		});
		c.doc = doc.d;
	}

	public static function buildEnumDoc(com:Context, en:TEnum):Void {
		if (en.doc != null) en.doc.inherited = [];
		var doc = {d: en.doc};
		buildDoc(com, doc, en.meta, null);
		en.doc = doc.d;
	}

	public static function buildAbstractDoc(com:Context, a:TAbstract):Void {
		if (a.doc != null) a.doc.inherited = [];
		var doc = {d: a.doc};
		buildDoc(com, doc, a.meta, null);
		a.doc = doc.d;
	}

	public static function buildClassFieldDoc(com:Context, cOpt:Null<TClass>, cf:TClassField):Void {
		if (cf.doc != null) cf.doc.inherited = [];
		var doc = {d: cf.doc};
		buildDoc(com, doc, cf.meta, function(add) {
			if (cOpt == null || cOpt.superClass == null) return;
			var csup = cOpt.superClass.c;
			var found = cf.name == "new" ? getConstructor(csup) : getClassField(csup, cf.name);
			if (found == null) return;
			buildClassFieldDoc(com, found.c, found.cf);
			add(found.cf.doc);
		});
		cf.doc = doc.d;
	}

	public static function buildEnumFieldDoc(com:Context, ef:TEnumField):Void {
		if (ef.doc != null) ef.doc.inherited = [];
		var doc = {d: ef.doc};
		buildDoc(com, doc, ef.meta, null);
		ef.doc = doc.d;
	}

	// The target is a dot path naming a type, a sub-type or a field, and the three are told
	// apart by case and by what resolves.
	static function getTargetDoc(com:Context, eTarget:Expr):Null<Documentation> {
		var target = exprToTarget(eTarget);
		var path = target.path;
		var p = eTarget.pos;

		// resolveField: an uppercase last pack element is the module name, so the type being addressed is
		// a sub-type of it.
		function resolveField(fieldName:String):Null<Documentation> {
			var t:Null<T>;
			if (path.pack.length > 0 && !Ast.isLowerIdent(path.pack[path.pack.length - 1])) {
				var moduleName = path.pack[path.pack.length - 1];
				var pack = path.pack.slice(0, path.pack.length - 1);
				t = findType(com, {pack: pack, name: moduleName}, path.name, p);
			} else {
				t = findType(com, path, null, p);
			}
			if (t == null) return null;
			return switch (TypeFunctions.follow(t)) {
				case TInst(c, _):
					var found = fieldName == "new" ? getConstructor(c) : getClassField(c, fieldName);
					if (found == null) null else {
						buildClassFieldDoc(com, found.c, found.cf);
						found.cf.doc;
					}
				case TAnon(an):
					var cf = an.fields.get(fieldName);
					if (cf == null) null else {
						buildClassFieldDoc(com, null, cf);
						cf.doc;
					}
				case TEnum(en, _):
					var ef = en.constrs.get(fieldName);
					if (ef == null) null else {
						buildEnumFieldDoc(com, ef);
						ef.doc;
					}
				// An abstract resolves through its impl class, where a constructor is _new.
				case TAbstract(a, _) if (a.impl != null):
					var found = getClassField(a.impl, fieldName == "new" ? "_new" : fieldName);
					if (found == null) null else {
						buildClassFieldDoc(com, found.c, found.cf);
						found.cf.doc;
					}
				case _: null;
			}
		}

		function resolveTypeT(t:Null<T>):Null<Documentation> {
			if (t == null) return null;
			return switch (TypeFunctions.follow(t)) {
				case TInst(c, _): buildClassDoc(com, c); c.doc;
				case TAbstract(a, _): buildAbstractDoc(com, a); a.doc;
				case TEnum(en, _): buildEnumDoc(com, en); en.doc;
				case _: null;
			}
		}

		if (target.sub == null) return resolveTypeT(findType(com, path, null, p));
		if (Ast.isLowerIdent(target.sub)) return resolveField(target.sub);
		// An uppercase name is a sub-type first and a field only if that fails.
		var r = resolveTypeT(findType(com, path, target.sub, p));
		return r != null ? r : resolveField(target.sub);
	}
}
