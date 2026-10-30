#include <stdint.h>
#include "heic.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 16 || size > (4u << 20)) return -1;
    heic_ctx *ctx = heic_ctx_new(NULL, NULL, NULL, NULL);
    if (!ctx) return 0;
    heic_limits lim = {4096, 4096, 8u << 20, 256u << 20};
    heic_ctx_set_limits(ctx, &lim);
    heic_doc *doc = heic_doc_open(ctx, data, size);
    if (doc) {
        heic_image_info info;
        if (heic_doc_info(doc, &info) == 0) {
            heic_image *img = heic_doc_decode(doc, HEIC_FORMAT_RGBA);
            if (img) heic_image_destroy(ctx, img);
        }
        heic_doc_close(doc);
    }
    heic_ctx_free(ctx);
    return 0;
}
