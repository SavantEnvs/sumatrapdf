// Shared MuPDF harness: compiled once per document format with -DMAGIC="<mime/ext>" (or -DIMAGE_ONLY).
#include <mupdf/fitz.h>
#include <stdint.h>
#include <string.h>

static void quiet(void *user, const char *message) { (void)user; (void)message; }

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size < 8 || size > (4u << 20)) return -1;
    fz_context *ctx = fz_new_context(NULL, NULL, 16u << 20);
    if (!ctx) return 0;
    fz_set_error_callback(ctx, quiet, NULL);
    fz_set_warning_callback(ctx, quiet, NULL);
    fz_document *doc = NULL;
    fz_page *page = NULL;
    fz_pixmap *pix = NULL;
    fz_stext_page *text = NULL;
    fz_stream *stm = NULL;
    fz_image *img = NULL;
    fz_buffer *buf = NULL;
    fz_var(doc); fz_var(page); fz_var(pix); fz_var(text); fz_var(stm); fz_var(img); fz_var(buf);
    fz_try(ctx) {
#ifdef IMAGE_ONLY
        buf = fz_new_buffer_from_copied_data(ctx, data, size);
        img = fz_new_image_from_buffer(ctx, buf);
        int w = img->w, h = img->h;
        if (w > 0 && h > 0 && (int64_t)w * h <= (8 << 20)) {
            pix = fz_get_pixmap_from_image(ctx, img, NULL, NULL, NULL, NULL);
        }
#else
        fz_register_document_handlers(ctx);
        stm = fz_open_memory(ctx, data, size);
        doc = fz_open_document_with_stream(ctx, MAGIC, stm);
        int n = fz_count_pages(ctx, doc);
        if (n > 2) n = 2;
        for (int i = 0; i < n; i++) {
            page = fz_load_page(ctx, doc, i);
            fz_rect r = fz_bound_page(ctx, page);
            float w = r.x1 - r.x0, h = r.y1 - r.y0;
            float m = w > h ? w : h;
            float s = (m > 256.0f) ? 256.0f / m : 1.0f;
            if (!(w > 0 && h > 0) || m > 1e7f) { fz_drop_page(ctx, page); page = NULL; continue; }
            pix = fz_new_pixmap_from_page(ctx, page, fz_scale(s, s), fz_device_rgb(ctx), 0);
            fz_drop_pixmap(ctx, pix); pix = NULL;
            text = fz_new_stext_page_from_page(ctx, page, NULL);
            fz_drop_stext_page(ctx, text); text = NULL;
            fz_drop_page(ctx, page); page = NULL;
        }
#endif
    }
    fz_always(ctx) {
        fz_drop_pixmap(ctx, pix);
        fz_drop_stext_page(ctx, text);
        fz_drop_page(ctx, page);
        fz_drop_document(ctx, doc);
        fz_drop_stream(ctx, stm);
        fz_drop_image(ctx, img);
        fz_drop_buffer(ctx, buf);
    }
    fz_catch(ctx) {
    }
    fz_drop_context(ctx);
    return 0;
}
