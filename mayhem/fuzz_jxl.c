#include <stdint.h>
#include "jxl.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    jxl_ctx *ctx = jxl_ctx_new(NULL, NULL, NULL, NULL);
    if (!ctx) return 0;
    jxl_doc *doc = jxl_doc_open(ctx, data, size);
    if (doc) {
        jxl_image *img = jxl_frame_render(doc, 0, JXLDEC_FORMAT_RGBA32);
        if (img) jxl_image_destroy(ctx, img);
        jxl_doc_close(doc);
    }
    jxl_ctx_free(ctx);
    return 0;
}
