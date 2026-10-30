// Content sniffer (src/base/GuessFileType.cpp) the app runs on every opened file and on every embedded image: the file
// type, the image sizes it reads out of the headers, and the ZIP-container variant.
#include "base/Base.h"
#include "base/GuessFileType.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    Str d((const char *)data, (int)size);
    FileTypeInfo info = GuessFileInfoFromData(d);
    FreeFileTypeInfo(&info);
    GuessFileTypeFromData(d);
    GuessFileTypeFromZipData(d);
    WebpExifOrientation(d);
    ResetTempArena();
    return 0;
}
