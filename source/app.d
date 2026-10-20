/**
 * antora-source-resolver — resolve Antora content remotes to local paths.
 *
 * Usage: antora-source-resolver resolve <request.json> <response.json>
 *
 * Request JSON: { sources, searchRoots, cachePath, maxDepth }
 * Response JSON: { resolved, cache, report } (same contract as the Node resolver)
 */
module;

import std.datetime.systime;
import std.digest.sha;
import std.exception;
import std.file;
import std.format;
import std.json;
import std.path;
import std.regex;
import std.stdio;
import std.string;

enum MARKER_NAMESPACE = "antora-supplemental:local-content-sources:v1";
enum MARKER_LEGACY = ".antora-source-id";

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

string walkForFile(string dir, string basename, int depth) {
    if (depth < 0) return null;
    if (!exists(dir)) return null;
    foreach (entry; dirEntries(dir, SpanMode.shallow)) {
        if (!entry.isDir && (entry.name == basename || entry.name == MARKER_LEGACY)) {
            return entry.path;
        }
    }
    foreach (entry; dirEntries(dir, SpanMode.shallow)) {
        if (!entry.isDir) continue;
        if (entry.name == ".git" || entry.name == "node_modules" || entry.name == "build") continue;
        auto hit = walkForFile(entry.path, basename, depth - 1);
        if (hit !is null) return hit;
    }
    return null;
}

string findMarkerRoot(string[] roots, string markerBasename, int maxDepth) {
    foreach (root; roots) {
        if (root.length == 0) continue;
        auto abs = absolutePath(root);
        if (!exists(abs)) continue;
        auto hit = walkForFile(abs, markerBasename, maxDepth);
        if (hit !is null) return dirName(hit);
    }
    return null;
}

void main(string[] args) {
    if (args.length < 4 || args[1] != "resolve") {
        stderr.writeln("usage: antora-source-resolver resolve <request.json> <response.json>");
        return;
    }
    auto reqText = readText(args[2]);
    auto req = parseJSON(reqText);
    auto sources = req["sources"];
    auto searchRoots = req["searchRoots"].deserializeJson!(string[]);
    int maxDepth = ("maxDepth" in req) ? req["maxDepth"].integer : 10;

    JSONValue[string] cacheEntries;
    if ("cachePath" in req && exists(req["cachePath"].str)) {
        try {
            auto cache = parseJSON(readText(req["cachePath"].str));
            if ("entries" in cache) cacheEntries = cache["entries"].object;
        } catch (Exception e) { /* fresh cache */ }
    }

    string[string] byRemote;
    JSONValue[] report;

    foreach (src; sources.array) {
        auto url = src["url"].str;
        if (!url.startsWith("http") && !url.startsWith("git@")) continue;
        auto normalized = normalizeGitRemoteUrl(url);
        if (normalized in byRemote) continue;
        auto marker = markerBasenameForRemote(url);
        string localRoot;
        string method = "none";
        if (marker in cacheEntries && "path" in cacheEntries[marker]) {
            localRoot = cacheEntries[marker]["path"].str;
            if (localRoot.length && isGitCheckout(localRoot)) method = "cache";
            else localRoot = null;
        }
        if (localRoot is null) {
            localRoot = findMarkerRoot(searchRoots, marker, maxDepth);
            if (localRoot !is null) method = "marker-search";
        }
        if (localRoot !is null) {
            byRemote[normalized] = localRoot;
            cacheEntries[marker] = JSONValue([
                "path": JSONValue(localRoot),
                "updatedAt": JSONValue(SysTime.now.toISOString()),
            ]);
        }
        report ~= JSONValue([
            "remote": JSONValue(normalized),
            "marker": JSONValue(marker),
            "localRoot": JSONValue(localRoot is null ? JSONValue(null) : JSONValue(localRoot)),
            "method": JSONValue(method),
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

    auto out = JSONValue([
        "resolved": JSONValue(resolved),
        "cache": JSONValue(["version": JSONValue(1), "entries": JSONValue(cacheEntries)]),
        "report": JSONValue(report),
    ]);
    write(args[3], out.toPrettyString());
}
