$ErrorActionPreference='Stop'
$root=$env:GAT_TRACE_DIR.TrimEnd('\')
$runtime=Join-Path $root 'runtime'
$request=Join-Path $runtime 'replay.request'
$transcript=$false
$tfu2Session=@{}
$evilSession=@{}
function Read-ReplayRequest {
 try{
  $value=[IO.File]::ReadAllText($request)
  if(-not [string]::IsNullOrWhiteSpace($value)){return $value}
 }catch{}
 return $null
}
try {
 $null=Start-Transcript -LiteralPath (Join-Path $runtime 'replay-last.log') -Force
 $transcript=$true
 while($true){
  $requestSeen=Read-ReplayRequest
  try {
   if($requestSeen -and $requestSeen.StartsWith('evil:')){
    & (Join-Path $runtime 'EvilWithin-Control.ps1') -Root $root -Request $requestSeen -Session $evilSession
   }elseif($requestSeen -and $requestSeen.StartsWith('tfu2:')){
    & (Join-Path $runtime 'TFU2-Control.ps1') -Root $root -Request $requestSeen -Session $tfu2Session
   }elseif($requestSeen -and $requestSeen.StartsWith('game:')){
    & (Join-Path $runtime 'Gat-Game-Control.ps1') -Root $root
   }else{
    $captures=Join-Path $root 'capture\faithful'
    $frames=@(Get-ChildItem -LiteralPath $captures -Filter '*.xtr' -File | Sort-Object LastWriteTime)
    if(-not $frames.Count){throw 'Noch keine neue Aufnahme vorhanden.'}
    $trace=$frames[-1].FullName
    $config=Join-Path $root 'config\Gat.toml'
    $out=Join-Path $runtime ('replay-results\'+[guid]::NewGuid().ToString('N'))
    & (Join-Path $runtime 'Gat-Replay-Compare.ps1') -Executable (Join-Path $runtime 'xenia_trace_replay.exe') -Trace $trace -Config $config -OutputDirectory $out
   }
  } catch {Write-Host ($_ | Out-String) -ForegroundColor Red}
  Write-Host 'Replay-Helfer aktiv. Fenster offen lassen; weitere Aufnahme-Pruefungen werden hier ausgeloest. Ctrl+C beendet.' -ForegroundColor Cyan
  do {
   Start-Sleep -Milliseconds 500
   $requestNow=Read-ReplayRequest
  } while(-not $requestNow -or $requestNow -eq $requestSeen)
 }
} catch {Write-Host ($_ | Out-String) -ForegroundColor Red}
finally {
 if($evilSession.Count){
  try{& (Join-Path $runtime 'EvilWithin-Control.ps1') -Root $root -Request ('evil:'+('0'*32)+':stop') -Session $evilSession}catch{Write-Warning 'Evil Within cleanup could not complete.'}
 }
 if($tfu2Session.Count){
  try{& (Join-Path $runtime 'TFU2-Control.ps1') -Root $root -Request ('tfu2:'+('0'*32)+':stop') -Session $tfu2Session}catch{Write-Warning 'TFU2 cleanup could not complete.'}
 }
 if($transcript){$null=Stop-Transcript}
}
