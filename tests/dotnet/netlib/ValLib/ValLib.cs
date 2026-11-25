using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace ValLib
{
    public enum Kind { A = 1, B = 2, C = 3 }
    [Flags] public enum Mods { None = 0, Shift = 1, Ctrl = 2 }

    public struct Pt
    {
        public int X;
        public Pt(int x) { X = x; }
        public override string ToString() { return "Pt(" + X + ")"; }
    }

    public class Model
    {
        public int? NField;
        public int? NProp { get; set; }
        public DateTime? NDate { get; set; }
        public bool? NBool { get; set; }
        public Guid? NGuid { get; set; }
        public decimal? NDec { get; set; }
        public Kind? NKind { get; set; }
        public Pt? NPt { get; set; }
        public override string ToString()
        {
            return "Model(" + S(NField) + "," + S(NProp) + "," + S(NBool) + "," + S(NKind) + "," + S(NPt) + ")";
        }
        static string S<T>(T? v) where T : struct { return v.HasValue ? v.Value.ToString() : "null"; }
    }

    public static class Nul
    {
        public static int? Maybe(bool b) { return b ? 5 : (int?)null; }
        public static DateTime? MaybeDate(bool b) { return b ? new DateTime(2020, 1, 2) : (DateTime?)null; }
        public static string Show(int? x) { return x.HasValue ? "has " + x.Value : "none"; }
        public static string ShowB(bool? x) { return x.HasValue ? "has " + x.Value : "none"; }
        public static string ShowObj(object o) { return o == null ? "obj null" : "obj " + o.GetType().FullName + " " + o; }
        public static List<int?> ListOf() { return new List<int?> { 1, null, 3 }; }
        public static string ShowList(List<int?> l) { var s = ""; foreach (var x in l) s += (x.HasValue ? x.Value.ToString() : "null") + ";"; return s; }
        public static void OutNullable(out int? v) { v = 9; }
    }

    public static class Opt
    {
        public static string All(int a, int b = 7, string s = "dflt", double d = 1.5, Kind k = Kind.B, object o = null, bool f = true,
            long l = -3, float g = 0.25f, char c = 'z', Mods m = Mods.Ctrl, string n = null)
        {
            return "All(" + a + "," + b + "," + (s ?? "null") + "," + d + "," + k + "," + (o ?? "null") + "," + f + "," + l + "," + g + "," + c + "," + m + "," + (n ?? "null") + ")";
        }
        public static string Structs(int a, DateTime dt = default(DateTime), Pt p = default(Pt), int? ni = null, int? nj = 4, Kind? nk = Kind.C)
        {
            return "Structs(" + a + "," + dt.Ticks + "," + p + "," + (ni.HasValue ? ni.Value.ToString() : "null") + "," + (nj.HasValue ? nj.Value.ToString() : "null") + "," + (nk.HasValue ? nk.Value.ToString() : "null") + ")";
        }
        public static string Dec(int a, decimal m = 1.25m) { return "Dec(" + a + "," + m + ")"; }
        public static string Attr(int a, [Optional] int x, [Optional, DefaultParameterValue(42)] int y, [Optional] object z, [Optional] string w)
        {
            return "Attr(" + a + "," + x + "," + y + "," + (z == null ? "null" : z.GetType().Name + ":" + z) + "," + (w ?? "null") + ")";
        }
        public static string Params(int a, params int[] rest) { return "Params(" + a + "," + rest.Length + ")"; }
    }

    public class Element
    {
        public bool Focus(Kind k = Kind.A, Mods m = Mods.None) { Console.WriteLine("Focus(" + k + "," + m + ")"); return true; }
    }
    public class Input : Element { }

    public class Grid
    {
        readonly Dictionary<string, string> _d = new Dictionary<string, string>();
        readonly List<string> _l = new List<string> { "a", "b", "c" };
        public string this[int i] { get { return _l[i]; } set { _l[i] = value; } }
        public string this[string k] { get { string v; return _d.TryGetValue(k, out v) ? v : "missing"; } set { _d[k] = value; } }
        public int this[int r, int c] { get { return r * 10 + c; } }
    }
    public class RoGrid
    {
        public double this[int i] { get { return i * 0.5; } }
    }
    public class Cells
    {
        public int this[int r, int c] { get { return r * 100 + c; } set { Console.WriteLine("set " + r + "," + c + "=" + value); } }
    }

    public class SubGrid : Grid { }
    public class HiddenGrid : Grid
    {
        public new string this[int i] { get { return "hidden" + i; } }
    }
    public class WideGrid
    {
        public string this[long i] { get { return "long" + i; } }
        public string this[double d] { get { return "double" + d; } }
    }
    public struct Slots
    {
        int a, b;
        public int this[int i] { get { return i == 0 ? a : b; } set { if (i == 0) a = value; else b = value; } }
    }
    public class SlotHolder
    {
        public Slots S;
        public static int Calls;
        public static SlotHolder The = new SlotHolder();
        public static SlotHolder Get() { Calls++; return The; }
    }
    public class FBox
    {
        public string S = "s";
        public bool B;
        public int N = 1;
        public readonly int RO = 5;
        public int P { get; set; }
        public static int SP { get; set; }
        public static FBox The = new FBox();
        public static FBox Get() { Console.WriteLine("get"); return The; }
        public static Pt GetPt() { Console.WriteLine("getPt"); return new Pt(1); }
    }
    public class IdxBase
    {
        public virtual string this[int i] { get { return "base-int" + i; } }
        public virtual string this[long i] { get { return "base-long" + i; } }
    }
    public class IdxDerived : IdxBase
    {
        public override string this[long i] { get { return "derived-long" + i; } }
    }
    public class IdxRw
    {
        string v = "unset";
        public virtual string this[int i] { get { return v; } set { v = value; } }
    }
    public class IdxRo : IdxRw
    {
        public override string this[int i] { get { return "ro-" + base[i]; } }
    }
    public class IdxProt
    {
        public string this[long i] { get { return "public-long" + i; } }
        protected string this[int i] { get { return "protected-int" + i; } }
    }
    public class OddIdx
    {
        public int this[string s] { get { return 1; } }
        public string this[int i] { get { return "odd" + i; } }
    }
    public class OddIdxD
    {
        public int this[string s] { get { return 1; } }
        public double this[int i] { get { return i + 0.5; } }
    }
    public class OrderedIdx
    {
        public string this[int i] { get { return "ordered" + i; } }
        public int this[string s] { get { return 1; } }
    }

    public static class Refs
    {
        public static bool TryParse(string s, out int v) { return int.TryParse(s, out v); }
        public static void Inc(ref int x) { x++; }
        public static void IncD(ref double x) { x += 0.5; }
        public static void SetS(out string s) { s = "set"; }
        public static void SetPt(ref Pt p) { p.X += 100; }
        public static int ReadIn(in Pt p) { return p.X; }
        public static void SetObj(out object o) { o = 5; }
    }

    public class Visual { }
    public class Control : Visual { }
    public class Panel : Control { }
    public static class Sig
    {
        public static string Scale(Visual v) { return "Scale(" + v.GetType().Name + ")"; }
        public static string Over(Visual v) { return "Over(Visual)"; }
        public static string Over(Control c) { return "Over(Control)"; }
        public static string Num(double d) { return "Num(" + d + ")"; }
        public static string Obj(object o) { return "Obj(" + o + ")"; }
        public static string Ret() { return "Ret"; }
        public static string Pick(Visual v) { return "Pick(Visual)"; }
        public static string Pick(Control c) { return "Pick(Control)"; }
        public static string Cmp(IComparable c) { return "Cmp(" + c.GetType().Name + " " + c + ")"; }
        public static string Wide(long l, float f) { return "Wide(" + l + "," + f + ")"; }
        public static string Ifc(object o) { return "Ifc(object)"; }
        public static string Ifc(IComparable c) { return "Ifc(IComparable)"; }
        public static string Pick2(Visual v) { return "Pick2(Visual)"; }
        public static string Pick2(Panel p) { return "Pick2(Panel)"; }
    }

    public class LinkBase { public string Foo(string s) { return "LinkBase.Foo(string)"; } }
    public class LinkDerived : LinkBase { public string Foo(object o) { return "LinkDerived.Foo(object)"; } }

    public class OvA { public virtual string Bar(object o) { return "OvA.Bar(object)"; } }
    public class OvB : OvA { public string Bar(Control c) { return "OvB.Bar(Control)"; } }
    public class OvD : OvB { public override string Bar(object o) { return "OvD.Bar(object)"; } }

    public class Prot
    {
        public string Go(object o) { return "Go(object)"; }
        protected string Go(string s) { return "Go(string)"; }
    }

    public static class HxArg
    {
        public static string Foo(object o) { return "Foo(object)"; }
        public static string Foo(Exception e) { return "Foo(Exception)"; }
        public static string Bar(Exception e) { return "Bar(Exception)"; }
        public static string Bar(ArgumentException e) { return "Bar(ArgumentException)"; }
        public static string Baz(object o) { return "Baz(object)"; }
        public static string Baz(IDisposable d) { return "Baz(IDisposable)"; }
        public static string Only<T>(T t) where T : IComparable { return "Only(" + t + ")"; }
    }

    public interface IHear { string Hear(); }
    public static class Ears
    {
        public static string Take(IHear h) { return "Take(" + h.Hear() + ")"; }
    }

    public class Gen<T>
    {
        public string Foo(T t) { return "Foo(T)"; }
        public string Foo(int i) { return "Foo(int)"; }
    }

    public interface ICo<out T> { T Get(); }
    public interface IFoo { string Name(); }

    public static class HxInfer
    {
        public static string T1<T>(T x) { return "T1<" + typeof(T).Name + ">"; }
        public static string T2<T>(T x) { return "T2<" + typeof(T).Name + ">"; }
        public static string T2(Exception e) { return "T2(Exception)"; }
        public static T[] Arr1<T>(T x) { return new T[] { x }; }
        public static string Co(ICo<object> c) { return "Co(ICo<object>)"; }
        public static string Co(object o) { return "Co(object)"; }
        public static string Vt(ValueType v) { return "Vt(ValueType)"; }
        public static string Vt(object o) { return "Vt(object)"; }
        public static T Id<T>(T x) { Console.WriteLine("Id<" + typeof(T).Name + ">"); return x; }
        public static string N(int i) { return "N(int)"; }
        public static string N(double d) { return "N(double)"; }
    }

    public interface IBaseF { string F(object o); }
    public interface IDerivedF : IBaseF { string F(IFoo f); }
    public class FImpl : IDerivedF
    {
        public string F(object o) { return "IBaseF.F(object)"; }
        public string F(IFoo f) { return "IDerivedF.F(IFoo)"; }
    }
    public interface IBaseG { string G(object o); }
    public interface IDerivedG : IBaseG { }
    public class GImpl : IDerivedG { public string G(object o) { return "IBaseG.G(object)"; } }
    public interface IDiaA { string F(object o); }
    public interface IDiaB : IDiaA { string F(IFoo f); }
    public interface IDiaC : IDiaA { }
    public interface IDiaD : IDiaB, IDiaC { }
    public class DiaImpl : IDiaD
    {
        public string F(object o) { return "IDiaA.F(object)"; }
        public string F(IFoo f) { return "IDiaB.F(IFoo)"; }
    }

    public class FBase { public string F(object o) { return "FBase.F(object)"; } }
    public class FDerived : FBase { public string F(IFoo f) { return "FDerived.F(IFoo " + f.Name() + ")"; } }
    public class FooImpl : IFoo { public virtual string Name() { return "FooImpl"; } }
    // Ruling X: overloads C# picks by an integer constant's or a null literal's value.
    public enum Hue { Red, Green }
    public class Thing { public override string ToString() { return "Thing"; } }
    public static class ByVal
    {
        public static string B(byte b) { return "B(byte)"; }
        public static string B(object o) { return "B(object)"; }
        public static string E(Hue c) { return "E(Hue)"; }
        public static string E(object o) { return "E(object)"; }
        public static string N(Thing t) { return "N(Thing)"; }
        public static string N(object o) { return "N(object)"; }
        public static string S(short s) { return "S(short)"; }
        public static string S(double d) { return "S(double)"; }
        public static string P(params object[] a) { return "P(params " + (a == null ? "null" : a.Length.ToString()) + ")"; }
        public static string P(object o) { return "P(object)"; }
        public static string O(int a, Thing t) { return "O(int,Thing)"; }
        public static string O(int a, object o) { return "O(int,object)"; }
        public static string I(int i) { return "I(int " + i + ")"; }
        public static string I(object o) { return "I(object)"; }
        public static string R(string s) { return "R(" + (s == null ? "null" : s) + ")"; }
        public static string L(long l) { return "L(long " + l + ")"; }
    }
    // Ruling Z: overloads C# picks for a null literal argument by betterness (C# 12.6.4.5: for an argument with
    // no type, T1 is the better target when T1 converts implicitly to T2 and T2 does not to T1).
    public class NBase { }
    public class NDerived : NBase { }
    public class NDerivedB : NBase { }
    public static class ByNull
    {
        // string converts to object: S2(null) binds S2(string)
        public static string S2(string s) { return "S2(string)"; }
        public static string S2(object o) { return "S2(object)"; }
        // string and Thing are unrelated: S3(null) is ambiguous (CS0121)
        public static string S3(string s) { return "S3(string)"; }
        public static string S3(Thing t) { return "S3(Thing)"; }
        // three candidates on one chain: the most derived wins
        public static string H(NBase b) { return "H(NBase)"; }
        public static string H(NDerived d) { return "H(NDerived)"; }
        public static string H(object o) { return "H(object)"; }
        // two siblings, each better than object but neither better than the other: ambiguous
        public static string H2(NDerived d) { return "H2(NDerived)"; }
        public static string H2(NDerivedB d) { return "H2(NDerivedB)"; }
        public static string H2(object o) { return "H2(object)"; }
        // an interface converts to object
        public static string I(System.IDisposable d) { return "I(IDisposable)"; }
        public static string I(object o) { return "I(object)"; }
        // two null positions, better in both
        public static string T2(string a, string b) { return "T2(string,string)"; }
        public static string T2(object a, object b) { return "T2(object,object)"; }
        // two null positions, each better in one: ambiguous
        public static string T(string a, object b) { return "T(string,object)"; }
        public static string T(object a, string b) { return "T(object,string)"; }
        // a null position and a typed one with the same parameter type
        public static string U(string a, int b) { return "U(string,int " + b + ")"; }
        public static string U(object a, int b) { return "U(object,int " + b + ")"; }
        // a null position and a typed one whose parameters differ: ambiguous for (null, "s")
        public static string V(string a, object b) { return "V(string,object)"; }
        public static string V(object a, string b) { return "V(object,string)"; }
        // Nullable<int> converts to object (boxing): N2(null) binds N2(int?)
        public static string N2(int? x) { return "N2(int?)"; }
        public static string N2(object o) { return "N2(object)"; }
        // int? converts to long? (an implicit nullable conversion): N3(null) binds N3(int?)
        public static string N3(int? x) { return "N3(int?)"; }
        public static string N3(long? x) { return "N3(long?)"; }
        // Nullable<int> and string are unrelated: ambiguous
        public static string N4(int? x) { return "N4(int?)"; }
        public static string N4(string s) { return "N4(string)"; }
        // params arrays in their normal form: string[] converts to object[] (array covariance)
        public static string P2(params string[] a) { return "P2(params string[] " + (a == null ? "null" : a.Length.ToString()) + ")"; }
        public static string P2(params object[] a) { return "P2(params object[] " + (a == null ? "null" : a.Length.ToString()) + ")"; }
        // a trailing optional parameter left out: betterness compares the given arguments only
        public static string Q(string s) { return "Q(string)"; }
        public static string Q(object o, int x = 0) { return "Q(object,int)"; }
        // a nullable and a params array with a null: object[] does not convert to int? nor back
        public static string NP(int? x) { return "NP(int?)"; }
        public static string NP(params object[] a) { return "NP(params)"; }
        // neutral at one null position (unrelated types), better at the other: X(null, null) binds X(string,string)
        public static string X(string a, string b) { return "X(string,string)"; }
        public static string X(Thing a, object b) { return "X(Thing,object)"; }
        // a null gives a generic method no type argument, so G<T>(T) does not apply: G(null) binds G(string)
        public static string G<T>(T x) { return "G<T>"; }
        public static string G(string s) { return "G(string)"; }
        // T occurs only in the params array: C# infers it from a typed argument in the expanded form, so PG(null, "s")
        // binds PG<string>(params string[]) over PG(object,object)
        public static string PG(object a, object b) { return "PG(object,object)"; }
        public static string PG<T>(params T[] a) { return "PG<" + typeof(T).Name + ">(params T[])"; }
        // the same parameter types at the given position: C#'s tie-breaker (no default filled in) picks Q2(string)
        public static string Q2(string s) { return "Q2(string)"; }
        public static string Q2(string s, int x = 0) { return "Q2(string,int)"; }
    }
    public class NCtor
    {
        public string Which;
        public NCtor(string s) { Which = "NCtor(string)"; }
        public NCtor(object o) { Which = "NCtor(object)"; }
    }
    public class ByValCtor
    {
        public string Which;
        public ByValCtor(byte b) { Which = "ByValCtor(byte)"; }
        public ByValCtor(object o) { Which = "ByValCtor(object)"; }
    }
    public class HueIdx { public string this[object o] { get { return "HueIdx[object]"; } } }
    public class HueIdxD : HueIdx { public string this[Hue c] { get { return "HueIdxD[Hue]"; } } }
    // Ruling Y: a derived class's `new` members hide the base's.
    public class HideBase
    {
        public string Name = "HideBase.Name";
        public int Count = 1;
        public string Prop { get { return "HideBase.Prop"; } }
        public string Rw { get; set; } = "HideBase.Rw";
    }
    public class HideDerived : HideBase
    {
        public new string Name = "HideDerived.Name";
        public new int Count = 10;
        public new string Prop { get { return "HideDerived.Prop"; } }
        public new string Rw { get; set; } = "HideDerived.Rw";
    }
    public class HideProt : HideBase
    {
        protected new string Name = "HideProt.Name";
    }
    // For a call, C#'s member lookup lets only an invocable derived member (of a delegate type) hide a base
    // method of its name: X does, Y (a string) and Z (private) do not, and W (an object) could be `dynamic`.
    public class CallHideBase
    {
        public string X() { return "CallHideBase.X()"; }
        public string Y() { return "CallHideBase.Y()"; }
        public string Z() { return "CallHideBase.Z()"; }
        public string W() { return "CallHideBase.W()"; }
    }
    public class CallHideDerived : CallHideBase
    {
        public new System.Func<string> X = () => "CallHideDerived.X delegate";
        public new string Y { get { return "CallHideDerived.Y"; } }
        private new string Z = "CallHideDerived.Z";
        public new object W = "CallHideDerived.W";
        public static CallHideDerived Make() { return new CallHideDerived(); }
        public string ZField() { return Z; }
    }
}
