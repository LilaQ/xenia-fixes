$ErrorActionPreference='Stop'
$bridgeStarted=$false
try {
 $traceRoot=$env:GAT_TRACE_DIR.TrimEnd('\')
 $emulators=Split-Path -Parent $traceRoot
 $lb=Split-Path -Parent $emulators
 $normal=Join-Path $emulators 'Xenia Edge'
 $runtime=Join-Path $traceRoot 'runtime'
 $exe=Join-Path $runtime 'xenia_edge_trace.exe'
 $sourceConfig=Join-Path $normal 'config\games\Saints Row_ Gat Out of Hell [9794c93a].toml'
 $configDir=Join-Path $traceRoot 'config'
 $config=Join-Path $configDir 'Gat.toml'
 $game=Join-Path $lb 'Games\Microsoft Xbox 360\Saints Row Gat out of Hell [RF]\Saints Row Gat out of Hell [RF].iso'
 $bridge=Join-Path $lb 'ThirdParty\Keys2Pad'
 $setup=Join-Path $bridge 'LaunchBox\Start-Profile.ps1'
 $profile=Join-Path $bridge 'XBLA.profile.json'
 foreach($p in @($exe,$sourceConfig,$game,$setup,$profile)) {if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Datei fehlt: $p"}}
 if(@(Get-Process -Name 'xenia_edge*','xenia_canary*' -ErrorAction SilentlyContinue).Count){throw 'Bitte zuerst Xenia schliessen.'}
 $null=New-Item -ItemType Directory -Path $configDir -Force
 Copy-Item -LiteralPath $sourceConfig -Destination $config -Force
 $expected='BUILD_SHA256_PLACEHOLDER'
 if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $expected){throw 'Unerwartete Diagnose-Binary.'}
 & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setup -ProfileFile $profile -WatchProcess xenia_edge_trace.exe
 if($LASTEXITCODE -ne 0){throw 'Keys2Pad-Start fehlgeschlagen.'}
 $bridgeStarted=$true
 $captures=Join-Path $traceRoot 'capture\faithful'
 $null=New-Item -ItemType Directory -Path $captures -Force
 Write-Host 'Im Gameplay zur langsamen Stelle schauen, einmal F4 druecken, dann Xenia schliessen.' -ForegroundColor Cyan
 Write-Host 'Danach startet der Vergleich automatisch. F3/F7/F8 fuer die Aufnahme unveraendert lassen.'
 $launchArguments='--config="{0}" --storage_root="{1}" --trace_gpu_prefix="{2}" --trace_gpu_stream=false --profiler_on_demand=true --d3d12_skip_no_output_draws=true --d3d12_submission_timing=true --d3d12_draw_timing=true --d3d12_expand_points_in_vs=false --d3d12_fsi_late_blended=false --force_convert_quad_lists_to_triangle_lists=false --log_file="{3}" "{4}"' -f $config,$normal,($captures.Replace('\','/')+'/'),(Join-Path $traceRoot 'xenia.log'),$game
 $captureStarted=Get-Date
 $process=Start-Process -FilePath $exe -ArgumentList $launchArguments -WorkingDirectory $traceRoot -PassThru
 $process.WaitForExit()
 $process.Refresh()
 if($process.ExitCode -ne 0){throw "Xenia beendet: $($process.ExitCode)"}
 if($bridgeStarted){& (Join-Path $bridge 'Keys2Pad.exe') --exit; $bridgeStarted=$false}
 $frames=@(Get-ChildItem -LiteralPath $captures -Filter '*.xtr' -File | Where-Object {$_.LastWriteTime -ge $captureStarted} | Sort-Object LastWriteTime)
 if($frames.Count){
  $trace=$frames[-1].FullName
  $out=Join-Path $runtime ('replay-results\'+[guid]::NewGuid().ToString('N'))
  & (Join-Path $runtime 'Gat-Replay-Compare.ps1') -Executable (Join-Path $runtime 'xenia_trace_replay.exe') -Trace $trace -Config $config -OutputDirectory $out
 } else{Write-Host 'Keine neue F4-Aufnahme vorhanden; kein Vergleich gestartet.' -ForegroundColor Yellow}
} catch {Write-Host $_.Exception.Message -ForegroundColor Red}
finally {if($bridgeStarted){& (Join-Path $bridge 'Keys2Pad.exe') --exit}}
Read-Host 'Enter zum Schliessen'
