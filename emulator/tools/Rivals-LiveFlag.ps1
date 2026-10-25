param([ValidateSet('StageReadback','DrawTiming','TextureLoads','TextureTiming','FramePacing','AtlasGpu')][string]$Flag,[bool]$Enabled)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$owned=@(Get-CimInstance Win32_Process -Filter "Name='xenia_rivals_trace.exe'" | Where-Object {$_.CommandLine -like '*Rivals\runtime\work\storage*'})
if($owned.Count -ne 1){throw 'Expected exactly one owned Rivals diagnostic process.'}
$hash=(Get-FileHash -LiteralPath $owned[0].ExecutablePath -Algorithm SHA256).Hash
$offsets=switch($hash){
 'E5C29A1CB7E2A7158AB550AAB6CE53D6860593557050DCBC45019F16A20362F4' {
  @{TextureLoads=43015005;StageReadback=43015272;DrawTiming=43015002;TextureTiming=43015264;FramePacing=43015268}
 }
 'A2B4B71A25EBF3FFDE230975FD2C932D9A6EB9E27D6F32A3757968A50B70616D' {
  @{TextureLoads=43023213;StageReadback=43023480;DrawTiming=43023210;TextureTiming=43023472;FramePacing=43023476;AtlasGpu=43023634}
 }
 default {throw 'Rivals binary changed; no runtime write.'}
}
if(-not $offsets.ContainsKey($Flag)){throw 'This verified build does not contain the requested comparison.'}
$process=Get-Process -Id $owned[0].ProcessId
if(-not('RivalsBoundedFlagV1' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RivalsBoundedFlagV1 {
 [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr p);
 [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p,IntPtr a,byte[] b,UIntPtr n,out UIntPtr done);
 [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p,IntPtr a,byte[] b,UIntPtr n,out UIntPtr done);
 public static bool Set(uint pid,long address,bool enabled){
  IntPtr p=OpenProcess(0x38,false,pid);if(p==IntPtr.Zero)throw new Exception("Cannot open owned Rivals process.");
  try{byte[] b=new byte[1];UIntPtr done;IntPtr a=new IntPtr(address);
   if(!ReadProcessMemory(p,a,b,(UIntPtr)1,out done)||done.ToUInt64()!=1||b[0]>1)throw new Exception("Unexpected runtime bool.");
   byte old=b[0],value=(byte)(enabled?1:0);b[0]=value;
   if(!WriteProcessMemory(p,a,b,(UIntPtr)1,out done)||done.ToUInt64()!=1)throw new Exception("Cannot update runtime bool.");
   if(!ReadProcessMemory(p,a,b,(UIntPtr)1,out done)||done.ToUInt64()!=1||b[0]!=value){WriteProcessMemory(p,a,new byte[]{old},(UIntPtr)1,out done);throw new Exception("Runtime bool verification failed; rollback attempted.");}
   return old!=0;
  }finally{CloseHandle(p);}
 }
}
'@
}
$old=[RivalsBoundedFlagV1]::Set([uint32]$process.Id,$process.MainModule.BaseAddress.ToInt64()+[long]$offsets[$Flag],$Enabled)
Write-Output ('Owned Rivals '+$Flag+': '+$old+' -> '+$Enabled+'. Game clocks and coherent readback remain unchanged.')
