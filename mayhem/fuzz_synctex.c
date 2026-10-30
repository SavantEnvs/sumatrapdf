// synctex_parser.c: parses the .synctex(.gz) file TeX writes next to a PDF, then runs the app's edit/display queries
// (src/shared/PdfSync.cpp). The input is written as <fresh dir>/a.synctex and opened through the library's own
// entry point, synctex_scanner_new_with_output_file("<dir>/a.pdf"), which resolves the .synctex(.gz) file itself.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "synctex_parser.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) tmp = "/tmp";
    char dir[4096], sx[4200], pdf[4200];
    snprintf(dir, sizeof dir, "%s/synctexXXXXXX", tmp);
    if (!mkdtemp(dir)) return 0;
    snprintf(sx, sizeof sx, "%s/a.synctex", dir);
    snprintf(pdf, sizeof pdf, "%s/a.pdf", dir);
    FILE *f = fopen(sx, "wb");
    if (f) {
        fwrite(data, 1, size, f);
        fclose(f);
        synctex_scanner_p sc = synctex_scanner_new_with_output_file(pdf, NULL, 1);
        if (sc) {
            if (synctex_edit_query(sc, 1, 100.0f, 100.0f) > 0) {
                synctex_node_p n;
                while ((n = synctex_scanner_next_result(sc)) != NULL) {
                    const char *name = synctex_scanner_get_name(sc, synctex_node_tag(n));
                    (void)name;
                    synctex_node_line(n);
                    synctex_node_column(n);
                }
            }
            if (synctex_display_query(sc, "a.tex", 1, 0, 0) > 0) {
                synctex_node_p n;
                while ((n = synctex_scanner_next_result(sc)) != NULL) {
                    synctex_node_page(n);
                    synctex_node_box_visible_h(n);
                    synctex_node_box_visible_v(n);
                    synctex_node_box_visible_width(n);
                    synctex_node_box_visible_height(n);
                    synctex_node_box_visible_depth(n);
                }
            }
            synctex_scanner_free(sc);
        }
    }
    unlink(sx);
    snprintf(sx, sizeof sx, "%s/a.synctex.gz", dir);
    unlink(sx);
    rmdir(dir);
    return 0;
}
