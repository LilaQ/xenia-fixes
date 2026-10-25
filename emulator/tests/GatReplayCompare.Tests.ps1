$ErrorActionPreference='Stop'
$base=Join-Path ([IO.Path]::GetTempPath()) ('gat-compare-check-'+[guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $base){Remove-Item -LiteralPath $base -Recurse -Force}
$null=New-Item -ItemType Directory -Path $base -Force
foreach($n in @('tool.exe','xenia_canary_replay.exe','xenia_trace_replay_probe.exe','frame.xtr','config.toml')){Set-Content -LiteralPath (Join-Path $base $n) -Value 'mock'}
Set-Content -LiteralPath (Join-Path $base 'config.toml') -Value "[GPU]`nreadback_resolve = true # resolve`n[Vulkan]`nvulkan_validation = 0 # validation"
Set-Content -LiteralPath (Join-Path $base 'frame.png') -Value 'identical mock image bytes'
function Get-Process {param($Name,$ErrorAction) if($global:GatMockProcessRunning){return @([pscustomobject]@{Id=123})}; return @()}
function Get-Service {param($Name,$ErrorAction) return [pscustomobject]@{Status='Running'}}
function Invoke-GatReplayProcess {
 param($Executable,$Arguments,$WorkingDirectory,$Stdout,$Stderr)
 $ArgumentList=$Arguments
 if($Arguments -match '--cache_root='){throw 'Console replay received an unsupported GUI-only cache option'}
 $global:GatMockExecutables+=$Executable
 $runConfig=[regex]::Match($Arguments,'--config="([^"]+)"').Groups[1].Value
 if([IO.Path]::GetFileName($Executable) -eq 'xenia_canary_replay.exe'){
  if($Arguments -match '--gpu='){throw 'Canary console received an unsupported GPU option'}
  $cfg=[IO.File]::ReadAllText($runConfig)
  if($cfg -notmatch 'readback_resolve = "full" # resolve' -or $cfg -notmatch 'vulkan_validation = false # validation'){throw 'Cross-version config translation failed'}
 }
 $global:GatMockArguments+=$Arguments
 $log=[regex]::Match($ArgumentList,'--log_file="([^"]+)"').Groups[1].Value
 $out=[regex]::Match($ArgumentList,'--trace_dump_path="([^"]+)"').Groups[1].Value
 $passes=[regex]::Match($Arguments,'--trace_dump_repeat_count=(\d+)').Groups[1].Value
 $messages=@('Trace repeat complete: '+$passes+' passes; final image written')
 if($passes -ne '1'){$messages+=@('GPU timing: through frame 120, GPU submissions avg 25.0 ms','GPU timing: through frame 240, GPU submissions avg 25.0 ms')}
 if($Arguments.Contains('--d3d12_draw_statistics=true')){$messages+=@('GPU draw statistics: completed totals','GPU draw statistics: completed shader group')}
 if($Arguments.Contains('--d3d12_stage_timing=true')){$messages+=@('GPU stage timing: targets','GPU stage timing: textures','GPU stage timing: barriers','GPU stage timing: resolve')}
 if($Arguments.Contains('--d3d12_stencil_bit_coverage=true')){
  $usable=if($global:GatMockCoverageInvalid){'false'}else{'true'}
  $messages+=('GPU stencil coverage summary: 2 groups, controls valid true, usable '+$usable+', passed samples 12')
 }
 if($global:GatMockInjectFailure -and $log.Contains('candidate-a')){$messages+='Failed in backend'}
 Set-Content -LiteralPath $log -Value $messages
 Set-Content -LiteralPath (Join-Path $out 'frame.png') -Value 'identical mock image bytes'
 return 0
}
$runner=Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Gat-Replay-Compare.ps1'
$source=[IO.File]::ReadAllText($runner)
$start=$source.IndexOf('function Invoke-GatReplayProcess {')
$end=$source.IndexOf("`$ErrorActionPreference='Stop'",$start)
$runner=[scriptblock]::Create($source.Substring(0,$start)+$source.Substring($end))
$global:GatMockInjectFailure=$false
$global:GatMockProcessRunning=$false
$global:GatMockArguments=@()
$global:GatMockExecutables=@()
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/valid"
if([IO.File]::ReadAllText("$base/config.toml") -notmatch 'readback_resolve = true'){throw 'Original config was modified'}
foreach($mode in @('native-interpolation','host-render-targets','host-snorm-multiply','host-snorm-depth','host-snorm-depth-round','host-snorm-bias','host-snorm-bias-quantized','host-snorm-bias-truncated')){
 $global:GatMockArguments=@()
 & $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/$mode" -Candidate $mode
 $option=if($mode -eq 'native-interpolation'){'--precise_interpolation=false'}else{'--render_target_path=performance'}
 if($global:GatMockArguments.Count -ne 4 -or $global:GatMockArguments[0].Contains($option) -or -not $global:GatMockArguments[1].Contains($option) -or -not $global:GatMockArguments[2].Contains($option) -or $global:GatMockArguments[3].Contains($option)){throw 'Candidate option escaped its two comparison runs'}
 if($mode -in @('host-snorm-depth','host-snorm-depth-round','host-snorm-bias-quantized')){
  if($global:GatMockArguments[0].Contains('--depth_float24_convert_in_pixel_shader=true') -or -not $global:GatMockArguments[1].Contains('--depth_float24_convert_in_pixel_shader=true')){throw 'Depth option escaped candidate or was not set.'}
 }
}
$global:GatMockProcessRunning=$true
$rejected=$false
try{& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/busy"}catch{if($_.Exception.Message -like 'Close other Xenia*'){$rejected=$true}else{throw}}
if(-not $rejected){throw 'Performance comparison accepted concurrent Xenia.'}
$global:GatMockArguments=@();$global:GatMockExecutables=@()
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/inspect" -Candidate 'host-render-targets' -Inspect
if($global:GatMockExecutables.Count -ne 1 -or [IO.Path]::GetFileName($global:GatMockExecutables[0]) -ne 'xenia_trace_replay_probe.exe' -or -not $global:GatMockArguments[0].Contains('--trace_dump_repeat_count=1')){throw 'Image inspection did not use one isolated candidate frame.'}
$global:GatMockProcessRunning=$false
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/probe" -PlatformProbe
if(Test-Path -LiteralPath "$base/probe"){throw 'Read-only probe created an output directory'}
$global:GatMockInjectFailure=$true
$rejected=$false
try {& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/invalid"}catch {if($_.Exception.Message -like 'Invalid rendering/timing run:*'){$rejected=$true}else{throw}}
if(-not $rejected){throw 'Backend failure was not rejected'}
$global:GatMockInjectFailure=$false
Set-Content -LiteralPath (Join-Path $base 'frame.png') -Value 'different reference image'
$rejected=$false
try {& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/wrong-reference"}catch {if($_.Exception.Message -like 'Baseline replay differs*'){$rejected=$true}else{throw}}
if(-not $rejected){throw 'Reference mismatch was not rejected'}
@'
param($Root)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'game-dispatched'),$Root)
'@ | Set-Content -LiteralPath "$base/Gat-Game-Control.ps1"
[IO.File]::WriteAllText("$base/replay.request",'game:'+('a'*32)+':launch')
& $runner -Executable "$base/tool.exe" -Trace missing -Config missing -OutputDirectory "$base/live"
if(-not(Test-Path -LiteralPath "$base/game-dispatched") -or (Test-Path -LiteralPath "$base/live")){throw 'Explicit game dispatch failed or created replay output'}
Remove-Item -LiteralPath "$base/game-dispatched"
[IO.File]::WriteAllText("$base/replay.request",'game:'+('a'*32)+':stop')
& $runner -Executable "$base/tool.exe" -Trace missing -Config missing -OutputDirectory "$base/stopped"
if((Test-Path -LiteralPath "$base/game-dispatched") -or (Test-Path -LiteralPath "$base/stopped")){throw 'An already completed stop was dispatched again'}
Write-Host 'Mock checks passed: matching reference accepted; backend failure and reference mismatch rejected. No GPU execution tested.'
$referenceId='b'*32
$null=New-Item -ItemType Directory -Path "$base/replay-results/$referenceId" -Force
Set-Content -LiteralPath "$base/replay-results/$referenceId/candidate-a.png" -Value 'identical mock image bytes'
[IO.File]::WriteAllText("$base/replay.request",'decode:'+('a'*32)+':'+$referenceId)
$global:GatMockArguments=@();$global:GatMockExecutables=@()
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/decoder"
if($global:GatMockExecutables.Count -ne 4 -or @($global:GatMockExecutables | ForEach-Object {[IO.Path]::GetFileName($_)}) -join ',' -ne 'tool.exe,xenia_trace_replay_probe.exe,xenia_trace_replay_probe.exe,tool.exe'){throw 'Decoder comparison did not use the two binaries in ABBA order'}
foreach($arguments in $global:GatMockArguments){
 foreach($option in @('--render_target_path=performance','--d3d12_snorm16_multiply_scale=true','--depth_bias_shader_offset=true','--depth_float24_convert_in_pixel_shader=true','--depth_float24_round=true')){
  if(-not $arguments.Contains($option)){throw ('Decoder comparison changed the graphics policy: '+$option)}
 }
}
Write-Host 'Decoder mock checks passed: isolated ABBA executables, identical corrected graphics policy, exact reference validation.'
[IO.File]::WriteAllText("$base/replay.request",'statistics:'+('a'*32)+':'+$referenceId)
$global:GatMockArguments=@();$global:GatMockExecutables=@()
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/statistics"
if($global:GatMockExecutables.Count -ne 1 -or [IO.Path]::GetFileName($global:GatMockExecutables[0]) -ne 'xenia_trace_replay_probe.exe' -or -not $global:GatMockArguments[0].Contains('--d3d12_draw_statistics=true')){throw 'Pipeline statistics did not use the single isolated diagnostic executable'}
[IO.File]::WriteAllText("$base/replay.request",'stages:'+('a'*32)+':'+$referenceId)
$global:GatMockArguments=@();$global:GatMockExecutables=@()
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/stages"
if($global:GatMockExecutables.Count -ne 1 -or [IO.Path]::GetFileName($global:GatMockExecutables[0]) -ne 'xenia_trace_replay_probe.exe' -or -not $global:GatMockArguments[0].Contains('--d3d12_stage_timing=true') -or $global:GatMockArguments[0].Contains('--d3d12_draw_statistics=true')){throw 'Stage timing did not use its isolated executable or mixed query modes'}
[IO.File]::WriteAllText("$base/replay.request",'cache:'+('a'*32)+':'+$referenceId)
$global:GatMockArguments=@();$global:GatMockExecutables=@()
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/cache"
if($global:GatMockExecutables.Count -ne 4 -or @($global:GatMockExecutables | Select-Object -Unique).Count -ne 1){throw 'Cache comparison changed the executable between runs'}
for($i=0;$i -lt 4;$i++){
 $expected=if($i -in @(1,2)){'--texture_cache_memory_limit_hard=2048'}else{'--texture_cache_memory_limit_hard=768'}
 if(-not $global:GatMockArguments[$i].Contains($expected)){throw 'Cache budget did not follow ABBA order'}
}
[IO.File]::WriteAllText("$base/replay.request",'pitch:'+('a'*32)+':'+$referenceId)
$global:GatMockArguments=@();$global:GatMockExecutables=@()
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/pitch"
if($global:GatMockExecutables.Count -ne 4 -or @($global:GatMockExecutables | Select-Object -Unique).Count -ne 1){throw 'Static transfer pitch comparison changed binaries between runs'}
for($i=0;$i -lt 4;$i++){
 $expected=if($i -in @(1,2)){'--d3d12_transfer_static_source_pitch=true'}else{'--d3d12_transfer_static_source_pitch=false'}
 if(-not $global:GatMockArguments[$i].Contains($expected)){throw 'Static transfer pitch did not follow ABBA order'}
}
[IO.File]::WriteAllText("$base/replay.request",'depthcopy:'+('a'*32)+':'+$referenceId)
$global:GatMockArguments=@();$global:GatMockExecutables=@()
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/depthcopy"
if($global:GatMockExecutables.Count -ne 4 -or @($global:GatMockExecutables | Select-Object -Unique).Count -ne 1){throw 'Depth-copy comparison changed binaries between runs'}
for($i=0;$i -lt 4;$i++){
 $expected=if($i -in @(1,2)){'--depth_transfer_not_equal_test=false'}else{'--depth_transfer_not_equal_test=true'}
 if(-not $global:GatMockArguments[$i].Contains($expected) -or -not $global:GatMockArguments[$i].Contains('--d3d12_transfer_static_source_pitch=true')){throw 'Depth-copy testing did not follow the isolated ABBA comparison'}
}
[IO.File]::WriteAllText("$base/replay.request",'stencilcopy:'+('a'*32)+':'+$referenceId)
$global:GatMockArguments=@();$global:GatMockExecutables=@()
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/stencilcopy"
if($global:GatMockExecutables.Count -ne 4 -or @($global:GatMockExecutables | Select-Object -Unique).Count -ne 1 -or [IO.Path]::GetFileName($global:GatMockExecutables[0]) -ne 'xenia_trace_replay_probe.exe'){throw 'Stencil-copy comparison did not isolate the setting within one executable'}
for($i=0;$i -lt 4;$i++){
 if($global:GatMockArguments[$i].Contains('--d3d12_stencil_plane_copy=true') -ne ($i -in @(1,2))){throw 'Stencil-copy option escaped the candidate runs'}
 if(-not $global:GatMockArguments[$i].Contains('--d3d12_stage_timing=true') -or -not $global:GatMockArguments[$i].Contains('--depth_float24_round=true')){throw 'Stencil-copy comparison changed the corrected rendering policy'}
}
[IO.File]::WriteAllText("$base/replay.request",'coverage:'+('a'*32)+':'+$referenceId)
$global:GatMockArguments=@();$global:GatMockExecutables=@()
& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/coverage"
if($global:GatMockExecutables.Count -ne 1 -or -not $global:GatMockArguments[0].Contains('--d3d12_stencil_bit_coverage=true') -or -not $global:GatMockArguments[0].Contains('--no_discard_stencil_in_transfer_pipelines=false')){throw 'Coverage inspection did not use a single controlled diagnostic run'}
$global:GatMockCoverageInvalid=$true
$rejected=$false
try {& $runner -Executable "$base/tool.exe" -Trace "$base/frame.xtr" -Config "$base/config.toml" -OutputDirectory "$base/invalid-coverage"}catch{if($_.Exception.Message -like 'Stencil coverage is unusable:*'){$rejected=$true}else{throw}}
if(-not $rejected){throw 'An unusable GPU coverage control was accepted'}
$global:GatMockCoverageInvalid=$false
Remove-Item -LiteralPath $base -Recurse -Force
