// EXIF/TIFF-IFD reader (src/base/Exif.cpp): Parse takes a whole image file (JPEG APP1 or bare TIFF), then every
// parsed tag is read back through the typed accessors the app uses.
#include "base/Base.h"
#include "base/Exif.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    ExifParser parser;
    if (parser.Parse(Str((const char *)data, (int)size))) {
        for (int i = 0; i < parser.entries.len; i++) {
            ExifProp p = (ExifProp)parser.entries.els[i].tag;
            parser.GetFormattedPropTemp(p);
            parser.GetStringProp(p);
            i64 iv; parser.GetIntProp(p, &iv);
            ExifRational rv; parser.GetRationalProp(p, &rv);
            double fv; parser.GetFloatProp(p, &fv);
        }
    }
    ResetTempArena();
    return 0;
}
