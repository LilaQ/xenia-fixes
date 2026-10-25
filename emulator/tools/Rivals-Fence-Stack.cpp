#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <dbghelp.h>
#include <cstdio>
#include <cstdint>
#include <cwchar>
#include <vector>
#include <string>
struct Module { uint64_t base,size; std::wstring name; };
int main(int argc,char** argv){
 if(argc!=3)return 2; DWORD pid=strtoul(argv[1],nullptr,10),tid=strtoul(argv[2],nullptr,10);
 HANDLE process=OpenProcess(PROCESS_QUERY_INFORMATION|PROCESS_VM_READ,FALSE,pid);
 if(!process)return 3;
 wchar_t path[32768];DWORD length=32768;
 if(!QueryFullProcessImageNameW(process,0,path,&length)||std::wstring(path)!=L"D:\\LaunchBox\\Emulators\\Xenia Edge Trace\\runtime\\xenia_rivals_trace.exe"){CloseHandle(process);return 4;}
 HANDLE thread=OpenThread(THREAD_SUSPEND_RESUME|THREAD_GET_CONTEXT|THREAD_QUERY_INFORMATION,FALSE,tid);
 if(!thread||GetProcessIdOfThread(thread)!=pid){if(thread)CloseHandle(thread);CloseHandle(process);return 5;}
 std::vector<Module> modules;HANDLE snap=CreateToolhelp32Snapshot(TH32CS_SNAPMODULE,pid);MODULEENTRY32W me{};me.dwSize=sizeof(me);
 if(snap!=INVALID_HANDLE_VALUE){if(Module32FirstW(snap,&me))do{modules.push_back({(uint64_t)me.modBaseAddr,me.modBaseSize,me.szModule});}while(Module32NextW(snap,&me));CloseHandle(snap);}
 uint64_t waitpc=0;for(auto&m:modules)if(_wcsicmp(m.name.c_str(),L"win32u.dll")==0)waitpc=m.base+0x6154;
 SymSetOptions(SYMOPT_DEFERRED_LOADS|SYMOPT_FAIL_CRITICAL_ERRORS|SYMOPT_NO_PROMPTS|SYMOPT_IGNORE_NT_SYMPATH);
 if(!SymInitialize(process,"",TRUE)){CloseHandle(thread);CloseHandle(process);return 6;}
 unsigned found=0;
 for(unsigned sample=0;sample<160 && found<8;sample++){
  std::vector<uint64_t> addresses;DWORD previous=SuspendThread(thread);
  if(previous==DWORD(-1))break;
  if(!previous){CONTEXT ctx{};ctx.ContextFlags=CONTEXT_FULL;
   if(GetThreadContext(thread,&ctx)&&ctx.Rip==waitpc){
    STACKFRAME64 frame{};frame.AddrPC.Offset=ctx.Rip;frame.AddrPC.Mode=AddrModeFlat;frame.AddrFrame.Offset=ctx.Rbp;frame.AddrFrame.Mode=AddrModeFlat;frame.AddrStack.Offset=ctx.Rsp;frame.AddrStack.Mode=AddrModeFlat;
    addresses.push_back(ctx.Rip);
    for(unsigned level=0;level<24;level++){
     if(!StackWalk64(IMAGE_FILE_MACHINE_AMD64,process,thread,&frame,&ctx,nullptr,SymFunctionTableAccess64,SymGetModuleBase64,nullptr)||!frame.AddrPC.Offset)break;
     addresses.push_back(frame.AddrPC.Offset);
    }
   }
  }
  if(ResumeThread(thread)==DWORD(-1)){std::fprintf(stderr,"Failed to resume owned thread\n");return 7;}
  if(!addresses.empty()){
   std::printf("Unwound GPU fence stack %u\n",++found);
   for(auto pc:addresses){bool mapped=false;for(auto&m:modules)if(pc>=m.base&&pc-m.base<m.size){std::printf("%ls+0x%llX\n",m.name.c_str(),(unsigned long long)(pc-m.base));mapped=true;break;}if(!mapped)std::printf("unmapped 0x%llX\n",(unsigned long long)pc);}
  }
  Sleep(11);
 }
 SymCleanup(process);CloseHandle(thread);CloseHandle(process);
 std::printf("Finished: %u actual unwound fence-wait samples; no game memory writes.\n",found);return 0;
}
