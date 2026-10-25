param([string]$Root=$env:GAT_TRACE_DIR,[string]$Request,[hashtable]$Session,[switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
function Read-TFU2Request([string]$Text) {
 if($Text -notmatch '^tfu2:([0-9a-f]{32}):(status|launch-baseline|launch-candidate|stop|capture|snapshot|window|timing-state|Enter|replay-baseline|replay-candidate|clear-captures|A|B|X|Y|Start|Back|Up|Down|Left|Right|MoveForward|MoveBackward|CameraLeft|CameraRight)(?::([0-9]{1,4}))?$'){throw 'Invalid TFU2 command.'}
 $ms=if($Matches[3]){[int]$Matches[3]}else{150}
 if($ms -lt 20 -or $ms -gt 5000){throw 'TFU2 input duration must be 20..5000 ms.'}
 [pscustomobject]@{Id=$Matches[1];Action=$Matches[2];Milliseconds=$ms}
}
function Assert-TFU2Hash([string]$Path,[string]$Hash) {
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash){throw ('Unexpected TFU2 test binary: '+[IO.Path]::GetFileName($Path))}
}
function Get-TFU2Processes([string]$Exe) {
 @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $Exe})
}
function Add-TFU2NativeTypes([string]$Library) {
 if('TFU2PadV1' -as [type]){return}
 Assert-TFU2Hash $Library '00303F99E1968D523FBD08A7C691D60D145B7335059EC593947841D124C10875'
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public sealed class TFU2PadV1 : IDisposable {
 [StructLayout(LayoutKind.Sequential,Pack=1)] struct Report {public ushort Buttons;public byte LT,RT;public short LX,LY,RX,RY;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr LoadLibrary(string path);
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
 IntPtr client,target;bool added;
 static void Check(uint value){if(value!=0x20000000)throw new InvalidOperationException("Virtual controller error 0x"+value.ToString("X8"));}
 public TFU2PadV1(string library){
  if(LoadLibrary(library)==IntPtr.Zero)throw new InvalidOperationException("Cannot load installed controller client.");
  try{client=vigem_alloc();if(client==IntPtr.Zero)throw new InvalidOperationException("Controller allocation failed.");Check(vigem_connect(client));target=vigem_target_x360_alloc();if(target==IntPtr.Zero)throw new InvalidOperationException("Pad allocation failed.");Check(vigem_target_add(client,target));added=true;uint index;Check(vigem_target_x360_get_user_index(client,target,out index));if(index!=0)throw new InvalidOperationException("Player-one slot occupied; other controllers were left untouched.");}catch{Dispose();throw;}
 }
 public void Update(ushort buttons,short lx,short ly,short rx,short ry){Check(vigem_target_x360_update(client,target,new Report{Buttons=buttons,LX=lx,LY=ly,RX=rx,RY=ry}));}
 public void Dispose(){if(target!=IntPtr.Zero){if(added)vigem_target_remove(client,target);vigem_target_free(target);target=IntPtr.Zero;added=false;}if(client!=IntPtr.Zero){vigem_disconnect(client);vigem_free(client);client=IntPtr.Zero;}}
}
public static class TFU2WindowV1 {
 delegate bool Visitor(IntPtr window,IntPtr data);
 [StructLayout(LayoutKind.Sequential)] struct Rect {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,Visitor visit,IntPtr data);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window,out Rect rect);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window,uint message,IntPtr wParam,IntPtr lParam);
 public static void Key(IntPtr parent,int key){
  IntPtr panel=parent;long area=0;
  EnumChildWindows(parent,delegate(IntPtr child,IntPtr ignored){Rect r;if(IsWindowVisible(child)&&GetClientRect(child,out r)){long a=(long)(r.Right-r.Left)*(r.Bottom-r.Top);if(a>area){area=a;panel=child;}}return true;},IntPtr.Zero);
  if(parent==IntPtr.Zero||!PostMessage(panel,0x100,(IntPtr)key,(IntPtr)1))throw new InvalidOperationException("TFU2 window is not ready.");
  PostMessage(panel,0x101,(IntPtr)key,new IntPtr(3221225473L));
 }
}
'@
}
function Sync-TFU2Test([hashtable]$State,[string]$CaptureExe,[string]$Storage) {
 # The first Agility runtime installation restarts Xenia. Adopt only its direct
 # child with the same executable and the private working-storage argument.
 if(-not $State.Game -or -not $State.Game.HasExited){return}
 $parentId=$State.Game.Id
 foreach($child in @(Get-CimInstance Win32_Process -Filter "Name='xenia_tfu2_capture.exe'")){
  if($child.ParentProcessId -eq $parentId -and $child.ExecutablePath -eq $CaptureExe -and $child.CommandLine -and $child.CommandLine.IndexOf($Storage,[StringComparison]::OrdinalIgnoreCase) -ge 0){
   $next=Get-Process -Id $child.ProcessId -ErrorAction Stop
   $State.Game.Dispose();$State.Game=$next
   Write-Host ('TFU2 adopted its runtime-install restart: PID '+$next.Id)
   return
  }
 }
}
function Stop-TFU2Test([hashtable]$State,[string]$CaptureExe) {
 if($State.Pad){$State.Pad.Update(0,0,0,0,0)}
 if($State.Game -and -not $State.Game.HasExited){
  if($State.Game.Path -ne $CaptureExe){throw 'Refusing to close an unowned process.'}
  $null=$State.Game.CloseMainWindow()
  if(-not $State.Game.WaitForExit(10000)){$State.Game.Kill();$State.Game.WaitForExit()}
 }
 if($State.Pad){$State.Pad.Dispose();$State.Remove('Pad')}
 if($State.Game){$State.Game.Dispose();$State.Remove('Game')}
}
function Invoke-TFU2Command([string]$TraceRoot,[string]$Text,[hashtable]$State) {
 $cmd=Read-TFU2Request $Text
 $emulators=Split-Path -Parent $TraceRoot;$lb=Split-Path -Parent $emulators
 $normal=Join-Path $emulators 'Xenia Edge'
 $diagnostics=Join-Path $normal 'diagnostics\TFU2';$runtime=Join-Path $diagnostics 'runtime'
 $work=Join-Path $runtime 'work';$capture=Join-Path $diagnostics 'capture'
 $captureExe=Join-Path $runtime 'xenia_tfu2_capture.exe';$replayExe=Join-Path $runtime 'xenia_tfu2_replay.exe'
 $library=Join-Path $TraceRoot 'runtime\ViGEmClient.dll'
 Sync-TFU2Test $State $captureExe (Join-Path $work 'storage')
 $sourceConfig=Join-Path $normal 'config\games\Star Wars_ The Force Unleashed II [3eed70e0].toml'
 $sourceContent=Join-Path $emulators 'Xenia Canary\content'
 $game=Join-Path $lb 'Games\Microsoft Xbox 360\Star Wars Force Unleashed 2 [RF]\Star Wars Force Unleashed 2 [RF].iso'
 if($cmd.Action -eq 'status'){
  $running=@(Get-TFU2Processes (Join-Path $normal 'xenia_edge_tfu2.exe')).Count
  $owned=@(Get-TFU2Processes $captureExe).Count
  Write-Host ('TFU2 status: normal='+$running+'; owned='+$owned+'; captures='+@(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File -ErrorAction SilentlyContinue).Count)
  return
 }
 if($cmd.Action -eq 'clear-captures'){
  if($State.Game -and -not $State.Game.HasExited){throw 'Stop the owned test before removing its captures.'}
  foreach($f in @(Get-ChildItem -LiteralPath $capture -File -ErrorAction SilentlyContinue | Where-Object {$_.Extension -in @('.xtr','.png')})){Remove-Item -LiteralPath $f.FullName -Force}
  Write-Host 'TFU2 diagnostic captures removed without backups.';return
 }
 if($cmd.Action -eq 'stop'){Stop-TFU2Test $State $captureExe;Write-Host 'Owned TFU2 test stopped; original saves unchanged.';return}
 if($cmd.Action.StartsWith('launch-')){
  Stop-TFU2Test $State $captureExe
  # Only the explicitly authorized TFU2 process may be closed. Never kill the
  # owner's normal process; a hung close is reported without touching it.
  foreach($normalProcess in @(Get-TFU2Processes (Join-Path $normal 'xenia_edge_tfu2.exe'))){
   Assert-TFU2Hash (Join-Path $normal 'xenia_edge_tfu2.exe') '332E5204F187FDFA92846BD0B6FA876A25CF0A4F10CD424C1ABFCD31C2237E2C'
   $null=$normalProcess.CloseMainWindow()
   if(-not $normalProcess.WaitForExit(10000)){throw 'Normal TFU2 did not close; no test launched.'}
  }
  if(@(Get-Process -Name 'xenia*' -ErrorAction SilentlyContinue).Count){throw 'Another Xenia is running; left unchanged.'}
  Assert-TFU2Hash $captureExe '09B4FBCF9C58F6D07B268A42CFA1A823DFED383D04561527B11F0B2BE40AC0A3'
  foreach($p in @($sourceConfig,$game)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw 'Missing TFU2 test input.'}}
  $null=New-Item -ItemType Directory -Path $work,$capture,(Join-Path $work 'storage\config') -Force
  $config=Join-Path $work ($cmd.Action.Substring(7)+'.toml')
  if(-not(Test-Path -LiteralPath $config)){Copy-Item -LiteralPath $sourceConfig -Destination $config}
  $profileText=[IO.File]::ReadAllText($sourceConfig)
  if($profileText -notmatch 'logged_profile_slot_0_xuid\s*=\s*"([0-9A-Fa-f]{16})"'){throw 'Missing private profile selection.'}
  $account=$Matches[1];$content=Join-Path $work 'content';$accountDir=Join-Path $content $account
  $null=New-Item -ItemType Directory -Path $accountDir -Force
  foreach($title in @('FFFE07D1','4C4107F2')){
   $src=Join-Path (Join-Path $sourceContent $account) $title;$dest=Join-Path $accountDir $title
   if(-not(Test-Path -LiteralPath $dest) -and (Test-Path -LiteralPath $src)){Copy-Item -LiteralPath $src -Destination $dest -Recurse}
  }
  $ui=Join-Path $work 'storage\config\4C4107F2.config.toml'
  if(Test-Path -LiteralPath $ui){Remove-Item -LiteralPath $ui -Force}
  Add-TFU2NativeTypes $library
  try{
   # The owner's bridge may need a moment to release its finished game watcher.
   for($attempt=0;$attempt -lt 15;$attempt++){
    try{$State.Pad=New-Object TFU2PadV1($library);break}catch{if($attempt -eq 14){throw};Start-Sleep -Milliseconds 200}
   }
   $info=New-Object Diagnostics.ProcessStartInfo
   $info.FileName=$captureExe;$info.WorkingDirectory=$normal;$info.UseShellExecute=$false
   $info.Arguments='--config="{0}" --storage_root="{1}" --content_root="{2}" --cache_root="{3}" --trace_gpu_prefix="{4}" --trace_gpu_stream=false --trace_draw_timing=false --trace_swap_timing=true --log_file="{5}" "{6}"' -f $config,(Join-Path $work 'storage'),$content,(Join-Path $normal 'cache'),($capture.Replace('\','/')+'/'),(Join-Path $runtime 'tfu2-capture.log'),$game
   $info.EnvironmentVariables['SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT']='0x045e/0x028e'
   $info.EnvironmentVariables['SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS']='1'
   $State.Game=[Diagnostics.Process]::Start($info)
   Write-Host ('TFU2 owned test launched: PID '+$State.Game.Id+'; private working save, original save untouched.')
  }catch{if($State.Pad){$State.Pad.Dispose();$State.Remove('Pad')};throw}
  return
 }
 if($cmd.Action.StartsWith('replay-')){
  if(@(Get-Process -Name 'xenia*' -ErrorAction SilentlyContinue).Count){throw 'Stop other Xenia processes before measuring a replay; no concurrent GPU workload.'}
  Assert-TFU2Hash $replayExe '51F9D5560CB541C8BB441A01293F909DCC71BF6C56B40AC0EFDF93CA4BEDEB76'
  $frames=@(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File | Sort-Object LastWriteTime)
  if(-not $frames.Count){throw 'No TFU2 GPU frame captured yet.'}
  $frame=$frames[-1].FullName
  $stream=[IO.File]::OpenRead($frame)
  try{$header=New-Object byte[] 48;if($stream.Read($header,0,48)-ne 48 -or [BitConverter]::ToUInt32($header,0)-ne 1 -or [BitConverter]::ToUInt32($header,44)-ne 0x4C4107F2 -or [Text.Encoding]::ASCII.GetString($header,4,40) -ne '644ba68febd06c4e0affa2c6ea146d0eb7fbfc73'){throw 'Not a supported TFU2 frame.'}}finally{$stream.Dispose()}
  $config=Join-Path $work ($cmd.Action.Substring(7)+'.toml');if(-not(Test-Path $config)){$config=$sourceConfig}
  $log=Join-Path $runtime ('tfu2-'+$cmd.Action+'.log');$image=Join-Path $runtime ('tfu2-'+$cmd.Action+'.png')
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$replayExe;$info.WorkingDirectory=$runtime;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $imageFolder=Join-Path $work $cmd.Action;$null=New-Item -ItemType Directory -Path $imageFolder -Force
  $rendered=Join-Path $imageFolder ([IO.Path]::GetFileNameWithoutExtension($frame)+'.png')
  if(Test-Path -LiteralPath $rendered){Remove-Item -LiteralPath $rendered -Force}
  $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $info.Arguments='--config="{0}" --target_trace_file="{1}" --trace_dump_path="{2}" --trace_draw_timing=true --trace_dump_repeat_count=8 --async_shader_compilation=false --async_shader_skip_draws=false --framerate_limit=0 --guest_display_refresh_cap=false --log_file="{3}"' -f $config,$frame,$imageFolder,$log
  foreach($previous in @($image,$log)){if(Test-Path -LiteralPath $previous){Remove-Item -LiteralPath $previous -Force}}
  $process=[Diagnostics.Process]::Start($info)
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  try{
   $timer=[Diagnostics.Stopwatch]::StartNew()
   while(-not $process.WaitForExit(1000)){
    if($timer.Elapsed.TotalMinutes -ge 5){$process.Kill();$process.WaitForExit();throw 'Owned TFU2 replay timed out.'}
   }
   $console=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
   if($console -and (-not(Test-Path -LiteralPath $log) -or $process.ExitCode -ne 0)){[IO.File]::AppendAllText($log,"`r`nReplay console:`r`n"+$console)}
   if($process.ExitCode -ne 0){throw ('TFU2 replay exit '+$process.ExitCode+'; see replay log.')}
   if(Test-Path -LiteralPath $rendered){Move-Item -LiteralPath $rendered -Destination $image -Force}
  }finally{
   if(-not $process.HasExited){$process.Kill();$process.WaitForExit()}
   $process.Dispose()
  }
  if(-not(Test-Path -LiteralPath $image -PathType Leaf)){throw 'Replay produced no image.'}
  Write-Host ('TFU2 replay complete: '+$image+'; GPU draw timings in '+$log)
  return
 }
 if(-not $State.Game -or $State.Game.HasExited){throw 'No owned TFU2 game running.'}

 if($cmd.Action -eq 'timing-state'){
  if(-not ('TFU2ClockReadV1' -as [type])){
   Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TFU2ClockReadV1 {
 [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr process);
 [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr process,IntPtr address,byte[] data,UIntPtr size,out UIntPtr read);
 static byte[] Read(IntPtr process,uint address){byte[] data=new byte[4];UIntPtr count;if(!ReadProcessMemory(process,new IntPtr((long)0x100000000UL+address),data,(UIntPtr)4,out count)||count.ToUInt64()!=4)throw new Exception("TFU2 timing read failed.");Array.Reverse(data);return data;}
 public static string Snapshot(uint pid){IntPtr p=OpenProcess(0x1010,false,pid);if(p==IntPtr.Zero)throw new Exception("Cannot read owned TFU2 timing state.");try{
  uint engine=BitConverter.ToUInt32(Read(p,0x832216C4),0);if(engine<0x10000||engine>0xFFFFF000)throw new Exception("Invalid TFU2 engine pointer.");
  float rate=BitConverter.ToSingle(Read(p,engine+0x244),0),delta=BitConverter.ToSingle(Read(p,0x831169B8),0),measured=BitConverter.ToSingle(Read(p,0x831169BC),0);
  uint mode=BitConverter.ToUInt32(Read(p,0x832216F0),0);
  return String.Format(System.Globalization.CultureInfo.InvariantCulture,"TFU2 clock: lock={0:F6} mode={1} delta={2:F6} measured={3:F6}",rate,mode,delta,measured);
 }finally{CloseHandle(p);}}
}
'@
  }
  Write-Host ([TFU2ClockReadV1]::Snapshot([uint32]$State.Game.Id));return
 }
 if($cmd.Action -in @('window','Enter')){
  if(-not ('TFU2HostWindowV1' -as [type])){
   Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;
public static class TFU2HostWindowV1 {
 [StructLayout(LayoutKind.Sequential)] struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] static extern IntPtr GetLastActivePopup(IntPtr window);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window,out Rect rect);
 [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window,IntPtr dc,uint flags);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window,uint message,IntPtr w,IntPtr l);
 public static void Run(IntPtr main,uint owner,string path,bool enter){
  IntPtr window=GetLastActivePopup(main);uint pid;GetWindowThreadProcessId(window,out pid);
  if(window==IntPtr.Zero||pid!=owner)throw new Exception("No owned TFU2 window.");
  if(enter){PostMessage(window,0x100,(IntPtr)13,(IntPtr)1);PostMessage(window,0x101,(IntPtr)13,new IntPtr(3221225473L));return;}
  Rect r;if(!GetWindowRect(window,out r))throw new Exception("No owned TFU2 window bounds.");
  int w=r.Right-r.Left,h=r.Bottom-r.Top;if(w<=0||h<=0||w>8192||h>8192)throw new Exception("Invalid TFU2 window dimensions.");
  using(var image=new Bitmap(w,h)){using(var g=Graphics.FromImage(image)){IntPtr dc=g.GetHdc();try{if(!PrintWindow(window,dc,2))throw new Exception("Owned TFU2 window capture failed.");}finally{g.ReleaseHdc(dc);}}image.Save(path,ImageFormat.Png);}
 }
}
'@
  }
  $State.Game.Refresh()
  [TFU2HostWindowV1]::Run($State.Game.MainWindowHandle,[uint32]$State.Game.Id,(Join-Path $work 'window.png'),($cmd.Action -eq 'Enter'))
  Write-Host ('TFU2 owned-window command complete: '+$cmd.Action);return
 }

 if($cmd.Action -in @('capture','snapshot')){
  if($cmd.Action -eq 'capture' -and @(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File -ErrorAction SilentlyContinue).Count -ge 2){throw 'Two-frame capture limit reached; analyze/remove those before capturing more.'}
  $State.Game.Refresh();Add-TFU2NativeTypes $library
  $screens=Join-Path $runtime 'screenshots\4C4107F2'
  $previousShots=@(Get-ChildItem -LiteralPath $screens -Filter '*.png' -File -ErrorAction SilentlyContinue | ForEach-Object {$_.FullName})
  $previousFrames=@(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File -ErrorAction SilentlyContinue | ForEach-Object {$_.FullName})
  [TFU2WindowV1]::Key($State.Game.MainWindowHandle,$(if($cmd.Action -eq 'capture'){0x73}else{0x7B}))
  if($cmd.Action -eq 'snapshot'){
   $image=$null
   for($attempt=0;$attempt -lt 60;$attempt++){
    Start-Sleep -Milliseconds 100
    $image=Get-ChildItem -LiteralPath $screens -Filter '*.png' -File -ErrorAction SilentlyContinue | Where-Object {$_.FullName -notin $previousShots} | Select-Object -First 1
    if($image){break}
   }
   if(-not $image){throw 'TFU2 did not produce a native screenshot.'}
   $ready=$false
   for($attempt=0;$attempt -lt 30;$attempt++){
    try{$stream=[IO.File]::Open($image.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$stream.Dispose();$ready=$true;break}catch{Start-Sleep -Milliseconds 100}
   }
   if(-not $ready){throw 'TFU2 screenshot writer did not finish.'}
   $snapshot=Join-Path $work 'snapshot.png';Copy-Item -LiteralPath $image.FullName -Destination $snapshot -Force
   foreach($old in @(Get-ChildItem -LiteralPath $screens -Filter '*.png' -File)){Remove-Item -LiteralPath $old.FullName -Force}
   Write-Host ('TFU2 native snapshot ready: '+$snapshot)
  }
  if($cmd.Action -eq 'capture'){
   $finished=$null
   for($attempt=0;$attempt -lt 120;$attempt++){
    Start-Sleep -Milliseconds 250
    $newFrame=Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File -ErrorAction SilentlyContinue | Where-Object {$_.FullName -notin $previousFrames} | Select-Object -First 1
    if(-not $newFrame -or -not(Test-Path -LiteralPath ([IO.Path]::ChangeExtension($newFrame.FullName,'.png')))){continue}
    try{
     $stream=[IO.File]::Open($newFrame.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
     try{
      $header=New-Object byte[] 48
      if($stream.Read($header,0,48)-eq 48 -and [BitConverter]::ToUInt32($header,0)-eq 1 -and [BitConverter]::ToUInt32($header,44)-eq 0x4C4107F2){$finished=$newFrame.FullName}
     }finally{$stream.Dispose()}
    }catch{continue}
    if($finished){break}
   }
   if(-not $finished){throw 'TFU2 frame writer did not finish within 30 seconds; game left running.'}
   Write-Host ('TFU2 GPU frame writer finished: '+[IO.Path]::GetFileName($finished))
  }
  Write-Host ('TFU2 '+$cmd.Action+' requested for owned PID '+$State.Game.Id)
  return
 }
 [uint16]$buttons=0;[int16]$lx=0;[int16]$ly=0;[int16]$rx=0
 switch($cmd.Action){
  A{$buttons=0x1000} B{$buttons=0x2000} X{$buttons=0x4000} Y{$buttons=0x8000} Start{$buttons=0x10} Back{$buttons=0x20}
  Up{$buttons=1} Down{$buttons=2} Left{$buttons=4} Right{$buttons=8}
  MoveForward{$ly=22000} MoveBackward{$ly=-22000} CameraLeft{$rx=-18000} CameraRight{$rx=18000}
 }
 if(-not $State.Pad){throw 'No owned TFU2 controller.'}
 if(-not ('TFU2PadReadV1' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TFU2PadReadV1 {
 [StructLayout(LayoutKind.Sequential)] public struct Gamepad {public ushort Buttons;public byte LT,RT;public short LX,LY,RX,RY;}
 [StructLayout(LayoutKind.Sequential)] public struct State {public uint Packet;public Gamepad Pad;}
 [DllImport("xinput1_4.dll")] static extern uint XInputGetState(uint slot,out State state);
 public static uint Buttons(){State state;uint error=XInputGetState(0,out state);if(error!=0)throw new Exception("Owned pad read failed: "+error);return state.Pad.Buttons;}
}
'@
 }
 try{
  $State.Pad.Update($buttons,$lx,$ly,$rx,0);Start-Sleep -Milliseconds 20
  $actual=[TFU2PadReadV1]::Buttons()
  if($actual -ne $buttons){throw ('Owned pad button mismatch: expected '+$buttons+' actual '+$actual)}
  Start-Sleep -Milliseconds $cmd.Milliseconds
 }finally{$State.Pad.Update(0,0,0,0,0)}
 Write-Host ('TFU2 input completed: '+$cmd.Action+' '+$cmd.Milliseconds+' ms')
}
if(-not $FunctionsOnly){
 if(-not $Session){throw 'TFU2 session state was not supplied.'}
 $command=Read-TFU2Request $Request
 try{Invoke-TFU2Command $Root $Request $Session;Write-Host ('TFU2 command complete: '+$command.Id+' '+$command.Action)}catch{Write-Host ('TFU2 command failed: '+$command.Id+' '+$_.Exception.Message) -ForegroundColor Red}
}
