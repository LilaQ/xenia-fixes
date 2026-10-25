param([string]$Root=$env:GAT_TRACE_DIR,[string]$Request,[hashtable]$Session,[switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
function Read-EvilWithinRequest([string]$Text) {
 if($Text -notmatch '^evil:([0-9a-f]{32}):(status|launch-baseline|launch-candidate|stop|capture|snapshot|window|restore-controller|bind-keyboard|Enter|replay-paused|replay-baseline|replay-candidate|clear-captures|A|B|X|Y|Start|Back|Up|Down|Left|Right|MoveForward|MoveBackward|CameraLeft|CameraRight)(?::([0-9]{1,4}))?$'){throw 'Invalid EvilWithin command.'}
 $ms=if($Matches[3]){[int]$Matches[3]}else{150}
 if($ms -lt 20 -or $ms -gt 5000){throw 'EvilWithin input duration must be 20..5000 ms.'}
 [pscustomobject]@{Id=$Matches[1];Action=$Matches[2];Milliseconds=$ms}
}
function Assert-EvilWithinHash([string]$Path,[string]$Hash) {
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash){throw ('Unexpected EvilWithin test binary: '+[IO.Path]::GetFileName($Path))}
}
function Get-EvilWithinProcesses([string]$Exe) {
 @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $Exe})
}
function Add-EvilWithinNativeTypes([string]$Library) {
 if('EvilWithinPadV1' -as [type]){return}
 Assert-EvilWithinHash $Library '00303F99E1968D523FBD08A7C691D60D145B7335059EC593947841D124C10875'
 Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public sealed class EvilWithinPadV1 : IDisposable {
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
 public EvilWithinPadV1(string library){
  if(LoadLibrary(library)==IntPtr.Zero)throw new InvalidOperationException("Cannot load installed controller client.");
  try{client=vigem_alloc();if(client==IntPtr.Zero)throw new InvalidOperationException("Controller allocation failed.");Check(vigem_connect(client));target=vigem_target_x360_alloc();if(target==IntPtr.Zero)throw new InvalidOperationException("Pad allocation failed.");Check(vigem_target_add(client,target));added=true;uint index;Check(vigem_target_x360_get_user_index(client,target,out index));if(index!=0)throw new InvalidOperationException("Player-one slot occupied; other controllers were left untouched.");}catch{Dispose();throw;}
 }
 public void Update(ushort buttons,short lx,short ly,short rx,short ry){Check(vigem_target_x360_update(client,target,new Report{Buttons=buttons,LX=lx,LY=ly,RX=rx,RY=ry}));}
 public void Dispose(){if(target!=IntPtr.Zero){if(added)vigem_target_remove(client,target);vigem_target_free(target);target=IntPtr.Zero;added=false;}if(client!=IntPtr.Zero){vigem_disconnect(client);vigem_free(client);client=IntPtr.Zero;}}
}
public static class EvilWithinWindowV1 {
 delegate bool Visitor(IntPtr window,IntPtr data);
 [StructLayout(LayoutKind.Sequential)] struct Rect {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,Visitor visit,IntPtr data);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window,out Rect rect);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window,uint message,IntPtr wParam,IntPtr lParam);
 public static void Key(IntPtr parent,int key){
  IntPtr panel=parent;long area=0;
  EnumChildWindows(parent,delegate(IntPtr child,IntPtr ignored){Rect r;if(IsWindowVisible(child)&&GetClientRect(child,out r)){long a=(long)(r.Right-r.Left)*(r.Bottom-r.Top);if(a>area){area=a;panel=child;}}return true;},IntPtr.Zero);
  if(parent==IntPtr.Zero||!PostMessage(panel,0x100,(IntPtr)key,(IntPtr)1))throw new InvalidOperationException("EvilWithin window is not ready.");
  PostMessage(panel,0x101,(IntPtr)key,new IntPtr(3221225473L));
 }
}
'@
}
function Sync-EvilWithinTest([hashtable]$State,[string]$CaptureExe,[string]$Storage) {
 # The first Agility runtime installation restarts Xenia. Adopt only its direct
 # child with the same executable and the private working-storage argument.
 if(-not $State.Game -or -not $State.Game.HasExited){return}
 $parentId=$State.Game.Id
 foreach($child in @(Get-CimInstance Win32_Process -Filter ("Name='"+[IO.Path]::GetFileName($CaptureExe)+"'"))){
  if($child.ParentProcessId -eq $parentId -and $child.ExecutablePath -eq $CaptureExe -and $child.CommandLine -and $child.CommandLine.IndexOf($Storage,[StringComparison]::OrdinalIgnoreCase) -ge 0){
   $next=Get-Process -Id $child.ProcessId -ErrorAction Stop
   $State.Game.Dispose();$State.Game=$next
   Write-Host ('EvilWithin adopted its runtime-install restart: PID '+$next.Id)
   return
  }
 }
}
function Stop-EvilWithinTest([hashtable]$State,[string]$CaptureExe) {
 if($State.Pad){$State.Pad.Update(0,0,0,0,0)}
 if($State.Game -and -not $State.Game.HasExited){
  if($State.Game.Path -ne $CaptureExe){throw 'Refusing to close an unowned process.'}
  $null=$State.Game.CloseMainWindow()
  if(-not $State.Game.WaitForExit(10000)){$State.Game.Kill();$State.Game.WaitForExit()}
 }
 if($State.Pad){$State.Pad.Dispose();$State.Remove('Pad')}
 if($State.Game){$State.Game.Dispose();$State.Remove('Game')}
}
function Invoke-EvilWithinCommand([string]$TraceRoot,[string]$Text,[hashtable]$State) {
 $cmd=Read-EvilWithinRequest $Text
 $emulators=Split-Path -Parent $TraceRoot;$lb=Split-Path -Parent $emulators
 $normal=Join-Path $emulators 'Xenia Edge'
 $diagnostics=Join-Path $normal 'diagnostics\EvilWithin';$runtime=Join-Path $diagnostics 'runtime'
 $work=Join-Path $runtime 'work';$capture=Join-Path $diagnostics 'capture'
 $captureExe=Join-Path $normal 'xenia_edge_evilwithin.exe';$replayExe=Join-Path $normal 'diagnostics\TFU2\runtime\xenia_evilwithin_replay.exe'
 $library=Join-Path $TraceRoot 'runtime\ViGEmClient.dll'
 Sync-EvilWithinTest $State $captureExe $normal
 $sourceConfig=Join-Path $normal 'config\games\The Evil Within [a743cd71].toml'
 $sourceContent=Join-Path $emulators 'Xenia Canary\content'
 $game=Join-Path $lb 'Games\Microsoft Xbox 360\The Evil Within [NTSCU]\The Evil Within [NTSCU].iso'
 if($cmd.Action -eq 'status'){
  $running=@(Get-EvilWithinProcesses (Join-Path $normal 'xenia_edge_tfu2.exe')).Count
  $owned=@(Get-EvilWithinProcesses $captureExe).Count
  Write-Host ('EvilWithin status: normal='+$running+'; owned='+$owned+'; captures='+@(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File -ErrorAction SilentlyContinue).Count)
  return
 }
 if($cmd.Action -eq 'clear-captures'){
  if($State.Game -and -not $State.Game.HasExited){throw 'Stop the owned test before removing its captures.'}
  foreach($f in @(Get-ChildItem -LiteralPath $capture -File -ErrorAction SilentlyContinue | Where-Object {$_.Extension -in @('.xtr','.png')})){Remove-Item -LiteralPath $f.FullName -Force}
  Write-Host 'EvilWithin diagnostic captures removed without backups.';return
 }
 if($cmd.Action -eq 'stop'){Stop-EvilWithinTest $State $captureExe;Write-Host 'Owned EvilWithin test stopped.';return}
 if($cmd.Action.StartsWith('launch-')){
  Stop-EvilWithinTest $State $captureExe
  # Only the explicitly authorized EvilWithin process may be closed. Never kill the
  # owner's normal process; a hung close is reported without touching it.
  if(@(Get-Process -Name 'xenia*' -ErrorAction SilentlyContinue).Count){throw 'Another Xenia is running; left unchanged.'}
  Assert-EvilWithinHash $captureExe '4D5EAE0A04966AB1AF8B899DF4A417296EC922E79535D7C2BE40F1025722702D'
  foreach($p in @($sourceConfig,$game)){if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw 'Missing EvilWithin test input.'}}
  $null=New-Item -ItemType Directory -Path $work,$capture,(Join-Path $work 'storage\config') -Force
  $config=Join-Path $work ($cmd.Action.Substring(7)+'.toml')
  if(-not(Test-Path -LiteralPath $config)){Copy-Item -LiteralPath $sourceConfig -Destination $config}
  $profileText=[IO.File]::ReadAllText($sourceConfig)
  if($profileText -notmatch 'logged_profile_slot_0_xuid\s*=\s*"([0-9A-Fa-f]{16})"'){throw 'Missing private profile selection.'}
  $content=$sourceContent
  $ui=Join-Path $work 'storage\config\425307F4.config.toml'
  Add-EvilWithinNativeTypes $library
  try{
   $info=New-Object Diagnostics.ProcessStartInfo
   $info.FileName=$captureExe;$info.WorkingDirectory=$normal;$info.UseShellExecute=$false
   $info.Arguments='--config="{0}" --storage_root="{1}" --content_root="{2}" --cache_root="{3}" --trace_gpu_prefix="{4}" --trace_gpu_stream=false --trace_draw_timing=false --trace_swap_timing=true --trace_readback_timing=true --log_file="{5}" "{6}"' -f $config,$normal,$content,(Join-Path $normal 'cache'),($capture.Replace('\','/')+'/'),(Join-Path $runtime 'evil-capture.log'),$game
   $info.EnvironmentVariables.Remove('SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT')
   $info.EnvironmentVariables.Remove('SDL_GAMECONTROLLER_IGNORE_DEVICES')
   $info.EnvironmentVariables.Remove('SDL_JOYSTICK_IGNORE_DEVICES_EXCEPT')
   $info.EnvironmentVariables.Remove('SDL_JOYSTICK_IGNORE_DEVICES')
   $info.EnvironmentVariables['SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS']='1'
   $State.Game=[Diagnostics.Process]::Start($info)
   Write-Host ('EvilWithin owned test launched: PID '+$State.Game.Id+'; existing game content and save selected.')
  }catch{if($State.Pad){$State.Pad.Dispose();$State.Remove('Pad')};throw}
  return
 }
 if($cmd.Action.StartsWith('replay-')){
  $other=@(Get-Process -Name 'xenia*' -ErrorAction SilentlyContinue)
  if($cmd.Action -ne 'replay-paused' -and $other.Count){throw 'Stop other Xenia processes before measuring a replay; no concurrent GPU workload.'}
  if($cmd.Action -eq 'replay-paused' -and (-not $State.Game -or $State.Game.HasExited -or @($other | Where-Object {$_.Id -ne $State.Game.Id}).Count)){throw 'Paused replay requires only the owned game to be running.'}
  Assert-EvilWithinHash $replayExe '94AE7B186340C307D42D91C2C91257ADE42293C59F8D48F123BF8BC9376F8F91'
  $frames=@(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File | Sort-Object LastWriteTime)
  if(-not $frames.Count){throw 'No EvilWithin GPU frame captured yet.'}
  $frame=$frames[-1].FullName
  $stream=[IO.File]::OpenRead($frame)
  try{$header=New-Object byte[] 48;if($stream.Read($header,0,48)-ne 48 -or [BitConverter]::ToUInt32($header,0)-ne 1 -or [BitConverter]::ToUInt32($header,44)-ne 0x425307F4 -or [Text.Encoding]::ASCII.GetString($header,4,40) -ne '644ba68febd06c4e0affa2c6ea146d0eb7fbfc73'){throw 'Not a supported EvilWithin frame.'}}finally{$stream.Dispose()}
  $config=Join-Path $work ($cmd.Action.Substring(7)+'.toml');if(-not(Test-Path $config)){$config=$sourceConfig}
  $log=Join-Path $runtime ('evil-'+$cmd.Action+'.log');$image=Join-Path $runtime ('evil-'+$cmd.Action+'.png')
  $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$replayExe;$info.WorkingDirectory=(Split-Path -Parent $replayExe);$info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $imageFolder=Join-Path $work $cmd.Action;$null=New-Item -ItemType Directory -Path $imageFolder -Force
  $rendered=Join-Path $imageFolder ([IO.Path]::GetFileNameWithoutExtension($frame)+'.png')
  if(Test-Path -LiteralPath $rendered){Remove-Item -LiteralPath $rendered -Force}
  $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $info.Arguments='--config="{0}" --target_trace_file="{1}" --trace_dump_path="{2}" --trace_draw_timing=true --trace_dump_repeat_count=16 --async_shader_compilation=false --async_shader_skip_draws=false --framerate_limit=0 --guest_display_refresh_cap=false --log_file="{3}"' -f $config,$frame,$imageFolder,$log
  foreach($previous in @($image,$log)){if(Test-Path -LiteralPath $previous){Remove-Item -LiteralPath $previous -Force}}
  $paused=$null
  if($cmd.Action -eq 'replay-paused'){
   if(-not ('EvilWithinSuspendV1' -as [type])){
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class EvilWithinSuspendV1 {
 [DllImport("ntdll.dll")]public static extern int NtSuspendProcess(IntPtr h);
 [DllImport("ntdll.dll")]public static extern int NtResumeProcess(IntPtr h);
}
'@
   }
   if($State.Game.Path -ne $captureExe){throw 'Not the owned game.'}
   if([EvilWithinSuspendV1]::NtSuspendProcess($State.Game.Handle) -ne 0){throw 'Cannot suspend owned game.'}
   $paused=$State.Game
   Write-Host ('Temporarily paused owned game PID '+$paused.Id+' for isolated replay; resumes in finally.')
   Start-Sleep -Milliseconds 500
  }
  try {
  $process=[Diagnostics.Process]::Start($info)
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  try{
   $timer=[Diagnostics.Stopwatch]::StartNew()
   while(-not $process.WaitForExit(1000)){
    if($timer.Elapsed.TotalMinutes -ge 5){$process.Kill();$process.WaitForExit();throw 'Owned EvilWithin replay timed out.'}
   }
   $console=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
   if($console -and (-not(Test-Path -LiteralPath $log) -or $process.ExitCode -ne 0)){[IO.File]::AppendAllText($log,"`r`nReplay console:`r`n"+$console)}
   if($process.ExitCode -ne 0){throw ('EvilWithin replay exit '+$process.ExitCode+'; see replay log.')}
   if(Test-Path -LiteralPath $rendered){Move-Item -LiteralPath $rendered -Destination $image -Force}
  }finally{
   if(-not $process.HasExited){$process.Kill();$process.WaitForExit()}
   $process.Dispose()
  }
  if(-not(Test-Path -LiteralPath $image -PathType Leaf)){throw 'Replay produced no image.'}
  } finally {
   if($paused -and -not $paused.HasExited){
    if([EvilWithinSuspendV1]::NtResumeProcess($paused.Handle) -ne 0){throw 'Resume failed; owned game needs manual attention.'}
    Write-Host ('Resumed owned game PID '+$paused.Id)
   }
  }
  Write-Host ('EvilWithin replay complete: '+$image+'; GPU draw timings in '+$log)
  return
 }
 if(-not $State.Game -or $State.Game.HasExited){throw 'No owned EvilWithin game running.'}

 if($cmd.Action -in @('restore-controller','bind-keyboard')){
  Add-EvilWithinNativeTypes $library
  if(-not ('EvilWithinMenuRestoreV2' -as [type])){
   Add-Type -TypeDefinition @'
using System;using System.Text;using System.Threading;using System.Runtime.InteropServices;
public static class EvilWithinMenuRestoreV2 {
 [DllImport("user32.dll")]static extern IntPtr GetMenu(IntPtr w);
 [DllImport("user32.dll")]static extern IntPtr GetSubMenu(IntPtr m,int p);
 [DllImport("user32.dll")]static extern int GetMenuItemCount(IntPtr m);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetMenuString(IntPtr m,uint p,StringBuilder s,int n,uint f);
 [DllImport("user32.dll")]static extern uint GetMenuItemID(IntPtr m,int p);
 [DllImport("user32.dll")]static extern bool PostMessage(IntPtr w,uint m,IntPtr k,IntPtr l);
 static string Label(IntPtr m,int i){var s=new StringBuilder(256);GetMenuString(m,(uint)i,s,256,0x400);return s.ToString().Replace("&","");}
 static IntPtr Find(IntPtr m,string label){for(int i=0;i<GetMenuItemCount(m);i++){var s=GetSubMenu(m,i);if(Label(m,i).StartsWith(label,StringComparison.OrdinalIgnoreCase))return s;if(s!=IntPtr.Zero){var x=Find(s,label);if(x!=IntPtr.Zero)return x;}}return IntPtr.Zero;}
 public static string Restore(IntPtr w,string device){
  IntPtr menu=GetMenu(w);if(menu==IntPtr.Zero)throw new Exception("Menu not visible; no binding changed.");
  IntPtr slot=Find(menu,"Slot 1");if(slot==IntPtr.Zero)throw new Exception("Slot 1 menu missing.");
  uint id=0;string name="";int n=0;
  for(int i=0;i<GetMenuItemCount(slot);i++){string l=Label(slot,i);if(l.Contains(device)){id=GetMenuItemID(slot,i);name=l;n++;}}
  if(n!=1||id==0||id==0xFFFFFFFF)throw new Exception("Xbox entry ambiguous or missing; no binding changed.");
  if(!PostMessage(w,0x111,(IntPtr)id,IntPtr.Zero))throw new Exception("Controller binding event failed.");
  Thread.Sleep(500);menu=GetMenu(w);
  for(int i=0;i<GetMenuItemCount(menu);i++){} // Refresh performed by Xenia's binding callback.
  return "Bound Slot 1 to "+name;
 }
}
'@
  }
  $State.Game.Refresh()
  [EvilWithinWindowV1]::Key($State.Game.MainWindowHandle,0x7A)
  Start-Sleep -Milliseconds 500
  try{Write-Host ([EvilWithinMenuRestoreV2]::Restore($State.Game.MainWindowHandle,$(if($cmd.Action -eq 'bind-keyboard'){'Keyboard'}else{'Xbox Series X Controller'})))}
  finally{[EvilWithinWindowV1]::Key($State.Game.MainWindowHandle,0x7A)}
  return
 }
 if($cmd.Action -in @('window','Enter')){
  if(-not ('EvilWithinHostWindowV1' -as [type])){
   Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;
public static class EvilWithinHostWindowV1 {
 [StructLayout(LayoutKind.Sequential)] struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] static extern IntPtr GetLastActivePopup(IntPtr window);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window,out Rect rect);
 [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window,IntPtr dc,uint flags);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window,out uint pid);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window,uint message,IntPtr w,IntPtr l);
 public static void Run(IntPtr main,uint owner,string path,bool enter){
  IntPtr window=GetLastActivePopup(main);uint pid;GetWindowThreadProcessId(window,out pid);
  if(window==IntPtr.Zero||pid!=owner)throw new Exception("No owned EvilWithin window.");
  if(enter){PostMessage(window,0x100,(IntPtr)13,(IntPtr)1);PostMessage(window,0x101,(IntPtr)13,new IntPtr(3221225473L));return;}
  Rect r;if(!GetWindowRect(window,out r))throw new Exception("No owned EvilWithin window bounds.");
  int w=r.Right-r.Left,h=r.Bottom-r.Top;if(w<=0||h<=0||w>8192||h>8192)throw new Exception("Invalid EvilWithin window dimensions.");
  using(var image=new Bitmap(w,h)){using(var g=Graphics.FromImage(image)){IntPtr dc=g.GetHdc();try{if(!PrintWindow(window,dc,2))throw new Exception("Owned EvilWithin window capture failed.");}finally{g.ReleaseHdc(dc);}}image.Save(path,ImageFormat.Png);}
 }
}
'@
  }
  $State.Game.Refresh()
  [EvilWithinHostWindowV1]::Run($State.Game.MainWindowHandle,[uint32]$State.Game.Id,(Join-Path $work 'window.png'),($cmd.Action -eq 'Enter'))
  Write-Host ('EvilWithin owned-window command complete: '+$cmd.Action);return
 }

 if($cmd.Action -in @('capture','snapshot')){
  if($cmd.Action -eq 'capture' -and @(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File -ErrorAction SilentlyContinue).Count -ge 2){throw 'Two-frame capture limit reached; analyze/remove those before capturing more.'}
  $State.Game.Refresh();Add-EvilWithinNativeTypes $library
  $screens=Join-Path (Split-Path -Parent $captureExe) 'screenshots\425307F4'
  $previousShots=@(Get-ChildItem -LiteralPath $screens -Filter '*.png' -File -ErrorAction SilentlyContinue | ForEach-Object {$_.FullName})
  $previousFrames=@(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File -ErrorAction SilentlyContinue | ForEach-Object {$_.FullName})
  [EvilWithinWindowV1]::Key($State.Game.MainWindowHandle,$(if($cmd.Action -eq 'capture'){0x73}else{0x7B}))
  if($cmd.Action -eq 'snapshot'){
   $image=$null
   for($attempt=0;$attempt -lt 60;$attempt++){
    Start-Sleep -Milliseconds 100
    $image=Get-ChildItem -LiteralPath $screens -Filter '*.png' -File -ErrorAction SilentlyContinue | Where-Object {$_.FullName -notin $previousShots} | Select-Object -First 1
    if($image){break}
   }
   if(-not $image){throw 'EvilWithin did not produce a native screenshot.'}
   $ready=$false
   for($attempt=0;$attempt -lt 30;$attempt++){
    try{$stream=[IO.File]::Open($image.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$stream.Dispose();$ready=$true;break}catch{Start-Sleep -Milliseconds 100}
   }
   if(-not $ready){throw 'EvilWithin screenshot writer did not finish.'}
   $snapshot=Join-Path $work 'snapshot.png';Copy-Item -LiteralPath $image.FullName -Destination $snapshot -Force
   foreach($old in @(Get-ChildItem -LiteralPath $screens -Filter '*.png' -File)){Remove-Item -LiteralPath $old.FullName -Force}
   Write-Host ('EvilWithin native snapshot ready: '+$snapshot)
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
      if($stream.Read($header,0,48)-eq 48 -and [BitConverter]::ToUInt32($header,0)-eq 1 -and [BitConverter]::ToUInt32($header,44)-eq 0x425307F4){$finished=$newFrame.FullName}
     }finally{$stream.Dispose()}
    }catch{continue}
    if($finished){break}
   }
   if(-not $finished){throw 'EvilWithin frame writer did not finish within 30 seconds; game left running.'}
   Write-Host ('EvilWithin GPU frame writer finished: '+[IO.Path]::GetFileName($finished))
  }
  Write-Host ('EvilWithin '+$cmd.Action+' requested for owned PID '+$State.Game.Id)
  return
 }
 [uint16]$buttons=0;[int16]$lx=0;[int16]$ly=0;[int16]$rx=0
 switch($cmd.Action){
  A{$buttons=0x1000} B{$buttons=0x2000} X{$buttons=0x4000} Y{$buttons=0x8000} Start{$buttons=0x10} Back{$buttons=0x20}
  Up{$buttons=1} Down{$buttons=2} Left{$buttons=4} Right{$buttons=8}
  MoveForward{$ly=22000} MoveBackward{$ly=-22000} CameraLeft{$rx=-18000} CameraRight{$rx=18000}
 }
 if(-not $State.Pad){
  if(-not ('EvilWithinKeyboardV3' -as [type])){
   Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class EvilWithinKeyboardV3 {
 [StructLayout(LayoutKind.Explicit,Size=40)] struct KeyboardInput {
  [FieldOffset(0)] public uint Type;
  [FieldOffset(8)] public ushort Key;
  [FieldOffset(12)] public uint Flags;
 }
 [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint count,KeyboardInput[] input,int size);
 [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();

 delegate bool Visitor(IntPtr w,IntPtr data);
 [StructLayout(LayoutKind.Sequential)] struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p,Visitor v,IntPtr d);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr w,out Rect r);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr w);
 [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr w);
 [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr w,IntPtr p);
 [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a,uint b,bool attach);
 [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr w);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr w,uint m,IntPtr k,IntPtr l);
 public static void Hold(IntPtr parent,int key,int ms){
  if(parent==IntPtr.Zero)throw new Exception("Owned game window missing.");
  IntPtr panel=parent;long area=0;
  EnumChildWindows(parent,delegate(IntPtr w,IntPtr d){Rect r;if(IsWindowVisible(w)&&GetClientRect(w,out r)){long a=(long)(r.Right-r.Left)*(r.Bottom-r.Top);if(a>area){area=a;panel=w;}}return true;},IntPtr.Zero);
  uint inputThread=GetCurrentThreadId(),windowThread=GetWindowThreadProcessId(panel,IntPtr.Zero);
  bool attached=AttachThreadInput(inputThread,windowThread,true);
  try{SetForegroundWindow(parent);SetFocus(panel);}finally{if(attached)AttachThreadInput(inputThread,windowThread,false);}
  Thread.Sleep(100);
  if(GetForegroundWindow()!=parent)throw new Exception("Owned test is not foreground; no global input injected.");
  try{if(SendInput(1,new[]{new KeyboardInput{Type=1,Key=(ushort)key}},40)!=1)throw new Exception("Owned key-down failed.");Thread.Sleep(ms);}
  finally{SendInput(1,new[]{new KeyboardInput{Type=1,Key=(ushort)key,Flags=2}},40);}

 }
}
'@
  }
  $key=switch($cmd.Action){A{0xBA} B{0xDE} X{0x4C} Y{0x50} Start{0x58} Back{0x5A} Up{0x57} Down{0x53} Left{0x41} Right{0x44} MoveForward{0x57} MoveBackward{0x53} CameraLeft{0x25} CameraRight{0x27} default{throw 'Unsupported owned keyboard action.'}}
  [EvilWithinKeyboardV3]::Hold($State.Game.MainWindowHandle,[int]$key,$cmd.Milliseconds)
  Write-Host ('EvilWithin owned keyboard command: '+$cmd.Action);return
 }

 if(-not ('EvilWithinPadReadV1' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EvilWithinPadReadV1 {
 [StructLayout(LayoutKind.Sequential)] public struct Gamepad {public ushort Buttons;public byte LT,RT;public short LX,LY,RX,RY;}
 [StructLayout(LayoutKind.Sequential)] public struct State {public uint Packet;public Gamepad Pad;}
 [DllImport("xinput1_4.dll")] static extern uint XInputGetState(uint slot,out State state);
 public static uint Buttons(){State state;uint error=XInputGetState(0,out state);if(error!=0)throw new Exception("Owned pad read failed: "+error);return state.Pad.Buttons;}
}
'@
 }
 try{
  $State.Pad.Update($buttons,$lx,$ly,$rx,0);Start-Sleep -Milliseconds 20
  $actual=[EvilWithinPadReadV1]::Buttons()
  if($actual -ne $buttons){throw ('Owned pad button mismatch: expected '+$buttons+' actual '+$actual)}
  Start-Sleep -Milliseconds $cmd.Milliseconds
 }finally{$State.Pad.Update(0,0,0,0,0)}
 Write-Host ('EvilWithin input completed: '+$cmd.Action+' '+$cmd.Milliseconds+' ms')
}
if(-not $FunctionsOnly){
 if(-not $Session){throw 'EvilWithin session state was not supplied.'}
 $command=Read-EvilWithinRequest $Request
 try{Invoke-EvilWithinCommand $Root $Request $Session;Write-Host ('EvilWithin command complete: '+$command.Id+' '+$command.Action)}catch{Write-Host ('EvilWithin command failed: '+$command.Id+' '+$_.Exception.Message) -ForegroundColor Red}
}
