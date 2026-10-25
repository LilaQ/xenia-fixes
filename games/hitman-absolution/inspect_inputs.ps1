$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
try {
    if (@(Get-Process -Name 'xenia_edge','xenia_canary' -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'Bitte Xenia vor der GPU-Auswertung schliessen. LaunchBox darf offen bleiben.'
    }
    $captures = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Hitman-Aufnahmen') -Filter '*.rdc' -File -Recurse | Sort-Object LastWriteTime -Descending)
    if ($captures.Count -eq 0) { throw 'Keine RDC-Aufnahme gefunden.' }
    $capture = $captures[0]
    $previous = @(Get-ChildItem -LiteralPath $capture.DirectoryName -Directory -Filter 'Meer-Auswertung-*' | Sort-Object LastWriteTime -Descending)
    $source = $null
    foreach ($candidate in $previous) {
        $resultPath = Join-Path $candidate.FullName 'result.json'
        if (-not (Test-Path -LiteralPath $resultPath)) { continue }
        $resultData = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ($resultData.success -and $resultData.capture -eq $capture.FullName -and $resultData.sceneDraws -gt 200) {
            $source = $candidate.FullName
            break
        }
    }
    if (-not $source) { throw 'Keine erfolgreiche erweiterte Meer-Auswertung fuer diese Aufnahme vorhanden.' }
    $env:HITMAN_ANALYSIS_SOURCE = $source
    $root = Join-Path $capture.DirectoryName ('Meer-Eingaben-' + (Get-Date -Format 'HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    $null = New-Item -ItemType Directory -Path $root
    $env:HITMAN_ANALYSIS_ROOT = $root
    $env:HITMAN_ANALYSIS_CAPTURE = $capture.FullName
    $env:HITMAN_DIAGNOSTIC_ROOT = $PSScriptRoot
    $gui = Join-Path $PSScriptRoot 'RenderDoc_1.46_64\qrenderdoc.exe'
    $script = Join-Path $PSScriptRoot 'Hitman-Meer-Eingaben.py'
    $log = Join-Path $root 'analysis.log'
    Write-Host ('Meer-Texturen und Zwischenbilder: ' + $capture.Name) -ForegroundColor Cyan
    Write-Host 'Kein neuer Spieltest noetig. Die vorhandene Aufnahme wird auf der Windows-GPU ausgewertet.'
    Write-Host 'Exportiert nur die Meer-Draws, deren Texturen und Zwischenbilder. Keine Spielaenderung.'
    Write-Host 'Bitte dieses Fenster bis FERTIG offen lassen.'
    $process = Start-Process -FilePath $gui -ArgumentList ('--python "{0}"' -f $script) -PassThru
    $lineCount = 0
    while (-not $process.HasExited) {
        if (Test-Path -LiteralPath $log) {
            try {
                $lines = @([IO.File]::ReadAllLines($log))
                while ($lineCount -lt $lines.Count) { Write-Host $lines[$lineCount]; $lineCount++ }
            } catch { }
        }
        Start-Sleep -Milliseconds 300
        $process.Refresh()
    }
    if (Test-Path -LiteralPath $log) {
        $lines = @([IO.File]::ReadAllLines($log))
        while ($lineCount -lt $lines.Count) { Write-Host $lines[$lineCount]; $lineCount++ }
    }
    $result = Join-Path $root 'result.json'
    if (-not (Test-Path -LiteralPath $result)) { throw "RenderDoc hat kein Ergebnis geschrieben. Logs: $root" }
    $data = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
    if (-not $data.success) { throw $data.error }
    Write-Host ('Auswertung gespeichert: ' + $root) -ForegroundColor Green
} catch {
    Write-Host ('Auswertung fehlgeschlagen: ' + $_.Exception.Message) -ForegroundColor Red
    Read-Host 'Enter zum Schliessen'
    exit 1
}
Read-Host 'Enter zum Schliessen'
