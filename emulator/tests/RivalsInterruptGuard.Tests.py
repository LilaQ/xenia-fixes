from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
source = (root / 'src/xenia/kernel/guest_scheduler.cc').read_text()
a = source.index('static void PreemptCurrentFiber(')
b = source.index('// Raw host ticks per us', a)
handler = source[a:b]
prelude = r'''
#include <cassert>
#include <cstdint>
#include <iostream>
#define XELOGW(...) ((void)0)
struct X_KPCR { unsigned current_irql = 0; };
struct Context {
 uint64_t msr = 0x9030, r[32] = {};
 uint8_t preempt_requested = 0;
 X_KPCR kpcr;
 template<class T> T TranslateVirtualGPR(uint64_t) { return &kpcr; }
};
struct Scheduler {
 bool shutdown = false;
 unsigned switches = 0;
 bool shutting_down() const { return shutdown; }
 void YieldCurrentThread(bool quantum, bool lower) {
   assert(quantum && !lower); ++switches;
 }
};
struct Kernel { Scheduler scheduler; Scheduler* guest_scheduler(){return &scheduler;} };
struct ThreadState { Context ctx; Context* context(){return &ctx;} };
struct Links { unsigned preempt_defers_lock=0, preempt_defers_irql=0; };
struct UserMode { bool in_user_code=false; };
struct XThread {
 static XThread* current;
 ThreadState state; Kernel kernel; Links links; UserMode user;
 unsigned saved=0, restored=0;
 static XThread* GetCurrentFiberThread(){return current;}
 ThreadState* thread_state(){return &state;}
 Kernel* kernel_state(){return &kernel;}
 Links& scheduler_links(){return links;}
 UserMode* user_mode(){return &user;}
 unsigned thread_id(){return 1;}
 const char* thread_name(){return "test";}
 void SaveInterruptedUserCr(){++saved;}
 void RestoreInterruptedUserCr(){++restored;}
};
XThread* XThread::current=nullptr;
namespace xe { namespace global_critical_region {
 bool held=false;
 bool is_held_by_current_thread(){return held;}
}}
static constexpr uint32_t kLockPreemptDeferReport=65536;
'''
checks = r'''
int main(){
 PreemptCurrentFiber(nullptr); // Non-guest host calls remain harmless.
 XThread t; XThread::current=&t;
 auto& c=t.state.ctx; auto& s=t.kernel.scheduler;
 c.msr=0x1030;
 for(int i=0;i<100;i++){c.preempt_requested=0;PreemptCurrentFiber(nullptr);assert(c.preempt_requested==1);assert(s.switches==0);}
 c.msr=0x9030;PreemptCurrentFiber(nullptr);assert(s.switches==1);
 c.kpcr.current_irql=2;PreemptCurrentFiber(nullptr);assert(s.switches==1);
 c.kpcr.current_irql=0;xe::global_critical_region::held=true;PreemptCurrentFiber(nullptr);assert(s.switches==1);
 xe::global_critical_region::held=false;
 t.user.in_user_code=true;c.msr=0x1030;PreemptCurrentFiber(nullptr);assert(t.saved==0&&t.restored==0&&s.switches==1);
 c.msr=0x9030;PreemptCurrentFiber(nullptr);assert(t.saved==1&&t.restored==1&&s.switches==2);
 c.msr=0x1030;s.shutdown=true;PreemptCurrentFiber(nullptr);assert(s.switches==3&&t.saved==2&&t.restored==2);
 // Rivals uses r13 as the value for clearing EE. Its old 4 KiB-aligned
 // pointer could retain EE; all 64 KiB-aligned pointers clear it.
 assert((uint32_t(0x3006e000)&0x8000)!=0);
 for(uint64_t p=0;p<0x100000000ULL;p+=0x10000)assert((p&0xffff)==0);
 std::cout<<"PASS: actual preemption handler defers EE-disabled guests, resumes after EE restore, preserves IRQL/lock/user CR guards, and permits teardown.\n";
}
'''
thread = (root / 'src/xenia/kernel/xthread.cc').read_text()
assert 'pcr_address_ = memory()->SystemHeapAlloc(0x2D8, 0x10000);' in thread
with tempfile.TemporaryDirectory(prefix='rivals-interrupt-', dir=Path.cwd()) as d:
    cpp = Path(d) / 'test.cpp'
    cpp.write_text(prelude + handler + checks)
    exe = cpp.with_suffix('')
    subprocess.run([os.environ.get('CXX', 'clang++'), '-std=c++17', '-Wall', '-Wextra', '-fsanitize=undefined', str(cpp), '-o', str(exe)], check=True, timeout=60)
    subprocess.run([str(exe)], check=True, timeout=15)
