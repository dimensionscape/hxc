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
    }
}
