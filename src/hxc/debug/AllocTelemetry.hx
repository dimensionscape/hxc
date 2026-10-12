package hxc.debug;

// HXC_DBG_TELEMETRY=<report file>: where a warm server's allocations come from, by type, by allocating
// function and by call stack. Needs a build with HXCPP_TELEMETRY and HXCPP_STACK_TRACE (hxcpp's telemetry
// records every allocation with its call stack); in any other build every call is a no-op. The report is
// rewritten after each request. The live heap says how much is KEPT (HXC_DBG_LIVEMEM); this says what is
// ALLOCATED, which is what the collector spends its time on.
//
// Building it: add .defineToken("HXCPP_TELEMETRY") to Aedifex.hx, build, keep the exe, take the line out
// and build again. That needs an hxcpp whose Options.txt check sees upper-case defines and whose library
// groups track it. An older hxcpp leaves the shared obj/ half compiled each way and fails at the link:
// clear obj/obj then. It also needs an hxcpp whose telemetry does not crash looking up the type of an Array
// whose constructor has not run yet.
@:cppFileCode('
#if defined(HXCPP_TELEMETRY) && defined(HXCPP_STACK_TRACE)
#include <hx/Telemetry.h>
#include <map>
#include <string>
#include <vector>
#include <algorithm>
#include <cstdio>
namespace {
struct HxcTally { long long count = 0; long long bytes = 0; };
std::vector<std::string> hxcNames(1, std::string("1-indexed"));
std::vector<std::vector<int> > hxcStacks;
std::map<int, HxcTally> hxcByType, hxcBySite, hxcByStack, hxcByCreator;
std::map<long long, HxcTally> hxcByCreatorType;
long long hxcCount = 0, hxcBytes = 0;
int hxcThread = -1;
int hxcRequests = 0;

void hxcTelStart() { hxcThread = __hxcpp_hxt_start_telemetry(true, true); }

void hxcTelCollect() {
	if (hxcThread < 0) return;
	__hxcpp_hxt_stash_telemetry();
	TelemetryFrame *f = __hxcpp_hxt_dump_telemetry(hxcThread);
	if (!f) return;
	hxcRequests++;
	if (f->names) for (size_t i = 0; i < f->names->size(); i++) hxcNames.push_back(f->names->at(i) ? f->names->at(i) : "?");
	if (f->stacks) {
		std::vector<int> &s = *f->stacks;
		size_t i = 0;
		while (i < s.size()) {
			int n = s[i++];
			hxcStacks.push_back(std::vector<int>(s.begin() + i, s.begin() + i + n));
			i += n;
		}
	}
	if (f->allocation_data) {
		std::vector<int> &a = *f->allocation_data;
		size_t i = 0;
		while (i < a.size()) {
			int flag = a[i];
			if (flag == 0) {
				int type = a[i + 2], size = a[i + 3], stack = a[i + 4];
				hxcCount++; hxcBytes += size;
				HxcTally &t = hxcByType[type]; t.count++; t.bytes += size;
				HxcTally &k = hxcByStack[stack]; k.count++; k.bytes += size;
				int site = (stack >= 0 && stack < (int)hxcStacks.size() && !hxcStacks[stack].empty()) ? hxcStacks[stack][0] : -1;
				HxcTally &w = hxcBySite[site]; w.count++; w.bytes += size;
				int creator = site;
				if (stack >= 0 && stack < (int)hxcStacks.size())
					for (size_t j = 0; j < hxcStacks[stack].size(); j++) {
						const std::string &nm = hxcNames[hxcStacks[stack][j]];
						if (nm.size() < 4 || nm.compare(nm.size() - 4, 4, ".new") != 0) { creator = hxcStacks[stack][j]; break; }
					}
				HxcTally &c = hxcByCreator[creator]; c.count++; c.bytes += size;
				HxcTally &ct = hxcByCreatorType[((long long)creator << 32) | (unsigned int)type]; ct.count++; ct.bytes += size;
				i += 5;
			} else if (flag == 1) i += 2;
			else if (flag == 2) i += 4;
			else break;
		}
	}
}

const char *hxcName(int i) { return (i >= 0 && i < (int)hxcNames.size()) ? hxcNames[i].c_str() : "?"; }

void hxcTelTable(FILE *o, const char *title, std::map<int, HxcTally> &m, int limit, bool stacks) {
	std::vector<std::pair<int, HxcTally> > v(m.begin(), m.end());
	std::sort(v.begin(), v.end(), [](const std::pair<int, HxcTally> &a, const std::pair<int, HxcTally> &b) { return a.second.bytes > b.second.bytes; });
	fprintf(o, "\\n== %s (top %d by bytes)\\n", title, limit);
	for (int i = 0; i < (int)v.size() && i < limit; i++) {
		fprintf(o, "%10lld KB %5.1f%% %10lld  ", v[i].second.bytes / 1024, hxcBytes ? 100.0 * v[i].second.bytes / hxcBytes : 0.0, v[i].second.count);
		if (!stacks) fprintf(o, "%s\\n", hxcName(v[i].first));
		else {
			int id = v[i].first;
			fprintf(o, "\\n");
			if (id >= 0 && id < (int)hxcStacks.size())
				for (size_t j = 0; j < hxcStacks[id].size() && j < 12; j++) fprintf(o, "              %s\\n", hxcName(hxcStacks[id][j]));
		}
	}
}

void hxcTelReport(const char *path) {
	FILE *o = fopen(path, "w");
	if (!o) return;
	fprintf(o, "%d requests, %lld allocations, %lld KB allocated (%lld KB per request)\\n", hxcRequests, hxcCount, hxcBytes / 1024,
		hxcRequests ? hxcBytes / 1024 / hxcRequests : 0);
	hxcTelTable(o, "by type", hxcByType, 60, false);
	hxcTelTable(o, "by allocating function", hxcBySite, 80, false);
	hxcTelTable(o, "by creating function (constructor frames skipped)", hxcByCreator, 80, false);
	// Count allocations inclusively for every function on the stack. Recursive occurrences of a
	// function count once.
	std::map<int, HxcTally> inclusive;
	for (std::map<int, HxcTally>::iterator it = hxcByStack.begin(); it != hxcByStack.end(); ++it) {
		if (it->first < 0 || it->first >= (int)hxcStacks.size()) continue;
		std::vector<int> &frames = hxcStacks[it->first];
		std::vector<int> seen;
		for (size_t j = 0; j < frames.size(); j++) {
			if (std::find(seen.begin(), seen.end(), frames[j]) != seen.end()) continue;
			seen.push_back(frames[j]);
			HxcTally &t = inclusive[frames[j]]; t.count += it->second.count; t.bytes += it->second.bytes;
		}
	}
	hxcTelTable(o, "inclusive, by function on the stack", inclusive, 150, false);
	{
		std::vector<std::pair<long long, HxcTally> > v(hxcByCreatorType.begin(), hxcByCreatorType.end());
		std::sort(v.begin(), v.end(), [](const std::pair<long long, HxcTally> &a, const std::pair<long long, HxcTally> &b) { return a.second.bytes > b.second.bytes; });
		fprintf(o, "\\n== by creating function and type (top 120 by bytes)\\n");
		for (int i = 0; i < (int)v.size() && i < 120; i++)
			fprintf(o, "%10lld KB %5.1f%% %10lld  %s  <-  %s\\n", v[i].second.bytes / 1024, hxcBytes ? 100.0 * v[i].second.bytes / hxcBytes : 0.0,
				v[i].second.count, hxcName((int)(v[i].first & 0xffffffff)), hxcName((int)(v[i].first >> 32)));
	}
	hxcTelTable(o, "by call stack", hxcByStack, 40, true);
	fclose(o);
}
}
#else
namespace {
void hxcTelStart() {}
void hxcTelCollect() {}
void hxcTelReport(const char *) {}
}
#endif
')
class AllocTelemetry {
	static var reportFile:Null<String> = Sys.getEnv("HXC_DBG_TELEMETRY");
	static var started = false;

	public static function afterRequest():Void {
		if (reportFile == null) return;
		if (!started) {
			// The first request only starts the recording: what it allocates is the warm-up
			started = true;
			untyped __cpp__("hxcTelStart()");
			return;
		}
		untyped __cpp__("hxcTelCollect()");
		var path = reportFile;
		untyped __cpp__("hxcTelReport({0}.utf8_str())", path);
	}
}
