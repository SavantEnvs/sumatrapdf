#include <stdlib.h>

void *sumatra_hb_malloc(size_t size) { return malloc(size); }
void *sumatra_hb_calloc(size_t n, size_t size) { return calloc(n, size); }
void *sumatra_hb_realloc(void *ptr, size_t size) { return realloc(ptr, size); }
void sumatra_hb_free(void *ptr) { free(ptr); }
