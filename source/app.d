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
import std.regex;
import std.stdio;
import std.string;

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

string markerBasenameForRemote(string remoteUrl) {
    auto key = normalizeGitRemoteUrl(remoteUrl);
    ubyte[] buf;
    buf ~= cast(ubyte[]) MARKER_NAMESPACE;
    buf ~= cast(ubyte) 0;
    buf ~= cast(ubyte[]) key;
    auto digest = sha256Of(buf);
    return format!".antora-src-%(%02x%)"(digest[0 .. 16]);
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

void walkCollectMarkerFiles(string dir, string markerBasename, int depth, string excludeSubdir, ref string[] outPaths) {
    if (depth < 0) return;
    if (!exists(dir)) return;
    foreach (entry; dirEntries(dir, SpanMode.shallow)) {
        auto full = buildPath(dir, entry.name);
        if (!entry.isDir) {
            if (entry.name == markerBasename || entry.name == MARKER_LEGACY)
                outPaths ~= full;
            continue;
        }
        if (shouldSkipDir(entry.name)) continue;
        if (excludeSubdir.length && absolutePath(full) == absolutePath(excludeSubdir)) continue;
        walkCollectMarkerFiles(full, markerBasename, depth - 1, null, outPaths);
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

string[] searchUpwardFrom(string startDir, string markerBasename, int maxDepth, int maxUpwardHops) {
    string[] ordered;
    bool[string] seen;
    string dir = absolutePath(startDir);
    string excludeChild;
    for (int hop = 0; hop <= maxUpwardHops; hop++) {
        string[] hits;
        walkCollectMarkerFiles(dir, markerBasename, maxDepth, excludeChild, hits);
        foreach (h; hits) {
            auto root = absolutePath(dirName(h));
            if (root in seen) continue;
            seen[root] = true;
            ordered ~= root;
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

string[] searchDriveRoot(string driveRoot, string markerBasename, int maxDepth) {
    string[] hits;
    walkCollectMarkerFiles(driveRoot, markerBasename, maxDepth, null, hits);
    return uniqueRoots(hits);
}

string[] collectMarkerCloneRoots(string startDir, string markerBasename, int maxDepth, int maxUpwardHops, string[] extraRoots, bool searchOtherDrives) {
    string[] ordered;
    bool[string] seen;
    void push(string[] roots) {
        foreach (r; roots) {
            auto key = absolutePath(r);
            if (key in seen) continue;
            seen[key] = true;
            ordered ~= r;
        }
    }
    push(searchUpwardFrom(startDir, markerBasename, maxDepth, maxUpwardHops));
    foreach (root; extraRoots) {
        if (!root.length || !exists(root)) continue;
        string[] hits;
        walkCollectMarkerFiles(absolutePath(root), markerBasename, maxDepth, null, hits);
        push(uniqueRoots(hits));
    }
    if (searchOtherDrives) {
        auto drives = listOtherDriveRoots(startDir);
        foreach (d; parallel(drives)) {
            push(searchDriveRoot(d, markerBasename, maxDepth));
        }
    }
    return ordered;
}

bool markerContentMatches(string repoRoot, string normalizedRemote) {
    auto legacy = buildPath(repoRoot, MARKER_LEGACY);
    if (!exists(legacy)) return false;
    try {
        auto text = readText(legacy).strip;
        auto nl = text.indexOf("\n");
        if (nl < 0) nl = text.indexOf("\r");
        auto body = nl >= 0 ? text[0 .. nl].strip : text;
        return normalizeGitRemoteUrl(body) == normalizedRemote;
    } catch (Exception e) {
        return false;
    }
}

bool rootHasMarker(string root, string markerBasename, string normalizedRemote) {
    if (exists(buildPath(root, markerBasename))) return true;
    return markerContentMatches(root, normalizedRemote);
}

string pickOverride(JSONValue[string] overrides, string normalizedRemote, string markerBasename) {
    if (normalizedRemote in overrides) return overrides[normalizedRemote].str;
    if (markerBasename in overrides) return overrides[markerBasename].str;
    return null;
}

struct Choice {
    string localRoot;
    string method;
    bool overrideUsed;
}

Choice chooseLocalRoot(string[] matches, string overridePath, string markerBasename, string normalizedRemote) {
    if (overridePath.length) {
        auto resolved = absolutePath(overridePath);
        if (rootHasMarker(resolved, markerBasename, normalizedRemote) && isGitCheckout(resolved)) {
            bool inList = matches.any!(m => absolutePath(m) == resolved);
            return Choice(resolved, inList ? "override" : "override-forced", true);
        }
    }
    if (matches.length)
        return Choice(matches[0], matches.length > 1 ? "first-match" : "marker-search", false);
    return Choice(null, "none", false);
}

void main(string[] args) {
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
        auto marker = markerBasenameForRemote(url);

        string[] matches;
        string localRoot;
        string method = "none";
        bool overrideUsed;

        if (marker in cacheEntries && "path" in cacheEntries[marker]) {
            localRoot = cacheEntries[marker]["path"].str;
            if (localRoot.length && isGitCheckout(localRoot) && rootHasMarker(localRoot, marker, normalized)) {
                method = "cache";
                matches = [localRoot];
            } else localRoot = null;
        }

        if (localRoot is null) {
            matches = collectMarkerCloneRoots(startDir, marker, maxDepth, maxUpwardHops, searchRoots, searchOtherDrives);
            auto overridePath = pickOverride(overrides, normalized, marker);
            auto choice = chooseLocalRoot(matches, overridePath, marker, normalized);
            localRoot = choice.localRoot;
            method = choice.method;
            overrideUsed = choice.overrideUsed;
        }

        bool conflict = matches.length > 1 && !overrideUsed;
        if (conflict) {
            stderr.writeln(format!"multiple local clones for %s (%s):"(normalized, marker));
            foreach (m; matches) stderr.writeln(format!"  - %s"(m));
            stderr.writeln(format!"using %s (%s). Pin one path in .antora-local-sources.yml"(localRoot, method));
        }

        JSONValue[] matchJson;
        foreach (m; matches) matchJson ~= JSONValue(absolutePath(m));

        if (localRoot !is null) {
            byRemote[normalized] = localRoot;
            cacheEntries[marker] = JSONValue([
                "path": JSONValue(localRoot),
                "updatedAt": JSONValue(Clock.currTime.toISOString()),
            ]);
        }

        report ~= JSONValue([
            "remote": JSONValue(normalized),
            "marker": JSONValue(marker),
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
        "cache": JSONValue(["version": JSONValue(1), "entries": JSONValue(cacheEntries)]),
        "report": JSONValue(report),
    ]);
    std.file.write(args[3], cast(const(ubyte)[]) responseDoc.toPrettyString());
}
