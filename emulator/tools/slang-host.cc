#include <cstdio>
#include <fstream>
#include <string>
#include "slang.h"
#include "slang-deprecated.h"
static std::string MakePath(const char* path) {
 std::string result;
 for (const char* p = path; *p; ++p) {
  if (*p == '$') result += '$';
  if (*p == ' ' || *p == '#' || *p == char(92)) result += char(92);
  result += *p;
 }
 return result;
}
int main(int argc, char** argv) {
 const char* output = nullptr;
 const char* depfile = nullptr;
 for (int i = 1; i + 1 < argc; ++i) {
  if (std::string(argv[i]) == "-o") output = argv[++i];
  else if (std::string(argv[i]) == "-depfile") depfile = argv[++i];
 }
 if (!output) { std::fputs("Missing -o output path\n", stderr); return 1; }
 auto* session = spCreateSession();
 if (!session) return 1;
 auto* request = spCreateCompileRequest(session);
 auto result = spProcessCommandLineArguments(request, const_cast<const char**>(argv + 1), argc - 1);
 if (SLANG_SUCCEEDED(result)) result = spCompile(request);
 if (const char* text = spGetDiagnosticOutput(request)) std::fputs(text, stderr);
 bool written = false;
 if (SLANG_SUCCEEDED(result)) {
  size_t size = 0;
  auto* bytes = spGetEntryPointCode(request, 0, &size);
  if (bytes && size) {
   std::ofstream file(output, std::ios::binary);
   file.write(static_cast<const char*>(bytes), size);
   written = bool(file);
  }
  if (written && depfile) {
   std::ofstream deps(depfile);
   deps << MakePath(output) << ':';
   for (int i = 0; i < spGetDependencyFileCount(request); ++i)
    deps << ' ' << MakePath(spGetDependencyFilePath(request, i));
   deps << char(10);
   written = bool(deps);
  }
 }
 spDestroyCompileRequest(request);
 spDestroySession(session);
 return SLANG_SUCCEEDED(result) && written ? 0 : 1;
}
