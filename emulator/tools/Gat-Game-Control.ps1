param([string]$Root=$env:GAT_TRACE_DIR,[switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
# Reuse the existing Gat-View command channel for the scoped Rivals session.
if(-not $FunctionsOnly){
 $rivalsRequest=[IO.File]::ReadAllText((Join-Path $Root 'runtime\replay.request'))
 if($rivalsRequest -match '^game:[0-9a-f]{32}:rivals-'){
  & (Join-Path $PSScriptRoot 'Rivals-Control.ps1') -TraceRoot $Root
  return
 }
}

function Read-GatGameCommand([string]$Text) {
 if($Text -notmatch '^game:([0-9a-f]{32}):(launch|launch-depth|launch-release|launch-stages|launch-pitch|launch-stencilcopy|launch-no-msaa|launch-hdr-async|launch-sr4|launch-sr3|launch-queries|launch-unlimited|launch-vulkan|launch-stock|snapshot|capture|sample|readback-on|readback-off|async-hdr-on|async-hdr-off|present-ui|present-direct|present-window|gpu|layout|frames|frames-spin|stop|A|B|Y|Start|Back|Up|Down|Left|Right|MoveForward|MoveBackward|StrafeLeft|StrafeRight|CameraLeft|CameraRight)(?::([0-9]{1,4}))?$'){
  throw 'Invalid game-test request.'
 }
 $duration=if($Matches[3]){[int]$Matches[3]}else{150}
 if($duration -lt 20 -or $duration -gt 5000){throw 'Input duration must be 20..5000 ms.'}
 [pscustomobject]@{Id=$Matches[1];Action=$Matches[2];Milliseconds=$duration}
}

function Read-GatGameRequest([string]$Path) {
 try {
  $text=[IO.File]::ReadAllText($Path)
  $null=Read-GatGameCommand $text
  return $text
 } catch {
  # SMB replacement and truncation may expose a missing or empty file briefly.
  # It is not a command, and must never terminate the owned game session.
  return $null
 }
}

function Set-GatScenePatch([string]$Source,[string]$Destination,[bool]$Enabled) {
 if(-not $Enabled){if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Force};return}
 if(-not(Test-Path -LiteralPath $Source -PathType Leaf) -or (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -notin @('245C7A214A117E1FC09C841CE0EBB0E873CBD9B4BEBE8817705BABB100D85BB3','1DF63DFFF693136D48D2D1562B8267FD1D20CDC921C7B8C7037EFDB360FC6A52','72D8ED484E648F8660ABDFB4B007932DAEEACE597C2B549987D6810DDC28487D')){throw 'Missing or unverified single-sample scene patch.'}
 Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Add-SaintsTitlePackages([string]$Source,[string]$Destination) {
 if(-not(Test-Path -LiteralPath $Source -PathType Container)){throw 'Installed title packages are missing.'}
 foreach($item in @(Get-ChildItem -LiteralPath $Source -Recurse -Force)){
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected reparse point in title packages.'}
  if($item.PSIsContainer){continue}
  $relative=$item.FullName.Substring($Source.TrimEnd('\','/').Length).TrimStart('\','/')
  $target=Join-Path $Destination $relative
  $null=New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
  if(-not(Test-Path -LiteralPath $target)){$null=New-Item -ItemType HardLink -Path $target -Target $item.FullName}
 }
}

function New-GatGameArguments([string]$Config,[string]$Storage,[string]$Content,[string]$Log,[string]$Game) {
 foreach($path in @($Config,$Storage,$Content,$Log,$Game)){
  if(-not $path -or $path.Contains('"')){throw 'Invalid game-test path.'}
 }
 '--config="{0}" --storage_root="{1}" --content_root="{2}" --log_file="{3}" --render_target_path=performance --d3d12_snorm16_multiply_scale=true --snorm16_render_target_full_range=true --d3d12_skip_no_output_draws=true --d3d12_submission_timing=true --d3d12_draw_timing=false --profiler_on_demand=true --fullscreen=true "{4}"' -f $Config,$Storage,$Content,$Log,$Game
}

function Move-GatFinishedScreenshot([string]$Source,[string]$Destination) {
 # The PNG appears before Xenia's writer closes it. Never remove a previous
 # image in order to rename a still-open file; use a unique destination.
 for($attempt=0;$attempt -lt 50;$attempt++){
  try {
   $stream=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
   try{$ready=$stream.Length -gt 0}finally{$stream.Dispose()}
   if($ready){Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop;return $true}
  }catch{}
  Start-Sleep -Milliseconds 100
 }
 return $false
}

function Invoke-GatCpuSample([Diagnostics.Process]$Process,[string]$Log) {
 $frontends=@(Get-Process -Name 'LaunchBox','BigBox','Keys2Pad' -ErrorAction SilentlyContinue)
 Write-Host ('Frontend/input processes during owned test: '+$frontends.Count)
 if(-not ('GatCpuSamplerV14' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
public static class GatCpuSamplerV14 {
 [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access,bool inherit,uint id);
 [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access,bool inherit,uint id);
 [DllImport("kernel32.dll")] static extern uint SuspendThread(IntPtr thread);
 [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll")] static extern bool GetThreadContext(IntPtr thread,IntPtr context);
 [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr process,IntPtr address,byte[] buffer,UIntPtr size,out UIntPtr read);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr process,IntPtr address,byte[] buffer,UIntPtr size,out UIntPtr written);
 public sealed class Row {public uint Thread; public ulong Address; public bool Stack; public int Count;}
 public sealed class JitMapping {public uint Guest;public uint Entry;public ulong PC;public int Hits;public string HostCode,GuestCode;}
 static byte[] ReadBytes(IntPtr process,ulong address,int size) {
  byte[] data=new byte[size];UIntPtr read;
  if(!ReadProcessMemory(process,new IntPtr(checked((long)address)),data,(UIntPtr)size,out read)||read.ToUInt64()!=(ulong)size)return null;
  return data;
 }
 public static JitMapping[] Map(uint processId,Row[] rows,ulong guestMemoryBase) {
  var hot=new List<Row>();foreach(var row in rows)if(!row.Stack&&row.Address>=0xA0000000UL&&row.Address<0xC0000000UL)hot.Add(row);
  hot.Sort(delegate(Row a,Row b){return b.Count.CompareTo(a.Count);});
  if(hot.Count>16)hot.RemoveRange(16,hot.Count-16);
  if(hot.Count==0)return new JitMapping[0];
  IntPtr process=OpenProcess(0x10,false,processId);
  if(process==IntPtr.Zero)throw new InvalidOperationException("Cannot read owned JIT table.");
  try {
   // CodeCacheBase's fast dispatch table: host slot VA equals guest address,
   // with a little-endian 32-bit generated-code target. Scan only this XEX's
   // bounded address window; uncommitted table pages are skipped.
   var entries=new Dictionary<uint,uint>();byte[] page=new byte[4096];
   for(ulong address=0x82000000UL;address<0x83200000UL;address+=4096){
    UIntPtr read;if(!ReadProcessMemory(process,new IntPtr((long)address),page,(UIntPtr)4096,out read)||read.ToUInt64()!=4096)continue;
    for(int offset=0;offset<4096;offset+=4){uint target=BitConverter.ToUInt32(page,offset);
     if(target>=0xA0000000U&&target<0xC0000000U&&!entries.ContainsKey(target))entries.Add(target,(uint)address+(uint)offset);
    }
   }
   var targets=new List<uint>(entries.Keys);targets.Sort();
   var result=new List<JitMapping>();var seen=new Dictionary<uint,JitMapping>();
   foreach(var row in hot){
    int low=0,high=targets.Count;
    while(low<high){int mid=low+(high-low)/2;if(targets[mid]<=row.Address)low=mid+1;else high=mid;}
    if(low==0)continue;uint entry=targets[low-1];
    if(row.Address-entry>65536)continue;
    JitMapping mapped;if(seen.TryGetValue(entry,out mapped)){mapped.Hits+=row.Count;continue;}
    byte[] host=ReadBytes(process,entry,256);uint guest=entries[entry];byte[] code=ReadBytes(process,checked(guestMemoryBase+guest),256);
    if(host==null||code==null)continue;
    mapped=new JitMapping{Guest=guest,Entry=entry,PC=row.Address,Hits=row.Count,HostCode=BitConverter.ToString(host).Replace("-",""),GuestCode=BitConverter.ToString(code).Replace("-","")};
    seen.Add(entry,mapped);result.Add(mapped);
   }
   return result.ToArray();
  } finally {CloseHandle(process);}
 }
 public static byte SetSmallReadback(uint processId,ulong imageBase,bool enabled) {
  IntPtr process=OpenProcess(0x38,false,processId);
  if(process==IntPtr.Zero)throw new InvalidOperationException("Cannot set owned snapshot experiment.");
  ulong address=checked(imageBase+0x28FBBFCUL);
  try {
   byte[] original=ReadBytes(process,address,1);UIntPtr written;
   if(original==null||original[0]>1)throw new InvalidOperationException("Unexpected small-readback bool.");
   byte value=enabled?(byte)1:(byte)0;
   if(!WriteProcessMemory(process,new IntPtr((long)address),new byte[]{value},(UIntPtr)1,out written)||written.ToUInt64()!=1)throw new InvalidOperationException("Cannot set small-readback bool.");
   byte[] actual=ReadBytes(process,address,1);
   if(actual==null||actual[0]!=value)throw new InvalidOperationException("Small-readback bool verification failed.");
   return original[0];
  } finally {CloseHandle(process);}
 }
 public static byte SetAsyncHdr(uint processId,ulong imageBase,bool enabled) {
  IntPtr process=OpenProcess(0x38,false,processId);
  if(process==IntPtr.Zero)throw new InvalidOperationException("Cannot set owned async HDR comparison.");
  ulong address=checked(imageBase+0x28FBB2BUL);
  try {
   byte[] original=ReadBytes(process,address,1);UIntPtr written;
   if(original==null||original[0]>1)throw new InvalidOperationException("Unexpected async HDR bool.");
   byte value=enabled?(byte)1:(byte)0;
   if(!WriteProcessMemory(process,new IntPtr((long)address),new byte[]{value},(UIntPtr)1,out written)||written.ToUInt64()!=1)throw new InvalidOperationException("Cannot set async HDR bool.");
   byte[] actual=ReadBytes(process,address,1);
   if(actual==null||actual[0]!=value)throw new InvalidOperationException("Async HDR bool verification failed.");
   return original[0];
  } finally {CloseHandle(process);}
 }
 public static byte SetHostPresent(uint processId,ulong imageBase,bool enabled) {
  return SetFrameBool(processId,checked(imageBase+0x2893598UL),enabled);
 }
 static byte SetFrameBool(uint processId,ulong address,bool enabled) {
  IntPtr process=OpenProcess(0x38,false,processId);
  if(process==IntPtr.Zero)throw new InvalidOperationException("Cannot set owned presentation bool.");
  try {
   byte[] original=ReadBytes(process,address,1);UIntPtr written;
   if(original==null||original[0]>1)throw new InvalidOperationException("Unexpected presentation bool.");
   byte value=enabled?(byte)1:(byte)0;
   if(!WriteProcessMemory(process,new IntPtr((long)address),new byte[]{value},(UIntPtr)1,out written)||written.ToUInt64()!=1)throw new InvalidOperationException("Cannot set presentation bool.");
   byte[] actual=ReadBytes(process,address,1);
   if(actual==null||actual[0]!=value)throw new InvalidOperationException("Presentation bool verification failed.");
   return original[0];
  } finally {CloseHandle(process);}
 }
 public static void MeasurePresentWindow(uint processId,ulong imageBase) {
  ulong address=checked(imageBase+0x28FBBC3UL);
  byte previous=SetFrameBool(processId,address,true);
  try {Thread.Sleep(18000);}
  finally {SetFrameBool(processId,address,previous!=0);}
 }
 // Only the exact verified timing/statistics bools are writable here.
 // No guest code, rendering options or persisted configuration changes.
 public static void MeasureGpuWindow(uint processId,ulong imageBase) {
  IntPtr process=OpenProcess(0x38,false,processId);
  if(process==IntPtr.Zero)throw new InvalidOperationException("Cannot enable owned diagnostic window.");
  ulong[] addresses={checked(imageBase+0x28FBBC3UL),checked(imageBase+0x28FBB5BUL),checked(imageBase+0x28FBAFAUL),checked(imageBase+0x28FBB24UL)};
  byte[] original=new byte[addresses.Length];bool[] changed=new bool[addresses.Length];
  try {
   for(int i=0;i<addresses.Length;i++){
    byte[] value=ReadBytes(process,addresses[i],1);UIntPtr written;
    if(value==null||value[0]>1)throw new InvalidOperationException("Unexpected diagnostic bool.");
    original[i]=value[0];
    if(value[0]==0){
     if(!WriteProcessMemory(process,new IntPtr((long)addresses[i]),new byte[]{1},(UIntPtr)1,out written)||written.ToUInt64()!=1)throw new InvalidOperationException("Cannot enable diagnostic bool.");
     changed[i]=true;
    }
   }
   Thread.Sleep(6500);
  } finally {
   Exception failure=null;
   for(int i=addresses.Length-1;i>=0;i--){
    if(!changed[i])continue;
    try {
     UIntPtr written;
     if(!WriteProcessMemory(process,new IntPtr((long)addresses[i]),new byte[]{original[i]},(UIntPtr)1,out written)||written.ToUInt64()!=1)throw new InvalidOperationException("Cannot restore diagnostic bool.");
     byte[] restored=ReadBytes(process,addresses[i],1);
     if(restored==null||restored[0]!=original[i])throw new InvalidOperationException("Diagnostic restoration mismatch.");
    } catch(Exception error){if(failure==null)failure=error;}
   }
   CloseHandle(process);
   if(failure!=null)throw failure;
  }
 }
 public static Row[] Sample(uint processId,uint[] threadIds,ulong imageBase,ulong imageSize) {
  var rows=new List<Row>();
  IntPtr process=OpenProcess(0x10,false,processId);
  if(process==IntPtr.Zero)throw new InvalidOperationException("Cannot read owned test process.");
  try {
   foreach(uint id in threadIds){
    IntPtr thread=OpenThread(0x000A,false,id);
    if(thread==IntPtr.Zero)continue;
    IntPtr allocation=Marshal.AllocHGlobal(0x4D0+15);
    IntPtr context=new IntPtr((allocation.ToInt64()+15)&~15L);
    var pcs=new Dictionary<ulong,int>();var callers=new Dictionary<ulong,int>();
    byte[] stack=new byte[512];
    try {
     for(int sample=0;sample<200;sample++){
      bool suspended=false;
      try {
       uint previous=SuspendThread(thread);
       if(previous==UInt32.MaxValue)continue;
       suspended=true;
       if(previous!=0)continue;
       Marshal.WriteInt32(context,0x30,0x100001);
       if(!GetThreadContext(thread,context))continue;
       ulong pc=unchecked((ulong)Marshal.ReadInt64(context,0xF8));
       int count;pcs.TryGetValue(pc,out count);pcs[pc]=count+1;
       IntPtr sp=new IntPtr(Marshal.ReadInt64(context,0x98));UIntPtr read;
       if(ReadProcessMemory(process,sp,stack,(UIntPtr)stack.Length,out read)){
        var unique=new HashSet<ulong>();
        for(int offset=0;offset+8<=(int)read.ToUInt64();offset+=8){
         ulong address=BitConverter.ToUInt64(stack,offset);
         if(address>=imageBase&&address-imageBase<imageSize&&unique.Add(address)){
          callers.TryGetValue(address,out count);callers[address]=count+1;
         }
        }
       }
      } finally {if(suspended)ResumeThread(thread);}
      Thread.Sleep(10);
     }
    } finally {Marshal.FreeHGlobal(allocation);CloseHandle(thread);}
    foreach(var row in pcs)rows.Add(new Row{Thread=id,Address=row.Key,Count=row.Value});
    foreach(var row in callers)rows.Add(new Row{Thread=id,Address=row.Key,Count=row.Value,Stack=true});
   }
  } finally {CloseHandle(process);}
  return rows.ToArray();
 }
}
'@
 }
 $before=@{}
 $Process.Refresh()
 foreach($thread in $Process.Threads){try{$before[$thread.Id]=$thread.TotalProcessorTime.Ticks}catch{}}
 Start-Sleep -Milliseconds 1000
 $Process.Refresh()
 $active=@(foreach($thread in $Process.Threads){
  try{if($before.ContainsKey($thread.Id)){
   [pscustomobject]@{Id=[uint32]$thread.Id;Ticks=$thread.TotalProcessorTime.Ticks-$before[$thread.Id]}
  }}catch{}
 }) | Sort-Object Ticks -Descending | Select-Object -First 3
 $module=$Process.MainModule
 $modules=@($Process.Modules)
 Write-Host ('Owned CPU sample: image=0x'+$module.BaseAddress.ToInt64().ToString('X')+'; bytes='+$module.ModuleMemorySize)
 foreach($thread in $active){Write-Host ('CPU thread '+$thread.Id+': '+($thread.Ticks/10000.0)+' ms in preceding second')}
 $rows=[GatCpuSamplerV14]::Sample([uint32]$Process.Id,[uint32[]]@($active.Id),[uint64]$module.BaseAddress.ToInt64(),[uint64]$module.ModuleMemorySize)
 foreach($thread in $active){
  foreach($stack in @($false,$true)){
   foreach($row in @($rows | Where-Object {$_.Thread -eq $thread.Id -and $_.Stack -eq $stack} | Sort-Object Count -Descending | Select-Object -First 20)){
    $location='unmapped/JIT'
    foreach($m in $modules){$base=[uint64]$m.BaseAddress.ToInt64();if($row.Address -ge $base -and $row.Address-$base -lt $m.ModuleMemorySize){$location=$m.ModuleName+'+0x'+($row.Address-$base).ToString('X');break}}
    $kind=if($stack){'stack candidate'}else{'PC'}
    Write-Host ('CPU sample: tid='+$row.Thread+'; '+$kind+'; hits='+$row.Count+'; address=0x'+$row.Address.ToString('X')+'; '+$location)
   }
  }
 }
 $stream=[IO.File]::Open($Log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 $reader=New-Object IO.StreamReader($stream)
 try{$text=$reader.ReadToEnd()}finally{$reader.Dispose();$stream.Dispose()}
 if($text -notmatch 'virtual membase 0x([0-9A-Fa-f]+)'){throw 'Missing verified guest mapping for JIT inspection.'}
 $membase=[Convert]::ToUInt64($Matches[1],16)
 $mapped=[GatCpuSamplerV14]::Map([uint32]$Process.Id,$rows,$membase)
 foreach($item in $mapped){
  Write-Host ('JIT candidate: guest=0x'+$item.Guest.ToString('X8')+'; host=0x'+$item.Entry.ToString('X8')+'; pc=0x'+$item.PC.ToString('X')+'; hits='+$item.Hits)
  Write-Host ('JIT host bytes: '+$item.HostCode)
  Write-Host ('JIT guest bytes: '+$item.GuestCode)
 }
 Write-Host ('Direct-table JIT candidates: '+$mapped.Count+'. Confirm instruction boundaries against guest bytes; no game memory was changed.')
 Write-Host 'Stack candidates are raw stack words, not an unwound call stack. No game memory was changed.'
 # The RVA belongs only to the exact privately built and tested probe binary.
 if($module.ModuleName -eq 'xenia_edge_gat.exe' -and
    (Get-FileHash -LiteralPath $module.FileName -Algorithm SHA256).Hash -eq '99244AB2D4ED7805B97D4DE63B2968EF800A69F15E24CB715C81CB00D72518C3'){
  Write-Host 'Owned GPU timestamp window: 6.5 s; rendering and guest code unchanged.'
  [GatCpuSamplerV14]::MeasureGpuWindow([uint32]$Process.Id,[uint64]$module.BaseAddress.ToInt64())
  Write-Host 'Owned GPU timestamp window complete; previous instrumentation values restored.'
  Write-Host 'Owned presentation timing window: 18 s; hardware draw instrumentation off.'
  [GatCpuSamplerV14]::MeasurePresentWindow([uint32]$Process.Id,[uint64]$module.BaseAddress.ToInt64())
  Write-Host 'Owned presentation timing window complete; previous instrumentation restored.'
 }
}

function Measure-GatFrames([Diagnostics.Process]$Process,[int]$Milliseconds) {
 $counterRva=switch($Process.MainModule.ModuleName){
  'xenia_edge_gat.exe'{0x28F0A38}
  'xenia_edge_sr4.exe'{0x28F0A40}
  'xenia_edge_sr3.exe'{0x28F0A48}
  'xenia_edge.exe'{0x222DD00}
  default{throw 'No verified frame counter for this test executable.'}
 }
 if(-not ('GatFrameCounterV3' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public static class GatFrameCounterV3 {
 [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr process,IntPtr address,byte[] buffer,UIntPtr size,out UIntPtr read);
 [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint period);
 [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint period);
 public sealed class Result {public uint Frames;public double Seconds,FPS,P50,P95,Maximum,PollMilliseconds;public int ObservedIntervals,MissedFrames;}
 static uint Read(IntPtr process,IntPtr address,byte[] value) {
  UIntPtr count;
  if(!ReadProcessMemory(process,address,value,(UIntPtr)4,out count)||count.ToUInt64()!=4)throw new InvalidOperationException("Cannot read owned frame counter.");
  return BitConverter.ToUInt32(value,0);
 }
 public static Result Summarize(uint frames,double seconds,double[] intervals,int missed) {
  if(seconds<=0)throw new ArgumentOutOfRangeException("seconds");
  double[] sorted=(double[])intervals.Clone();Array.Sort(sorted);
  var result=new Result{Frames=frames,Seconds=seconds,FPS=frames/seconds,ObservedIntervals=sorted.Length,MissedFrames=missed};
  if(sorted.Length>0){result.P50=sorted[(int)Math.Ceiling(sorted.Length*.5)-1];result.P95=sorted[(int)Math.Ceiling(sorted.Length*.95)-1];result.Maximum=sorted[sorted.Length-1];}
  return result;
 }
 public static Result Measure(IntPtr process,IntPtr address,int milliseconds) {
  if(milliseconds<20||milliseconds>5000)throw new ArgumentOutOfRangeException("milliseconds");
  byte[] value=new byte[4];uint first=Read(process,address,value),last=first;bool completeInterval=false;
  var timer=Stopwatch.StartNew();long lastTick=0;int missed=0;var intervals=new List<double>();
  bool precise=timeBeginPeriod(1)==0;int polls=0;
  try {
  while(timer.ElapsedMilliseconds<milliseconds){
   Thread.Sleep(1);uint current=Read(process,address,value);long now=timer.ElapsedTicks;polls++;
   if(current<last)throw new InvalidOperationException("Owned frame counter reset during measurement.");
   if(current==last)continue;
   uint delta=current-last;
   if(delta==1&&completeInterval)intervals.Add((now-lastTick)*1000.0/Stopwatch.Frequency);
   else if(delta>1)missed+=checked((int)delta-1);
   last=current;lastTick=now;completeInterval=true;
  }
  } finally {if(precise)timeEndPeriod(1);}
  timer.Stop();var result=Summarize(last-first,timer.Elapsed.TotalSeconds,intervals.ToArray(),missed);
  result.PollMilliseconds=timer.Elapsed.TotalMilliseconds/Math.Max(1,polls);return result;
 }
}
'@
 }
 # xe::global_frame_number_, verified with llvm-nm and the getter's RIP-relative load.
 $address=[IntPtr]($Process.MainModule.BaseAddress.ToInt64()+$counterRva)
 $result=[GatFrameCounterV3]::Measure($Process.Handle,$address,$Milliseconds)
 Write-Host ('Owned frame counter: '+$result.Frames+' frames in '+$result.Seconds.ToString('F3')+' s; FPS='+$result.FPS.ToString('F2'))
 Write-Host ('Observed command-frame intervals: n='+$result.ObservedIntervals+'; median='+$result.P50.ToString('F2')+' ms; p95='+$result.P95.ToString('F2')+' ms; max='+$result.Maximum.ToString('F2')+' ms; missed counter transitions='+$result.MissedFrames+'; actual polling='+$result.PollMilliseconds.ToString('F2')+' ms (not presentation timestamps)')
}

function Show-GatRenderLayout([Diagnostics.Process]$Process,[string]$Log) {
 if(-not ('GatRenderLayoutReadV2' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GatRenderLayoutReadV2 {
 [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr process,IntPtr address,byte[] buffer,UIntPtr size,out UIntPtr read);
 public static uint Read(IntPtr process,ulong membase,uint guest) {
  if(guest<0x00010000||guest>0xBFFFFFFB)throw new InvalidOperationException("Invalid render-layout pointer.");
  byte[] value=new byte[4];UIntPtr count;
  if(!ReadProcessMemory(process,new IntPtr(checked((long)(membase+guest))),value,(UIntPtr)4,out count)||count.ToUInt64()!=4)throw new InvalidOperationException("Cannot read owned render layout.");
  return ((uint)value[0]<<24)|((uint)value[1]<<16)|((uint)value[2]<<8)|value[3];
 }
}
'@
 }
 $stream=[IO.File]::Open($Log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 $reader=New-Object IO.StreamReader($stream)
 try{$text=$reader.ReadToEnd()}finally{$reader.Dispose();$stream.Dispose()}
 if($text -notmatch 'virtual membase 0x([0-9A-Fa-f]+)'){throw 'Missing verified guest mapping.'}
 $membase=[Convert]::ToUInt64($Matches[1],16)
 if([GatRenderLayoutReadV2]::Read($Process.Handle,$membase,[Convert]::ToUInt32('82F85FFC',16)) -ne [Convert]::ToUInt32('81430014',16)){throw 'Unexpected render-layout code.'}
 $root=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,[Convert]::ToUInt32('849331A8',16))
 # 82F5FB58 stores the layout at renderer+0x60; +0xC0 is the texture manager.
 $context=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($root+0x60))
 foreach($item in @(@('device',$root),@('context',$context))){
  $words=@(for($offset=0;$offset -lt 0x80;$offset+=4){[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,([uint32]$item[1]+$offset)).ToString('X8')})
  Write-Host ('Owned render '+$item[0]+' 0x'+([uint32]$item[1]).ToString('X8')+': '+($words -join ' '))
 }
 # Main-scene surfaces are separate from the generic descriptor pool.
 # 8302E760 creates each 0x5C-byte tile-layout entry's color/depth pair;
 # render state+0x8EC selects that entry (8302E358), independently of
 # the device presentation mode at context+0x64.
 try {
  $table=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,[Convert]::ToUInt32('83C845D8',16))
  $presentationMode=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($context+0x64))
  $state=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,[Convert]::ToUInt32('83C84418',16))
  $mode=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($state+0x8EC))
  if($mode -gt 4){throw 'Unexpected scene tile-layout index.'}
  $entry=[uint32]($table+$mode*0x5C)
  $samples=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,$entry)
  $tiles=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($entry+0xC))
  Write-Host ('Owned main scene: presentation mode='+$presentationMode+'; active mode='+$mode+'; raw MSAA='+$samples+'; tiles='+$tiles)
  foreach($item in @(@('color',0x54),@('depth',0x58))){
   $surface=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($entry+$item[1]))
   $header=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($surface+0x18))
   Write-Host ('Owned main surface: type='+$item[0]+'; address=0x'+$surface.ToString('X8')+'; raw MSAA='+(($header -shr 16) -band 3))
  }
 } catch {Write-Warning ('Main-scene inspection unavailable: '+$_.Exception.Message)}
 # The verified render-library allocation walker reads descriptor+0x30 as
 # the Xenos MSAA enum. Inspect only its bounded circular descriptor list.
 try {
  $node=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,[Convert]::ToUInt32('83C84554',16))
  $seen=New-Object 'Collections.Generic.HashSet[uint32]'
  $counts=@{}
  while($node -ne 0 -and $seen.Count -lt 128 -and $seen.Add($node)){
   $samples=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($node+0x30))
   if(-not $counts.ContainsKey($samples)){$counts[$samples]=0}
   $counts[$samples]++
   $node=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($node+4))
  }
  foreach($key in @($counts.Keys | Sort-Object)){
   Write-Host ('Owned render descriptors: raw MSAA='+$key+'; count='+$counts[$key])
  }
 } catch {Write-Warning ('Descriptor inspection unavailable: '+$_.Exception.Message)}
 try {
  $manager=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($root+0xC0))
  foreach($pool in @(@('context',($context+0xEC)),@('manager',($manager+0xC8)))){
   $counts=@{};$listed=0
   for($id=0;$id -lt 96;$id++){
    $unit=[uint32]($pool[1]+$id*0xD0)
    $surface=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($unit+0xCC))
    if($id -lt 3){Write-Host ('Owned surface pointer: pool='+$pool[0]+'; id='+$id+'; address=0x'+$surface.ToString('X8'))}
    if($surface -lt [Convert]::ToUInt32('00010000',16) -or $surface -gt [Convert]::ToUInt32('BFFFFF00',16)){continue}
    $header=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($surface+0x18))
    $samples=($header -shr 16) -band 3
    if(-not $counts.ContainsKey($samples)){$counts[$samples]=0}
    $counts[$samples]++
    if($samples -ne 0 -and $listed -lt 24){
     $width=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($unit+0x10))
     $height=[GatRenderLayoutReadV2]::Read($Process.Handle,$membase,($unit+0x14))
     Write-Host ('Owned render surface: pool='+$pool[0]+'; id='+$id+'; dimensions='+$width+'x'+$height+'; raw MSAA='+$samples)
     $listed++
    }
   }
   foreach($key in @($counts.Keys | Sort-Object)){Write-Host ('Owned surface totals: pool='+$pool[0]+'; raw MSAA='+$key+'; count='+$counts[$key])}
  }
 } catch {Write-Warning ('Surface inspection unavailable: '+$_.Exception.Message)}
}

function Invoke-GatGameSession([string]$Root) {
 $runtime=Join-Path $Root 'runtime'
 $request=Join-Path $runtime 'replay.request'
 $first=$null
 for($attempt=0;$attempt -lt 50 -and -not $first;$attempt++){
  $first=Read-GatGameRequest $request
  if(-not $first){Start-Sleep -Milliseconds 100}
 }
 if(-not $first){throw 'No valid game-test launch request.'}
 $launch=Read-GatGameCommand $first
 $isSr4=$launch.Action -eq 'launch-sr4'
 $isSr3=$launch.Action -eq 'launch-sr3'
 $testTitle=if($isSr3){'5451086D'}elseif($isSr4){'4B4D07F6'}else{'4B4D0800'}
 if($launch.Action -notin @('launch','launch-depth','launch-release','launch-stages','launch-pitch','launch-stencilcopy','launch-no-msaa','launch-hdr-async','launch-sr4','launch-sr3','launch-queries','launch-unlimited','launch-vulkan','launch-stock')){throw 'Start a game-test session first.'}
 if(@(Get-Process -Name 'xenia_edge*','xenia_canary*','xenia_trace*','Keys2Pad','LaunchBox','BigBox' -ErrorAction SilentlyContinue).Count){
  throw 'Close Xenia, Keys2Pad and LaunchBox before this isolated test.'
 }
 $normal=Join-Path (Split-Path -Parent $Root) 'Xenia Edge'
 $lb=Split-Path -Parent (Split-Path -Parent $Root)
 $exe=Join-Path $runtime 'xenia_edge_gat.exe'
 $expectedExeHash='99244AB2D4ED7805B97D4DE63B2968EF800A69F15E24CB715C81CB00D72518C3'
 if($launch.Action -eq 'launch-stock'){
  $exe=Join-Path $normal 'xenia_edge.exe'
  $expectedExeHash='41313FDC1C22B08A19A3BD2334332DE2BA597E1F7FB27010A757E2AC573662A5'
 }
 if($isSr4){
  $exe=Join-Path $runtime 'xenia_edge_sr4.exe'
  $expectedExeHash='FEA485385CC9245C03D383987D11CBBDC309EF4AE40F0BF9DFB95CB4E2D59185'
 }
 if($isSr3){
  $exe=Join-Path $runtime 'xenia_edge_sr3.exe'
  $expectedExeHash='783F1E3CF7289B04A86A733F4B219490911025F5CAE523E6F772CDC3101B26AD'
 }
 $library=Join-Path $runtime 'ViGEmClient.dll'
 $config=Join-Path $Root 'config\Gat-Fixed.toml'
 $game=Join-Path $lb 'Games\Microsoft Xbox 360\Saints Row Gat out of Hell [RF]\Saints Row Gat out of Hell [RF].iso'
 if($isSr4){
  $config=Join-Path $Root 'config\SR4-Fixed.toml'
  $game=Join-Path $lb 'Games\Microsoft Xbox 360\Saints Row 4 Game of the Century Edition [RF][DVD1]\Saints Row 4 Game of the Century Edition [RF][DVD1].iso'
 }
 if($isSr3){
  $config=Join-Path $Root 'config\SR3-Fixed.toml'
  $game=Join-Path $lb 'Games\Microsoft Xbox 360\Saints Row The Thrid Full Package [RF][DVD1]\Saints Row The Thrid Full Package [RF][DVD1].iso'
 }
 foreach($p in @($exe,$library,$config,$game)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing test input: $p"}}
 if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $expectedExeHash){throw 'Unexpected game-test executable.'}
 if((Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash -ne '00303F99E1968D523FBD08A7C691D60D145B7335059EC593947841D124C10875'){throw 'Unexpected controller client library.'}
 $work=Join-Path $runtime $(if($isSr3){'sr3-test'}elseif($isSr4){'sr4-test'}else{'game-test'})
 $content=Join-Path $work 'content'
 $null=New-Item -ItemType Directory -Path $content -Force
 # The game may autosave. Only this disposable copy is exposed to the test.
 $sourceContent=Join-Path (Join-Path (Split-Path -Parent $Root) 'Xenia Canary') 'content'
 $profileConfig=[IO.File]::ReadAllText($config)
 if($profileConfig -notmatch 'logged_profile_slot_0_xuid\s*=\s*"([0-9A-Fa-f]{16})"'){throw 'Missing configured profile.'}
 $profile=$Matches[1]
 $targetProfile=Join-Path $content $profile
 $null=New-Item -ItemType Directory -Path $targetProfile -Force
 foreach($title in @('FFFE07D1',$testTitle)){
  $source=Join-Path (Join-Path $sourceContent $profile) $title
  if(-not(Test-Path -LiteralPath $source)){
   if($isSr3 -and $title -eq $testTitle){continue}
   throw 'Missing original game/profile data.'
  }
  # Reuse only the disposable test progress so each comparison need not replay
  # the introduction. Never copy this state back over the owner's save.
  if(-not(Test-Path -LiteralPath (Join-Path $targetProfile $title))){Copy-Item -LiteralPath $source -Destination $targetProfile -Recurse}
 }
 $storage=Join-Path $work 'storage'
 $capture=Join-Path $Root 'capture\active'
 $null=New-Item -ItemType Directory -Path $capture -Force
 $null=New-Item -ItemType Directory -Path (Join-Path $storage 'config'),(Join-Path $storage 'patches') -Force
 $titleConfig=Join-Path $normal ('config\'+$testTitle+'.config.toml')
 if(Test-Path -LiteralPath $titleConfig){Copy-Item -LiteralPath $titleConfig -Destination (Join-Path $storage 'config') -Force}
 $localPatch=if($isSr4){'4B4D07F6 - Saints Row IV Local Address.patch.toml'}else{'4B4D0800 - Gat Out of Hell Local Address.patch.toml'}
 if(-not $isSr3){Copy-Item -LiteralPath (Join-Path $normal ('patches\'+$localPatch)) -Destination (Join-Path $storage 'patches') -Force}
 if($isSr4){
  # Read-only installed STFS packages use hard links, not another 1.2 GB copy.
  # Autosaves still go only to the separate profile copy above.
  Add-SaintsTitlePackages (Join-Path $sourceContent ('0000000000000000\'+$testTitle)) (Join-Path $content ('0000000000000000\'+$testTitle))
  Set-GatScenePatch (Join-Path $Root 'config\SR4-SingleSample.patch.toml') (Join-Path $storage 'patches\4B4D07F6 - SR4 Single-sample Scene.patch.toml') $true
 }
 if($isSr3){
  Add-SaintsTitlePackages (Join-Path $sourceContent ('0000000000000000\'+$testTitle)) (Join-Path $content ('0000000000000000\'+$testTitle))
  Set-GatScenePatch (Join-Path $Root 'config\SR3-SingleSample.patch.toml') (Join-Path $storage 'patches\5451086D - SR3 Single-sample Scene.patch.toml') $true
 }
 $legacyScenePatch=Join-Path $storage 'patches\4B4D0800 - Single-sample Renderer Test.patch.toml'
 if(Test-Path -LiteralPath $legacyScenePatch){Remove-Item -LiteralPath $legacyScenePatch -Force}
 Set-GatScenePatch (Join-Path $Root 'config\Gat-SingleSample.patch.toml') (Join-Path $storage 'patches\4B4D0800 - Gat Single-sample Scene.patch.toml') ($launch.Action -in @('launch-no-msaa','launch-hdr-async'))
 $hdrPatch=Join-Path $storage 'patches\4B4D0800 - Gat HDR Feedback Test.patch.toml'
 if(Test-Path -LiteralPath $hdrPatch){Remove-Item -LiteralPath $hdrPatch -Force}
 $resolutionPatch=Join-Path $storage 'patches\4B4D0800 - Native 576p Test.patch.toml'
 if(Test-Path -LiteralPath $resolutionPatch){
  Remove-Item -LiteralPath $resolutionPatch -Force
 }
 if(-not ('GatTestPadV2' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public sealed class GatTestPadV2 : IDisposable {
 [StructLayout(LayoutKind.Sequential)] public struct Report {
  public ushort Buttons; public byte LT,RT; public short LX,LY,RX,RY;
 }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibrary(string path);
 [DllImport("ViGEmClient.dll",CallingConvention=CallingConvention.Cdecl)] static extern IntPtr vigem_alloc();
 [DllImport("ViGEmClient.dll",CallingConvention=CallingConvention.Cdecl)] static extern uint vigem_connect(IntPtr client);
 [DllImport("ViGEmClient.dll",CallingConvention=CallingConvention.Cdecl)] static extern IntPtr vigem_target_x360_alloc();
 [DllImport("ViGEmClient.dll",CallingConvention=CallingConvention.Cdecl)] static extern uint vigem_target_add(IntPtr client,IntPtr target);
 [DllImport("ViGEmClient.dll",CallingConvention=CallingConvention.Cdecl)] static extern uint vigem_target_x360_update(IntPtr client,IntPtr target,Report report);
 [DllImport("ViGEmClient.dll",CallingConvention=CallingConvention.Cdecl)] static extern uint vigem_target_x360_get_user_index(IntPtr client,IntPtr target,out uint index);
 [DllImport("ViGEmClient.dll",CallingConvention=CallingConvention.Cdecl)] static extern uint vigem_target_remove(IntPtr client,IntPtr target);
 [DllImport("ViGEmClient.dll",CallingConvention=CallingConvention.Cdecl)] static extern void vigem_target_free(IntPtr target);
 [DllImport("ViGEmClient.dll",CallingConvention=CallingConvention.Cdecl)] static extern void vigem_disconnect(IntPtr client);
 [DllImport("ViGEmClient.dll",CallingConvention=CallingConvention.Cdecl)] static extern void vigem_free(IntPtr client);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window,uint message,IntPtr wParam,IntPtr lParam);
 IntPtr client,target; bool added;
 static void Check(uint code) {if(code!=0x20000000)throw new InvalidOperationException("ViGEm error 0x"+code.ToString("X8"));}
 public GatTestPadV2(string library) {
  if(LoadLibrary(library)==IntPtr.Zero)throw new InvalidOperationException("Controller client load failed.");
  try {
   client=vigem_alloc(); if(client==IntPtr.Zero)throw new InvalidOperationException("Controller allocation failed.");
   Check(vigem_connect(client)); target=vigem_target_x360_alloc();
   if(target==IntPtr.Zero)throw new InvalidOperationException("Pad allocation failed.");
   Check(vigem_target_add(client,target)); added=true;
   uint index; Check(vigem_target_x360_get_user_index(client,target,out index));
   if(index!=0)throw new InvalidOperationException("Player-one slot is occupied; native controllers left unchanged.");
  } catch {Dispose();throw;}
 }
 public void Update(ushort buttons,short lx,short ly,short rx) {Check(vigem_target_x360_update(client,target,new Report{Buttons=buttons,LX=lx,LY=ly,RX=rx}));}
 public void Dispose() {
  if(target!=IntPtr.Zero){if(added)vigem_target_remove(client,target);vigem_target_free(target);target=IntPtr.Zero;added=false;}
  if(client!=IntPtr.Zero){vigem_disconnect(client);vigem_free(client);client=IntPtr.Zero;}
 }
}
'@
 }
 if(-not ('GatTestWindowV2' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GatTestWindowV2 {
 delegate bool Visitor(IntPtr window,IntPtr data);
 [StructLayout(LayoutKind.Sequential)] struct Rect {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,Visitor callback,IntPtr data);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window,out Rect rect);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
 [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr window,IntPtr rect,bool erase);
 public static void Repaint(IntPtr parent) {
  if(!InvalidateRect(RenderPanel(parent),IntPtr.Zero,false))throw new InvalidOperationException("Cannot request an owned window repaint.");
 }
 public static IntPtr RenderPanel(IntPtr parent) {
  IntPtr result=IntPtr.Zero;long area=0;
  EnumChildWindows(parent,delegate(IntPtr child,IntPtr data){
   Rect rect;if(IsWindowVisible(child)&&GetClientRect(child,out rect)){
    long candidate=(long)(rect.Right-rect.Left)*(rect.Bottom-rect.Top);
    if(candidate>area){area=candidate;result=child;}
   }return true;
  },IntPtr.Zero);
  if(result==IntPtr.Zero)throw new InvalidOperationException("Render panel not ready.");
  return result;
 }
}
'@
 }
 $pad=$null;$process=$null
 try {
  $pad=New-Object GatTestPadV2($library)
  $info=New-Object Diagnostics.ProcessStartInfo
  $info.FileName=$exe
  $info.Arguments=New-GatGameArguments $config $storage $content (Join-Path $work 'xenia.log') $game
  $info.Arguments+=' --cache_root="'+(Join-Path $normal 'cache')+'" --trace_gpu_prefix="'+($capture.Replace('\','/')+'/')+'" --trace_gpu_stream=false'
  if($launch.Action -in @('launch-depth','launch-release','launch-stages','launch-pitch','launch-stencilcopy','launch-no-msaa','launch-hdr-async','launch-sr4','launch-sr3','launch-queries','launch-unlimited','launch-vulkan','launch-stock')){$info.Arguments+=' --depth_bias_shader_offset=true --depth_float24_convert_in_pixel_shader=true --depth_float24_round=true'}
  if($launch.Action -in @('launch-release','launch-stages','launch-pitch','launch-stencilcopy','launch-no-msaa','launch-hdr-async','launch-sr4','launch-sr3','launch-queries','launch-unlimited','launch-vulkan')){
   $info.Arguments=$info.Arguments.Replace('--d3d12_submission_timing=true','--d3d12_submission_timing=false')
   $probeCache=Join-Path $work 'cache'
   $info.Arguments=$info.Arguments.Replace('--cache_root="'+(Join-Path $normal 'cache')+'"','--cache_root="'+$probeCache+'"')
  }
  if($launch.Action -eq 'launch-stages'){
   $info.Arguments=$info.Arguments.Replace('--d3d12_submission_timing=false','--d3d12_submission_timing=true').Replace('--d3d12_draw_timing=false','--d3d12_draw_timing=true')
   $info.Arguments+=' --d3d12_stage_timing=true'
  }
  if($launch.Action -in @('launch-stencilcopy','launch-no-msaa','launch-hdr-async')){$info.Arguments+=' --d3d12_stencil_plane_copy=true --occlusion_query=fake'}
  if($launch.Action -in @('launch-no-msaa','launch-hdr-async')){$info.Arguments+=' --postprocess_antialiasing=fxaa --d3d12_stage_small_readback=true'}
  if($launch.Action -eq 'launch-hdr-async'){$info.Arguments+=' --d3d12_gat_async_hdr=true --host_present_from_non_ui_thread=false'}
  if($isSr4){$info.Arguments=$info.Arguments.Replace('--d3d12_submission_timing=false','--d3d12_submission_timing=true');$info.Arguments+=' --gpu=d3d12 --d3d12_stencil_plane_copy=true --d3d12_stage_small_readback=true --d3d12_sr4_async_hdr=true --host_present_from_non_ui_thread=false --postprocess_antialiasing=fxaa --occlusion_query=strict --framerate_limit=60 --guest_display_refresh_cap=false --draw_resolution_scale_x=1 --draw_resolution_scale_y=1'}
  if($launch.Action -eq 'launch-pitch'){$info.Arguments+=' --d3d12_transfer_static_source_pitch=true'}
  if($launch.Action -eq 'launch-queries'){$info.Arguments+=' --occlusion_query=fast-alt --d3d12_query_summary=true'}
  if($launch.Action -eq 'launch-unlimited'){$info.Arguments+=' --framerate_limit=0'}
  if($launch.Action -eq 'launch-vulkan'){$info.Arguments+=' --gpu=vulkan --vulkan_snorm16_multiply_scale=true'}
  if($isSr3){$info.Arguments=$info.Arguments.Replace('--d3d12_submission_timing=false','--d3d12_submission_timing=true');$info.Arguments+=' --gpu=d3d12 --d3d12_stencil_plane_copy=true --d3d12_stage_small_readback=true --d3d12_sr3_async_hdr=true --host_present_from_non_ui_thread=false --postprocess_antialiasing=fxaa --occlusion_query=strict --framerate_limit=60 --guest_display_refresh_cap=false --draw_resolution_scale_x=1 --draw_resolution_scale_y=1'}
  if($launch.Action -eq 'launch-stock'){
   foreach($flag in @(' --d3d12_snorm16_multiply_scale=true',' --d3d12_skip_no_output_draws=true',' --d3d12_submission_timing=true',' --d3d12_draw_timing=false',' --profiler_on_demand=true')){
    $info.Arguments=$info.Arguments.Replace($flag,'')
   }
  }
  $info.WorkingDirectory=$runtime
  $info.UseShellExecute=$false
  # Process-local SDL filter; no native controller or Keys2Pad settings are edited.
  $info.EnvironmentVariables['SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT']='0x045e/0x028e'
  $info.EnvironmentVariables['SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS']='1'
  $process=[Diagnostics.Process]::Start($info)
  $seen=$first
  $unreadable=0
  $timer=[Diagnostics.Stopwatch]::StartNew()
  Write-Host ('Game-test active; owned Xenia PID '+$process.Id+'. Originals are not used for saving.')
  while(-not $process.HasExited -and $timer.Elapsed.TotalMinutes -lt 30){
   Start-Sleep -Milliseconds 100
   $text=Read-GatGameRequest $request
   if(-not $text){
    $unreadable++
    if($unreadable % 50 -eq 0){Write-Warning 'Waiting for a readable game-test command; owned game remains running.'}
    continue
   }
   $unreadable=0
   if($text -eq $seen){continue}
   $seen=$text
   $command=Read-GatGameCommand $text
   if($command.Action -eq 'stop'){break}
   if($command.Action -in @('snapshot','capture')){
    if($command.Action -eq 'capture' -and @(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File).Count){
     Write-Warning 'One GPU frame is already pending analysis; no additional capture.'
     continue
    }
    if($command.Action -eq 'snapshot' -and @(Get-ChildItem -LiteralPath $work -Filter 'snapshot-*.png' -File).Count -ge 8){
     Write-Warning 'Test image limit reached; no additional screenshot.'
     continue
    }
    $process.Refresh()
    if($process.MainWindowHandle -eq [IntPtr]::Zero){throw 'Game window is not ready.'}
    $shots=Join-Path $runtime ('screenshots\'+$testTitle)
    $before=@();if(Test-Path -LiteralPath $shots){$before=@(Get-ChildItem -LiteralPath $shots -File | ForEach-Object {$_.FullName})}
    $panel=[GatTestWindowV2]::RenderPanel($process.MainWindowHandle)
    $key=if($command.Action -eq 'capture'){0x73}else{0x7B}
    if(-not [GatTestPadV2]::PostMessage($panel,0x100,[IntPtr]$key,[IntPtr]1)){throw 'Capture key-down failed.'}
    $null=[GatTestPadV2]::PostMessage($panel,0x101,[IntPtr]$key,[IntPtr]3221225473)
    if($command.Action -eq 'capture'){
     Write-Host ('Single GPU frame requested: '+$command.Id)
     continue
    }
    $image=$null
    for($i=0;$i -lt 50;$i++){
     Start-Sleep -Milliseconds 100
     if(Test-Path -LiteralPath $shots){$image=Get-ChildItem -LiteralPath $shots -Filter '*.png' -File | Where-Object {$_.FullName -notin $before} | Select-Object -First 1}
     if($image){break}
    }
    $destination=Join-Path $work ('snapshot-'+$command.Id+'.png')
    if($image -and (Move-GatFinishedScreenshot $image.FullName $destination)){
     Write-Host ('Native test image: '+[IO.Path]::GetFileName($destination))
     $old=@(Get-ChildItem -LiteralPath $work -Filter 'snapshot-*.png' -File | Sort-Object LastWriteTime -Descending | Select-Object -Skip 4)
     foreach($oldImage in $old){try{Remove-Item -LiteralPath $oldImage.FullName -ErrorAction Stop}catch{Write-Warning 'Previous test image still open; cleanup deferred.'}}
    } else{Write-Warning 'Native image is not ready; game remains open.'}
   } elseif($command.Action -in @('frames','frames-spin')) {
    if($command.Action -eq 'frames-spin'){$pad.Update(0,0,0,11000)}
    try {Measure-GatFrames $process $command.Milliseconds}
    finally {$pad.Update(0,0,0,0)}
   } elseif($command.Action -eq 'gpu') {
    $smi=Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if(Test-Path -LiteralPath $smi){
     & $smi '--query-gpu=name,pstate,temperature.gpu,utilization.gpu,clocks.current.graphics,clocks.current.memory,power.draw,power.limit' '--format=csv,noheader,nounits'
     if($LASTEXITCODE -ne 0){Write-Warning 'GPU status query was unavailable.'}
    }else{Write-Warning 'No installed NVIDIA status utility found.'}
   } elseif($command.Action -eq 'layout') {
    if($isSr4 -or $isSr3){Write-Warning 'Gat-only layout inspector is disabled for this title.'}else{Show-GatRenderLayout $process (Join-Path $work 'xenia.log')}
   } elseif($command.Action -in @('present-ui','present-direct','present-window')) {
    $module=$process.MainModule
    if($module.ModuleName -ne 'xenia_edge_gat.exe' -or (Get-FileHash -LiteralPath $module.FileName -Algorithm SHA256).Hash -ne '99244AB2D4ED7805B97D4DE63B2968EF800A69F15E24CB715C81CB00D72518C3'){throw 'Unexpected presentation test executable.'}
    if(-not ('GatCpuSamplerV14' -as [type])){throw 'Run the owned sample once to initialize verified interop.'}
    if($command.Action -eq 'present-window'){
     Write-Host 'Owned presentation timing window: 18 s; rendering unchanged.'
     [GatCpuSamplerV14]::MeasurePresentWindow([uint32]$process.Id,[uint64]$module.BaseAddress.ToInt64())
     Write-Host 'Owned presentation timing window complete; previous instrumentation restored.'
    }else{
     $enabled=$command.Action -eq 'present-direct'
     $previous=[GatCpuSamplerV14]::SetHostPresent([uint32]$process.Id,[uint64]$module.BaseAddress.ToInt64(),$enabled)
     Write-Host ('Owned host presentation mode: direct='+$enabled+'; previous='+$previous)
     [GatTestWindowV2]::Repaint($process.MainWindowHandle)
    }
   } elseif($command.Action -in @('async-hdr-on','async-hdr-off')) {
    $module=$process.MainModule
    if($module.ModuleName -ne 'xenia_edge_gat.exe' -or (Get-FileHash -LiteralPath $module.FileName -Algorithm SHA256).Hash -ne '99244AB2D4ED7805B97D4DE63B2968EF800A69F15E24CB715C81CB00D72518C3'){throw 'Unexpected async HDR executable.'}
    if(-not ('GatCpuSamplerV14' -as [type])){throw 'Run the owned sample once to initialize verified interop.'}
    $enabled=$command.Action -eq 'async-hdr-on'
    $previous=[GatCpuSamplerV14]::SetAsyncHdr([uint32]$process.Id,[uint64]$module.BaseAddress.ToInt64(),$enabled)
    Write-Host ('Owned async HDR experiment: '+$enabled+'; previous='+$previous)
   } elseif($command.Action -in @('readback-on','readback-off')) {
    $module=$process.MainModule
    if($module.ModuleName -ne 'xenia_edge_gat.exe' -or
       (Get-FileHash -LiteralPath $module.FileName -Algorithm SHA256).Hash -ne '99244AB2D4ED7805B97D4DE63B2968EF800A69F15E24CB715C81CB00D72518C3'){
     throw 'Unexpected executable for the isolated small-readback comparison.'
    }
    if(-not ('GatCpuSamplerV14' -as [type])){throw 'Run the owned sample once to initialize verified interop.'}
    $enabled=$command.Action -eq 'readback-on'
    $previous=[GatCpuSamplerV14]::SetSmallReadback([uint32]$process.Id,[uint64]$module.BaseAddress.ToInt64(),$enabled)
    Write-Host ('Owned small-readback experiment: '+$enabled+'; previous='+$previous)
   } elseif($command.Action -eq 'sample') {
    # Reload trusted inspection and bounded telemetry functions without
    # restarting the owned game. Native type changes use a new
    # versioned class name because PowerShell keeps loaded assemblies alive.
    . (Join-Path $runtime 'Gat-Game-Control.ps1') -Root $Root -FunctionsOnly
    Invoke-GatCpuSample $process (Join-Path $work 'xenia.log')
   } elseif($command.Action -notin @('launch','launch-depth','launch-release','launch-stages','launch-pitch','launch-stencilcopy','launch-no-msaa','launch-hdr-async','launch-sr4','launch-sr3','launch-queries','launch-unlimited','launch-vulkan','launch-stock')) {
    $buttons=@{A=0x1000;B=0x2000;Y=0x8000;Start=0x10;Back=0x20;Up=1;Down=2;Left=4;Right=8}
    $mask=0;$rx=0;$lx=0;$ly=0
    if($buttons.ContainsKey($command.Action)){$mask=$buttons[$command.Action]}
    if($command.Action -eq 'CameraLeft'){$rx=-22000}
    if($command.Action -eq 'CameraRight'){$rx=22000}
    if($command.Action -eq 'MoveForward'){$ly=24000}
    if($command.Action -eq 'MoveBackward'){$ly=-24000}
    if($command.Action -eq 'StrafeLeft'){$lx=-24000}
    if($command.Action -eq 'StrafeRight'){$lx=24000}
    try {$pad.Update($mask,$lx,$ly,$rx);Start-Sleep -Milliseconds $command.Milliseconds}
    finally {$pad.Update(0,0,0,0)}
   }
   Write-Host ('Game-test command complete: '+$command.Id+' '+$command.Action)
  }
 } finally {
  if($process){
   if(-not $process.HasExited){
    $null=$process.CloseMainWindow()
    if(-not $process.WaitForExit(10000)){$process.Kill();$process.WaitForExit()}
   }
   Write-Host ('Owned game process closed with exit '+$process.ExitCode)
   $process.Dispose()
  }
  if($pad){$pad.Dispose()}
  Write-Host 'Game-test controller released. Replay workflow remains available.'
 }
}

if(-not $FunctionsOnly){Invoke-GatGameSession $Root}
