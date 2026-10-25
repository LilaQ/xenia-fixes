$ErrorActionPreference='Stop'
try {
 $normal=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
 $emulators=Split-Path -Parent $normal
 $lb=Split-Path -Parent $emulators
 $runtime=$normal
 $exe=Join-Path $normal 'xenia_edge_cartel.exe'
 $config=Join-Path $normal "config\games\Army of Two_ The Devil's Cartel [bbc9ee54].toml"
 $game=Join-Path $lb 'Games\Microsoft Xbox 360\Army of Two the Devil Cartel [RF]\Army of Two the Devil Cartel [RF]\DVD.iso'
 $capture=Join-Path $normal 'diagnostics\Devils-Cartel\capture'
 foreach($path in @($exe,$config,$game)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw ('Datei fehlt: '+$path)}}
 if(@(Get-Process -Name 'xenia_edge*','xenia_canary*','xenia_trace*' -ErrorAction SilentlyContinue).Count){throw 'Bitte zuerst alle Xenia-Fenster schliessen.'}
 # Restore only this title's tested UI overrides after the no-Xenia guard.
 $titleConfig=Join-Path $normal 'config\454109AB.config.toml'
 $baseline=@'
# Game-specific config overrides
# Title ID: 454109AB

[GPU]
gpu = "d3d12"
async_shader_vs_interpreter = false
async_shader_skip_draws = false
async_shader_compilation = false
framerate_limit = 60
guest_display_refresh_cap = false
occlusion_query = 'fast'
occlusion_query_viz = false
readback_resolve = true
render_target_path = "performance"

[Kernel]
guest_scheduler = false
'@
 $oldTitle=[IO.File]::ReadAllText($titleConfig)
 if($oldTitle.Trim() -ne $baseline.Trim()){
  $backup=Join-Path $lb 'Backups\Codex-Cartel-City-20261023'
  $null=New-Item -ItemType Directory -Path $backup -Force
  $savedTitle=Join-Path $backup '454109AB.config.toml'
  if(-not(Test-Path -LiteralPath $savedTitle)){[IO.File]::WriteAllText($savedTitle,$oldTitle)}
  [IO.File]::WriteAllText($titleConfig,$baseline+[Environment]::NewLine)
 }
 $null=New-Item -ItemType Directory -Path $capture -Force
 $existingTraceCount=@(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File).Count
 $request=Join-Path $capture 'capture.request'
 if(Test-Path -LiteralPath $request){Remove-Item -LiteralPath $request -Force}
 if(-not ('CartelCaptureWindow' -as [type])){
  Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class CartelCaptureWindow {
 delegate bool Visitor(IntPtr window,IntPtr data);
 [StructLayout(LayoutKind.Sequential)] struct Rect {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,Visitor callback,IntPtr data);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window,out Rect rect);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window,uint message,IntPtr wParam,IntPtr lParam);
 public static void Capture(IntPtr parent){
  IntPtr panel=parent;long area=0;
  EnumChildWindows(parent,delegate(IntPtr child,IntPtr data){Rect rect;if(IsWindowVisible(child)&&GetClientRect(child,out rect)){long n=(long)(rect.Right-rect.Left)*(rect.Bottom-rect.Top);if(n>area){area=n;panel=child;}}return true;},IntPtr.Zero);
  if(!PostMessage(panel,0x100,new IntPtr(0x73),new IntPtr(1)))throw new Exception("F4 konnte nicht zugestellt werden.");
  PostMessage(panel,0x101,new IntPtr(0x73),new IntPtr(3221225473L));
 }
}
'@
 }
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=$exe
 $info.WorkingDirectory=$runtime
 $info.UseShellExecute=$false
 $info.Arguments='--config="{0}" --storage_root="{1}" --trace_gpu_prefix="{2}/" --trace_gpu_stream=false --trace_gpu_frame_count=4 --gpu=d3d12 --render_target_path=performance --readback_resolve=true --framerate_limit=60 --guest_display_refresh_cap=false --occlusion_query=fast --occlusion_query_viz=false --async_shader_compilation=false --async_shader_skip_draws=false --async_shader_vs_interpreter=false --guest_scheduler=false --draw_resolution_scale_x=1 --draw_resolution_scale_y=1 --time_scalar=1 --d3d12_skip_no_effect_draws=true --d3d12_mirror_host_geometry=true --d3d12_split_geometry_copy_fence=true --trace_swap_timing=true --trace_draw_timing=false --trace_submission_timing=false --trace_cpu_timing=false --d3d12_await_host_buffer_reads=true --memexport_await_vertex_exports=true --fullscreen=true --log_file="{3}" "{4}"' -f $config,$normal,$capture.Replace('\','/'),(Join-Path $capture 'xenia.log'),$game
 $process=[Diagnostics.Process]::Start($info)
 Write-Host 'Devils-Cartel-Framehelfer aktiv. Selbst zur Fehlerstelle gehen; dieses Fenster offen lassen.' -ForegroundColor Cyan
 Write-Host 'Der Helfer akzeptiert eine F4-Serie mit vier aufeinanderfolgenden GPU-Frames. Keine Fahr-/Spielsteuerung.'
 $seen='';$issued=0
 while(-not $process.HasExited){
  Start-Sleep -Milliseconds 250
  if(-not(Test-Path -LiteralPath $request)){continue}
  try{$text=[IO.File]::ReadAllText($request).Trim()}catch{continue}
  if($text -eq $seen -or $text -notmatch '^capture:[0-9a-f]{32}$'){continue}
  $seen=$text
  $frames=@(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File)
  $bytes=($frames | Measure-Object -Property Length -Sum).Sum
  if($issued -ge 1 -or $frames.Count -gt $existingTraceCount -or $bytes -ge 536870912){Write-Warning 'Aufnahmegrenze erreicht. Vorhandene Frames zuerst auswerten.';continue}
  $process.Refresh()
  if($process.MainWindowHandle -eq [IntPtr]::Zero){Write-Warning 'Spielfenster noch nicht bereit.';continue}
  [CartelCaptureWindow]::Capture($process.MainWindowHandle)
  $issued++
  Write-Host ('Serie mit vier lueckenlosen GPU-Frames angefordert: '+$issued)
 }
 $process.Dispose()
} catch {Write-Host ($_ | Out-String) -ForegroundColor Red;Read-Host 'Enter zum Schliessen'}
