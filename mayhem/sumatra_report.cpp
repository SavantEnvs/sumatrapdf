// SumatraPDF's soft assert (ReportIf) calls _uploadDebugReport, which the app defines in its crash handler. Here it
// aborts, as the app's own -for-testing mode does (CrashHandler_posix.cpp: a ReportIf fails the run), so a violated
// internal invariant is reported as a defect instead of being silently logged and bailed out of.
#include <stdlib.h>
#include "base/Base.h"

void _uploadDebugReport(Str, Str, bool) { abort(); }
