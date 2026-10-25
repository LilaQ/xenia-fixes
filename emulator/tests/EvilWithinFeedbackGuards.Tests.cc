#include "xenia/gpu/resolve_feedback_guards.h"
#include <cassert>
using namespace xe::gpu::detail;
int main() {
 assert(IsEvilWithinTextureFeedback(0x425307F4,32768,32,128,37));
 assert(IsEvilWithinTextureFeedback(0x425307F4,32768,32,128,32));
 for(unsigned f=0;f<64;++f) if(f!=32&&f!=37)
  assert(!IsEvilWithinTextureFeedback(0x425307F4,32768,32,128,f));
 for(unsigned bit=0;bit<32;++bit)
  assert(!IsEvilWithinTextureFeedback(0x425307F4^(1U<<bit),32768,32,128,37));
 assert(IsEvilWithinTextureFeedback(0x425307F4,40960,160,64,6));
 for(unsigned f=0;f<64;++f) if(f!=6)
  assert(!IsEvilWithinTextureFeedback(0x425307F4,40960,160,64,f));
 assert(!IsEvilWithinTextureFeedback(0x425307F4,32768,160,64,6));
 assert(!IsEvilWithinTextureFeedback(0x425307F4,40960,32,128,6));
 assert(!IsEvilWithinTextureFeedback(0x425307F4,32764,32,128,37));
 assert(!IsEvilWithinTextureFeedback(0x425307F4,32768,64,64,37));
 assert(!IsEvilWithinTextureFeedback(0x425307F4,32768,32,64,37));
 assert(FeedbackAgeAllowed(100,100,20,20));
 assert(FeedbackAgeAllowed(100,80,20,16));
 assert(!FeedbackAgeAllowed(100,80,20,15));
 assert(!FeedbackAgeAllowed(100,101,20,20));
 assert(!FeedbackAgeAllowed(100,0,20,20));
 assert(!FeedbackAgeAllowed(100,80,20,21));
 assert(FeedbackAgeAllowed(100,80,1,0xFFFFFFFF));
}
