$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/TFU2-Control.ps1') -FunctionsOnly
$token='a'*32
foreach($action in @('status','launch-baseline','launch-candidate','stop','capture','snapshot','replay-baseline','replay-candidate','clear-captures','A','CameraRight')){
 $r=Read-TFU2Request ('tfu2:'+$token+':'+$action)
 if($r.Action -ne $action -or $r.Milliseconds -ne 150){throw 'Valid action rejected or changed.'}
}
foreach($bad in @('tfu2:'+ $token+':powershell','tfu2:'+$token+':A:19','tfu2:'+$token+':A:5001','game:'+$token+':launch','tfu2:bad:status','tfu2:'+$token+':A;exit')){
 $rejected=$false
 try{$null=Read-TFU2Request $bad}catch{$rejected=$true}
 if(-not $rejected){throw 'Unapproved action accepted.'}
}
# A wrong process path can never be terminated by the test cleanup.
$wrong=[pscustomobject]@{HasExited=$false;Path='C:\Other\game.exe'}
$rejected=$false
try{Stop-TFU2Test @{Game=$wrong} 'D:\Expected\capture.exe'}catch{$rejected=$true}
if(-not $rejected){throw 'Cleanup accepted an unowned process.'}
# Use real helper invocations to verify TFU2 works without a Gat .xtr and that
# command state persists across requests; no Windows/game APIs run in this test.
$root=Join-Path ([IO.Path]::GetTempPath()) ('tfu2-watch-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path (Join-Path $root 'runtime') -Force
@'
param($Root,$Request,$Session)
if(-not $Session.ContainsKey('Calls')){$Session.Calls=0}
$Session.Calls++
[IO.File]::WriteAllText((Join-Path $Root 'calls'),[string]$Session.Calls)
'@ | Set-Content -LiteralPath (Join-Path $root 'runtime/TFU2-Control.ps1')
$req=Join-Path $root 'runtime/replay.request'
[IO.File]::WriteAllText($req,('tfu2:'+('a'*32)+':status'))
$info=New-Object Diagnostics.ProcessStartInfo
$info.FileName=(Get-Process -Id $PID).Path
$helper=Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Gat-Replay-View.ps1'
$info.Arguments='-NoProfile -File "'+$helper+'"'
$info.UseShellExecute=$false
$info.EnvironmentVariables['GAT_TRACE_DIR']=$root
$p=[Diagnostics.Process]::Start($info)
try {
 foreach($count in @(1,2)){
  if($count -eq 2){[IO.File]::WriteAllText($req,('tfu2:'+('b'*32)+':status'))}
  $found=$false
  for($attempt=0;$attempt -lt 60;$attempt++){
   if($p.HasExited){throw 'Helper exited.'}
   if((Test-Path (Join-Path $root 'calls')) -and [IO.File]::ReadAllText((Join-Path $root 'calls')) -eq [string]$count){$found=$true;break}
   Start-Sleep -Milliseconds 100
  }
  if(-not $found){throw ('Missing dispatch '+$count)}
 }
 'PASS: TFU2 command allowlist, input bounds, owned-process guard and real helper dispatch/state persistence.'
}finally{
 if(-not $p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()
 Remove-Item -LiteralPath $root -Recurse -Force
}
