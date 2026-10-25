param(
 [Parameter(Mandatory=$true)][string]$Executable,
 [Parameter(Mandatory=$true)][string]$Trace,
 [Parameter(Mandatory=$true)][string]$Config,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$ReferenceImage,
 [ValidateSet('canary','native-interpolation','host-render-targets','host-snorm-multiply','host-snorm-depth','host-snorm-depth-round','host-snorm-bias','host-snorm-bias-quantized','host-snorm-bias-truncated')][string]$Candidate='canary',
 [switch]$Inspect,
 [int]$StopCommand=-1,
 [switch]$PlatformProbe
)
function Get-GatReplayRequest([string]$Path) {
 if(-not $Path){return $null}
 try{
  $text=[IO.File]::ReadAllText($Path)
  if(-not [string]::IsNullOrWhiteSpace($text)){return $text}
 }catch{}
 return $null
}
function Invoke-GatReplayProcess {
 param([string]$Executable,[string]$Arguments,[string]$WorkingDirectory,[string]$Stdout,[string]$Stderr,[string]$RequestFile)
 $info=New-Object System.Diagnostics.ProcessStartInfo
 $info.FileName=$Executable
 $info.Arguments=$Arguments
 $info.WorkingDirectory=$WorkingDirectory
 $info.UseShellExecute=$false
 $info.RedirectStandardOutput=$true
 $info.RedirectStandardError=$true
 $requestSeen=Get-GatReplayRequest $RequestFile
 $process=New-Object System.Diagnostics.Process
 $process.StartInfo=$info
 $outStream=$null
 $errStream=$null
 try {
  $outStream=[IO.File]::Create($Stdout)
  $errStream=[IO.File]::Create($Stderr)
  if(-not $process.Start()){throw 'Could not start replay process.'}
  $outCopy=$process.StandardOutput.BaseStream.CopyToAsync($outStream)
  $errCopy=$process.StandardError.BaseStream.CopyToAsync($errStream)
  $timer=[Diagnostics.Stopwatch]::StartNew()
  $nextHeartbeat=15000
  $stopReason=$null
  while(-not $process.WaitForExit(500)){
   if($timer.ElapsedMilliseconds -ge $nextHeartbeat){
    Write-Host ('Replay process '+$process.Id+' is running; elapsed '+[int]$timer.Elapsed.TotalSeconds+' s')
    $nextHeartbeat=$timer.ElapsedMilliseconds+15000
   }
   $requestNow=Get-GatReplayRequest $RequestFile
   if($requestNow -and $requestNow -ne $requestSeen){$stopReason='Replay superseded by a new request.';break}
   if($timer.ElapsedMilliseconds -ge 900000){$stopReason='Replay process timed out.';break}
  }
  if($stopReason){
   if(-not $process.HasExited){$process.Kill()}
   $process.WaitForExit()
  }
  $null=$outCopy.GetAwaiter().GetResult()
  $null=$errCopy.GetAwaiter().GetResult()
  if($stopReason){throw $stopReason}
  return $process.ExitCode
 } finally {
  if($outStream){$outStream.Dispose()}
  if($errStream){$errStream.Dispose()}
  $process.Dispose()
 }
}
$ErrorActionPreference='Stop'
if($PlatformProbe){
 $cache=Join-Path ([IO.Path]::GetTempPath()) '.net\Keys2Pad'
 $nativeCount=0
 if(Test-Path -LiteralPath $cache){$nativeCount=@(Get-ChildItem -LiteralPath $cache -Filter '*ViGEm*.dll' -File -Recurse).Count}
 $bridgeCount=@(Get-Process -Name 'Keys2Pad' -ErrorAction SilentlyContinue).Count
 $xeniaCount=@(Get-Process -Name 'xenia_edge*','xenia_canary*','xenia_trace*' -ErrorAction SilentlyContinue).Count
 $lbCount=@(Get-Process -Name 'LaunchBox','BigBox' -ErrorAction SilentlyContinue).Count
 $service=Get-Service -Name 'ViGEmBus' -ErrorAction SilentlyContinue
 $serviceState=if($service){$service.Status.ToString()}else{'Absent'}
 Write-Host ('Read-only platform check: bridge='+$bridgeCount+'; xenia='+$xeniaCount+'; LaunchBox='+$lbCount+'; ViGEm='+$serviceState+'; cached native libraries='+$nativeCount)
 return
}
# Ordinary nonce requests retain the existing replay comparison. Only an explicit
# game: request enters the isolated live test, whose controller and game are owned
# and released by that session. No alternate default mode is installed.
$gameRequest=Join-Path (Split-Path -Parent $Executable) 'replay.request'
$requestText=Get-GatReplayRequest $gameRequest
$decodeComparison=$false
$statisticsInspection=$false
$stageInspection=$false
$cacheComparison=$false
$pitchComparison=$false
$depthCopyComparison=$false
$stencilCopyComparison=$false
$coverageInspection=$false
if($env:GAT_TRACE_DIR -and -not $requestText){return}
if($requestText -match '^game:[0-9a-f]{32}:stop$'){return}
if($requestText -and $requestText.StartsWith('game:')){
 & (Join-Path (Split-Path -Parent $Executable) 'Gat-Game-Control.ps1') -Root (Split-Path -Parent (Split-Path -Parent $Executable))
 return
}
if($requestText){
 if($requestText -match '^(decode|statistics|stages|cache|pitch|coverage|depthcopy|stencilcopy):[0-9a-f]{32}:([0-9a-f]{32})$'){
  $decodeComparison=$true
  $statisticsInspection=$Matches[1] -eq 'statistics'
  $stageInspection=$Matches[1] -in @('stages','coverage')
  $coverageInspection=$Matches[1] -eq 'coverage'
  $cacheComparison=$Matches[1] -eq 'cache'
  $pitchComparison=$Matches[1] -eq 'pitch'
  $depthCopyComparison=$Matches[1] -eq 'depthcopy'
  $stencilCopyComparison=$Matches[1] -eq 'stencilcopy'
  $Candidate='host-snorm-bias-quantized'
  $ReferenceImage=Join-Path (Split-Path -Parent $Executable) ('replay-results\'+$Matches[2]+'\candidate-a.png')
  if(@(Get-Process -Name 'xenia_edge*','xenia_canary*','xenia_trace*','Keys2Pad','LaunchBox','BigBox' -ErrorAction SilentlyContinue).Count){throw 'Close other Xenia, Keys2Pad and LaunchBox before the isolated comparison.'}
  if($cacheComparison -and $env:SystemRoot){
   $smi=Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
   if(Test-Path -LiteralPath $smi){
    Write-Host 'GPU memory before isolated cache-budget comparison (total, used MiB):'
    & $smi '--query-gpu=memory.total,memory.used' '--format=csv,noheader,nounits'
    if($LASTEXITCODE -ne 0){throw 'GPU memory query failed.'}
   }
  }
 }
 if($requestText -match '^inspect:[0-9a-f]{32}:(host-snorm-multiply|host-snorm-depth|host-snorm-depth-round|host-snorm-bias|host-snorm-bias-quantized|host-snorm-bias-truncated)$'){
  $Candidate=$Matches[1]
  $Inspect=$true
 }
 if($requestText -match '^benchmark:[0-9a-f]{32}:(host-snorm-bias-quantized|host-snorm-bias-truncated)$'){$Candidate=$Matches[1]}
 if($requestText -match '^prefix:[0-9a-f]{32}:([0-9]{1,5})$'){
  $Candidate='host-snorm-multiply';$Inspect=$true;$StopCommand=[int]$Matches[1]
 }
}
if(-not $ReferenceImage){$ReferenceImage=[IO.Path]::ChangeExtension($Trace,'.png')}
if(-not(Test-Path -LiteralPath $ReferenceImage -PathType Leaf)){
 throw 'The original trace screenshot is required to validate replay output.'
}
$canaryExecutable=Join-Path (Split-Path -Parent $Executable) 'xenia_canary_replay.exe'
$inputs=@($Executable,$Trace,$Config)
if($Candidate -eq 'canary'){$inputs+=$canaryExecutable}
foreach($p in $inputs) {
 if(-not(Test-Path -LiteralPath $p -PathType Leaf)){throw "Missing input: $p"}
 if($p.Contains('"')){throw 'Quote in input path is unsupported.'}
}
if($OutputDirectory.Contains('"')){throw 'Quote in output path is unsupported.'}
if(-not $Inspect -and @(Get-Process -Name 'xenia_edge*','xenia_canary*','xenia_trace*' -ErrorAction SilentlyContinue).Count){
 throw 'Close other Xenia processes before comparing GPU workload.'
}
if($Inspect){Write-Host 'Image inspection only: other GPU workloads are permitted; no performance result will be accepted.'}
$null=New-Item -ItemType Directory -Path $OutputDirectory -Force
$work=Join-Path $OutputDirectory 'work'
$null=New-Item -ItemType Directory -Path $work -Force
# ABBA order reduces the risk of mistaking warm-up or clock drift for a gain.
# Compare the chosen renderer or interpolation policy on the same GPU and trace.
# The host-render-targets mode is diagnostic; image validation remains mandatory.
# These are repeated GPU commands, not new game starts or a gameplay FPS claim.
if($StopCommand -ge 0){
 if(-not $Inspect -or $Candidate -notin @('host-render-targets','host-snorm-multiply')){throw 'Prefix snapshots require inspection of host render targets.'}
 foreach($prefix in @(@{Name='baseline-a';Path='accuracy'},@{Name='candidate-a';Path='performance'})){
  $stem=Join-Path $OutputDirectory $prefix.Name
  $log=$stem+'.log'
  $snapshot=Join-Path $OutputDirectory (([IO.Path]::GetFileNameWithoutExtension($Trace))+'_edram.bin')
  if(Test-Path -LiteralPath $snapshot){throw 'A previous prefix snapshot is present.'}
  $arguments='--config="{0}" --target_trace_file="{1}" --trace_dump_path="{2}" --log_file="{3}" --trace_dump_repeat_count=0 --trace_dump_edram_frame=0 --trace_dump_stop_command={4} --gpu=d3d12 --render_target_path={5} --async_shader_compilation=false --precise_interpolation=true --d3d12_skip_no_output_draws=true --d3d12_draw_timing=false --d3d12_submission_timing=false --d3d12_fsi_late_simple=false --d3d12_fsi_late_blended=false --d3d12_expand_points_in_vs=false --d3d12_snorm16_multiply_scale=false --snorm16_render_target_full_range=true --occlusion_query=fake --readback_resolve=true --draw_resolution_scale_x=1 --draw_resolution_scale_y=1 --log_draws=false --log_resolves=false --log_transfers=false' -f $Config,$Trace,$OutputDirectory,$log,$StopCommand,$prefix.Path
  if($prefix.Path -eq 'performance' -and $Candidate -eq 'host-snorm-multiply'){
   $arguments=$arguments.Replace('--d3d12_snorm16_multiply_scale=false','--d3d12_snorm16_multiply_scale=true')
  }
  Write-Host ('Inspecting '+$prefix.Name+' through command '+$StopCommand)
  $exitCode=Invoke-GatReplayProcess -Executable $Executable -Arguments $arguments -WorkingDirectory $work -Stdout ($stem+'.stdout.log') -Stderr ($stem+'.stderr.log') -RequestFile (Join-Path (Split-Path -Parent $Executable) 'replay.request')
  $lines=Get-Content -LiteralPath $log
  # No swap has occurred in a prefix: exit 1 may only mean no final image.
  # Require the completed, fenced EDRAM dump and the exact requested command.
  $completed=@($lines -match ('wrote the EDRAM snapshot after frame 0 command '+$StopCommand+'$')).Count -gt 0
  if($exitCode -notin @(0,1) -or -not $completed -or -not(Test-Path -LiteralPath $snapshot) -or (Get-Item -LiteralPath $snapshot).Length -ne 10485760){throw 'Prefix replay did not produce its requested complete EDRAM snapshot.'}
  if($lines -match 'Failed in backend|Failed to create.*pipeline'){throw 'Invalid backend rendering in prefix replay.'}
  Move-Item -LiteralPath $snapshot -Destination ($stem+'.edram.bin')
 }
 Write-Host 'Two prefix snapshots written. These are intermediate GPU buffers, not final images or performance measurements.'
 return
}
$passes=if($Inspect){1}else{360}
$candidateKind=if($Candidate -eq 'canary'){'canary'}else{'edge'}
$runs=@(
 @{Name='baseline-a';Kind='edge'},
 @{Name='candidate-a';Kind=$candidateKind},
 @{Name='candidate-b';Kind=$candidateKind},
 @{Name='baseline-b';Kind='edge'}
)
if($Inspect -or $statisticsInspection -or $stageInspection){$runs=@(@{Name='candidate-a';Kind=$candidateKind})}
foreach($run in $runs) {
 $stem=Join-Path $OutputDirectory $run.Name
 $log=$stem+'.log'
 $image=$stem+'.png'
 if((Test-Path -LiteralPath $log) -or (Test-Path -LiteralPath $image)){
  throw "Output already exists: $stem; choose an empty output directory."
 }
 $runExecutable=$Executable
 $runConfig=$Config
 if(($Inspect -and $run.Kind -eq 'edge') -or $cacheComparison -or $pitchComparison -or $depthCopyComparison -or $stencilCopyComparison -or ($decodeComparison -and $run.Name.StartsWith('candidate'))){
  $runExecutable=Join-Path (Split-Path -Parent $Executable) 'xenia_trace_replay_probe.exe'
  if(-not(Test-Path -LiteralPath $runExecutable -PathType Leaf)){throw 'Missing separate decoder comparison executable.'}
 }
 if($run.Kind -eq 'canary'){
  $runConfig=Join-Path $work 'canary-replay.toml'
  $configText=[IO.File]::ReadAllText($Config)
  $configText=[regex]::Replace($configText,'(?m)^(\s*readback_resolve\s*=\s*)(true|false)(\s*(?:#.*)?)$','$1"full"$3')
  $configText=[regex]::Replace($configText,'(?m)^(\s*vulkan_validation\s*=\s*)\d+(\s*(?:#.*)?)$','$1false$2')
  [IO.File]::WriteAllText($runConfig,$configText)
 }
 $arguments='--config="{3}" --target_trace_file="{0}" --trace_dump_path="{1}" --trace_dump_repeat_count={4} --async_shader_compilation=false --d3d12_submission_timing=true --log_file="{2}" --occlusion_query=fake --framerate_limit=0 --draw_resolution_scale_x=1 --draw_resolution_scale_y=1 --draw_resolution_scaled_texture_offsets=true --readback_resolve_half_pixel_offset=false' -f $Trace,$OutputDirectory,$log,$runConfig,$passes
 if($run.Kind -eq 'canary'){
  $runExecutable=$canaryExecutable
  $arguments+=' --render_target_path_d3d12=rov --readback_resolve=full'
 } else {
  $arguments+=' --gpu=d3d12 --d3d12_snorm16_multiply_scale=false --snorm16_render_target_full_range=true --depth_float24_convert_in_pixel_shader=false --depth_float24_round=false --depth_bias_shader_offset=false --precise_interpolation=true --profiler_on_demand=true --d3d12_draw_timing=true --d3d12_skip_no_output_draws=true --d3d12_expand_points_in_vs=false --force_convert_quad_lists_to_triangle_lists=false --d3d12_fsi_late_blended=false --d3d12_fsi_late_simple=false --shared_memory_zero_copy=false --enable_host_buffer=true --render_target_path=accuracy --readback_resolve=true'
 }
 # The console replay has no --cache_root option or title shader-storage
 # initialization. Each owned process starts with an independent memory cache;
 # its repeated passes retain that cache for the warm timing windows.

 if($run.Name.StartsWith('candidate') -and $Candidate -eq 'native-interpolation'){
  $arguments=$arguments.Replace('--precise_interpolation=true','--precise_interpolation=false')
 }
 if(($decodeComparison -or $run.Name.StartsWith('candidate')) -and $Candidate -in @('host-render-targets','host-snorm-multiply','host-snorm-depth','host-snorm-depth-round','host-snorm-bias','host-snorm-bias-quantized','host-snorm-bias-truncated')){
  $arguments=$arguments.Replace('--render_target_path=accuracy','--render_target_path=performance')
  if($Candidate -ne 'host-render-targets'){$arguments=$arguments.Replace('--d3d12_snorm16_multiply_scale=false','--d3d12_snorm16_multiply_scale=true')}
  if($Candidate -in @('host-snorm-depth','host-snorm-depth-round','host-snorm-bias-quantized','host-snorm-bias-truncated')){$arguments=$arguments.Replace('--depth_float24_convert_in_pixel_shader=false','--depth_float24_convert_in_pixel_shader=true')}
  if($Candidate -in @('host-snorm-depth-round','host-snorm-bias-quantized')){$arguments=$arguments.Replace('--depth_float24_round=false','--depth_float24_round=true')}
  if($Candidate -in @('host-snorm-bias','host-snorm-bias-quantized','host-snorm-bias-truncated')){$arguments=$arguments.Replace('--depth_bias_shader_offset=false','--depth_bias_shader_offset=true')}
 }

 if($Inspect){$arguments+=' --log_draws=true --log_resolves=true --log_transfers=true'}
 if($statisticsInspection){$arguments+=' --d3d12_draw_statistics=true'}
 if($stageInspection){$arguments+=' --d3d12_stage_timing=true'}
 if($coverageInspection){$arguments+=' --d3d12_stencil_bit_coverage=true --d3d12_transfer_static_source_pitch=true --no_discard_stencil_in_transfer_pipelines=false'}
 if($cacheComparison){
  $arguments+=if($run.Name.StartsWith('candidate')){' --texture_cache_memory_limit_soft=1536 --texture_cache_memory_limit_hard=2048'}else{' --texture_cache_memory_limit_soft=384 --texture_cache_memory_limit_hard=768'}
 }
 if($depthCopyComparison){
  $arguments+=' --d3d12_stage_timing=true --d3d12_transfer_static_source_pitch=true'
  $arguments+=if($run.Name.StartsWith('candidate')){' --depth_transfer_not_equal_test=false'}else{' --depth_transfer_not_equal_test=true'}
 }
 if($stencilCopyComparison){
  $arguments+=' --d3d12_stage_timing=true'
  if($run.Name.StartsWith('candidate')){$arguments+=' --d3d12_stencil_plane_copy=true'}
 }
 if($pitchComparison){
  $arguments+=' --d3d12_stage_timing=true'
  $arguments+=if($run.Name.StartsWith('candidate')){' --d3d12_transfer_static_source_pitch=true'}else{' --d3d12_transfer_static_source_pitch=false'}
 }


 # Named trace_dump_path is a directory; the tool uses the trace stem.
 $defaultImage=Join-Path $OutputDirectory (([IO.Path]::GetFileNameWithoutExtension($Trace))+'.png')
 if(Test-Path -LiteralPath $defaultImage){throw "Unexpected image: $defaultImage"}
 Write-Host ('Replaying '+$run.Name+' ('+$run.Kind+', candidate='+$Candidate+')')
 $stdout=$stem+'.stdout.log'
 $stderr=$stem+'.stderr.log'
 $exitCode=Invoke-GatReplayProcess -Executable $runExecutable -Arguments $arguments -WorkingDirectory $work -Stdout $stdout -Stderr $stderr -RequestFile (Join-Path (Split-Path -Parent $Executable) 'replay.request')
 if($exitCode -eq -1073741511 -and $runExecutable -eq $Executable){
  $probe=Join-Path (Split-Path -Parent $Executable) 'replay-import-check.exe'
  if(Test-Path -LiteralPath $probe -PathType Leaf){
   $probeExit=Invoke-GatReplayProcess -Executable $probe -Arguments '' -WorkingDirectory $work -Stdout ($stem+'.imports.log') -Stderr ($stem+'.imports.stderr.log')
   Write-Host ('Loader import check exit '+$probeExit+'; see '+$stem+'.imports.log')
  }
 }
 if($exitCode -ne 0){throw ('Replay failed: '+$run.Name+' exit '+$exitCode+'; see '+$stdout+' and '+$stderr)}
 if(-not(Test-Path -LiteralPath $defaultImage -PathType Leaf)){throw 'No final replay image.'}
 Move-Item -LiteralPath $defaultImage -Destination $image
 $lines=Get-Content -LiteralPath $log
 if(-not($lines -match ('Trace repeat complete: '+$passes+' passes; final image written'))){throw 'Replay did not complete.'}
 if($lines -match 'Failed in backend|unsupported host vertex shader|invalid.*timestamp|timing.*ring.*full|Failed to create.*pipeline|Stencil plane copy: (unsupported|scratch allocation failed)'){
  throw ('Invalid rendering/timing run: '+$run.Name)
 }
 $timings=@($lines | Select-String 'GPU timing: through frame')
 if($statisticsInspection){
  $statistics=@($lines | Select-String 'GPU draw statistics:')
  if($statistics.Count -lt 2){throw 'No completed pipeline invocation sample.'}
  foreach($line in $statistics){Write-Host $line.Line}
 }
 if($stageInspection){
  $stages=@($lines | Select-String 'GPU stage timing:')
  if($stages.Count -lt 4 -or $lines -match 'capacity reached'){throw 'Incomplete GPU stage sample.'}
  foreach($line in $stages){Write-Host $line.Line}
 }
 if($coverageInspection){
  $coverage=@($lines | Select-String 'GPU stencil coverage summary:.*usable true')
  if(-not $coverage.Count){throw 'Stencil coverage is unusable: missing samples or failed discard control.'}
  Write-Host $coverage[-1].Line
  Write-Host 'Coverage inspection only; query overhead excludes a performance result.'
 }elseif(-not $Inspect){
  if($timings.Count -lt 2){throw ('No warm GPU timing window: '+$run.Name)}
  Write-Host ($timings[-1].Line)
 }else{Write-Host 'Single-frame inspection only; no performance result.'}
}
$hashes=@($runs | ForEach-Object {(Get-FileHash -LiteralPath (Join-Path $OutputDirectory ($_.Name+'.png')) -Algorithm SHA256).Hash})
$referenceHash=(Get-FileHash -LiteralPath $ReferenceImage -Algorithm SHA256).Hash
if($Inspect){
 if($hashes[0] -eq $referenceHash){Write-Host 'Inspection image matches the reference exactly; no performance measurement was requested.'}
 else{Write-Warning 'Inspection image differs from the reference; inspect it directly. No performance result was accepted.'}
 return
}
if($hashes[0] -ne $referenceHash){
 throw 'Baseline replay differs from the original trace screenshot. Validate replay correctness before accepting any timing comparison.'
}
if(@($hashes | Select-Object -Unique).Count -ne 1){
 throw 'Final images differ. Do not accept a performance gain until the rendering difference is inspected.'
}
if($coverageInspection){Write-Host 'Stencil coverage image matches the validated reference exactly; discard controls and nonzero sample coverage passed.'}
elseif($stageInspection){Write-Host 'GPU stage sample image matches the validated reference exactly. Inclusive nested intervals overlap; instrumented sample is not gameplay FPS.'}
elseif($statisticsInspection){Write-Host 'Pipeline statistics image matches the validated reference exactly. Instrumented draw counts only; not a speed comparison.'}
else{Write-Host 'All four final images match the original trace screenshot exactly. Compare warm GPU windows; replay wall time is not game FPS.'}
