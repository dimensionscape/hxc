import haxe.macro.Context;
import haxe.macro.Expr;

class M {
	#if macro
	static function names(fields:Array<haxe.macro.Type.ClassField>):String
		return "[" + [for (f in fields) f.name].join(",") + "]";
	#end

	// What the class being built and its superclass hold while the build runs.
	macro public static function show():Array<Field> {
		var c = Context.getLocalClass().get();
		var sup = c.superClass == null ? "-" : names(c.superClass.t.get().fields.get());
		Context.warning(c.name + " fields=" + names(c.fields.get()) + " statics=" + names(c.statics.get())
			+ " constructor=" + (c.constructor != null) + " super=" + sup, Context.currentPos());
		return null;
	}

	macro public static function keep():Array<Field>
		return Context.getBuildFields();

	// Drops the declared fields the superclass already has.
	macro public static function dropInherited():Array<Field> {
		var sup = Context.getLocalClass().get().superClass.t.get();
		var inherited = [for (f in sup.fields.get()) f.name];
		return [for (f in Context.getBuildFields()) if (inherited.indexOf(f.name) == -1) f];
	}

	// What each named class and its superclass hold when a build reaches it; then adds a field.
	macro public static function peek(paths:Array<String>):Array<Field> {
		for (path in paths) switch (Context.getType(path)) {
			case TInst(r, _):
				var c = r.get();
				var sup = c.superClass == null ? "-" : names(c.superClass.t.get().fields.get());
				Context.warning("peek " + c.name + " fields=" + names(c.fields.get()) + " super=" + sup, Context.currentPos());
			case _:
		}
		var fields = Context.getBuildFields();
		fields.push({name: "added", access: [APublic], kind: FVar(macro :Int, macro 3), pos: Context.currentPos()});
		return fields;
	}

	// Gives the field `f` a String @:overload whose function expression has a null kind.
	macro public static function nullKindOverload():Array<Field> {
		var fields = Context.getBuildFields();
		for (f in fields) if (f.name == "f") {
			var func:Function = {args: [{name: "s", type: macro :String}], ret: macro :Void, expr: macro {}};
			f.meta.push({name: ":overload", params: [{expr: EFunction(null, func), pos: f.pos}], pos: f.pos});
		}
		return fields;
	}
}
