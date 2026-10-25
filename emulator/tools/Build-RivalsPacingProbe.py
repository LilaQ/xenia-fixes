from pathlib import Path
import argparse
import subprocess

parser = argparse.ArgumentParser(description="Build a Windows probe using the exact Xenia host-pacing method.")
parser.add_argument("source", type=Path, help="Xenia source checkout")
parser.add_argument("output", type=Path, help="Output .exe; run only on an authorized Windows test machine")
parser.add_argument("--cxx", required=True, help="Windows x86_64 MinGW C++ compiler")
args = parser.parse_args()
source=(args.source / 'src/xenia/gpu/command_processor.cc').read_text()
a=source.index('void CommandProcessor::ThrottlePresentation() {');b=source.index('\nvoid CommandProcessor::WorkerThreadMain()',a)
method=source[a:b]
prefix=r'''
#define XE_PLATFORM_WIN32 1
#define XE_PLATFORM_MAC 0
#include <windows.h>
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <vector>
#include <immintrin.h>
extern "C" LONG NTAPI NtDelayExecution(BOOLEAN,LARGE_INTEGER*);
extern "C" LONG NTAPI NtQueryTimerResolution(ULONG*,ULONG*,ULONG*);
extern "C" LONG NTAPI NtSetTimerResolution(ULONG,BOOLEAN,ULONG*);
namespace cvars { uint32_t framerate_limit=60; bool host_frame_pacing_precise=false; }
struct Clock {
 static uint64_t QueryGuestTickCount(){LARGE_INTEGER t;QueryPerformanceCounter(&t);return t.QuadPart;}
 static uint64_t guest_tick_frequency(){LARGE_INTEGER t;QueryPerformanceFrequency(&t);return t.QuadPart;}
};
namespace xe {
 inline void SpinPause(){_mm_pause();}
 namespace threading { void NanoSleep(int64_t ns){LARGE_INTEGER t;t.QuadPart=-(ns/100);NtDelayExecution(FALSE,&t);} }
}
struct CommandProcessor {uint64_t last_swap_time_=0;void ThrottlePresentation();};
'''
suffix=r'''
int main(){
 ULONG min,max,current;NtQueryTimerResolution(&min,&max,&current);
 if(NtSetTimerResolution(max,TRUE,&current)<0)return 2;
 for(int mode=0;mode<4;++mode){
  cvars::host_frame_pacing_precise=(mode==1||mode==2);
  bool before_present=(mode==2);
  CommandProcessor cp;cp.last_swap_time_=Clock::QueryGuestTickCount();
  std::vector<double> intervals;
  uint64_t prev=cp.last_swap_time_;int outside_half=0;
  for(int n=-20;n<240;++n){
   // Simulate waiting for other frame work before the real extracted pacer.
   xe::threading::NanoSleep(10000000+(n+20)%5*800000);
   if(before_present)cp.ThrottlePresentation();
   uint64_t now=Clock::QueryGuestTickCount();
   double ms=double(now-prev)*1000.0/Clock::guest_tick_frequency();prev=now;
   if(n>=0){intervals.push_back(ms);outside_half+=(ms<16.1666667||ms>17.1666667);}
   if(!before_present)cp.ThrottlePresentation();
  }
  std::sort(intervals.begin(),intervals.end());double sum=0;for(double x:intervals)sum+=x;
  std::cout<<(mode==2?"precise-before-present":mode==1?"precise-after-present":"original-after-present")<<" n="<<intervals.size()<<" avg="<<sum/intervals.size()<<" p5="<<intervals[11]<<" median="<<intervals[120]<<" p95="<<intervals[227]<<" max="<<intervals.back()<<" ms; outside +/-0.5ms="<<outside_half<<std::endl;
 }
 NtSetTimerResolution(max,FALSE,&current);
}
'''
cpp = args.output.with_suffix('.cpp')
cpp.write_text(prefix + method + suffix)
subprocess.run([args.cxx, '-O2', '-static', '-std=c++17', str(cpp), '-o', str(args.output), '-lntdll'], check=True)
print('Built pacing comparison probe:', args.output)
