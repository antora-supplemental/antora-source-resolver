/**
 * NTFS MFT filename scan (Windows). Finds exact file paths without directory walks.
 */
module mft_search;

version (Windows) {
import core.sys.windows.winbase;
import core.sys.windows.winnt;
import core.sys.windows.windef;
import std.algorithm;
import std.array;
import std.conv;
import std.format;
import std.string;
import std.utf;

enum FSCTL_GET_NTFS_VOLUME_DATA = 0x00090064;
enum FILE_NAME_ATTR = 0x30;
enum MFT_ROOT_FRN = 5;

align (1) struct NtfsVolumeData {
    long VolumeSerialNumber;
    long NumberSectors;
    long TotalClusters;
    long FreeClusters;
    long TotalReserved;
    uint BytesPerSector;
    uint BytesPerCluster;
    uint BytesPerFileRecordSegment;
    uint ClustersPerFileRecordSegment;
    long MftValidDataLength;
    long MftStartLcn;
    long Mft2StartLcn;
    uint MftZoneStart;
    uint MftZoneEnd;
}

struct FrnEntry {
    ulong frn;
    ulong parentFrn;
    string name;
    bool isDirectory;
}

struct MftVolume {
    HANDLE handle = INVALID_HANDLE_VALUE;
    string letter;
    ulong mftOffset;
    uint recordSize;
    uint sectorSize;
    ulong totalRecords;
    FrnEntry[ulong] index;
    bool indexBuilt;
}

void closeVolume(ref MftVolume vol) {
    if (vol.handle != INVALID_HANDLE_VALUE) {
        CloseHandle(vol.handle);
        vol.handle = INVALID_HANDLE_VALUE;
    }
    vol.index = null;
    vol.indexBuilt = false;
}

bool openVolume(ref MftVolume vol, string driveRoot) {
    closeVolume(vol);
    if (driveRoot.length < 2 || driveRoot[1] != ':') return false;
    vol.letter = driveRoot[0 .. 2].toUpper;
    auto path = format!"\\\\.\\%s"(vol.letter);
    vol.handle = CreateFileW(
        toUTF16z(path),
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (vol.handle == INVALID_HANDLE_VALUE) return false;

    NtfsVolumeData data;
    DWORD returned;
    if (!DeviceIoControl(
            vol.handle,
            FSCTL_GET_NTFS_VOLUME_DATA,
            null,
            0,
            &data,
            NtfsVolumeData.sizeof,
            &returned,
            null)) {
        closeVolume(vol);
        return false;
    }
    vol.mftOffset = cast(ulong) data.MftStartLcn * data.BytesPerCluster;
    vol.recordSize = data.BytesPerFileRecordSegment;
    vol.sectorSize = data.BytesPerSector;
    vol.totalRecords = cast(ulong)(data.MftValidDataLength / data.BytesPerFileRecordSegment);
    return vol.recordSize > 0 && vol.totalRecords > 0;
}

bool readAt(ref MftVolume vol, ulong offset, ubyte[] buf) {
    LARGE_INTEGER pos;
    pos.QuadPart = cast(long) offset;
    if (SetFilePointerEx(vol.handle, pos, null, FILE_BEGIN) == 0) return false;
    DWORD read;
    return ReadFile(vol.handle, buf.ptr, cast(DWORD) buf.length, &read, null) != 0 && read == buf.length;
}

bool applyUsnFixup(ref ubyte[] rec, uint sectorSize) {
    if (rec.length < 8 || *cast(uint*) rec.ptr != 0x454C4946) return false;
    auto usaOff = *cast(ushort*) (rec.ptr + 4);
    auto usaCount = *cast(ushort*) (rec.ptr + 6);
    if (usaOff + usaCount * 2 > rec.length) return false;
    auto usa = cast(ushort*) (rec.ptr + usaOff);
    auto updateSeq = usa[0];
    foreach (i; 1 .. usaCount) {
        auto sectorEnd = i * sectorSize - 2;
        if (sectorEnd + 2 > rec.length) return false;
        if (*cast(ushort*) (rec.ptr + sectorEnd) != updateSeq) return false;
        *cast(ushort*) (rec.ptr + sectorEnd) = usa[i];
    }
    return true;
}

bool parseFileNameValue(const(ubyte)* data, size_t length, ref ulong parentFrn, ref string name) {
    if (length < 0x42) return false;
    parentFrn = *cast(ulong*) data & 0x0000FFFFFFFFFFFFUL;
    auto nameLen = data[0x40];
    if (nameLen == 0 || 0x42 + nameLen * 2 > length) return false;
    name = toUTF8((cast(wchar*) (data + 0x42))[0 .. nameLen]);
    return true;
}

void indexRecord(ref MftVolume vol, ulong recordNumber, ubyte[] rec) {
    auto flags = *cast(ushort*) (rec.ptr + 0x16);
    bool isDir = (flags & 0x02) != 0;
    auto attrOff = *cast(ushort*) (rec.ptr + 0x14);
    if (attrOff >= rec.length) return;

    string bestName;
    ulong bestParent;
    ubyte bestNs = 0xFF;

    for (size_t offset = attrOff; offset + 4 <= rec.length;) {
        auto attrType = *cast(uint*) (rec.ptr + offset);
        if (attrType == 0xFFFFFFFF) break;
        auto attrLen = *cast(uint*) (rec.ptr + offset + 4);
        if (attrLen < 24 || offset + attrLen > rec.length) break;
        if (attrType == FILE_NAME_ATTR && rec.ptr[offset + 8] == 0) {
            auto valueLen = *cast(uint*) (rec.ptr + offset + 16);
            auto valueOff = *cast(ushort*) (rec.ptr + offset + 20);
            if (offset + valueOff + valueLen <= rec.length) {
                ulong parentFrn;
                string name;
                if (parseFileNameValue(rec.ptr + offset + valueOff, valueLen, parentFrn, name)) {
                    auto ns = rec.ptr[offset + valueOff + 0x41];
                    if (bestName.length == 0 || ns == 1) {
                        bestNs = ns;
                        bestName = name;
                        bestParent = parentFrn;
                    }
                }
            }
        }
        offset += attrLen;
    }
    if (bestName.length) {
        vol.index[recordNumber] = FrnEntry(recordNumber, bestParent, bestName, isDir);
    }
}

void buildFrnIndex(ref MftVolume vol) {
    if (vol.indexBuilt) return;
    vol.index = null;
    auto rec = new ubyte[vol.recordSize];
    foreach (recordNumber; 0 .. vol.totalRecords) {
        if (!readAt(vol, vol.mftOffset + recordNumber * vol.recordSize, rec)) continue;
        if (!applyUsnFixup(rec, vol.sectorSize)) continue;
        indexRecord(vol, recordNumber, rec);
    }
    vol.indexBuilt = true;
}

string resolveFullPath(ref MftVolume vol, ulong fileFrn) {
    if (fileFrn !in vol.index) return null;
    string[] parts;
    auto cur = fileFrn;
    int guard;
    while (cur != 0 && cur != MFT_ROOT_FRN && guard++ < 512) {
        if (cur !in vol.index) break;
        auto ent = vol.index[cur];
        parts ~= ent.name;
        cur = ent.parentFrn;
    }
    parts.reverse;
    return format!"%s\\%(%s\\%)"(vol.letter, parts);
}

string[] findExactFilePathsInVolume(ref MftVolume vol, string[] names) {
    if (!names.length) return null;
    buildFrnIndex(vol);
    bool[string] want;
    foreach (n; names) want[n] = true;
    string[] paths;
    foreach (frn, ent; vol.index) {
        if (ent.isDirectory) continue;
        if (ent.name !in want) continue;
        auto full = resolveFullPath(vol, frn);
        if (full.length) paths ~= full;
    }
    return paths;
}

/**
 * Scan one NTFS volume for exact file names; returns full paths to each matching file.
 */
string[] mftFindExactFilePaths(string driveRoot, string[] names) {
    MftVolume vol;
    if (!openVolume(vol, driveRoot)) return null;
    scope (exit) closeVolume(vol);
    return findExactFilePathsInVolume(vol, names);
}

} else {

string[] mftFindExactFilePaths(string driveRoot, string[] names) {
    return null;
}

}
