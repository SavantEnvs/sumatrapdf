// MOBI/AZW/PDB e-books (src/shared/MobiDoc.cpp over PalmDbReader.cpp): CreateFromData parses the PDB record table and the
// MOBI/EXTH headers; then the text (PalmDoc/Huffman decompression), the images, the properties and the table of contents
// are read the way EngineEbook does.
#include "base/Base.h"
#include "base/ByteReaderWriter.h"
#include "gui/UIModels.h"
#include "DocProperties.h"
#include "DocController.h"
#include "EbookBase.h"
#include "PalmDbReader.h"
#include "MobiDoc.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    MobiDoc *mb = MobiDoc::CreateFromData(Str((const char *)data, (int)size));
    if (mb) {
        mb->GetHtmlData();
        mb->GetCoverImage();
        for (int i = 0; i < len(mb->images) + 1; i++) {
            mb->GetImage(i);
        }
        mb->GetPropertyTemp(DocProp::Title);
        mb->GetPropertyTemp(DocProp::Author);
        EbookToc toc;
        mb->ParseToc(toc);
        delete mb;
    }
    ResetTempArena();
    return 0;
}
