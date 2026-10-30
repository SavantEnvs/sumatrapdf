// SumatraPDF's own archive layer (src/base/Archive.cpp) over the vendored libarchive: the path CB7/CBT/tar/7z/zip
// comics and archive-wrapped documents take. OpenArchiveFromData sniffs the format, lists the entries and
// (eagerLoad) decompresses every one; GetFileDataById then re-reads each entry through the public accessor.
#include "base/Base.h"
#include "base/Archive.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    Archive *a = OpenArchiveFromData(Str((const char *)data, (int)size));
    if (!a) return 0;
    const auto &infos = a->GetFileInfos();
    for (int i = 0; i < infos.len; i++) {
        a->GetFileDataById(infos.els[i]->fileId);
    }
    delete a;
    return 0;
}
