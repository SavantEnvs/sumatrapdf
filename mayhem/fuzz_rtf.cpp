// RTF documents (src/shared/RtfDoc.cpp): RtfToHtml is the converter CreateEngineRtfFromFile runs before handing the HTML
// to MuPDF. It tokenizes the control words, groups, fonts, tables, lists and embedded pictures.
#include "base/Base.h"
#include "RtfDoc.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    Str html = RtfToHtml(Str((const char *)data, (int)size));
    str::Free(html);
    ResetTempArena();
    return 0;
}
