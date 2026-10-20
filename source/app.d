/**
 * antora-source-resolver — resolve Antora content remotes to local paths.
 *
 * Usage: antora-source-resolver resolve <request.json> <response.json>
 */
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.datetime.systime;
import std.digest.sha;
import std.exception;
import std.file;
import std.format;
import std.json;
import std.parallelism;
import std.path;
import std.process;
import std.range;
import std.regex;
import std.stdio;
import std.string;

version (Windows) {
import mft_search;
MftVolume[string] g_mftVolumeCache;
}

enum MARKER_NAMESPACE = "antora-supplemental:local-content-sources:v1";
enum MARKER_LEGACY = ".antora-source-id";
enum DEFAULT_MAX_UPWARD_HOPS = 16;

string normalizeGitRemoteUrl(string url) {
    url = url.strip();
    if (url.length == 0) return url;
    url = url.replace("\\", "/");
    while (url.endsWith("/")) url = url[0 .. $ - 1];
    if (url.toLower.endsWith(".git")) url = url[0 .. $ - 4];
    if (auto m = matchFirst(url, r"^git@github\.com:([^/]+)/(.+)$")) {
        url = format!"https://github.com/%s/%s"(m[1], m[2]);
    }
    return url.toLower;
}

string markerIdForRemote(string remoteUrl) {
    auto key = normalizeGitRemoteUrl(remoteUrl);
    ubyte[] buf;
    buf ~= cast(ubyte[]) MARKER_NAMESPACE;
    buf ~= cast(ubyte) 0;
    buf ~= cast(ubyte[]) key;
    auto digest = sha256Of(buf);
    return format!"%(%02x%)"(digest[0 .. 16]);
}

struct ParsedMarker {
    string id;
    string url;
}

ParsedMarker parseMarkerFile(string text) {
    ParsedMarker pm;
    foreach (raw; text.replace("\r", "").split("\n")) {
        auto line = raw.strip;
        if (!line.length || line == MARKER_NAMESPACE) continue;
        if (auto m = matchFirst(line, r"^id:\s*([0-9a-f]{32})\s*$")) {
            pm.id = m[1].toLower;
            continue;
        }
        if (auto m = matchFirst(line, r"^url:\s*(.+)\s*$")) {
            pm.url = normalizeGitRemoteUrl(m[1]);
            continue;
        }
        if (!pm.url.length && (line.startsWith("http") || line.startsWith("git@")))
            pm.url = normalizeGitRemoteUrl(line);
    }
    return pm;
}

bool isGitCheckout(string dir) {
    return exists(buildPath(dir, ".git"));
}

bool shouldSkipDir(string name) {
    return name == ".git" || name == "node_modules" || name == "build"
        || name == "$RECYCLE.BIN" || name == "System Volume Information"
        || name == "AppData" || name == "Application Data"
        || name == "Program Files" || name == "Program Files (x86)"
        || name == "Windows" || name == ".npm" || name == ".pnpm"
        || name == ".cursor" || name == "Cache" || name == "Caches";
}

void walkCollectMarkerFiles(string dir, int depth, string excludeSubdir, ref string[] outPaths) {
    if (depth < 0) return;
    if (!exists(dir)) return;
    foreach (entry; dirEntries(dir, SpanMode.shallow)) {
        auto full = buildPath(dir, entry.name);
        if (!entry.isDir) {
            if (entry.name == MARKER_LEGACY) outPaths ~= full;
            continue;
        }
        if (shouldSkipDir(entry.name)) continue;
        if (excludeSubdir.length && absolutePath(full) == absolutePath(excludeSubdir)) continue;
        walkCollectMarkerFiles(full, depth - 1, null, outPaths);
    }
}

string[] uniqueRoots(string[] markerPaths) {
    string[] roots;
    bool[string] seen;
    foreach (p; markerPaths) {
        auto root = absolutePath(dirName(p));
        if (root in seen) continue;
        seen[root] = true;
        roots ~= root;
    }
    return roots;
}

string[] searchUpwardFrom(string startDir, int maxDepth, int maxUpwardHops) {
    string[] ordered;
    bool[string] seen;
    string dir = absolutePath(startDir);
    string excludeChild;
    for (int hop = 0; hop <= maxUpwardHops; hop++) {
        string[] hits;
        walkCollectMarkerFiles(dir, maxDepth, excludeChild, hits);
        foreach (h; hits) {
            auto key = absolutePath(h);
            if (key in seen) continue;
            seen[key] = true;
            ordered ~= h;
        }
        if (hop == maxUpwardHops) break;
        excludeChild = dir;
        auto parent = dirName(dir);
        if (parent == dir) break;
        dir = parent;
    }
    return ordered;
}

string driveRootForPath(string startDir) {
    version (Windows) {
        auto resolved = absolutePath(startDir);
        auto m = matchFirst(resolved, r"^([A-Za-z]:)[\\/]");
        if (m) return m[1] ~ dirSeparator;
        return null;
    } else {
        return dirName(absolutePath(startDir)) == absolutePath(startDir) ? "/" : null;
    }
}

string[] listOtherDriveRoots(string startDir) {
    string[] roots;
    version (Windows) {
        auto startDrive = driveRootForPath(startDir);
        foreach (c; 'A' .. 'Z' + 1) {
            auto root = format!"%s:\\"(c);
            if (startDrive.length && root.toLower == startDrive.toLower) continue;
            if (exists(root)) roots ~= root;
        }
    } else {
        foreach (mountRoot; ["/Volumes", "/mnt"]) {
            if (!exists(mountRoot)) continue;
            foreach (entry; dirEntries(mountRoot, SpanMode.shallow)) {
                if (entry.isDir) roots ~= buildPath(mountRoot, entry.name);
            }
        }
    }
    return roots;
}

string[] searchDriveRoot(string driveRoot, int maxDepth) {
    string[] hits;
    walkCollectMarkerFiles(driveRoot, maxDepth, null, hits);
    return hits;
}

bool useMftSearch(string searchMethod) {
    version (Windows) {
        if (searchMethod == "walk") return false;
        return true;
    }
    return false;
}

string[] searchDriveMft(string driveRoot) {
    version (Windows) {
        if (driveRoot.length < 2) return null;
        auto key = driveRoot[0 .. 2].toUpper;
        if (key !in g_mftVolumeCache) {
            MftVolume vol;
            if (!openVolume(vol, driveRoot)) return null;
            g_mftVolumeCache[key] = vol;
        }
        return findExactFilePathsInVolume(g_mftVolumeCache[key], [MARKER_LEGACY]);
    }
    return null;
}

string[] drivesToScan(string startDir, bool searchOtherDrives) {
    string[] drives;
    auto home = driveRootForPath(startDir);
    if (home.length) drives ~= home;
    if (searchOtherDrives) {
        foreach (d; listOtherDriveRoots(startDir)) {
            bool dup;
            foreach (h; drives) {
                if (absolutePath(h) == absolutePath(d)) dup = true;
            }
            if (!dup) drives ~= d;
        }
    }
    return drives;
}

string[] filterCloneRoots(string[] markerFiles, string normalizedRemote, string markerId) {
    string[] ordered;
    bool[string] seen;
    foreach (fp; markerFiles) {
        auto root = absolutePath(dirName(fp));
        if (root in seen) continue;
        if (!markerContentMatchesRemote(root, normalizedRemote, markerId)) continue;
        seen[root] = true;
        ordered ~= root;
    }
    return ordered;
}

string[] collectMarkerCloneRoots(string startDir, string normalizedRemote, string markerId, int maxDepth, int maxUpwardHops, string[] extraRoots, bool searchOtherDrives, string searchMethod) {
    string[] filePaths;
    bool[string] seen;
    void pushPaths(string[] paths) {
        foreach (fp; paths) {
            auto key = absolutePath(fp);
            if (key in seen) continue;
            seen[key] = true;
            filePaths ~= fp;
        }
    }
    pushPaths(searchUpwardFrom(startDir, maxDepth, maxUpwardHops));
    foreach (root; extraRoots) {
        if (!root.length || !exists(root)) continue;
        string[] hits;
        walkCollectMarkerFiles(absolutePath(root), maxDepth, null, hits);
        pushPaths(hits);
    }
    auto drives = drivesToScan(startDir, searchOtherDrives);
    if (useMftSearch(searchMethod)) {
        version (Windows) {
            foreach (d; parallel(drives)) {
                auto mftFiles = searchDriveMft(d);
                if (mftFiles !is null) pushPaths(mftFiles);
                else pushPaths(searchDriveRoot(d, maxDepth));
            }
        }
    } else {
        foreach (d; parallel(drives)) {
            pushPaths(searchDriveRoot(d, maxDepth));
        }
    }
    return filterCloneRoots(filePaths, normalizedRemote, markerId);
}

bool markerContentMatchesRemote(string repoRoot, string normalizedRemote, string markerId) {
    auto primary = buildPath(repoRoot, MARKER_LEGACY);
    if (exists(primary)) {
        try {
            auto pm = parseMarkerFile(readText(primary));
            if (pm.url == normalizedRemote) return true;
            if (pm.id.length && pm.id == markerId) return true;
        } catch (Exception e) { }
    }
    auto depPath = buildPath(repoRoot, format!".antora-src-%s"(markerId));
    if (exists(depPath)) {
        try {
            auto pm = parseMarkerFile(readText(depPath));
            if (pm.url == normalizedRemote) return true;
        } catch (Exception e) {
            return true;
        }
    }
    return false;
}

bool rootHasMarker(string root, string markerId, string normalizedRemote) {
    return markerContentMatchesRemote(root, normalizedRemote, markerId) && isGitCheckout(root);
}

string pickOverride(JSONValue[string] overrides, string normalizedRemote, string markerId) {
    if (normalizedRemote in overrides) return overrides[normalizedRemote].str;
    if (markerId in overrides) return overrides[markerId].str;
    auto dep = format!".antora-src-%s"(markerId);
    if (dep in overrides) return overrides[dep].str;
    return null;
}

struct Choice {
    string localRoot;
    string method;
    bool overrideUsed;
}

Choice chooseLocalRoot(string[] matches, string overridePath, string markerId, string normalizedRemote) {
    if (overridePath.length) {
        auto resolved = absolutePath(overridePath);
        if (rootHasMarker(resolved, markerId, normalizedRemote)) {
            bool inList = matches.any!(m => absolutePath(m) == resolved);
            return Choice(resolved, inList ? "override" : "override-forced", true);
        }
    }
    if (matches.length)
        return Choice(matches[0], matches.length > 1 ? "first-match" : "marker-search", false);
    return Choice(null, "none", false);
}

void main(string[] args) {
    version (Windows) {
        scope (exit) {
            foreach (ref v; g_mftVolumeCache.byValue) closeVolume(v);
            g_mftVolumeCache = null;
        }
    }
    if (args.length < 4 || args[1] != "resolve") {
        stderr.writeln("usage: antora-source-resolver resolve <request.json> <response.json>");
        return;
    }
    auto req = parseJSON(readText(args[2]));
    auto sources = req["sources"];
    string[] searchRoots;
    foreach (v; req["searchRoots"].array) searchRoots ~= v.str;
    string startDir = ("startDir" in req) ? req["startDir"].str : getcwd();
    int maxDepth = ("maxDepth" in req) ? cast(int) req["maxDepth"].integer : 10;
    int maxUpwardHops = ("maxUpwardHops" in req) ? cast(int) req["maxUpwardHops"].integer : DEFAULT_MAX_UPWARD_HOPS;
    bool searchOtherDrives = !("searchOtherDrives" in req) || req["searchOtherDrives"].type != JSONType.false_;
    string searchMethod = ("searchMethod" in req) ? req["searchMethod"].str.toLower : "auto";

    JSONValue[string] overrides;
    if ("overrides" in req && req["overrides"].type == JSONType.object)
        overrides = req["overrides"].object;

    JSONValue[string] cacheEntries;
    if ("cachePath" in req && exists(req["cachePath"].str)) {
        try {
            auto cache = parseJSON(readText(req["cachePath"].str));
            if ("entries" in cache) cacheEntries = cache["entries"].object;
        } catch (Exception e) { }
    }

    string[string] byRemote;
    JSONValue[] report;

    foreach (src; sources.array) {
        auto url = src["url"].str;
        if (!url.startsWith("http") && !url.startsWith("git@")) continue;
        auto normalized = normalizeGitRemoteUrl(url);
        if (normalized in byRemote) continue;
        auto markerId = markerIdForRemote(url);

        string[] matches;
        string localRoot;
        string method = "none";
        bool overrideUsed;

        if (markerId in cacheEntries && "path" in cacheEntries[markerId]) {
            localRoot = cacheEntries[markerId]["path"].str;
            if (localRoot.length && rootHasMarker(localRoot, markerId, normalized)) {
                method = "cache";
                matches = [localRoot];
            } else localRoot = null;
        }

        if (localRoot is null) {
            matches = collectMarkerCloneRoots(startDir, normalized, markerId, maxDepth, maxUpwardHops, searchRoots, searchOtherDrives, searchMethod);
            auto overridePath = pickOverride(overrides, normalized, markerId);
            auto choice = chooseLocalRoot(matches, overridePath, markerId, normalized);
            localRoot = choice.localRoot;
            method = choice.method;
            if (method == "marker-search" && useMftSearch(searchMethod)) method = "mft-search";
            else if (method == "first-match" && useMftSearch(searchMethod)) method = "mft-first-match";
            overrideUsed = choice.overrideUsed;
        }

        bool conflict = matches.length > 1 && !overrideUsed;
        if (conflict) {
            stderr.writeln(format!"multiple local clones for %s (id %s):"(normalized, markerId));
            foreach (m; matches) stderr.writeln(format!"  - %s"(m));
            stderr.writeln(format!"using %s (%s). Pin one path in .antora-local-sources.yml"(localRoot, method));
        }

        JSONValue[] matchJson;
        foreach (m; matches) matchJson ~= JSONValue(absolutePath(m));

        if (localRoot !is null) {
            byRemote[normalized] = localRoot;
            cacheEntries[markerId] = JSONValue([
                "path": JSONValue(localRoot),
                "updatedAt": JSONValue(Clock.currTime.toISOString()),
            ]);
        }

        report ~= JSONValue([
            "remote": JSONValue(normalized),
            "markerId": JSONValue(markerId),
            "markerFile": JSONValue(MARKER_LEGACY),
            "localRoot": JSONValue(localRoot is null ? JSONValue(null) : JSONValue(localRoot)),
            "method": JSONValue(method),
            "matches": JSONValue(matchJson),
            "conflict": JSONValue(conflict),
            "overrideUsed": JSONValue(overrideUsed),
        ]);
    }

    JSONValue[] resolved;
    foreach (src; sources.array) {
        auto copy = src;
        auto url = src["url"].str;
        if (url.startsWith("http") || url.startsWith("git@")) {
            auto normalized = normalizeGitRemoteUrl(url);
            if (normalized in byRemote) {
                copy["url"] = JSONValue(byRemote[normalized]);
                copy["worktrees"] = JSONValue(true);
            }
        }
        resolved ~= copy;
    }

    auto responseDoc = JSONValue([
        "resolved": JSONValue(resolved),
        "cache": JSONValue(["version": JSONValue(2), "entries": JSONValue(cacheEntries)]),
        "report": JSONValue(report),
    ]);
    std.file.write(args[3], cast(const(ubyte)[]) responseDoc.toPrettyString());
}
