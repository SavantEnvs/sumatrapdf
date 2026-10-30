#include <stddef.h>
#include <stdint.h>
#include "djvu.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 16 || size > (4u << 20)) return -1;
    djvu_ctx *ctx = djvu_ctx_new(NULL, NULL, NULL, NULL, NULL, NULL);
    if (!ctx) return 0;
    djvu_doc *doc = djvu_doc_open(ctx, data, size);
    if (doc) {
        int n = djvu_doc_page_count(doc);
        if (n > 3) n = 3;
        for (int i = 0; i < n; i++) {
            djvu_page_info pi;
            if (djvu_doc_page_info(doc, i, &pi) != 0) continue;
            if ((long long)pi.width * pi.height > (2ll << 20)) continue;
            djvu_image *img = djvu_page_render(doc, i, 4);
            if (img) djvu_image_destroy(ctx, img);
        }
        djvu_doc_close(doc);
    }
    djvu_ctx_free(ctx);
    return 0;
}
