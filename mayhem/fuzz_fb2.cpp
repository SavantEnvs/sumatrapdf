// FictionBook (FB2 and zipped FB2.ZIP) e-books (src/shared/EbookDoc.cpp): CreateFromData unpacks a zip container when
// it sees one, parses the XML for properties, cover and embedded images, then the table of contents is read.
#include "base/Base.h"
#include "base/Archive.h"
#include "base/HtmlTags.h"
#include "gui/UIModels.h"
#include "DocProperties.h"
#include "DocController.h"
#include "EbookBase.h"
#include "GumboHtmlParser.h"
#include "PalmDbReader.h"
#include "MobiDoc.h"
#include "EbookDoc.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    // Fb2Doc::Load asserts that it was given data or a file name (EbookDoc.cpp: ReportIf(len(srcData) == 0 && len(fileName) == 0)).
    if (size == 0) return -1;
    Fb2Doc *doc = Fb2Doc::CreateFromData(Str((const char *)data, (int)size));
    if (doc) {
        doc->GetCoverImage();
        for (int i = 0; i < len(doc->images); i++) {
            doc->GetImageData(doc->images[i].fileName);
        }
        EbookToc toc;
        doc->ParseToc(toc);
        delete doc;
    }
    ResetTempArena();
    return 0;
}
