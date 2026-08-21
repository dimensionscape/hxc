package hxc.context;

import hxc.ast.Position;
import hxc.core.Json;

// Completion entry with a scored filter name and JSON writer; the writer may receive no list index.
typedef CompletionEntry = {
	var filterName:String;
	// Raise-site filtering information for a collected item.
	@:optional var info:hxc.typing.Typer.JsonItemInfo;
	var toJson:(gen:hxc.core.Genjson, index:Null<Int>) -> JsonValue;
}

class DisplayException {
	// Indexed by display/completionItem/resolve.
	public static var lastCompletionResult:Array<CompletionEntry> = [];
	// Reuse a truncated answer when the next request has the same subject start.
	public static var lastCompletionPos:Null<Position> = null;
	public static var maxCompletionItems:Int = 0;

	// Lowercase ASCII identifier characters only.
	static function lower(s:String):String {
		var b = new StringBuf();
		for (i in 0...s.length) {
			var c = s.charCodeAt(i);
			b.addChar(c >= "A".code && c <= "Z".code ? c + 32 : c);
		}
		return b.toString();
	}

	static function filterSomehow(gen:hxc.core.Genjson, items:Array<CompletionEntry>, subjectName:Null<String>):Array<JsonValue> {
		var subject = subjectName == null ? "" : lower(subjectName);
		var subjectLength = subject.length;
		function determineCost(s:String):Int {
			// A subject prefix is a perfect match; otherwise charge twice the distance from the closest
			// preceding dot.
			function getInitialCost(o:Int):Int {
				if (o == 0) return 0;
				var lastAnchor = s.lastIndexOf(".", o);
				return lastAnchor < 0 ? o * 2 : (o - (lastAnchor + 1)) * 2;
			}
			if (subjectLength == 0) return 0;
			var o = s.indexOf(subject.charAt(0));
			if (o < 0) return -1;
			var cost = getInitialCost(o);
			// Search each character from the previous match inclusively. Gaps cost 3; exhaustion rejects the
			// candidate.
			for (i in 1...subjectLength) {
				var c = subject.charCodeAt(i);
				var newCost = 0;
				while (true) {
					if (o >= s.length) return -1;
					if (s.charCodeAt(o) == c) break;
					o++;
					newCost += 3;
				}
				cost += newCost;
			}
			return cost + (o == s.length - 1 ? 0 : 1);
		}
		// Prepending reverses items. Empty subjects restore input order; nonempty subjects sort by cost
		// with reversed order for ties.
		var acc:Array<{e:CompletionEntry, index:Int, cost:Int}> = [];
		for (index in 0...items.length) {
			var cost = determineCost(lower(items[index].filterName));
			if (cost >= 0) acc.push({e: items[index], index: index, cost: cost});
		}
		acc.reverse();
		if (subjectLength == 0) acc.reverse()
		else {
			var order = [for (i in 0...acc.length) i];
			order.sort(function(a, b) return acc[a].cost != acc[b].cost ? acc[a].cost - acc[b].cost : a - b);
			acc = [for (i in order) acc[i]];
		}
		var ret:Array<JsonValue> = [];
		for (x in acc) {
			if (ret.length >= maxCompletionItems) break;
			ret.push(x.e.toJson(gen, x.index));
		}
		return ret;
	}

	// Generate fields for the subject prefix at the cursor; startPos retains its uncut start.
	public static function fieldsToJson(gen:hxc.core.Genjson, items:Array<CompletionEntry>, mode:JsonValue,
			subjectName:Null<String>, insertPos:Null<Position>, startPos:Null<Position>):JsonValue {
		lastCompletionResult = items;
		var needsFiltering = maxCompletionItems > 0 && items.length > maxCompletionItems;
		var ja = needsFiltering ? filterSomehow(gen, items, subjectName) : [for (i in 0...items.length) items[i].toJson(gen, i)];
		var numItems = needsFiltering ? ja.length : items.length;
		var didFilter = numItems == maxCompletionItems;
		lastCompletionPos = didFilter ? (startPos != null ? startPos : insertPos) : null;
		return JObject([
			{name: "items", value: JArray(ja)},
			{name: "isIncomplete", value: JBool(didFilter)},
			{name: "mode", value: mode},
			{name: "filterString", value: JString(subjectName == null ? "" : subjectName)},
			{name: "replaceRange", value: insertPos == null
				? JObject([
					{name: "start", value: JObject([{name: "line", value: JInt(0)}, {name: "character", value: JInt(0)}])},
					{name: "end", value: JObject([{name: "line", value: JInt(0)}, {name: "character", value: JInt(0)}])}
				])
				: gen.generatePosAsRange(insertPos)}
		]);
	}
}
