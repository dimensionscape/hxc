package hxc.parser;

// Type version (a single dotted component)
enum Version {
	SVNum(n:Int);
	SVStr(s:String); // `alpha`, `pre`, `rc`, etc.
}

// Major, minor, patch
typedef Release = {major:Version, minor:Version, patch:Version};

typedef SemVer = {release:Release, pre:Null<Array<Version>>};

class Semver {
	public static function sVersion(v:Version):String {
		return switch v {
			case SVNum(n): "SVNum " + n;
			case SVStr(s): "SVStr " + s;
		}
	}

	static function str(v:Version):String {
		return switch v {
			case SVNum(n): Std.string(n);
			case SVStr(s): s;
		}
	}

	public static function toString(v:SemVer):String {
		var r = v.release;
		var base = [str(r.major), str(r.minor), str(r.patch)].join(".");
		return base + (v.pre == null ? "" : "-" + [for (p in v.pre) str(p)].join("."));
	}

	// Parse: each dotted part is SVNum if it is an int literal, else SVStr.
	static function parsePart(s:String):Version {
		return isIntLiteral(s) ? SVNum(Std.parseInt(s)) : SVStr(s);
	}

	// Strict: the whole string is a decimal integer
	static function isIntLiteral(s:String):Bool {
		if (s.length == 0)
			return false;
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			if (c < "0".code || c > "9".code)
				return false;
		}
		return true;
	}

	static function parse(dotted:String):Array<Version> {
		return [for (p in dotted.split(".")) parsePart(p)];
	}

	public static function parseVersion(s:String):SemVer {
		function error():Dynamic
			throw new haxe.Exception('Invalid version string "$s". Should follow SemVer.');

		function parseRelease(dotted:String):Release {
			var parts = parse(dotted);
			if (parts.length == 3)
				switch [parts[0], parts[1], parts[2]] {
					case [SVNum(_), SVNum(_), SVNum(_)]:
						return {major: parts[0], minor: parts[1], patch: parts[2]};
					case _:
				}
			return error();
		}

		var index = s.indexOf("-");
		if (index < 0)
			return {release: parseRelease(s), pre: null};
		if (index + 1 == s.length)
			return error();
		var release = parseRelease(s.substr(0, index));
		var preStr = s.substr(index + 1);
		var plus = preStr.indexOf("+"); // Remove build meta
		if (plus >= 0)
			preStr = preStr.substr(0, plus);
		return {release: release, pre: parse(preStr)};
	}

	static function compareV(v1:Version, v2:Version):Int {
		return switch [v1, v2] {
			case [SVNum(n1), SVNum(n2)]: n1 < n2 ? -1 : (n1 > n2 ? 1 : 0);
			case [SVStr(s1), SVStr(s2)]: s1 < s2 ? -1 : (s1 > s2 ? 1 : 0);
			case [SVStr(_), SVNum(_)]: 1;
			case [SVNum(_), SVStr(_)]: -1;
		}
	}

	static function compareLists(l1:Array<Version>, l2:Array<Version>):Int {
		var i = 0;
		while (true) {
			var e1 = i >= l1.length;
			var e2 = i >= l2.length;
			if (e1 && e2)
				return 0;
			if (e1)
				return -1;
			if (e2)
				return 1;
			var diff = compareV(l1[i], l2[i]);
			if (diff != 0)
				return diff;
			i++;
		}
	}

	// Compare_version (https://semver.org/#spec-item-11)
	public static function compareVersion(a:SemVer, b:SemVer):Int {
		var diff = compareLists([a.release.major, a.release.minor, a.release.patch],
			[b.release.major, b.release.minor, b.release.patch]);
		if (diff != 0)
			return diff;
		return switch [a.pre, b.pre] {
			case [null, null]: 0;
			case [null, _]: 1;
			case [_, null]: -1;
			case [p1, p2]: compareLists(p1, p2);
		}
	}
}
