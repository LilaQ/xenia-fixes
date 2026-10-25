#include <assert.h>
#include <string.h>
#include <stdio.h>
#include "capture.c"
static void *api[27];static U64 ticks;static U32 capturing,count,discarded,saves,api_ok=1,start_ok=1,end_ok=1;static U64 setup;
static int get_api(int version,void**p){assert(version==10400);*p=api;return api_ok;}
static int counter(U64*p){*p=ticks;return 1;}
static void sleep_ms(U32 n){assert(capturing && saves==0);ticks+=(U64)n*10000;}
static void start(void*a,void*b){assert(!a&&!b);ticks+=setup;capturing=start_ok;}
static U32 active(void){return capturing;}
static U32 end(void*a,void*b){assert(!a&&!b);++saves;ticks+=50000000;capturing=0;if(end_ok)++count;return end_ok;}
static U32 discard(void*a,void*b){++discarded;capturing=0;return 1;}
static U32 num(void){return count;}
static U32 file(U32 i,char*p,U32*n,U64*t){assert(i==count-1);strcpy(p,"D:\\Rise_frame.rdc");*n=18;return 1;}
static Context fresh(void){Context c={0};c.get_api=get_api;c.sleep_ms=sleep_ms;c.counter=counter;c.frequency=10000000;ticks=0;capturing=0;count=0;discarded=0;saves=0;setup=0;api_ok=1;start_ok=1;end_ok=1;return c;}
int main(void){
 api[13]=num;api[14]=file;api[19]=start;api[20]=active;api[21]=end;api[24]=discard;
 for(int i=0;i<4;i++){Context c=fresh();setup=(U64)i*2500000;assert(CaptureWindow(&c)==5);assert(c.end-c.begin==10000000);assert(saves==1 && discarded==0 && c.count_after-c.count_before==1);}
 Context c=fresh();setup=10000001;assert(CaptureWindow(&c)==8 && discarded==1 && saves==0);
 c=fresh();api_ok=0;assert(CaptureWindow(&c)==2 && saves==0);
 c=fresh();capturing=1;assert(CaptureWindow(&c)==7 && saves==0);
 c=fresh();start_ok=0;assert(CaptureWindow(&c)==3 && saves==0);
 c=fresh();end_ok=0;assert(CaptureWindow(&c)==6 && discarded==1);
 assert(sizeof(Context)==4184);
 puts("PASS: one-second window including setup; one save; slow-start discard; API/start/end failure paths; existing capture guard; context layout.");
}
