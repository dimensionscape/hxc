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

typedef FieldAccess = {
	// The expression on which the field is accessed (for abstracts, a type expression to the impl).
	on:TExpr,
	// The field being accessed (for overloads, the main field hosting overloads).
	field:TClassField,
	// The host of the field.
	host:FieldHost,
	// Whether to inline the access (set for non-inline fields via `inline call` syntax).
	isInline:Bool,
	// The position of the field-access expression in syntax.
	pos:Position,
}

typedef StaticExtensionAccess = {
	// The `this` expression passed as the first argument.
	thisExpr:TExpr,
	// The field access information.
	access:FieldAccess,
}

// Safe_nav_access (the `?.` chain).
typedef SafeNavAccess = {
	// Position of the safe-navigation chain start (the initial `?.field` expression).
	pos:Position,
	// Starting value to be checked for null.
	base:TExpr,
	// Temp var declaration to store a complex base expression.
	tempVar:Null<TExpr>,
	// Safe-navigation access to be done if the base value is not null.
	access:AccessKind,
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
