using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public sealed class RiseWindowResult {
 public uint State, Before, After;
 public double Seconds;
 public ulong Bytes;
 public string Path;
}
public static class RiseWindowCapture {
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint rights,bool inherit,int pid);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr VirtualAllocEx(IntPtr p,IntPtr address,UIntPtr size,uint type,uint protect);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool VirtualFreeEx(IntPtr p,IntPtr address,UIntPtr size,uint type);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteProcessMemory(IntPtr p,IntPtr address,byte[] data,UIntPtr size,out UIntPtr written);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadProcessMemory(IntPtr p,IntPtr address,byte[] data,UIntPtr size,out UIntPtr read);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateRemoteThread(IntPtr p,IntPtr attributes,UIntPtr size,IntPtr start,IntPtr arg,uint flags,out uint id);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeThread(IntPtr thread,out uint code);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
 [DllImport("kernel32.dll",CharSet=CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr module,string name);
 [DllImport("kernel32.dll")] static extern bool QueryPerformanceFrequency(out long frequency);
 static void Check(bool ok,string what) {if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error(),what);}
 static IntPtr Native(Process target,string name) {
  IntPtr pointer=GetProcAddress(GetModuleHandle("kernel32.dll"),name);
  if(pointer==IntPtr.Zero)throw new Exception("Windows-Funktion fehlt: "+name);
  long address=pointer.ToInt64();
  using(Process own=Process.GetCurrentProcess()) {
   foreach(ProcessModule local in own.Modules) {
    long start=local.BaseAddress.ToInt64();
    if(address<start || address>=start+local.ModuleMemorySize)continue;
    foreach(ProcessModule remote in target.Modules)
     if(String.Equals(remote.ModuleName,local.ModuleName,StringComparison.OrdinalIgnoreCase))
      return new IntPtr(remote.BaseAddress.ToInt64()+address-start);
   }
  }
  throw new Exception("Windows-Modul im Zielprozess fehlt fuer "+name);
 }
 static IntPtr Allocate(IntPtr p,byte[] data) {
  IntPtr a=VirtualAllocEx(p,IntPtr.Zero,new UIntPtr((uint)data.Length),0x3000,4);
  Check(a!=IntPtr.Zero,"Diagnosespeicher anlegen");
  UIntPtr written;
  if(!WriteProcessMemory(p,a,data,new UIntPtr((uint)data.Length),out written) || written.ToUInt64()!=(ulong)data.Length) {
   VirtualFreeEx(p,a,UIntPtr.Zero,0x8000);throw new Win32Exception(Marshal.GetLastWin32Error(),"Diagnosedaten schreiben");
  }
  return a;
 }
 static byte[] Read(IntPtr p,IntPtr a,int size) {
  byte[] b=new byte[size];UIntPtr read;
  Check(ReadProcessMemory(p,a,b,new UIntPtr((uint)size),out read)&&read.ToUInt64()==(ulong)size,"Diagnosestatus lesen");return b;
 }
 static void Put(byte[] b,int offset,long value) {Array.Copy(BitConverter.GetBytes(value),0,b,offset,8);}
 static IntPtr Start(IntPtr p,IntPtr entry,IntPtr arg) {
  uint id;IntPtr t=CreateRemoteThread(p,IntPtr.Zero,UIntPtr.Zero,entry,arg,0,out id);
  Check(t!=IntPtr.Zero,"Aufnahmefunktion starten");return t;
 }
 static void Wait(IntPtr thread,int seconds,IntPtr p,IntPtr context,Action<string> progress) {
  Stopwatch timer=Stopwatch.StartNew();uint previous=UInt32.MaxValue;
  while(true) {
   uint r=WaitForSingleObject(thread,100);
   if(r==0)return;
   if(r!=258)throw new Win32Exception(Marshal.GetLastWin32Error(),"Aufnahmethread abwarten");
   if(context!=IntPtr.Zero) {
    uint state=BitConverter.ToUInt32(Read(p,context,24),16);
    if(state!=previous) {
     previous=state;
     if(state==1)progress("Zeitfenster aktiv.");
     else if(state==4)progress("Zeitfenster beendet. Speichere eine RDC-Datei ...");
    }
   }
   if(timer.Elapsed.TotalSeconds>seconds)throw new TimeoutException("Diagnosethread noch aktiv. Xenia normal beenden; Diagnose darf nicht erneut gestartet werden.");
  }
 }
 public static RiseWindowResult Run(int pid,string dll,string expectedRenderDoc,long apiRva,long captureRva,Action<string> progress) {
  if(IntPtr.Size!=8)throw new Exception("Bitte 64-Bit-PowerShell verwenden.");
  IntPtr p=IntPtr.Zero,path=IntPtr.Zero,context=IntPtr.Zero,thread=IntPtr.Zero;
  bool pending=false;IntPtr kit=IntPtr.Zero;
  using(Process target=Process.GetProcessById(pid)) {
   try {
    ProcessModule renderdoc=null;
    foreach(ProcessModule m in target.Modules)
     if(String.Equals(m.FileName,expectedRenderDoc,StringComparison.OrdinalIgnoreCase))renderdoc=m;
    if(renderdoc==null)throw new Exception("Dieser Spielstart laeuft nicht unter dem vorbereiteten RenderDoc. Bitte Rise-Start.cmd verwenden.");
    p=OpenProcess(0x43A,false,pid);Check(p!=IntPtr.Zero,"Xenia-Diagnosezugriff oeffnen");
    path=Allocate(p,Encoding.Unicode.GetBytes(dll+"\0"));
    thread=Start(p,Native(target,"LoadLibraryW"),path);pending=true;
    Wait(thread,60,p,IntPtr.Zero,progress);pending=false;CloseHandle(thread);thread=IntPtr.Zero;
    VirtualFreeEx(p,path,UIntPtr.Zero,0x8000);path=IntPtr.Zero;
    target.Refresh();
    foreach(ProcessModule m in target.Modules)
     if(String.Equals(m.FileName,dll,StringComparison.OrdinalIgnoreCase))kit=m.BaseAddress;
    if(kit==IntPtr.Zero)throw new Exception("Der Aufnahmehelfer konnte nicht in Xenia geladen werden.");
    long frequency;Check(QueryPerformanceFrequency(out frequency)&&frequency>0,"Zeitbasis abfragen");
    byte[] data=new byte[4184];
    Put(data,0,renderdoc.BaseAddress.ToInt64()+apiRva);
    Put(data,8,Native(target,"Sleep").ToInt64());
    Put(data,32,Native(target,"QueryPerformanceCounter").ToInt64());
    Put(data,56,frequency);
    context=Allocate(p,data);
    thread=Start(p,new IntPtr(kit.ToInt64()+captureRva),context);pending=true;
    Wait(thread,180,p,context,progress);pending=false;
    uint exit;Check(GetExitCodeThread(thread,out exit),"Aufnahmeergebnis abfragen");
    data=Read(p,context,4184);
    uint state=BitConverter.ToUInt32(data,16);
    if(state!=exit)throw new Exception("Inkonsistentes Aufnahmeergebnis.");
    if(state!=5)throw new Exception("Aufnahme abgebrochen, Status "+state+" (2=API, 3=Start, 6=Speichern, 7=bereits aktive Aufnahme, 8=Initialisierung laenger als eine Sekunde, 9=Dateiergebnis, 10=Zeitbasis).");
    int end=Array.IndexOf(data,(byte)0,80,4096);if(end<80)throw new Exception("Ungueltiger Aufnahmepfad.");
    return new RiseWindowResult {State=state,Before=BitConverter.ToUInt32(data,64),After=BitConverter.ToUInt32(data,68),Seconds=(BitConverter.ToUInt64(data,48)-BitConverter.ToUInt64(data,40))/(double)frequency,Bytes=BitConverter.ToUInt64(data,4176),Path=Encoding.UTF8.GetString(data,80,end-80)};
   } finally {
    if(thread!=IntPtr.Zero)CloseHandle(thread);
    if(!pending && p!=IntPtr.Zero) {
     if(path!=IntPtr.Zero)VirtualFreeEx(p,path,UIntPtr.Zero,0x8000);
     if(context!=IntPtr.Zero)VirtualFreeEx(p,context,UIntPtr.Zero,0x8000);
     // The tiny helper DLL remains loaded until Xenia exits; no hooks were installed.
    }
    if(p!=IntPtr.Zero)CloseHandle(p);
   }
  }
 }
}
