$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$errorLog=Join-Path $PSScriptRoot 'capture-last-error.log'
try {
    $diagnosticsRoot=Split-Path -Parent $PSScriptRoot
    $edgeRoot=Split-Path -Parent $diagnosticsRoot
    $targets=@(Get-Process -Name 'xenia_edge_rise' -ErrorAction SilentlyContinue)
    if($targets.Count -ne 1){throw 'Genau ein Rise-Aufnahmestart muss laufen. Bitte Rise-Start.cmd verwenden.'}
    $expectedExe=Join-Path $edgeRoot 'xenia_edge_rise.exe'
    if($targets[0].MainModule.FileName -ne $expectedExe){throw 'Unerwarteter Prozesspfad. Kein Zugriff ausgefuehrt.'}
    $renderdoc=Join-Path $diagnosticsRoot 'RenderDoc_1.46_64\renderdoc.dll'
    if((Get-FileHash -LiteralPath $renderdoc -Algorithm SHA256).Hash -ne '809DA38E3867D9FD09CC5C30DD5310500DEE75E999166D7A14AD1EF6E9ECA65D'){throw 'RenderDoc hat eine andere Version. Kein Prozesszugriff ausgefuehrt.'}
    $dll=Join-Path $PSScriptRoot 'RiseCaptureWindow.dll'
    if((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne '9FEE663AE2E56791F869DEA7382839C2000A3A0A76CF45C7B095E38D49875F1C'){throw 'Aufnahme-DLL hat eine andere Version.'}
    $runs=@(Get-ChildItem -LiteralPath (Join-Path $diagnosticsRoot 'Rise-Aufnahmen') -Directory | Sort-Object LastWriteTime -Descending)
    if($runs.Count -eq 0){throw 'Kein Aufnahmeordner vorhanden.'}
    $run=$runs[0].FullName
    $control=Join-Path $run ('Window-'+(Get-Date -Format 'HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
    $null=New-Item -ItemType Directory -Path $control
    $log=Join-Path $control 'window.log'
    $result=Join-Path $control 'window-result.json'
    Add-Type -Path (Join-Path $PSScriptRoot 'CaptureWindow.cs')
    Write-Host 'Eine zusammenhaengende GPU-Aufnahme, Speichern erst am Ende.' -ForegroundColor Cyan
    Write-Host 'In 8 Sekunden beginnt das gemessene Zeitfenster. Jetzt zur fehlerhaften Stelle wechseln.'
    Start-Sleep -Seconds 8
    $progress=[Action[string]]{param($message) Write-Host $message;Add-Content -LiteralPath $log -Value $message}
    $data=[RiseWindowCapture]::Run($targets[0].Id,$dll,$renderdoc,0x1F84D0,0x1000,$progress)
    if(-not (Test-Path -LiteralPath $data.Path -PathType Leaf)){throw 'RenderDoc meldet eine Datei, sie ist aber nicht vorhanden.'}
    $prefix=[IO.Path]::GetFullPath($run).TrimEnd('\')+'\'
    if(-not [IO.Path]::GetFullPath($data.Path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Aufnahme liegt ausserhalb des vorbereiteten Ordners.'}
    if((Get-Item -LiteralPath $data.Path).Length -eq 0){throw 'Aufnahme ist leer.'}
    $data.Bytes=[System.UInt64](Get-Item -LiteralPath $data.Path).Length
    $data | ConvertTo-Json | Set-Content -LiteralPath $result -Encoding UTF8
    Write-Host ('Gespeichert: {0}; Zeitfenster {1:N3} s; {2:N1} MiB' -f $data.Path,$data.Seconds,($data.Bytes/1MB)) -ForegroundColor Green
    Write-Host 'Xenia normal beenden und im Chat done schreiben. Keine weitere Aufnahme noetig.'
} catch {
    $_ | Out-String | Set-Content -LiteralPath $errorLog
    Write-Host ('Aufnahme fehlgeschlagen: '+$_.Exception.Message) -ForegroundColor Red
}
Read-Host 'Enter zum Schliessen'
