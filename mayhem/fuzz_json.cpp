// JSON pull parser (src/base/JsonParser.cpp): the reader behind the AI chat API streaming events, the update/online-file
// listings and the web-view messages. The input is walked the way the callers do, matching and formatting each value's path.
#include "base/Base.h"
#include "base/JsonParser.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    {
        json::Reader reader(Str((const char *)data, (int)size));
        for (json::Value &v : reader) {
            json::PathMatch(v.path, StrL("/choices"), StrL("i0"), StrL("/delta"), StrL("/content"));
            json::PathMatch(v.path, StrL("/files"), StrL("*"), StrL("/name"));
            json::PathFormatTemp(v.path);
            json::PathSegIndex(json::PathNth(v.path, 1));
            json::PathSegKey(json::PathNth(v.path, 0));
            json::EscapeStrTemp(v.value);
        }
        reader.Ok();
    }
    ResetTempArena();
    return 0;
}
