// KAT probe: exercises the same vendored libraries the fuzzers cover and prints deterministic facts on stdout.
// mayhem/test.sh builds nothing; it runs this (built by build.sh with plain flags) and compares each line.
#include <mupdf/fitz.h>
#include <dav1d/dav1d.h>
#include <stdio.h>
#include <string.h>

static void quiet(void *u, const char *m) { (void)u; (void)m; }

static const char svg_src[] =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\">"
    "<rect x=\"0\" y=\"0\" width=\"10\" height=\"10\" fill=\"#ff0000\"/>"
    "<rect x=\"10\" y=\"0\" width=\"10\" height=\"10\" fill=\"#0000ff\"/></svg>";

static void pix_at(fz_context *ctx, fz_pixmap *p, int x, int y, const char *tag) {
    unsigned char *s = fz_pixmap_samples(ctx, p) + (size_t)y * fz_pixmap_stride(ctx, p) + (size_t)x * fz_pixmap_components(ctx, p);
    printf("%s %d,%d=%d,%d,%d\n", tag, x, y, s[0], s[1], s[2]);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: kat_probe hello.pdf\n"); return 2; }
    fz_context *ctx = fz_new_context(NULL, NULL, 64u << 20);
    if (!ctx) return 3;
    fz_set_error_callback(ctx, quiet, NULL);
    fz_set_warning_callback(ctx, quiet, NULL);
    fz_register_document_handlers(ctx);
    fz_try(ctx) {
        fz_document *doc = fz_open_document(ctx, argv[1]);
        printf("pdf.pages %d\n", fz_count_pages(ctx, doc));
        fz_page *page = fz_load_page(ctx, doc, 0);
        fz_rect r = fz_bound_page(ctx, page);
        printf("pdf.bounds %g %g %g %g\n", r.x0, r.y0, r.x1, r.y1);
        fz_stext_page *st = fz_new_stext_page_from_page(ctx, page, NULL);
        fz_buffer *b = fz_new_buffer_from_stext_page(ctx, st);
        const char *t = fz_string_from_buffer(ctx, b);
        size_t n = strcspn(t, "\r\n");
        printf("pdf.text [%.*s]\n", (int)n, t);
        fz_drop_buffer(ctx, b);
        fz_drop_stext_page(ctx, st);
        fz_pixmap *pm = fz_new_pixmap_from_page(ctx, page, fz_identity, fz_device_rgb(ctx), 0);
        printf("pdf.pixmap %dx%d\n", fz_pixmap_width(ctx, pm), fz_pixmap_height(ctx, pm));
        pix_at(ctx, pm, 5, 5, "pdf.px");
        fz_drop_pixmap(ctx, pm);
        fz_drop_page(ctx, page);
        fz_drop_document(ctx, doc);

        fz_stream *ss = fz_open_memory(ctx, (const unsigned char *)svg_src, sizeof svg_src - 1);
        fz_document *sdoc = fz_open_document_with_stream(ctx, "image/svg+xml", ss);
        fz_page *sp = fz_load_page(ctx, sdoc, 0);
        fz_pixmap *sm = fz_new_pixmap_from_page(ctx, sp, fz_identity, fz_device_rgb(ctx), 0);
        printf("svg.pixmap %dx%d\n", fz_pixmap_width(ctx, sm), fz_pixmap_height(ctx, sm));
        pix_at(ctx, sm, 4, 4, "svg.left");
        pix_at(ctx, sm, 15, 4, "svg.right");
        fz_drop_pixmap(ctx, sm);
        fz_drop_page(ctx, sp);
        fz_drop_document(ctx, sdoc);
        fz_drop_stream(ctx, ss);

        /* 2x1 24-bit BMP: pixel0 = (0,255,0) green, pixel1 = (255,255,0) yellow */
        static const unsigned char bmp[] = {
            'B','M', 62,0,0,0, 0,0,0,0, 54,0,0,0, 40,0,0,0, 2,0,0,0, 1,0,0,0, 1,0, 24,0, 0,0,0,0, 8,0,0,0,
            0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
            0,255,0, 0,255,255, 0,0 };
        fz_buffer *bb = fz_new_buffer_from_copied_data(ctx, bmp, sizeof bmp);
        fz_image *im = fz_new_image_from_buffer(ctx, bb);
        fz_pixmap *ip = fz_get_pixmap_from_image(ctx, im, NULL, NULL, NULL, NULL);
        printf("bmp.size %dx%d\n", fz_pixmap_width(ctx, ip), fz_pixmap_height(ctx, ip));
        pix_at(ctx, ip, 0, 0, "bmp.px");
        pix_at(ctx, ip, 1, 0, "bmp.px");
        fz_drop_pixmap(ctx, ip);
        fz_drop_image(ctx, im);
        fz_drop_buffer(ctx, bb);
    }
    fz_catch(ctx) {
        printf("error %s\n", fz_caught_message(ctx));
        return 1;
    }
    fz_drop_context(ctx);
    printf("dav1d.version %s\n", dav1d_version());
    return 0;
}
