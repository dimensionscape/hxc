package hxia;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;
#end

// Interface-typed access to a script class (PLAN.md H3's `interface-typed mod.make`). The host
// declares the seam as an ordinary Haxe interface, and
//
// var pig:demo.Mod = hxia.Bind.make(mod, demo.Mod, "PigMod");
//
// gives back something that is that interface: `pig.tick(3)` is a typed call the compiler checks,
// not a string the host has to keep in sync by hand. A proxy class implementing the interface is
// generated once per interface at macro time; each method forwards through Module.call, so the seam
// stays tier-agnostic - the same host code drives T3 and T1.
class Bind {
	// Make(module, Interface, "ScriptClass", ?args) -> Interface
	public static macro function make(module:Expr, iface:Expr, scriptClass:Expr, ?args:Expr):Expr {
		var proxy = proxyFor(iface);
		var argsExpr = args == null || isNullExpr(args) ? macro [] : args;
		return macro @:pos(Context.currentPos()) {
			var __mod = $module;
			new $proxy(__mod, __mod.make($scriptClass, $argsExpr));
		};
	}

	// Wrap(module, Interface, existingInstance) -> Interface, for a script value the host already
	// holds (returned from another call, say).
	public static macro function wrap(module:Expr, iface:Expr, obj:Expr):Expr {
		var proxy = proxyFor(iface);
		return macro @:pos(Context.currentPos()) new $proxy($module, $obj);
	}

	#if macro
	static function isNullExpr(e:Expr):Bool
		return switch (e.expr) {
			case EConst(CIdent("null")): true;
			case _: false;
		};

	// The generated proxy type for an interface, defined on first use and reused after.
	static function proxyFor(iface:Expr):TypePath {
		var path = exprPath(iface);
		var t = Context.getType(path);
		var cl = switch (t) {
			case TInst(c, _): c.get();
			case _: Context.error(path + " is not an interface", iface.pos);
		};
		if (!cl.isInterface)
			Context.error(path + " is not an interface", iface.pos);

		var name = "HxiaProxy_" + StringTools.replace(path, ".", "_");
		var tp:TypePath = {pack: ["hxia", "proxy"], name: name};
		if (defined.exists(name))
			return tp;
		defined.set(name, true);

		var fields:Array<Field> = [
			{
				name: "__m",
				access: [APrivate, AFinal],
				kind: FVar(macro :hxia.Module),
				pos: cl.pos
			},
			{
				name: "__o",
				access: [APublic, AFinal],
				kind: FVar(macro :Dynamic),
				pos: cl.pos
			},
			{
				name: "new",
				access: [APublic],
				kind: FFun({
					args: [{name: "m", type: macro :hxia.Module}, {name: "o", type: macro :Dynamic}],
					ret: macro :Void,
					expr: macro {
						this.__m = m;
						this.__o = o;
					}
				}),
				pos: cl.pos
			}
		];
		for (f in cl.fields.get())
			fields.push(forward(f, path));

		Context.defineType({
			pack: tp.pack,
			name: name,
			pos: cl.pos,
			kind: TDClass(null, [{pack: cl.pack, name: cl.module.split(".").pop(), sub: cl.name}], false, true),
			fields: fields
		});
		return tp;
	}

	static function forward(f:ClassField, path:String):Field {
		switch (f.type) {
			case TFun(args, ret):
				var fargs:Array<FunctionArg> = [
					for (a in args)
						{name: a.name, opt: a.opt, type: TypeTools.toComplexType(a.t)}
				];
				var callArgs:Expr = {expr: EArrayDecl([for (a in args) macro $i{a.name}]), pos: f.pos};
				var isVoid = switch (Context.follow(ret)) {
					case TAbstract(_.get() => {name: "Void", pack: []}, _): true;
					case _: false;
				};
				var body = isVoid ? macro this.__m.call(this.__o, $v{f.name}, $callArgs) : macro return cast this.__m.call(this.__o,
					$v{f.name}, $callArgs);
				return {
					name: f.name,
					access: [APublic],
					kind: FFun({args: fargs, ret: TypeTools.toComplexType(ret), expr: body}),
					pos: f.pos
				};
			case _:
				// A property on the seam would need get/set forwarding with no way to tell a
				// physical field from an accessor; keep the contract to methods and say so.
				return Context.error("hxia.Bind: " + path + "." + f.name
					+ " is not a method; an interface seam must declare methods only", f.pos);
		}
	}

	static function exprPath(e:Expr):String
		return switch (e.expr) {
			case EConst(CIdent(s)): s;
			case EField(sub, name): exprPath(sub) + "." + name;
			case _: Context.error("expected an interface type path", e.pos);
		};

	static var defined:Map<String, Bool> = new Map();
	#end
}
