#include <stdint.h>
#include <stdlib.h>
#include "chm.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    chm_ctx *ctx = chm_ctx_new(NULL, NULL, NULL, NULL);
    if (!ctx) return 0;
    if (chm_open(ctx, data, size)) {
        struct chm_entry **entries = NULL;
        int n = chm_get_entries(ctx, &entries);
        uint8_t *buf = NULL;
        size_t cap = 0;
        for (int i = 0; i < n && i < 16; i++) {
            struct chm_entry *e = entries[i];
            /* chm.h: chm_read_entry needs a caller buffer of at least entry->length bytes. length is read
               from the file as a 64-bit value; an entry whose buffer the process cannot provide cannot be
               read through the API at all. kMaxAlloc is libFuzzer's own single-malloc limit (-malloc_limit_mb
               defaults to the 2048 MB rss limit), above which libFuzzer aborts inside the harness's malloc. */
            const uint64_t kMaxAlloc = 2048ull << 20;
            if (e->length > kMaxAlloc) continue;
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
