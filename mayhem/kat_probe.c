// KAT probe: exercises the same vendored libraries the fuzzers cover and prints deterministic facts on stdout.
// mayhem/test.sh builds nothing; it runs this (built by build.sh with plain flags) and compares each line.
#include <mupdf/fitz.h>
#include <dav1d/dav1d.h>
#include "djvu.h"
#include "chm.h"
#include "jxl.h"
#include "heic.h"
#include <stdint.h>
#include <stdlib.h>
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

static uint8_t *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = (uint8_t *)malloc(n > 0 ? (size_t)n : 1);
    if (b && fread(b, 1, (size_t)n, f) != (size_t)n) { free(b); b = NULL; }
    fclose(f);
    *len = (size_t)n;
    return b;
}

static unsigned fnv(const uint8_t *d, size_t n) {
    unsigned h = 2166136261u;
    for (size_t i = 0; i < n; i++) h = (h ^ d[i]) * 16777619u;
    return h;
}

static void px(const uint8_t *d, int stride, int bpp, int x, int y, const char *tag) {
    const uint8_t *s = d + (size_t)y * stride + (size_t)x * bpp;
    printf("%s %d,%d=", tag, x, y);
    for (int i = 0; i < bpp; i++) printf(i ? ",%d" : "%d", s[i]);
    printf("\n");
}

/* Decode the vendored djvu/chm/jxl/heic libraries directly (the same code the fuzz_djvu/chm/jxl/heic targets
   cover) from the files in <dir>, and print deterministic facts. */
static void kat_codecs(const char *dir) {
    char path[1024];
    size_t n;
    uint8_t *b;

    snprintf(path, sizeof path, "%s/test.djvu", dir);
    if ((b = slurp(path, &n))) {
        djvu_ctx *c = djvu_ctx_new(NULL, NULL, NULL, NULL, NULL, NULL);
        djvu_doc *d = djvu_doc_open(c, b, n);
        if (d) {
            djvu_page_info pi;
            printf("djvu.pages %d\n", djvu_doc_page_count(d));
            if (djvu_doc_page_info(d, 0, &pi) == 0) printf("djvu.page0 %dx%d dpi=%d\n", pi.width, pi.height, pi.dpi);
            djvu_image *im = djvu_page_render(d, 0, 1);
            if (im) {
                printf("djvu.render %dx%d fmt=%d\n", im->width, im->height, (int)im->format);
                printf("djvu.hash %08x\n", fnv(im->data, (size_t)im->stride * im->height));
                djvu_image_destroy(c, im);
            }
            djvu_doc_close(d);
        }
        djvu_ctx_free(c);
        free(b);
    }

    snprintf(path, sizeof path, "%s/test.chm", dir);
    if ((b = slurp(path, &n))) {
        chm_ctx *c = chm_ctx_new(NULL, NULL, NULL, NULL);
        if (chm_open(c, b, n)) {
            struct chm_entry **es = NULL;
            int ne = chm_get_entries(c, &es);
            for (int i = 0; i < ne; i++) {
                struct chm_entry *e = es[i];
                if (e->is_file && e->path && !strcmp(e->path, "/index.html")) {
                    uint8_t *buf = (uint8_t *)malloc(e->length + 1);
                    int64_t got = chm_read_entry(c, e, buf);
                    buf[got > 0 ? got : 0] = 0;
                    printf("chm.index.len %llu read=%lld\n", (unsigned long long)e->length, (long long)got);
                    printf("chm.index.text [%s]\n", (const char *)buf);
                    free(buf);
                }
            }
            chm_close(c);
        }
        chm_ctx_free(c);
        free(b);
    }

    snprintf(path, sizeof path, "%s/keong_macan.jxl", dir);
    if ((b = slurp(path, &n))) {
        jxl_ctx *c = jxl_ctx_new(NULL, NULL, NULL, NULL);
        jxl_doc *d = jxl_doc_open(c, b, n);
        if (d) {
            jxl_image_info inf;
            if (jxl_doc_info(d, &inf) == 0) printf("jxl.info %dx%d frames=%d\n", inf.width, inf.height, inf.num_frames);
            jxl_image *im = jxl_frame_render(d, 0, JXLDEC_FORMAT_RGBA32);
            if (im) {
                printf("jxl.render %dx%d\n", im->width, im->height);
                px(im->data, im->stride, 4, im->width / 2, im->height / 2, "jxl.px");
                printf("jxl.hash %08x\n", fnv(im->data, (size_t)im->stride * im->height));
                jxl_image_destroy(c, im);
            }
            jxl_doc_close(d);
        }
        jxl_ctx_free(c);
        free(b);
    }

    snprintf(path, sizeof path, "%s/two.avif", dir);
    if ((b = slurp(path, &n))) {
        heic_ctx *c = heic_ctx_new(NULL, NULL, NULL, NULL);
        heic_doc *d = heic_doc_open(c, b, n);
        if (d) {
            heic_image_info inf;
            if (heic_doc_info(d, &inf) == 0) printf("heic.info %ux%u depth=%d\n", inf.width, inf.height, inf.bit_depth);
            heic_image *im = heic_doc_decode(d, HEIC_FORMAT_RGBA);
            if (im) {
                printf("heic.render %ux%u\n", im->width, im->height);
                px(im->data, im->stride, 4, 2, 4, "heic.left");
                px(im->data, im->stride, 4, 13, 4, "heic.right");
                heic_image_destroy(c, im);
            }
            heic_doc_close(d);
        }
        heic_ctx_free(c);
        free(b);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: kat_probe hello.pdf [codec-dir]\n"); return 2; }
    if (argc > 2) kat_codecs(argv[2]);
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
