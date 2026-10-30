// Truevision TGA decoder (src/base/TgaReader.cpp): a pure byte-buffer parser, SumatraPDF's own code.
#include "base/Base.h"
#include "base/Pixmap.h"
#include "base/TgaReader.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    Str d((const char *)data, (int)size);
    tga::HasSignature(d);
    Pixmap *px = tga::PixmapFromData(d);
    if (px) FreePixmap(px);
    return 0;
}
