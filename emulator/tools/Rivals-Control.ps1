param([string]$TraceRoot)
$ErrorActionPreference='Stop'
$rivalsRuntime='D:\LaunchBox\Emulators\Xenia Edge\diagnostics\Rivals\runtime'
$rivalsTools=Join-Path $TraceRoot 'runtime'
$exe=Join-Path $rivalsTools 'xenia_rivals_trace.exe'
$rivalsWork=Join-Path $rivalsRuntime 'work'
$process=$null;$pad=$null;$seen='';$end=$false
function Initialize-RivalsWork {
$rivalsRuntime='D:\LaunchBox\Emulators\Xenia Edge\diagnostics\Rivals\runtime'
$rivalsWork=Join-Path $rivalsRuntime 'work'
$config='D:\LaunchBox\Emulators\Xenia Edge\config\games\Need for Speed_ Rivals [bef37e7b].toml'
$text=[IO.File]::ReadAllText($config)
if($text -notmatch 'logged_profile_slot_0_xuid\s*=\s*"([0-9A-Fa-f]{16})"'){throw 'Missing configured profile.'}
$account=$Matches[1]
$source='D:\LaunchBox\Emulators\Xenia Canary\content'
$null=New-Item -ItemType Directory -Force -Path $rivalsWork,(Join-Path $rivalsWork 'content'),(Join-Path $rivalsWork ('content\'+$account)),(Join-Path $rivalsWork 'storage\config'),(Join-Path $rivalsWork 'storage\patches'),(Join-Path $rivalsRuntime 'auto-capture')
$global=Join-Path $rivalsWork 'content\0000000000000000'
if(-not(Test-Path -LiteralPath $global)){$null=New-Item -ItemType Junction -Path $global -Target (Join-Path $source '0000000000000000')}
foreach($title in @('FFFE07D1','454109C6')){
 $src=Join-Path $source ($account+'\'+$title);$dst=Join-Path $rivalsWork ('content\'+$account+'\'+$title)
 if((Test-Path -LiteralPath $src) -and -not(Test-Path -LiteralPath $dst)){Copy-Item -LiteralPath $src -Destination $dst -Recurse}
}
Copy-Item -LiteralPath $config -Destination (Join-Path $rivalsWork 'Rivals.toml') -Force
Copy-Item -LiteralPath 'D:\LaunchBox\Emulators\Xenia Edge\config\454109C6.config.toml' -Destination (Join-Path $rivalsWork 'storage\config\454109C6.config.toml') -Force
$uiPath=Join-Path $rivalsWork 'storage\config\454109C6.config.toml'
$ui=[IO.File]::ReadAllText($uiPath) -replace '(?m)^(guest_display_refresh_cap\s*=\s*)true','$1false'
[IO.File]::WriteAllText($uiPath,$ui)
Copy-Item -LiteralPath (Join-Path $rivalsRuntime 'Rivals-render-test.patch.toml') -Destination (Join-Path $rivalsWork 'storage\patches\454109C6 - Rivals TU2.patch.toml') -Force
}
function Write-Result($text){[IO.File]::WriteAllText((Join-Path $rivalsRuntime 'auto-result.txt'),$text)}
try {
 . (Join-Path $rivalsTools 'TFU2-Control.ps1') -FunctionsOnly
 Add-TFU2NativeTypes (Join-Path $rivalsTools 'ViGEmClient.dll')
 while(-not $end){
  $request='';try{$request=[IO.File]::ReadAllText((Join-Path $rivalsTools 'replay.request'))}catch{}
  if($request -and $request -ne $seen){
   $seen=$request
   try{
    if($request -notmatch '^game:([0-9a-f]{32}):rivals-(launch|snap|capture|A|B|Start|Back|Up|Down|Left|Right|stop|exit|replay|status)$'){throw 'Invalid Rivals action.'}
    $action=$Matches[2]
    if($action -eq 'status'){Write-Result 'Rivals Gat-View helper ready';continue}
    if($action -eq 'replay'){
     & (Join-Path $rivalsRuntime 'Rivals.ps1') -Mode Replay -Unattended
     Write-Result 'replay complete';continue
    }
    if($action -eq 'launch'){
     if(@(Get-Process -Name 'xenia*' -ErrorAction SilentlyContinue).Count){throw 'Another Xenia is running; left unchanged.'}
     Initialize-RivalsWork
     $loader='D:\LaunchBox\ThirdParty\Keys2Pad\LaunchBox\Start-Profile.ps1'
     $profile='D:\LaunchBox\ThirdParty\Keys2Pad\XBLA.profile.json'
     $setup=New-Object Diagnostics.ProcessStartInfo
     $setup.FileName='powershell.exe';$setup.UseShellExecute=$false
     $setup.Arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProfileFile "{1}" -WatchProcess xenia_rivals_trace.exe' -f $loader,$profile
     $setupProcess=[Diagnostics.Process]::Start($setup);$setupProcess.WaitForExit()
     if($setupProcess.ExitCode -ne 0){throw 'Normal Keys2Pad startup failed.'}
     $info=New-Object Diagnostics.ProcessStartInfo
     $info.FileName=$exe;$info.WorkingDirectory=$rivalsTools;$info.UseShellExecute=$false
     $info.Arguments='--config="{0}" --storage_root="{1}" --content_root="{2}" --fullscreen=true --guest_display_refresh_cap=false --framerate_limit=60 --host_frame_pacing_precise=true --d3d12_rivals_gpu_atlas_coherency=true --trace_gpu_stream=false --trace_gpu_prefix="{3}/" --d3d12_submission_timing=true --d3d12_stage_small_readback=true --d3d12_stencil_plane_copy=true --d3d12_static_unsigned_texture_signs=true --d3d12_partial_cube_mips=true --d3d12_partial_atlas_upload=true --d3d12_draw_timing=false --d3d12_stage_timing=true --log_file="{4}" "{5}"' -f (Join-Path $rivalsWork 'Rivals.toml'),(Join-Path $rivalsWork 'storage'),(Join-Path $rivalsWork 'content'),((Join-Path $rivalsRuntime 'auto-capture').Replace('\','/')),(Join-Path $rivalsRuntime 'auto-play.log'),'D:\LaunchBox\Games\Microsoft Xbox 360\Need for Speed Rivals [RF]\Need for Speed Rivals [RF].iso'
     $info.EnvironmentVariables['SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS']='1'
     $process=[Diagnostics.Process]::Start($info)
     Write-Result ('launched '+$process.Id);continue
    }
    if($action -in @('stop','exit')){
     if($process -and -not $process.HasExited){$null=$process.CloseMainWindow();if(-not $process.WaitForExit(15000)){throw 'Owned Rivals did not close; left running.'}}
     if($pad){$pad.Dispose();$pad=$null}
     if($action -eq 'exit'){$end=$true}
     Write-Result 'owned test stopped';continue
    }
    if(-not $process -or $process.HasExited){throw 'No owned Rivals process.'}
    if($action -in @('snap','capture')){
     $process.Refresh()
     [TFU2WindowV1]::Key($process.MainWindowHandle,$(if($action -eq 'capture'){0x73}else{0x7B}))
     Write-Result ('requested '+$action);continue
    }
    $buttons=@{A=0x1000;B=0x2000;Start=0x10;Back=0x20;Up=1;Down=2;Left=4;Right=8}
    if(-not $pad){throw 'Manual navigation is active; no automated game input.'}
    $pad.Update([uint16]$buttons[$action],0,0,0,0);Start-Sleep -Milliseconds 160;$pad.Update(0,0,0,0,0)
    Write-Result ('input '+$action)
   }catch{Write-Result ('ERROR '+$_.Exception.Message)}
  }
  Start-Sleep -Milliseconds 200
 }
}catch{Write-Result ('ERROR '+$_.Exception.Message)}
finally{if($pad){$pad.Dispose()}}
