#include <stdint.h>
#include <stdlib.h>
#include "chm.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 32 || size > (4u << 20)) return -1;
    chm_ctx *ctx = chm_ctx_new(NULL, NULL, NULL, NULL);
    if (!ctx) return 0;
    if (chm_open(ctx, data, size)) {
        struct chm_entry **entries = NULL;
        int n = chm_get_entries(ctx, &entries);
        uint8_t *buf = NULL;
        size_t cap = 0;
        for (int i = 0; i < n && i < 16; i++) {
            struct chm_entry *e = entries[i];
            if (e->length == 0 || e->length > (8u << 20)) continue;
            if (e->length > cap) {
                free(buf);
                cap = e->length;
                buf = (uint8_t *)malloc(cap);
                if (!buf) { cap = 0; break; }
            }
            chm_read_entry(ctx, e, buf);
        }
        free(buf);
        chm_close(ctx);
    }
    chm_ctx_free(ctx);
    return 0;
}
