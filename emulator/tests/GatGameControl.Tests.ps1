$ErrorActionPreference='Stop'
$script=Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Gat-Game-Control.ps1'
. $script -FunctionsOnly
$id='a'*32
foreach($action in @('launch','launch-depth','launch-release','launch-stages','launch-pitch','launch-stencilcopy','launch-no-msaa','launch-hdr-async','launch-sr4','launch-sr3','launch-queries','launch-unlimited','launch-vulkan','launch-stock','snapshot','capture','sample','readback-on','readback-off','async-hdr-on','async-hdr-off','present-ui','present-direct','present-window','gpu','layout','frames','frames-spin','stop','A','B','Y','Start','Back','Up','Down','Left','Right','MoveForward','MoveBackward','StrafeLeft','StrafeRight','CameraLeft','CameraRight')){
 $c=Read-GatGameCommand "game:${id}:${action}"
 if($c.Id -ne $id -or $c.Action -cne $action -or $c.Milliseconds -ne 150){throw 'Command parsing failed.'}
}
foreach($text in @("game:${id}:A:0","game:${id}:CameraRight:5001","game:${id}:Delete","game:${id}:A;whoami",'game:start','nonce')){
 $rejected=$false
 try{$null=Read-GatGameCommand $text}catch{$rejected=$true}
 if(-not $rejected){throw "Unsafe request accepted: $text"}
}
$argsText=New-GatGameArguments 'private config' 'original storage' 'isolated content' 'test log' 'game.iso'
foreach($required in @('--content_root="isolated content"','--render_target_path=performance','--fullscreen=true','--d3d12_snorm16_multiply_scale=true','--profiler_on_demand=true')){
 if(-not $argsText.Contains($required)){throw "Missing override: $required"}
}
$rejected=$false
try{$null=New-GatGameArguments 'x" --injected' storage content log game}catch{$rejected=$true}
if(-not $rejected){throw 'Quote injection accepted.'}
# Compile the exact interop source without calling any Windows API on this host.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$errors)
if($errors){throw ($errors | Out-String)}
$native=$ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('using System;')},$true)
if($native.Count -ne 5){throw 'Interop sources missing.'}
foreach($part in $native){Add-Type -TypeDefinition $part.Value}
if([Runtime.InteropServices.Marshal]::SizeOf([type][GatTestPadV2+Report]) -ne 12){throw 'Wrong XUSB report ABI.'}
$timings=[GatFrameCounterV3]::Summarize(300,5,[double[]]@(16,16,17,17,34),0)
if($timings.FPS -ne 60 -or $timings.P50 -ne 17 -or $timings.P95 -ne 34 -or $timings.Maximum -ne 34 -or $timings.ObservedIntervals -ne 5){throw 'Frame pacing summary discarded a slowdown.'}
$empty=[GatFrameCounterV3]::Summarize(0,5,[double[]]@(),0)
if($empty.FPS -ne 0 -or $empty.P95 -ne 0){throw 'Empty frame timing summary is invalid.'}
$directory=Join-Path ([IO.Path]::GetTempPath()) ('gat-image-check-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $directory
try{
 $packages=Join-Path $directory 'packages'
 $linked=Join-Path $directory 'linked'
 $null=New-Item -ItemType Directory -Path (Join-Path $packages '000B0000') -Force
 $originalPackage=Join-Path $packages '000B0000/update'
 [IO.File]::WriteAllText($originalPackage,'original-package')
 Add-SaintsTitlePackages $packages $linked
 $linkedPackage=Join-Path $linked '000B0000/update'
 if([IO.File]::ReadAllText($linkedPackage) -ne 'original-package'){throw 'Read-only package link is invalid.'}
 Remove-Item -LiteralPath $linked -Recurse -Force
 if([IO.File]::ReadAllText($originalPackage) -ne 'original-package'){throw 'Removing disposable package links damaged the installed content.'}
 $sourcePatch=Join-Path (Split-Path -Parent $PSScriptRoot) 'game-patches/4B4D0800 - Gat Single-sample Scene.patch.toml'
 $destinationPatch=Join-Path $directory 'scene.patch.toml'
 Set-GatScenePatch $sourcePatch $destinationPatch $true
 $validPatch=[IO.File]::ReadAllText($destinationPatch)
 $invalidPatch=Join-Path $directory 'invalid.patch.toml';[IO.File]::WriteAllText($invalidPatch,'unverified')
 $rejected=$false;try{Set-GatScenePatch $invalidPatch $destinationPatch $true}catch{$rejected=$true}
 if(-not $rejected -or [IO.File]::ReadAllText($destinationPatch) -ne $validPatch){throw 'Invalid scene patch damaged the previous fixture.'}
 Set-GatScenePatch $sourcePatch $destinationPatch $false
 if(Test-Path -LiteralPath $destinationPatch){throw 'Scene patch leaked into the comparison baseline.'}
 $request=Join-Path $directory 'request'
 if($null -ne (Read-GatGameRequest $request)){throw 'Missing request was accepted.'}
 [IO.File]::WriteAllText($request,'')
 if($null -ne (Read-GatGameRequest $request)){throw 'Empty request was accepted.'}
 [IO.File]::WriteAllText($request,'game:partial')
 if($null -ne (Read-GatGameRequest $request)){throw 'Partial request was accepted.'}
 $valid="game:${id}:snapshot"
 [IO.File]::WriteAllText($request,$valid)
 if((Read-GatGameRequest $request) -ne $valid){throw 'Complete request was lost.'}
 $locked=[IO.File]::Open($request,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{if($null -ne (Read-GatGameRequest $request)){throw 'Locked request was accepted.'}}finally{$locked.Dispose()}
 if((Read-GatGameRequest $request) -ne $valid){throw 'Request did not recover after temporary lock.'}
 $source=Join-Path $directory 'writer.png';$destination=Join-Path $directory 'completed.png'
 [IO.File]::WriteAllText($source,'completed-image-bytes')
 $writer=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{
  if(Move-GatFinishedScreenshot $source $destination){throw 'A still-open image was moved.'}
  if(-not(Test-Path $source) -or (Test-Path $destination)){throw 'Failed image move damaged inputs.'}
 }finally{$writer.Dispose()}
 if(-not(Move-GatFinishedScreenshot $source $destination)){throw 'Completed image could not be moved.'}
 if([IO.File]::ReadAllText($destination) -ne 'completed-image-bytes'){throw 'Image bytes changed.'}
}finally{Remove-Item -LiteralPath $directory -Recurse -Force}
'PASS: bounded input commands, path isolation, injection rejection, native interop compilation and 12-byte controller ABI.'
