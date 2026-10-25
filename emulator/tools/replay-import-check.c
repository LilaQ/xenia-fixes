// Small loader probe with no C/C++ runtime dependency. Runs beside the replay EXE.
#include <windows.h>

static HANDLE output;
static void print(const char* text) {
  DWORD count = 0, written;
  while (text[count]) ++count;
  WriteFile(output, text, count, &written, NULL);
}
static void number(DWORD value) {
  char buffer[11];
  unsigned i = 10;
  buffer[i] = 0;
  do { buffer[--i] = (char)('0' + value % 10); value /= 10; } while (value);
  print(buffer + i);
}
static BYTE* rva(BYTE* file, IMAGE_NT_HEADERS64* nt, DWORD address, DWORD size) {
  IMAGE_SECTION_HEADER* section = IMAGE_FIRST_SECTION(nt);
  for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++section) {
    if (address >= section->VirtualAddress &&
        address - section->VirtualAddress < section->SizeOfRawData &&
        section->PointerToRawData + (ULONGLONG)(address - section->VirtualAddress) < size)
      return file + section->PointerToRawData + address - section->VirtualAddress;
  }
  return NULL;
}
static DWORD run(void) {
  static WCHAR path[32768];
  DWORD length = GetModuleFileNameW(NULL, path, 32768);
  if (!length || length >= 32768) return 1;
  while (length && path[length - 1] != L'\\') --length;
  const WCHAR name[] = L"xenia_trace_replay.exe";
  for (unsigned i = 0; i < sizeof(name) / sizeof(name[0]); ++i) path[length + i] = name[i];
  HANDLE handle = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
  if (handle == INVALID_HANDLE_VALUE) { print("Cannot open replay EXE\r\n"); return 2; }
  DWORD size = GetFileSize(handle, NULL), read;
  BYTE* file = VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  if (!file || !ReadFile(handle, file, size, &read, NULL) || read != size) return 3;
  CloseHandle(handle);
  IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)file;
  if (size < sizeof(*dos) || dos->e_magic != IMAGE_DOS_SIGNATURE ||
      dos->e_lfanew < 0 || (ULONGLONG)dos->e_lfanew + sizeof(IMAGE_NT_HEADERS64) > size) return 4;
  IMAGE_NT_HEADERS64* nt = (IMAGE_NT_HEADERS64*)(file + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return 5;
  DWORD imports = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
  IMAGE_IMPORT_DESCRIPTOR* entry = (IMAGE_IMPORT_DESCRIPTOR*)rva(file, nt, imports, size);
  if (!entry) return 6;
  DWORD failures = 0;
  for (; entry->Name; ++entry) {
    const char* dll = (const char*)rva(file, nt, entry->Name, size);
    if (!dll) return 7;
    print("MODULE "); print(dll); print("\r\n");
    HMODULE module = LoadLibraryA(dll);
    if (!module) { DWORD error = GetLastError(); print("LOAD FAILED "); number(error); print("\r\n"); ++failures; continue; }
    IMAGE_THUNK_DATA64* thunk = (IMAGE_THUNK_DATA64*)rva(file, nt, entry->OriginalFirstThunk, size);
    if (!thunk) return 8;
    for (; thunk->u1.AddressOfData; ++thunk) {
      const char* symbol;
      if (IMAGE_SNAP_BY_ORDINAL64(thunk->u1.Ordinal)) {
        symbol = (const char*)(ULONG_PTR)IMAGE_ORDINAL64(thunk->u1.Ordinal);
      } else {
        IMAGE_IMPORT_BY_NAME* imported = (IMAGE_IMPORT_BY_NAME*)rva(file, nt, (DWORD)thunk->u1.AddressOfData, size);
        if (!imported) return 9;
        symbol = (const char*)imported->Name;
      }
      if (!GetProcAddress(module, symbol)) {
        DWORD error = GetLastError();
        print("MISSING "); print(dll); print("!");
        if (IMAGE_SNAP_BY_ORDINAL64(thunk->u1.Ordinal)) number((DWORD)(ULONG_PTR)symbol); else print(symbol);
        print(" error "); number(error); print("\r\n"); ++failures;
      }
    }
    FreeLibrary(module);
  }
  VirtualFree(file, 0, MEM_RELEASE);
  print("Import failures: "); number(failures); print("\r\n");
  return failures ? 10 : 0;
}
void mainCRTStartup(void) {
  output = GetStdHandle(STD_OUTPUT_HANDLE);
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
  print("Replay import probe started\r\n");
  ExitProcess(run());
}
