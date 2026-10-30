// RtfDoc.cpp ends in CreateEngineRtfFromFile, which hands the converted HTML to the MuPDF engine. The RTF harness stops at
// the converter (RtfToHtml) and never calls it; this definition only satisfies the linker, so the MuPDF engine layer stays
// out of the binary.
#include "base/Base.h"
#include "base/GuessFileType.h"
#include "gui/UIModels.h"
#include "EngineBase.h"
#include "EngineAll.h"

EngineBase *CreateEngineMupdfFromData(Str, Str, PasswordUI *) { return nullptr; }
