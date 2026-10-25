$ErrorActionPreference='Stop'
$bridgeStarted=$false
try {
 $root=$env:GAT_TRACE_DIR.TrimEnd('\')
 $emulators=Split-Path -Parent $root
 $lb=Split-Path -Parent $emulators
 $runtime=Join-Path $root 'runtime'
 $exe=Join-Path $runtime 'xenia_edge_gat.exe'
 $config=Join-Path $root 'config\Gat-Fixed.toml'
 $normal=Join-Path $emulators 'Xenia Edge'
 $game=Join-Path $lb 'Games\Microsoft Xbox 360\Saints Row Gat out of Hell [RF]\Saints Row Gat out of Hell [RF].iso'
 $bridge=Join-Path $lb 'ThirdParty\Keys2Pad'
 $setup=Join-Path $bridge 'LaunchBox\Start-Profile.ps1'
 $profile=Join-Path $bridge 'XBLA.profile.json'
 foreach($p in @($exe,$config,$game,$setup,$profile)){
  if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Datei fehlt: $p"}
 }
 if(@(Get-Process -Name 'xenia_edge*','xenia_canary*','xenia_trace*' -ErrorAction SilentlyContinue).Count){throw 'Bitte zuerst Xenia schliessen.'}
 if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne '99244AB2D4ED7805B97D4DE63B2968EF800A69F15E24CB715C81CB00D72518C3'){throw 'Unerwartete Gat-Binary.'}
 $bridgeStarted=$true
 # Call the installed shared loader, waiting for setup rather than its tray child.
 $setupArguments='-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProfileFile "{1}" -WatchProcess xenia_edge_gat.exe' -f $setup,$profile
 $setupInfo=New-Object Diagnostics.ProcessStartInfo
 $setupInfo.FileName='powershell.exe'
 $setupInfo.Arguments=$setupArguments
 $setupInfo.UseShellExecute=$false
 $setupProcess=[Diagnostics.Process]::Start($setupInfo)
 $setupProcess.WaitForExit()
 if($setupProcess.ExitCode -ne 0){throw 'Keys2Pad-Start fehlgeschlagen.'}
 Write-Host 'Gat: separater Edge-Build mit Beleuchtungsfix und Vollbild.' -ForegroundColor Cyan
 $arguments='--config="{0}" --storage_root="{1}" --render_target_path=performance --d3d12_snorm16_multiply_scale=true --snorm16_render_target_full_range=true --d3d12_skip_no_output_draws=true --depth_bias_shader_offset=true --depth_float24_convert_in_pixel_shader=true --depth_float24_round=true --d3d12_stencil_plane_copy=true --d3d12_stage_small_readback=true --d3d12_gat_async_hdr=true --host_present_from_non_ui_thread=false --postprocess_antialiasing=fxaa --occlusion_query=fake --readback_resolve=true --draw_resolution_scale_x=1 --draw_resolution_scale_y=1 --framerate_limit=60 --guest_display_refresh_cap=false --d3d12_submission_timing=false --d3d12_draw_timing=false --profiler_on_demand=true --trace_gpu_stream=false --fullscreen=true --log_file="{2}" "{3}"' -f $config,$normal,(Join-Path $root 'xenia.log'),$game
 $info=New-Object Diagnostics.ProcessStartInfo
 $info.FileName=$exe
 $info.Arguments=$arguments
 $info.WorkingDirectory=$runtime
 $info.UseShellExecute=$false
 $process=[Diagnostics.Process]::Start($info)
 $process.WaitForExit()
 if($process.ExitCode -ne 0){throw ('Xenia beendet: '+$process.ExitCode)}
 $process.Dispose()
} catch {
 Write-Host $_.Exception.Message -ForegroundColor Red
 Read-Host 'Enter zum Schliessen'
} finally {
 if($bridgeStarted){
  $exitInfo=New-Object Diagnostics.ProcessStartInfo
  $exitInfo.FileName=Join-Path $bridge 'Keys2Pad.exe'
  $exitInfo.Arguments='--exit'
  $exitInfo.UseShellExecute=$false
  $exitProcess=[Diagnostics.Process]::Start($exitInfo)
  $exitProcess.WaitForExit()
 }
}
