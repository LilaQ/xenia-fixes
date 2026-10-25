/* Diagnostic RenderDoc API window, with no imports or persistent game hooks. */
typedef unsigned int U32;
typedef unsigned long long U64;
#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#define CALL __stdcall
#else
#define EXPORT
#define CALL
#endif
typedef struct Context {
 int (CALL *get_api)(int,void**);
 void (CALL *sleep_ms)(U32);
 volatile U32 state;
 U32 ended;
 void **api;
 int (CALL *counter)(U64*);
 U64 begin,end,frequency;
 U32 count_before,count_after,path_length,path_ok;
 char path[4096];
 U64 file_size;
} Context;
typedef void (CALL *Start)(void*,void*);
typedef U32 (CALL *Check)(void);
typedef U32 (CALL *End)(void*,void*);
typedef U32 (CALL *GetCapture)(U32,char*,U32*,U64*);
EXPORT U32 CALL CaptureWindow(Context *c) {
 if (!c || !c->frequency || !c->get_api || !c->counter || !c->sleep_ms) return 10;
 c->state=0;
 if(c->get_api(10400,(void**)&c->api)!=1 || !c->api) {c->state=2;return 2;}
 if(((Check)c->api[20])()) {c->state=7;return 7;}
 c->count_before=((Check)c->api[13])();
 if(!c->counter(&c->begin)) {c->state=10;return 10;}
 ((Start)c->api[19])(0,0);
 if(!((Check)c->api[20])()) {c->state=3;return 3;}
 if(!c->counter(&c->end) || c->end<c->begin || c->end-c->begin>=c->frequency) {
  ((End)c->api[24])(0,0);c->state=8;return 8;
 }
 c->state=1;
 U64 elapsed_ms=(c->end-c->begin)*1000/c->frequency;
 c->sleep_ms(1000-(U32)elapsed_ms);
 if(!c->counter(&c->end)) {((End)c->api[24])(0,0);c->state=10;return 10;}
 c->state=4;
 c->ended=((End)c->api[21])(0,0);
 if(!c->ended) {((End)c->api[24])(0,0);c->state=6;return 6;}
 c->count_after=((Check)c->api[13])();
 c->path_length=4096;
 c->path_ok=((GetCapture)c->api[14])(c->count_before,c->path,&c->path_length,0);
 if(!c->path_ok || c->count_after!=c->count_before+1) {c->state=9;return 9;}
 c->state=5;return 5;
}
#ifdef _WIN32
int CALL DllMain(void *module,U32 reason,void *reserved) {return 1;}
#endif
