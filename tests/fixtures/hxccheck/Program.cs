// Checks assemblies written by hxc's .NET generator.
//   verify <dll>          ILVerify over method bodies and type definitions
//   dump <dll> <items>    prints the metadata named by a comma-separated item list (a type name,
//                         attrs:<type> for its attribute rows, debugdir for the debug directory and
//                         the PDB it names, docs or doc:<name> for the PDB's documents, pdb:<type> for
//                         the sequence points of a type's methods, scopes:<type> for their local scopes)
//   stress-fieldlookup <dll>  calls the assembly's haxe.lang.FieldLookup from many threads at once
//   stress-arrayforward <dll> makes the first cast of one unserialized array from many threads at once
using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;
using System.Reflection.PortableExecutable;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using ILVerify;

static class Program {
	static int Main(string[] args) {
		if (args.Length == 2 && args[0] == "verify") return Verify(Path.GetFullPath(args[1]));
		if (args.Length == 3 && args[0] == "dump") return Dump(Path.GetFullPath(args[1]), args[2]);
		if (args.Length == 2 && args[0] == "stress-fieldlookup") return StressFieldLookup(Path.GetFullPath(args[1]));
		if (args.Length == 2 && args[0] == "stress-arrayforward") return StressArrayForward(Path.GetFullPath(args[1]));
		Console.Error.WriteLine("usage: HxcCheck verify <dll> | dump <dll> <items> | stress-fieldlookup <dll> | stress-arrayforward <dll>");
		return 2;
	}

	// hxcs's FieldLookup.doHash: over the UTF-16 code units, kept positive.
	static int FieldHash(string s) {
		var acc = 0;
		foreach (var c in s) acc = unchecked((223 * (acc >> 1) + c) << 1);
		return (int)((uint)acc >> 1);
	}

	// From 16 threads at once, each calls FieldLookup.hash on 2,000 names no thread used before, and
	// lookupHash on each result right away and again at the end: every name must hash as hxcs hashes it
	// and map back exactly. A name whose hash another name already owns hashes to ~hash, as in hxcs, and
	// that other name must be the one lookupHash gives. Any exception fails too (server app issue 6551).
	static int StressFieldLookup(string path) {
		const int threads = 16, perThread = 2000;
		var type = Assembly.LoadFrom(path).GetType("haxe.lang.FieldLookup", true)!;
		var hash = type.GetMethod("hash", [typeof(string)])!.CreateDelegate<Func<string, int>>();
		var lookupHash = type.GetMethod("lookupHash", [typeof(int)])!.CreateDelegate<Func<int, string>>();
		// Names that collide with none of the others, so a conflict can only be with a name the table
		// started with.
		var names = new string[threads][];
		var taken = new HashSet<int>();
		for (var t = 0; t < threads; t++) {
			names[t] = new string[perThread];
			var n = 0;
			for (var i = 0; n < perThread; i++) {
				var name = "stress_" + t + "_" + i;
				if (taken.Add(FieldHash(name))) names[t][n++] = name;
			}
		}
		var problems = new System.Collections.Concurrent.ConcurrentQueue<string>();
		void Check(string name, int got) {
			var want = FieldHash(name);
			if (got == want) {
				var back = lookupHash(got);
				if (back != name) problems.Enqueue("lookupHash(" + got + ") of " + name + " gave " + (back ?? "null"));
			} else if (got == ~want) {
				var owner = lookupHash(want);
				if (owner == name) problems.Enqueue(name + " hashed to ~" + want + " but owns it");
			} else {
				problems.Enqueue(name + " hashed to " + got + ", not " + want);
			}
		}
		var start = new Barrier(threads);
		var workers = new Thread[threads];
		for (var t = 0; t < threads; t++) {
			var mine = names[t];
			workers[t] = new Thread(() => {
				var got = new int[perThread];
				start.SignalAndWait();
				try {
					for (var i = 0; i < perThread; i++) {
						got[i] = hash(mine[i]);
						Check(mine[i], got[i]);
					}
					for (var i = 0; i < perThread; i++) Check(mine[i], got[i]);
				} catch (Exception e) {
					problems.Enqueue(e.GetType().Name + ": " + e.Message);
				}
			});
			workers[t].Start();
		}
		foreach (var w in workers) w.Join();
		foreach (var p in problems.Take(20)) Console.WriteLine(p);
		Console.WriteLine("stress-fieldlookup: " + threads * perThread + " names from " + threads + " threads, " + problems.Count + " problems");
		return problems.IsEmpty ? 0 : 1;
	}

	// Haxe issue 8314's forward under a race, in four shapes. Each round calls one of the assembly's
	// makers for a fresh Array`1<object> from haxe.Unserializer and starts 8 threads behind a barrier. Each
	// casts that one array with the shape's P.toInts(a:Dynamic):Array<Int> or P.toStrings and pushes onto
	// what it got, the pushes under a lock since an Array is not thread-safe. Every thread must get the same
	// typed array, holding the original's elements and then each thread's pushes, and the original's length
	// must follow it. Any exception fails too. P.make's [1,2,3] runs 200 rounds of one push a thread;
	// P.makeFull's [1,2,3,4], which fills its capacity, and P.makeStrings's ["a",null,"b"], whose null
	// converts losslessly, run 1000 rounds of 3 pushes a thread, so a push can race a late cast's scan.
	// The fourth shape races two target types (StressTwoTypes).
	static int StressArrayForward(string path) {
		var p = Assembly.LoadFrom(path).GetType("P", true)!;
		var failed = false;
		failed |= StressShape(p, "make", "toInts", typeof(int), [1, 2, 3], me => me, 200, 1);
		failed |= StressShape(p, "makeFull", "toInts", typeof(int), [1, 2, 3, 4], me => me, 1000, 3);
		failed |= StressShape(p, "makeStrings", "toStrings", typeof(string), ["a", null, "b"], me => "t" + me, 1000, 3);
		failed |= StressTwoTypes(p, 5000, 3);
		return failed ? 1 : 0;
	}

	// P.makeMixed's [1.5,2] converts losslessly into Float but not into Int, so of 8 threads casting it at
	// once the even ones (P.toFloats) reinterpret it and push 10 + their index onto the target, while the odd ones
	// (P.toInts) copy it. The Float threads must all get the same Array`1<double>, holding 1.5, 2 and then
	// their pushes, with the original's length following it. Each Int thread must get an Array`1<int> whose
	// storage holds its length, starting 2, 2 (1.5 rounds) and then some of the pushed values, and whose
	// toString works: a copy that took the original's length after pushes through the target grew it, but
	// the original's stale storage, reads past that storage's end. Any exception fails too.
	static bool StressTwoTypes(Type p, int rounds, int pushes) {
		const int threads = 8;
		var flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;
		var make = p.GetMethod("makeMixed", flags)!.CreateDelegate<Func<object>>();
		var toFloats = p.GetMethod("toFloats", flags)!.CreateDelegate<Func<object, object>>();
		var toInts = p.GetMethod("toInts", flags)!.CreateDelegate<Func<object, object>>();
		var problems = new List<string>();
		var pushers = Enumerable.Range(0, threads).Where(t => t % 2 == 0).ToArray();
		var want = 2 + pushers.Length * pushes;
		int Length(object o) => (int)o.GetType().GetField("length")!.GetValue(o)!;
		System.Array Store(object o) => (System.Array)o.GetType().GetField("__a")!.GetValue(o)!;
		// Looked up once, so a Float thread's pushes follow its cast closely.
		var generic = make().GetType().GetGenericTypeDefinition();
		var push = generic.MakeGenericType(typeof(double)).GetMethod("push")!;
		var watch = System.Diagnostics.Stopwatch.StartNew();
		for (var round = 0; round < rounds; round++) {
			var a = make();
			var got = new object?[threads];
			var errors = new System.Collections.Concurrent.ConcurrentQueue<string>();
			var gate = new object();
			var start = new Barrier(threads);
			var workers = new Thread[threads];
			for (var t = 0; t < threads; t++) {
				var me = t;
				workers[t] = new Thread(() => {
					start.SignalAndWait();
					try {
						if (me % 2 == 0) {
							var r = toFloats(a);
							got[me] = r;
							lock (gate) for (var i = 0; i < pushes; i++) push.Invoke(r, [(double)(me + 10)]);
						} else {
							var r = toInts(a);
							got[me] = r;
							r.GetType().GetMethod("toString")!.Invoke(r, []);
						}
					} catch (Exception e) {
						var x = e is TargetInvocationException && e.InnerException != null ? e.InnerException : e;
						errors.Enqueue(x.GetType().Name + ": " + x.Message);
					}
				});
				workers[t].Start();
			}
			foreach (var w in workers) w.Join();
			var where = "makeMixed round " + round + ": ";
			foreach (var e in errors) problems.Add(where + e);
			var first = got[0];
			if (first == null || first.GetType() != generic.MakeGenericType(typeof(double))) {
				problems.Add(where + "thread 0 got " + (first == null ? "null" : first.GetType().ToString()));
				continue;
			}
			foreach (var t in pushers)
				if (!ReferenceEquals(got[t], first)) problems.Add(where + "thread " + t + " got another array");
			var length = Length(first);
			if (length != want) problems.Add(where + "length " + length + ", not " + want);
			if (Length(a) != length) problems.Add(where + "the original's length is " + Length(a) + ", the target's " + length);
			var store = Store(first);
			var values = Enumerable.Range(0, Math.Min(length, store.Length)).Select(i => (double)store.GetValue(i)!).ToArray();
			var rest = values.Skip(2).OrderBy(v => v);
			var expected = pushers.SelectMany(t => Enumerable.Repeat((double)(t + 10), pushes)).OrderBy(v => v);
			if (!values.Take(2).SequenceEqual([1.5, 2.0]) || !rest.SequenceEqual(expected))
				problems.Add(where + "elements " + string.Join(",", values));
			for (var t = 1; t < threads; t += 2) {
				var copy = got[t];
				if (copy == null) continue;
				if (copy.GetType() != generic.MakeGenericType(typeof(int))) {
					problems.Add(where + "thread " + t + " got " + copy.GetType());
					continue;
				}
				var n = Length(copy);
				var own = Store(copy);
				if (n < 2 || n > own.Length) {
					problems.Add(where + "thread " + t + "'s copy has length " + n + " over storage of " + own.Length);
					continue;
				}
				var ints = Enumerable.Range(0, n).Select(i => (int)own.GetValue(i)!).ToArray();
				if (ints[0] != 2 || ints[1] != 2 || ints.Skip(2).Any(v => !pushers.Contains(v - 10)))
					problems.Add(where + "thread " + t + "'s copy " + string.Join(",", ints));
			}
		}
		foreach (var problem in problems.Take(20)) Console.WriteLine(problem);
		Console.WriteLine("stress-arrayforward makeMixed: " + rounds + " rounds of " + threads + " threads, two types, " + pushes
			+ " pushes each, in " + watch.ElapsedMilliseconds + " ms, " + problems.Count + " problems");
		return problems.Count != 0;
	}

	// One shape of stress-arrayforward; true when it found a problem.
	static bool StressShape(Type p, string maker, string caster, Type element, object?[] initial, Func<int, object> pushed, int rounds, int pushes) {
		const int threads = 8;
		var flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;
		var make = p.GetMethod(maker, flags)!.CreateDelegate<Func<object>>();
		var cast = p.GetMethod(caster, flags)!.CreateDelegate<Func<object, object>>();
		var problems = new List<string>();
		var want = initial.Length + threads * pushes;
		var watch = System.Diagnostics.Stopwatch.StartNew();
		for (var round = 0; round < rounds; round++) {
			var a = make();
			var got = new object?[threads];
			var errors = new System.Collections.Concurrent.ConcurrentQueue<string>();
			var gate = new object();
			var start = new Barrier(threads);
			var workers = new Thread[threads];
			for (var t = 0; t < threads; t++) {
				var me = t;
				workers[t] = new Thread(() => {
					start.SignalAndWait();
					try {
						var r = cast(a);
						got[me] = r;
						var push = r.GetType().GetMethod("push")!;
						lock (gate) for (var i = 0; i < pushes; i++) push.Invoke(r, [pushed(me)]);
					} catch (Exception e) {
						var x = e is TargetInvocationException && e.InnerException != null ? e.InnerException : e;
						errors.Enqueue(x.GetType().Name + ": " + x.Message);
					}
				});
				workers[t].Start();
			}
			foreach (var w in workers) w.Join();
			var where = maker + " round " + round + ": ";
			foreach (var e in errors) problems.Add(where + e);
			var first = got[0];
			if (first == null || first.GetType() != a.GetType().GetGenericTypeDefinition().MakeGenericType(element)) {
				problems.Add(where + "thread 0 got " + (first == null ? "null" : first.GetType().ToString()));
				continue;
			}
			for (var t = 1; t < threads; t++)
				if (!ReferenceEquals(got[t], first)) problems.Add(where + "thread " + t + " got another array");
			int Length(object o) => (int)o.GetType().GetField("length")!.GetValue(o)!;
			var length = Length(first);
			if (length != want) problems.Add(where + "length " + length + ", not " + want);
			if (Length(a) != length) problems.Add(where + "the original's length is " + Length(a) + ", the target's " + length);
			var store = (System.Array)first.GetType().GetField("__a")!.GetValue(first)!;
			var values = Enumerable.Range(0, Math.Min(length, store.Length)).Select(i => store.GetValue(i)).ToArray();
			var rest = values.Skip(initial.Length).Select(v => Convert.ToString(v)).OrderBy(v => v, StringComparer.Ordinal);
			var expected = Enumerable.Range(0, threads).SelectMany(t => Enumerable.Repeat(Convert.ToString(pushed(t)), pushes)).OrderBy(v => v, StringComparer.Ordinal);
			if (!values.Take(initial.Length).SequenceEqual(initial) || !rest.SequenceEqual(expected))
				problems.Add(where + "elements " + string.Join(",", values));
		}
		foreach (var problem in problems.Take(20)) Console.WriteLine(problem);
		Console.WriteLine("stress-arrayforward " + maker + ": " + rounds + " rounds of " + threads + " threads, " + pushes + " pushes each, in "
			+ watch.ElapsedMilliseconds + " ms, " + problems.Count + " problems");
		return problems.Count != 0;
	}

	static int Verify(string path) {
		var resolver = new Resolver(path);
		var verifier = new Verifier(resolver, new VerifierOptions { SanityChecks = true });
		verifier.SetSystemModuleName(new AssemblyNameInfo("System.Private.CoreLib"));
		var pe = resolver.Main;
		var md = pe.GetMetadataReader();
		var errors = 0;
		// Methods first, then types, as the ilverify CLI does.
		foreach (var h in md.MethodDefinitions) {
			var m = md.GetMethodDefinition(h);
			var where = TypeName(md, m.GetDeclaringType()) + "::" + md.GetString(m.Name);
			foreach (var r in verifier.Verify(pe, h)) {
				Console.WriteLine(where + ": " + Describe(r));
				errors++;
			}
		}
		foreach (var h in md.TypeDefinitions) {
			foreach (var r in verifier.Verify(pe, h, false)) {
				Console.WriteLine(TypeName(md, h) + ": " + Describe(r));
				errors++;
			}
		}
		return errors == 0 ? 0 : 1;
	}

	static string Describe(VerificationResult r) {
		var code = r.Code != VerifierError.None ? r.Code.ToString() : r.ExceptionID?.ToString() ?? "None";
		var s = code + " " + r.Message;
		if (r.ErrorArguments != null && r.ErrorArguments.Length > 0)
			s += " (" + string.Join(", ", r.ErrorArguments.Select(a => a.Name + "=" + a.Value)) + ")";
		return s;
	}

	// References resolve from the shared framework running this tool, then the DLL's own directory.
	sealed class Resolver : IResolver {
		readonly string[] dirs;
		readonly Dictionary<string, PEReader?> cache = new(StringComparer.OrdinalIgnoreCase);
		public readonly PEReader Main;

		public Resolver(string path) {
			dirs = [Path.GetDirectoryName(typeof(object).Assembly.Location)!, Path.GetDirectoryName(path)!];
			Main = new PEReader(File.OpenRead(path));
			cache[Path.GetFileNameWithoutExtension(path)] = Main;
		}

		public PEReader? ResolveAssembly(AssemblyNameInfo name) => Load(name.Name);

		public PEReader? ResolveModule(AssemblyNameInfo referencingAssembly, string fileName) =>
			Load(Path.GetFileNameWithoutExtension(fileName));

		PEReader? Load(string simpleName) {
			if (cache.TryGetValue(simpleName, out var pe)) return pe;
			pe = null;
			foreach (var dir in dirs) {
				var file = Path.Combine(dir, simpleName + ".dll");
				if (File.Exists(file)) {
					pe = new PEReader(File.OpenRead(file));
					break;
				}
			}
			cache[simpleName] = pe;
			return pe;
		}
	}

	static int Dump(string path, string items) {
		using var pe = new PEReader(File.OpenRead(path));
		var md = pe.GetMetadataReader();
		var types = new TypeNames(md);
		// The PDB, opened and checked by the first item that reads it.
		MetadataReaderProvider? pdbFile = null;
		MetadataReader? pdb = null;
		var opened = false;
		MetadataReader? Pdb() {
			if (opened) return pdb;
			opened = true;
			pdbFile = OpenPdb(pe, path);
			pdb = pdbFile?.GetMetadataReader();
			if (pdb == null) Console.WriteLine("pdb missing"); else CheckPdb(pe, md, pdb);
			return pdb;
		}
		foreach (var item in items.Split(',')) {
			switch (item) {
				case "assembly": {
					var a = md.GetAssemblyDefinition();
					Console.WriteLine("assembly " + md.GetString(a.Name) + " " + a.Version);
					break;
				}
				case "refs":
					foreach (var h in md.AssemblyReferences) {
						var r = md.GetAssemblyReference(h);
						Console.WriteLine("assemblyref " + md.GetString(r.Name) + " " + r.Version + " " + Token(md, r));
					}
					break;
				case "entrypoint": {
					var token = pe.PEHeaders.CorHeader!.EntryPointTokenOrRelativeVirtualAddress;
					if (token == 0) {
						Console.WriteLine("entrypoint none");
					} else {
						var m = md.GetMethodDefinition(MetadataTokens.MethodDefinitionHandle(token & 0xFFFFFF));
						Console.WriteLine("entrypoint " + TypeName(md, m.GetDeclaringType()) + "::" + md.GetString(m.Name));
					}
					break;
				}
				case "debugdir":
					DumpDebugDirectory(pe, md, path);
					break;
				// Whether the assembly holds ReadyToRun code beside its IL: crossgen2 writes a ManagedNativeHeader.
				case "r2r":
					Console.WriteLine(pe.PEHeaders.CorHeader!.ManagedNativeHeaderDirectory.Size > 0 ? "readytorun" : "il only");
					break;
				case "docs": {
					var p = Pdb();
					if (p == null) break;
					if (p.Documents.Count == 0) Console.WriteLine("documents none");
					foreach (var h in p.Documents) Console.WriteLine(DocumentLine(p, h));
					break;
				}
				case var a when a.StartsWith("doc:"): {
					var p = Pdb();
					if (p == null) break;
					var h = p.Documents.FirstOrDefault(d => p.GetString(p.GetDocument(d).Name) == a.Substring(4));
					Console.WriteLine(h.IsNil ? "missing " + a : DocumentLine(p, h));
					break;
				}
				case var a when a.StartsWith("pdb:"): {
					var p = Pdb();
					if (p != null && !DumpSequencePoints(md, p, a.Substring(4))) Console.WriteLine("missing " + a);
					break;
				}
				case var a when a.StartsWith("scopes:"): {
					var p = Pdb();
					if (p != null && !DumpScopes(md, p, a.Substring(7))) Console.WriteLine("missing " + a);
					break;
				}
				case var a when a.StartsWith("attrs:"):
					if (!DumpAttributes(md, types, a.Substring(6))) Console.WriteLine("missing " + a);
					break;
				default:
					if (!DumpType(md, types, item)) Console.WriteLine("missing " + item);
					break;
			}
		}
		pdbFile?.Dispose();
		return 0;
	}

	static readonly Guid Sha256Algorithm = new("8829d00f-11b8-4213-878b-770e8597ac16");
	static readonly Guid CSharpLanguage = new("3f5162f8-07c6-11d3-9053-00c04fa302a1");
	static readonly Guid EmbeddedSourceKind = new("0e8a571b-6926-466e-b4ad-8ab04611f5fe");

	// The PDB the CodeView entry names, read from beside the DLL, else <name>.pdb there; null for none.
	static MetadataReaderProvider? OpenPdb(PEReader pe, string path) {
		var file = Path.GetFileNameWithoutExtension(path) + ".pdb";
		foreach (var e in pe.ReadDebugDirectory())
			if (e.Type == DebugDirectoryEntryType.CodeView) file = Path.GetFileName(pe.ReadCodeViewDebugDirectoryData(e).Path);
		var full = Path.Combine(Path.GetDirectoryName(path)!, file);
		return File.Exists(full) ? MetadataReaderProvider.FromPortablePdbStream(new MemoryStream(File.ReadAllBytes(full))) : null;
	}

	// What every dump of a PDB checks, printing `bad pdb: <what>` for each failure: a MethodDebugInformation
	// row per MethodDef row, and in each method sequence point offsets strictly increasing and inside its
	// IL, and every document index a Document row; then the LocalScope rows (CheckScopes).
	static void CheckPdb(PEReader pe, MetadataReader md, MetadataReader pdb) {
		if (pdb.GetTableRowCount(TableIndex.MethodDebugInformation) != md.GetTableRowCount(TableIndex.MethodDef)) {
			Console.WriteLine("bad pdb: MethodDebugInformation rows are not MethodDef's");
			return;
		}
		var docs = pdb.GetTableRowCount(TableIndex.Document);
		foreach (var mh in md.MethodDefinitions) {
			var m = md.GetMethodDefinition(mh);
			var name = TypeName(md, m.GetDeclaringType()) + "::" + md.GetString(m.Name);
			try {
				var info = pdb.GetMethodDebugInformation(mh);
				if (info.SequencePointsBlob.IsNil) continue;
				var size = m.RelativeVirtualAddress == 0 ? 0 : pe.GetMethodBody(m.RelativeVirtualAddress).GetILBytes()!.Length;
				var last = -1;
				foreach (var sp in info.GetSequencePoints()) {
					if (sp.Offset <= last) Console.WriteLine("bad pdb: " + name + " has offset " + sp.Offset + " after " + last);
					if (sp.Offset >= size) Console.WriteLine("bad pdb: " + name + " has offset " + sp.Offset + " past its " + size + " bytes of IL");
					var row = MetadataTokens.GetRowNumber(sp.Document);
					if (row < 1 || row > docs) Console.WriteLine("bad pdb: " + name + " names document " + row);
					last = sp.Offset;
				}
			} catch (BadImageFormatException e) {
				Console.WriteLine("bad pdb: " + name + ": " + e.Message);
			}
		}
		CheckScopes(pe, md, pdb);
	}

	// The LocalScope rows sorted by method, then start ascending, then length descending; each method's
	// first scope its whole IL, the others nested in it and in each other, none empty, and no name twice
	// in one scope.
	static void CheckScopes(PEReader pe, MetadataReader md, MetadataReader pdb) {
		var methods = md.GetTableRowCount(TableIndex.MethodDef);
		int lastMethod = 0, lastStart = 0, lastLength = 0, size = 0;
		var ends = new Stack<int>();
		var name = "";
		for (var row = 1; row <= pdb.GetTableRowCount(TableIndex.LocalScope); row++) {
			try {
				var s = pdb.GetLocalScope(MetadataTokens.LocalScopeHandle(row));
				var method = MetadataTokens.GetRowNumber(s.Method);
				if (method < 1 || method > methods) {
					Console.WriteLine("bad pdb: scope " + row + " names method " + method);
					continue;
				}
				if (method < lastMethod || method == lastMethod && (s.StartOffset < lastStart || s.StartOffset == lastStart && s.Length > lastLength))
					Console.WriteLine("bad pdb: scope " + row + " is out of order");
				if (method != lastMethod) {
					var m = md.GetMethodDefinition(MetadataTokens.MethodDefinitionHandle(method));
					name = TypeName(md, m.GetDeclaringType()) + "::" + md.GetString(m.Name);
					size = m.RelativeVirtualAddress == 0 ? 0 : pe.GetMethodBody(m.RelativeVirtualAddress).GetILBytes()!.Length;
					ends.Clear();
					if (s.StartOffset != 0 || s.Length != size) Console.WriteLine("bad pdb: " + name + "'s first scope is not its " + size + " bytes of IL");
				}
				var where = name + "'s scope " + s.StartOffset + "+" + s.Length;
				if (s.Length <= 0) Console.WriteLine("bad pdb: " + where + " is empty");
				if (s.EndOffset > size) Console.WriteLine("bad pdb: " + where + " is past its " + size + " bytes of IL");
				while (ends.Count > 0 && ends.Peek() <= s.StartOffset) ends.Pop();
				if (ends.Count > 0 && s.EndOffset > ends.Peek()) Console.WriteLine("bad pdb: " + where + " overlaps the scope around it");
				ends.Push(s.EndOffset);
				var names = new HashSet<string>();
				foreach (var vh in s.GetLocalVariables())
					if (!names.Add(pdb.GetString(pdb.GetLocalVariable(vh).Name))) Console.WriteLine("bad pdb: " + where + " names a variable twice");
				lastMethod = method;
				lastStart = s.StartOffset;
				lastLength = s.Length;
			} catch (Exception e) when (e is BadImageFormatException || e is ArgumentException) {
				Console.WriteLine("bad pdb: scope " + row + ": " + e.Message);
			}
		}
	}

	// `document <name> <sha256|other> <csharp|language GUID>`, then for an EmbeddedSource entry whether its
	// text has the document's hash.
	static string DocumentLine(MetadataReader pdb, DocumentHandle h) {
		try {
			var d = pdb.GetDocument(h);
			var language = pdb.GetGuid(d.Language);
			var line = "document " + pdb.GetString(d.Name) + " " + (pdb.GetGuid(d.HashAlgorithm) == Sha256Algorithm ? "sha256" : "other") + " "
				+ (language == CSharpLanguage ? "csharp" : language.ToString());
			foreach (var ch in pdb.GetCustomDebugInformation(h)) {
				var cdi = pdb.GetCustomDebugInformation(ch);
				if (pdb.GetGuid(cdi.Kind) != EmbeddedSourceKind) continue;
				// A format of 0 is the text as it is; above 0, the length of the deflated text.
				var blob = pdb.GetBlobBytes(cdi.Value);
				if (blob.Length < 4) return "bad pdb: document " + MetadataTokens.GetRowNumber(h) + "'s EmbeddedSource is " + blob.Length + " bytes";
				var text = blob.AsSpan(4).ToArray();
				if (BitConverter.ToInt32(blob, 0) > 0) {
					using var inflated = new MemoryStream();
					using (var deflate = new System.IO.Compression.DeflateStream(new MemoryStream(text), System.IO.Compression.CompressionMode.Decompress))
						deflate.CopyTo(inflated);
					text = inflated.ToArray();
				}
				line += SHA256.HashData(text).AsSpan().SequenceEqual(pdb.GetBlobBytes(d.Hash)) ? " embedded ok" : " embedded mismatch";
			}
			return line;
		} catch (Exception e) when (e is BadImageFormatException || e is InvalidDataException || e is ArgumentException) {
			return "bad pdb: document " + MetadataTokens.GetRowNumber(h) + ": " + e.Message;
		}
	}

	// `pdb:<type>`: each method of the type that has sequence points, in MethodDef order, then a line per
	// point in IL order: its document and span, or `hidden`.
	static bool DumpSequencePoints(MetadataReader md, MetadataReader pdb, string item) {
		var rows = pdb.GetTableRowCount(TableIndex.MethodDebugInformation);
		foreach (var h in md.TypeDefinitions) {
			if (TypeName(md, h) != item) continue;
			foreach (var mh in md.GetTypeDefinition(h).GetMethods()) {
				var name = item + "::" + md.GetString(md.GetMethodDefinition(mh).Name);
				if (MetadataTokens.GetRowNumber(mh) > rows) {
					Console.WriteLine("bad pdb: " + name + " has no MethodDebugInformation row");
					continue;
				}
				try {
					var info = pdb.GetMethodDebugInformation(mh);
					if (info.SequencePointsBlob.IsNil) continue;
					Console.WriteLine("method " + name);
					foreach (var sp in info.GetSequencePoints()) {
						if (sp.IsHidden) {
							Console.WriteLine("  hidden");
							continue;
						}
						var doc = pdb.GetString(pdb.GetDocument(sp.Document).Name);
						Console.WriteLine("  " + doc + " " + sp.StartLine + ":" + sp.StartColumn + "-" + sp.EndLine + ":" + sp.EndColumn);
					}
				} catch (Exception e) when (e is BadImageFormatException || e is ArgumentException) {
					Console.WriteLine("bad pdb: " + name + ": " + e.Message);
				}
			}
			return true;
		}
		return false;
	}

	// `scopes:<type>`: each method of the type that has LocalScope rows, in MethodDef order, then its scopes
	// in row order, each indented two spaces more than the scope around it, with a line per named local.
	static bool DumpScopes(MetadataReader md, MetadataReader pdb, string item) {
		foreach (var h in md.TypeDefinitions) {
			if (TypeName(md, h) != item) continue;
			foreach (var mh in md.GetTypeDefinition(h).GetMethods()) {
				var name = item + "::" + md.GetString(md.GetMethodDefinition(mh).Name);
				try {
					var ends = new Stack<int>();
					var first = true;
					foreach (var sh in pdb.GetLocalScopes(mh)) {
						var s = pdb.GetLocalScope(sh);
						if (first) Console.WriteLine("method " + name);
						first = false;
						while (ends.Count > 0 && ends.Peek() <= s.StartOffset) ends.Pop();
						var indent = new string(' ', 2 * (ends.Count + 1));
						Console.WriteLine(indent + "scope");
						foreach (var vh in s.GetLocalVariables()) Console.WriteLine(indent + "  local " + pdb.GetString(pdb.GetLocalVariable(vh).Name));
						ends.Push(s.EndOffset);
					}
				} catch (Exception e) when (e is BadImageFormatException || e is ArgumentException) {
					Console.WriteLine("bad pdb: " + name + ": " + e.Message);
				}
			}
			return true;
		}
		return false;
	}

	// `debugdir`: the debug directory's entries in order, each checked against the PDB its CodeView entry
	// names (read from beside the DLL), then whether that PDB has a MethodDebugInformation row per
	// MethodDef row. With no directory, a PDB beside the DLL anyway is reported as stray.
	static void DumpDebugDirectory(PEReader pe, MetadataReader md, string path) {
		var entries = pe.ReadDebugDirectory();
		var dir = Path.GetDirectoryName(path)!;
		if (entries.Length == 0) {
			Console.WriteLine("debugdir none");
			var stray = Path.GetFileNameWithoutExtension(path) + ".pdb";
			if (File.Exists(Path.Combine(dir, stray))) Console.WriteLine("stray " + stray);
			return;
		}
		byte[]? pdb = null;
		MetadataReader? pdbMd = null;
		foreach (var e in entries) {
			switch (e.Type) {
				case DebugDirectoryEntryType.CodeView: {
					var cv = pe.ReadCodeViewDebugDirectoryData(e);
					var kind = e.MinorVersion == 0x504D ? "portable" : "windows";
					var file = Path.Combine(dir, Path.GetFileName(cv.Path));
					string id;
					if (File.Exists(file)) {
						pdb = File.ReadAllBytes(file);
						pdbMd = MetadataReaderProvider.FromPortablePdbStream(new MemoryStream(pdb)).GetMetadataReader();
						var header = pdbMd.DebugMetadataHeader!;
						var want = cv.Guid.ToByteArray().Concat(BitConverter.GetBytes(e.Stamp));
						id = header.Id.SequenceEqual(want) ? "id-match" : "id-mismatch";
					} else {
						id = "pdb-missing";
					}
					Console.WriteLine("codeview " + cv.Path + " age " + cv.Age + " " + kind + " " + id);
					break;
				}
				case DebugDirectoryEntryType.PdbChecksum: {
					var sum = pe.ReadPdbChecksumDebugDirectoryData(e);
					var state = "pdb-missing";
					if (pdb != null && pdbMd != null && sum.AlgorithmName == "SHA256") {
						var zeroed = (byte[])pdb.Clone();
						var header = pdbMd.DebugMetadataHeader!;
						Array.Clear(zeroed, header.IdStartOffset, header.Id.Length);
						state = SHA256.HashData(zeroed).AsSpan().SequenceEqual(sum.Checksum.AsSpan()) ? "match" : "mismatch";
					} else if (pdb != null) {
						state = "unknown";
					}
					Console.WriteLine("pdbchecksum " + sum.AlgorithmName + " " + state);
					break;
				}
				case DebugDirectoryEntryType.Reproducible:
					Console.WriteLine("reproducible");
					break;
				default:
					Console.WriteLine("entry " + e.Type);
					break;
			}
		}
		if (pdbMd != null) {
			var rows = pdbMd.GetTableRowCount(TableIndex.MethodDebugInformation) == md.GetTableRowCount(TableIndex.MethodDef);
			Console.WriteLine("pdb rows " + (rows ? "match" : "mismatch"));
		}
	}

	// The public key token, computed when the row holds a full public key.
	static string Token(MetadataReader md, AssemblyReference r) {
		if (r.PublicKeyOrToken.IsNil) return "null";
		var b = md.GetBlobBytes(r.PublicKeyOrToken);
		if (b.Length == 0) return "null";
		if ((r.Flags & AssemblyFlags.PublicKey) != 0) b = SHA1.HashData(b).TakeLast(8).Reverse().ToArray();
		return Convert.ToHexString(b).ToLowerInvariant();
	}

	static bool DumpType(MetadataReader md, TypeNames types, string item) {
		foreach (var h in md.TypeDefinitions) {
			if (TypeName(md, h) != item) continue;
			var t = md.GetTypeDefinition(h);
			var sb = new StringBuilder("type ");
			sb.Append(TypeWords(t.Attributes)).Append(item).Append(GenericNames(md, t.GetGenericParameters()));
			if (!t.BaseType.IsNil) sb.Append(" extends ").Append(types.Of(t.BaseType, default));
			var ifaces = t.GetInterfaceImplementations().Select(i => types.Of(md.GetInterfaceImplementation(i).Interface, default)).ToList();
			if (ifaces.Count > 0) sb.Append(" implements ").Append(string.Join(", ", ifaces));
			Console.WriteLine(sb.ToString());
			var typeArgs = new GenericContext(t.GetGenericParameters(), default);
			foreach (var fh in t.GetFields()) {
				var f = md.GetFieldDefinition(fh);
				var ft = f.DecodeSignature(types, typeArgs);
				Console.WriteLine("  field " + FieldWords(f.Attributes) + ft + " " + md.GetString(f.Name));
			}
			foreach (var mh in t.GetMethods()) {
				var m = md.GetMethodDefinition(mh);
				var sig = m.DecodeSignature(types, new GenericContext(t.GetGenericParameters(), m.GetGenericParameters()));
				Console.WriteLine("  method " + MethodWords(m.Attributes) + sig.ReturnType + " " + md.GetString(m.Name)
					+ GenericNames(md, m.GetGenericParameters()) + "(" + string.Join(", ", sig.ParameterTypes) + ")");
			}
			return true;
		}
		return false;
	}

	// `attrs:<type>`: the CustomAttribute rows of a type and its members, one line per row with its
	// decoded arguments, so that a dump compares row for row with another compiler's. The type's own rows
	// come first, then its generic parameters', interface implementations', fields', methods' (each
	// followed by its generic parameters' and parameters', the return value as #0), properties' and events', each
	// kind sorted by name and signature so that member order does not matter; the rows of one parent keep
	// the table's order.
	static bool DumpAttributes(MetadataReader md, TypeNames types, string item) {
		foreach (var h in md.TypeDefinitions) {
			if (TypeName(md, h) != item) continue;
			var t = md.GetTypeDefinition(h);
			var rows = new Dictionary<EntityHandle, List<CustomAttribute>>();
			foreach (var ch in md.CustomAttributes) {
				var ca = md.GetCustomAttribute(ch);
				if (!rows.TryGetValue(ca.Parent, out var l)) rows[ca.Parent] = l = new List<CustomAttribute>();
				l.Add(ca);
			}
			var typeArgs = new GenericContext(t.GetGenericParameters(), default);
			Console.WriteLine("attrs " + item);
			void Print(string parent, EntityHandle e) {
				if (!rows.TryGetValue(e, out var l)) return;
				foreach (var ca in l) Console.WriteLine("  " + parent + " :: " + AttributeText(md, types, ca));
			}
			Print("type", h);
			foreach (var gh in t.GetGenericParameters()) Print("genericparam " + md.GetString(md.GetGenericParameter(gh).Name), gh);
			foreach (var ih in t.GetInterfaceImplementations())
				Print("interfaceimpl " + types.Of(md.GetInterfaceImplementation(ih).Interface, typeArgs), ih);
			var members = new List<(string key, Action print)>();
			foreach (var fh in t.GetFields()) {
				var f = md.GetFieldDefinition(fh);
				var text = "field " + f.DecodeSignature(types, typeArgs) + " " + md.GetString(f.Name);
				members.Add(("1 " + md.GetString(f.Name) + " " + text, () => Print(text, fh)));
			}
			foreach (var mh in t.GetMethods()) {
				var m = md.GetMethodDefinition(mh);
				var sig = m.DecodeSignature(types, new GenericContext(t.GetGenericParameters(), m.GetGenericParameters()));
				var text = "method " + sig.ReturnType + " " + md.GetString(m.Name) + GenericNames(md, m.GetGenericParameters())
					+ "(" + string.Join(", ", sig.ParameterTypes) + ")";
				members.Add(("2 " + md.GetString(m.Name) + " " + text, () => {
					Print(text, mh);
					foreach (var gh in m.GetGenericParameters()) Print(text + " genericparam " + md.GetString(md.GetGenericParameter(gh).Name), gh);
					foreach (var ph in m.GetParameters()) {
						var p = md.GetParameter(ph);
						Print(text + " param #" + p.SequenceNumber + (p.Name.IsNil ? "" : " " + md.GetString(p.Name)), ph);
					}
				}));
			}
			foreach (var ph in t.GetProperties()) {
				var p = md.GetPropertyDefinition(ph);
				var text = "property " + p.DecodeSignature(types, typeArgs).ReturnType + " " + md.GetString(p.Name);
				members.Add(("3 " + md.GetString(p.Name) + " " + text, () => Print(text, ph)));
			}
			foreach (var eh in t.GetEvents()) {
				var e = md.GetEventDefinition(eh);
				var text = "event " + types.Of(e.Type, typeArgs) + " " + md.GetString(e.Name);
				members.Add(("4 " + md.GetString(e.Name) + " " + text, () => Print(text, eh)));
			}
			foreach (var (_, print) in members.OrderBy(x => x.key, StringComparer.Ordinal)) print();
			return true;
		}
		return false;
	}

	// An attribute row as `[Assembly]Namespace.Type(args)`: its constructor's type, and its fixed and named
	// arguments.
	static string AttributeText(MetadataReader md, TypeNames types, CustomAttribute ca) {
		var type = ca.Constructor.Kind switch {
			HandleKind.MemberReference => types.Of(md.GetMemberReference((MemberReferenceHandle)ca.Constructor).Parent, default),
			HandleKind.MethodDefinition => TypeName(md, md.GetMethodDefinition((MethodDefinitionHandle)ca.Constructor).GetDeclaringType()),
			_ => "?",
		};
		string args;
		try {
			var v = ca.DecodeValue(new AttributeTypes(types));
			args = string.Join(", ", v.FixedArguments.Select(a => AttributeValue(a.Type, a.Value))
				.Concat(v.NamedArguments.Select(a => a.Name + " = " + AttributeValue(a.Type, a.Value))));
		} catch (Exception e) {
			args = "undecodable " + e.GetType().Name;
		}
		return type + "(" + args + ")";
	}

	static string AttributeValue(string type, object? value) => value switch {
		null => type + " null",
		string s => type + " \"" + s + "\"",
		bool b => type + (b ? " true" : " false"),
		ImmutableArray<CustomAttributeTypedArgument<string>> a => type + " [" + string.Join(", ", a.Select(x => x.Value?.ToString() ?? "null")) + "]",
		_ => type + " " + Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture),
	};

	// Attribute argument types as ILDasm names them; an enum's underlying type is taken as int32.
	sealed class AttributeTypes(TypeNames types) : ICustomAttributeTypeProvider<string> {
		public string GetPrimitiveType(PrimitiveTypeCode code) => types.GetPrimitiveType(code);
		public string GetSystemType() => "type";
		public string GetSZArrayType(string elementType) => elementType + "[]";
		public string GetTypeFromDefinition(MetadataReader reader, TypeDefinitionHandle handle, byte rawTypeKind) => TypeName(reader, handle);
		public string GetTypeFromReference(MetadataReader reader, TypeReferenceHandle handle, byte rawTypeKind) =>
			types.GetTypeFromReference(reader, handle, rawTypeKind);
		public string GetTypeFromSerializedName(string name) => name;
		public PrimitiveTypeCode GetUnderlyingEnumType(string type) => PrimitiveTypeCode.Int32;
		public bool IsSystemType(string type) => type == "System.Type" || type.EndsWith("]System.Type");
	}

	static string GenericNames(MetadataReader md, GenericParameterHandleCollection ps) =>
		ps.Count == 0 ? "" : "<" + string.Join(", ", ps.Select(p => md.GetString(md.GetGenericParameter(p).Name))) + ">";

	static string Words(params (bool on, string word)[] words) {
		var sb = new StringBuilder();
		foreach (var (on, word) in words) if (on) sb.Append(word).Append(' ');
		return sb.ToString();
	}

	static string TypeWords(TypeAttributes a) {
		var visibility = (a & TypeAttributes.VisibilityMask) switch {
			TypeAttributes.Public or TypeAttributes.NestedPublic => "public",
			TypeAttributes.NotPublic or TypeAttributes.NestedPrivate => "private",
			TypeAttributes.NestedFamily => "family",
			TypeAttributes.NestedAssembly => "assembly",
			TypeAttributes.NestedFamANDAssem => "famandassem",
			_ => "famorassem",
		};
		return Words((true, visibility),
			((a & TypeAttributes.ClassSemanticsMask) == TypeAttributes.Interface, "interface"),
			((a & TypeAttributes.Abstract) != 0, "abstract"),
			((a & TypeAttributes.Sealed) != 0, "sealed"),
			((a & TypeAttributes.LayoutMask) == TypeAttributes.SequentialLayout, "sequential"),
			((a & TypeAttributes.BeforeFieldInit) != 0, "beforefieldinit"));
	}

	static string MethodWords(MethodAttributes a) {
		var access = (a & MethodAttributes.MemberAccessMask) switch {
			MethodAttributes.Public => "public",
			MethodAttributes.Private => "private",
			MethodAttributes.Family => "family",
			MethodAttributes.Assembly => "assembly",
			MethodAttributes.FamORAssem => "famorassem",
			MethodAttributes.FamANDAssem => "famandassem",
			_ => "privatescope",
		};
		return Words((true, access),
			((a & MethodAttributes.Static) != 0, "static"),
			((a & MethodAttributes.Final) != 0, "final"),
			((a & MethodAttributes.Virtual) != 0, "virtual"),
			((a & MethodAttributes.HideBySig) != 0, "hidebysig"),
			((a & MethodAttributes.VtableLayoutMask) == MethodAttributes.NewSlot, "newslot"),
			((a & MethodAttributes.Abstract) != 0, "abstract"),
			((a & MethodAttributes.SpecialName) != 0, "specialname"),
			((a & MethodAttributes.RTSpecialName) != 0, "rtspecialname"));
	}

	static string FieldWords(FieldAttributes a) {
		var access = (a & FieldAttributes.FieldAccessMask) switch {
			FieldAttributes.Public => "public",
			FieldAttributes.Private => "private",
			FieldAttributes.Family => "family",
			FieldAttributes.Assembly => "assembly",
			FieldAttributes.FamORAssem => "famorassem",
			FieldAttributes.FamANDAssem => "famandassem",
			_ => "privatescope",
		};
		return Words((true, access),
			((a & FieldAttributes.Static) != 0, "static"),
			((a & FieldAttributes.InitOnly) != 0, "initonly"),
			((a & FieldAttributes.Literal) != 0, "literal"));
	}

	// A defined type's full name: ns.Name, or Outer/Inner when nested.
	static string TypeName(MetadataReader md, TypeDefinitionHandle h) {
		var t = md.GetTypeDefinition(h);
		var name = md.GetString(t.Name);
		var outer = t.GetDeclaringType();
		if (!outer.IsNil) return TypeName(md, outer) + "/" + name;
		var ns = md.GetString(t.Namespace);
		return ns == "" ? name : ns + "." + name;
	}

	readonly record struct GenericContext(GenericParameterHandleCollection TypeParams, GenericParameterHandleCollection MethodParams);

	// Types printed ILDasm style.
	sealed class TypeNames(MetadataReader md) : ISignatureTypeProvider<string, GenericContext> {
		public string Of(EntityHandle h, GenericContext ctx) => h.Kind switch {
			HandleKind.TypeDefinition => GetTypeFromDefinition(md, (TypeDefinitionHandle)h, 0),
			HandleKind.TypeReference => GetTypeFromReference(md, (TypeReferenceHandle)h, 0),
			HandleKind.TypeSpecification => GetTypeFromSpecification(md, ctx, (TypeSpecificationHandle)h, 0),
			_ => "?" + h.Kind,
		};

		public string GetPrimitiveType(PrimitiveTypeCode code) => code switch {
			PrimitiveTypeCode.Void => "void",
			PrimitiveTypeCode.Boolean => "bool",
			PrimitiveTypeCode.Char => "char",
			PrimitiveTypeCode.SByte => "int8",
			PrimitiveTypeCode.Byte => "uint8",
			PrimitiveTypeCode.Int16 => "int16",
			PrimitiveTypeCode.UInt16 => "uint16",
			PrimitiveTypeCode.Int32 => "int32",
			PrimitiveTypeCode.UInt32 => "uint32",
			PrimitiveTypeCode.Int64 => "int64",
			PrimitiveTypeCode.UInt64 => "uint64",
			PrimitiveTypeCode.Single => "float32",
			PrimitiveTypeCode.Double => "float64",
			PrimitiveTypeCode.String => "string",
			PrimitiveTypeCode.Object => "object",
			PrimitiveTypeCode.TypedReference => "typedref",
			PrimitiveTypeCode.IntPtr => "native int",
			PrimitiveTypeCode.UIntPtr => "native uint",
			_ => code.ToString(),
		};

		public string GetTypeFromDefinition(MetadataReader reader, TypeDefinitionHandle handle, byte rawTypeKind) =>
			TypeName(reader, handle);

		public string GetTypeFromReference(MetadataReader reader, TypeReferenceHandle handle, byte rawTypeKind) {
			var r = reader.GetTypeReference(handle);
			var name = reader.GetString(r.Name);
			var ns = reader.GetString(r.Namespace);
			var full = ns == "" ? name : ns + "." + name;
			var scope = r.ResolutionScope;
			switch (scope.Kind) {
				case HandleKind.TypeReference:
					return GetTypeFromReference(reader, (TypeReferenceHandle)scope, rawTypeKind) + "/" + name;
				case HandleKind.AssemblyReference:
					return "[" + reader.GetString(reader.GetAssemblyReference((AssemblyReferenceHandle)scope).Name) + "]" + full;
				default:
					return full;
			}
		}

		public string GetTypeFromSpecification(MetadataReader reader, GenericContext ctx, TypeSpecificationHandle handle, byte rawTypeKind) =>
			reader.GetTypeSpecification(handle).DecodeSignature(this, ctx);

		public string GetGenericInstantiation(string genericType, ImmutableArray<string> typeArguments) =>
			genericType + "<" + string.Join(", ", typeArguments) + ">";

		public string GetGenericTypeParameter(GenericContext ctx, int index) => "!" + index;
		public string GetGenericMethodParameter(GenericContext ctx, int index) => "!!" + index;
		public string GetSZArrayType(string elementType) => elementType + "[]";
		public string GetArrayType(string elementType, ArrayShape shape) => elementType + "[" + new string(',', shape.Rank - 1) + "]";
		public string GetByReferenceType(string elementType) => elementType + "&";
		public string GetPointerType(string elementType) => elementType + "*";
		public string GetPinnedType(string elementType) => elementType + " pinned";
		public string GetModifiedType(string modifier, string unmodifiedType, bool isRequired) =>
			unmodifiedType + (isRequired ? " modreq(" : " modopt(") + modifier + ")";
		public string GetFunctionPointerType(MethodSignature<string> signature) =>
			"method " + signature.ReturnType + " *(" + string.Join(", ", signature.ParameterTypes) + ")";
	}
}
