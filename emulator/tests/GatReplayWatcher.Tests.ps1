$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('gat-watch-check-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Force "$root/runtime","$root/capture/faithful","$root/config"
Set-Content -LiteralPath "$root/capture/faithful/frame.xtr" -Value mock
@'
param($Executable,$Trace,$Config,$OutputDirectory)
[IO.File]::AppendAllText((Join-Path $env:GAT_TRACE_DIR 'runs'),"run`n")
'@ | Set-Content -LiteralPath "$root/runtime/Gat-Replay-Compare.ps1"
@'
param($Root)
[IO.File]::AppendAllText((Join-Path $Root 'game-runs'),"game`n")
'@ | Set-Content -LiteralPath "$root/runtime/Gat-Game-Control.ps1"
$info=New-Object Diagnostics.ProcessStartInfo
$info.FileName=(Get-Process -Id $PID).Path
$helper=Join-Path (Split-Path -Parent $PSScriptRoot) 'tools/Gat-Replay-View.ps1'
$info.Arguments='-NoProfile -File "'+$helper+'"'
$info.UseShellExecute=$false
$info.EnvironmentVariables['GAT_TRACE_DIR']=$root
$p=[Diagnostics.Process]::Start($info)
try {
 function Await-Runs($count){
  for($i=0;$i -lt 50;$i++){
   if($p.HasExited){throw "Watcher exited: $($p.ExitCode)"}
   if((Test-Path "$root/runs") -and @([IO.File]::ReadAllLines("$root/runs")).Count -eq $count){return}
   Start-Sleep -Milliseconds 100
  }
  throw "Missing expected run $count"
 }
 Await-Runs 1
 Start-Sleep -Milliseconds 700
 if(@([IO.File]::ReadAllLines("$root/runs")).Count -ne 1){throw 'Unrequested rerun'}
 [IO.File]::WriteAllText("$root/runtime/replay.request",'')
 Start-Sleep -Milliseconds 700
 if(@([IO.File]::ReadAllLines("$root/runs")).Count -ne 1){throw 'Empty request caused a run.'}
 [IO.File]::WriteAllText("$root/runtime/replay.request",'second')
 Await-Runs 2
 Start-Sleep -Milliseconds 700
 if(@([IO.File]::ReadAllLines("$root/runs")).Count -ne 2){throw 'Duplicate rerun'}
 [IO.File]::Delete("$root/runtime/replay.request")
 Start-Sleep -Milliseconds 700
 [IO.File]::WriteAllText("$root/runtime/replay.request",'second')
 Start-Sleep -Milliseconds 700
 if($p.HasExited -or @([IO.File]::ReadAllLines("$root/runs")).Count -ne 2){throw 'Missing/recreated request stopped or repeated the watcher.'}
 [IO.File]::WriteAllText("$root/runtime/replay.request",'third')
 Await-Runs 3
 Remove-Item -LiteralPath "$root/capture/faithful/frame.xtr"
 [IO.File]::WriteAllText("$root/runtime/replay.request",('game:'+('a'*32)+':launch-hdr-async'))
 for($i=0;$i -lt 50 -and -not(Test-Path "$root/game-runs");$i++){Start-Sleep -Milliseconds 100}
 if(-not(Test-Path "$root/game-runs") -or @([IO.File]::ReadAllLines("$root/game-runs")).Count -ne 1 -or @([IO.File]::ReadAllLines("$root/runs")).Count -ne 3){throw 'Owned game launch depends on retaining an obsolete trace.'}
 'PASS: real watcher survives missing/empty request files, ignores unchanged recreation, and executes only requested changes.'
} finally {
 if(-not $p.HasExited){$p.Kill();$p.WaitForExit()}
 $p.Dispose()
 Remove-Item -LiteralPath $root -Recurse -Force
}
