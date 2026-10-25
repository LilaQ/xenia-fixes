param([ValidateSet('Start','Replay')][string]$Mode='Start',[switch]$Unattended,[ValidateSet('Transfers','RenderPaths','UnsignedTextures','NativeInterpolation')][string]$Study='UnsignedTextures')
$ErrorActionPreference='Stop'
try {
 $root=Split-Path -Parent $PSScriptRoot
 $edge=Split-Path -Parent (Split-Path -Parent $root)
 $emulators=Split-Path -Parent $edge
 $lb=Split-Path -Parent $emulators
 $tools=Join-Path $emulators 'Xenia Edge Trace\runtime'
 $capture=Join-Path $root 'capture'
 $config=Join-Path $edge 'config\games\Need for Speed_ Rivals [bef37e7b].toml'
 $sourceConfig=$config
 $config=Join-Path $PSScriptRoot 'Rivals.toml'
 $game=Join-Path $lb 'Games\Microsoft Xbox 360\Need for Speed Rivals [RF]\Need for Speed Rivals [RF].iso'
 $running=@(Get-CimInstance Win32_Process -Filter "Name LIKE 'xenia%.exe'")
 $ownedOnly=$running.Count -eq 1 -and $running[0].Name -eq 'xenia_rivals_trace.exe' -and $running[0].CommandLine -like '*Rivals\runtime\work\storage*'
 if($running.Count -and -not($Mode -eq 'Replay' -and $Unattended -and $ownedOnly)){throw 'Another Xenia is running; left unchanged.'}
 $null=New-Item -ItemType Directory -Path $capture -Force
 if($Mode -eq 'Start'){
  Copy-Item -LiteralPath $sourceConfig -Destination $config -Force
  if(@(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File).Count -ge 2){throw 'Bereits zwei Aufnahmen vorhanden. Erst auswerten; keine weiteren grossen Dateien erzeugt.'}
  $exe=Join-Path $tools 'xenia_edge_trace.exe'
  $arguments='--config="{0}" --storage_root="{1}" --trace_gpu_prefix="{2}/" --trace_gpu_stream=false --fullscreen=true --log_file="{3}" "{4}"' -f $config,$edge,$capture.Replace('\','/'),(Join-Path $PSScriptRoot 'capture.log'),$game
  Write-Host 'Zur langsamen Gameplay-Stelle fahren. Dort F4 EINMAL druecken.' -ForegroundColor Cyan
  Write-Host 'F4 nimmt einen GPU-Frame auf; dabei kann das Spiel kurz haengen. Danach Xenia normal schliessen.'
 } else {
  $frames=@(@(Get-ChildItem -LiteralPath $capture -Filter '*.xtr' -File) + @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'auto-capture') -Filter '*.xtr' -File -ErrorAction SilentlyContinue) | Sort-Object LastWriteTime)
  if(-not $frames.Count){throw 'Keine F4-Aufnahme vorhanden.'}
  $frame=$frames[-1].FullName
  $stream=[IO.File]::OpenRead($frame)
  try{$header=New-Object byte[] 48;if($stream.Read($header,0,48)-ne 48 -or [BitConverter]::ToUInt32($header,44)-ne 0x454109C6){throw 'Aufnahme gehoert nicht zu Rivals.'}}finally{$stream.Dispose()}
  $exe=Join-Path $tools 'xenia_rivals_replay.exe'
  $output=Join-Path $root 'replay'
  $null=New-Item -ItemType Directory -Path $output -Force
  $arguments='--config="{0}" --d3d12_adapter=1 --target_trace_file="{2}" --trace_dump_path="{3}" --trace_dump_repeat_count=240 --d3d12_draw_timing_interval=1 --d3d12_stage_timing=false --occlusion_query=fake --d3d12_draw_timing=false --d3d12_submission_timing=true --async_shader_compilation=false --framerate_limit=0 --guest_display_refresh_cap=false --log_file="{4}"' -f $config,$edge,$frame,$output,(Join-Path $PSScriptRoot 'replay.log')
  Write-Host 'Vergleiche derselben Aufnahme. Kein Spielstart und kein erneutes Hinfahren.' -ForegroundColor Cyan
 }
 foreach($file in @($exe,$config,$game)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Datei fehlt: $file"}}
 $cases=@('game')
 if($Mode -eq 'Replay'){$cases=if($Study -eq 'NativeInterpolation'){@('native-baseline','native-hardware','native-control')}elseif($Study -eq 'UnsignedTextures'){@('unsigned-baseline','unsigned-specialized','unsigned-control')}elseif($Study -eq 'RenderPaths'){@('path-performance','path-accuracy','path-control')}else{@('transfer-baseline','stencil-copy','static-pitch','transfer-both')}}
 foreach($case in $cases){
  $caseArguments=$arguments
  if($Mode -eq 'Replay'){
   $caseOutput=Join-Path $output $case
   $null=New-Item -ItemType Directory -Path $caseOutput -Force
   $caseLog=Join-Path $PSScriptRoot ('replay-'+$case+'.log')
   $caseArguments=$arguments
   $caseArguments=$caseArguments.Replace(('--trace_dump_path="'+$output+'"'),('--trace_dump_path="'+$caseOutput+'"'))
   $caseArguments=$caseArguments.Replace(('--log_file="'+(Join-Path $PSScriptRoot 'replay.log')+'"'),('--log_file="'+$caseLog+'"'))
   if($case -in @('stencil-copy','transfer-both')){$caseArguments+=' --d3d12_stencil_plane_copy=true'}
   if($case -in @('static-pitch','transfer-both')){$caseArguments+=' --d3d12_transfer_static_source_pitch=true'}
   if($Study -eq 'NativeInterpolation'){
    $caseArguments+=' --render_target_path=performance --d3d12_stencil_plane_copy=true --d3d12_static_unsigned_texture_signs=true --trace_dump_memory_digest=true --trace_dump_memory_base=217931776 --trace_dump_memory_size=9437184'
    $caseArguments+=if($case -eq 'native-hardware'){' --precise_interpolation=false'}else{' --precise_interpolation=true'}
   }
   if($Study -eq 'UnsignedTextures'){
    $caseArguments+=' --render_target_path=performance --d3d12_stencil_plane_copy=true --trace_dump_memory_digest=true --trace_dump_memory_base=217931776 --trace_dump_memory_size=9437184'
    if($case -eq 'unsigned-specialized'){$caseArguments+=' --d3d12_static_unsigned_texture_signs=true'}
   }
   if($Study -eq 'RenderPaths'){
    $caseArguments+=' --log_texture_loads=false --d3d12_stencil_plane_copy=true'
    $caseArguments+=if($case -eq 'path-accuracy'){' --render_target_path=accuracy'}else{' --render_target_path=performance'}
   }
   Write-Host ('Bildtreue pruefen: '+$case) -ForegroundColor Cyan
  }
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=$exe;$info.Arguments=$caseArguments;$info.WorkingDirectory=$tools;$info.UseShellExecute=$false
 if($Mode -eq 'Start'){
  $bridge=Join-Path $lb 'ThirdParty\Keys2Pad'
  $loader=Join-Path $bridge 'LaunchBox\Start-Profile.ps1'
  $profile=Join-Path $bridge 'XBLA.profile.json'
  foreach($file in @($loader,$profile)){if(-not(Test-Path -LiteralPath $file)){throw "Datei fehlt: $file"}}
  $setup=New-Object Diagnostics.ProcessStartInfo
  $setup.FileName='powershell.exe';$setup.UseShellExecute=$false
  $setup.Arguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProfileFile "{1}" -WatchProcess xenia_edge_trace.exe' -f $loader,$profile
  $bridgeProcess=[Diagnostics.Process]::Start($setup);$bridgeProcess.WaitForExit()
  if($bridgeProcess.ExitCode -ne 0){throw 'Keys2Pad konnte nicht vorbereitet werden.'}
 }
 if($Mode -eq 'Replay'){$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true}
 $process=[Diagnostics.Process]::Start($info)
 if($Mode -eq 'Replay'){$stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync()}
 if($Mode -eq 'Replay'){
  if(-not $process.WaitForExit(180000)){
   $process.Kill();$process.WaitForExit()
   throw 'Owned replay exceeded three minutes and was stopped.'
  }
 }else{$process.WaitForExit()}
 if($process.ExitCode -ne 0){throw ('Xenia-Fehlercode: '+$process.ExitCode+'; Details im runtime-Log.')}
 if($Mode -eq 'Replay'){
  if(-not(Test-Path -LiteralPath $caseLog)){
   $startup=$stdoutTask.Result+"`n"+$stderrTask.Result
   throw ('Replay exited without its log. '+$startup.Substring(0,[Math]::Min(2400,$startup.Length)))
  }
  $replayText=[IO.File]::ReadAllText($caseLog)
  if($replayText -notmatch 'DXGI adapter: NVIDIA GeForce RTX 3060'){throw 'Replay used a different GPU than Rivals; timing comparison rejected.'}
  if($replayText -match 'Failed to execute packet|ExecutePacketType[0-9]+ overflow'){throw 'Replay hat weiterhin GPU-Befehlsfehler. Log bleibt zur Fehleranalyse erhalten.'}
  if($replayText -notmatch 'Trace repeat complete'){throw 'Replay wurde nicht vollstaendig abgeschlossen.'}
 }
 }
 Write-Host 'Fertig.' -ForegroundColor Green
} catch {if($Unattended){throw};Write-Host $_.Exception.Message -ForegroundColor Red}
if(-not $Unattended){Read-Host 'Enter zum Schliessen'}
