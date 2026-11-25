// Proposed addition to tests/dotnet/netlib/ValLib/ValLib.cs (inside namespace ValLib, after ByVal), for
// Ruling Z's cases: overloads C# picks for a null literal argument by betterness (C# spec 12.6.4.5: for an
// argument with no type, T1 is the better target when T1 converts implicitly to T2 and T2 does not to T1).
namespace ValLib
{
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
    }
    public class NCtor
    {
        public string Which;
        public NCtor(string s) { Which = "NCtor(string)"; }
        public NCtor(object o) { Which = "NCtor(object)"; }
    }
}
