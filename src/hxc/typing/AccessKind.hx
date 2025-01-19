package hxc.typing;

import hxc.ast.Position;
import hxc.ast.Ast;
import hxc.core.Type;

// Where a field lives.
enum FieldHost {
	FHStatic(c:TClass);
	FHInstance(c:TClass, tl:TParams);
	FHAbstract(a:TAbstract, tl:TParams, c:TClass);
	FHAnon;
}

// Real CLASSES, not anonymous typedefs: hxcpp compiles anon field reads into hashed __Field
// lookups, and the generated call-typing code still showed field 22 / access 13 / host 11 such
// sites after the TSignature conversion. These records ride through every field access the typer
// resolves. @:structInit keeps the {on: ..., ...} literals working.
@:structInit
class FieldAccess {
	// The expression on which the field is accessed (for abstracts, a type expression to the impl).
	public var on:TExpr;
	// The field being accessed (for overloads, the main field hosting overloads).
	public var field:TClassField;
	// The host of the field.
	public var host:FieldHost;
	// Whether to inline the access (set for non-inline fields via `inline call` syntax).
	public var isInline:Bool;
	// The position of the field-access expression in syntax.
	public var pos:Position;
	public function new(on:TExpr, field:TClassField, host:FieldHost, isInline:Bool, pos:Position) {
		this.on = on;
		this.field = field;
		this.host = host;
		this.isInline = isInline;
		this.pos = pos;
	}
}

@:structInit
class StaticExtensionAccess {
	// The `this` expression passed as the first argument.
	public var thisExpr:TExpr;
	// The field access information.
	public var access:FieldAccess;
	public function new(thisExpr:TExpr, access:FieldAccess) {
		this.thisExpr = thisExpr;
		this.access = access;
	}
}

// Safe_nav_access (the `?.` chain).
@:structInit
class SafeNavAccess {
	// Position of the safe-navigation chain start (the initial `?.field` expression).
	public var pos:Position;
	// Starting value to be checked for null.
	public var base:TExpr;
	// Temp var declaration to store a complex base expression.
	public var tempVar:Null<TExpr>;
	// Safe-navigation access to be done if the base value is not null.
	public var access:AccessKind;
	public function new(pos:Position, base:TExpr, tempVar:Null<TExpr>, access:AccessKind) {
		this.pos = pos;
		this.base = base;
		this.tempVar = tempVar;
		this.access = access;
	}
}

enum AccessMode {
	MGet;
	MSet(rhs:Null<Expr>);   // Rhs, if it exists
	MCall(args:Array<Expr>); // Call arguments
}

enum AccessKind {
	// Access is not possible or allowed.
	AKNo(ak:AccessKind, p:Position);
	// Access on an arbitrary expression.
	AKExpr(e:TExpr);
	// Safe navigation access chain.
	AKSafeNav(sn:SafeNavAccess);
	// Access on a non-property field.
	AKField(fa:FieldAccess);
	// Access on a property field (the field is the property, not the accessor).
	AKAccessor(fa:FieldAccess);
	// Access via static extension.
	AKUsingField(se:StaticExtensionAccess);
	// Access via static extension on a property field (the field is the property, not the accessor;
	// Currently only on abstract properties).
	AKUsingAccessor(se:StaticExtensionAccess);
	// Access on an abstract via array overload.
	AKAccess(a:TAbstract, tl:TParams, c:TClass, e1:TExpr, e2:TExpr);
	// Access on an abstract via resolve method.
	AKResolve(se:StaticExtensionAccess, name:String);
}
