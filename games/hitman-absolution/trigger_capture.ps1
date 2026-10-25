$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
try {
    $targets = @(Get-Process -Name 'xenia_edge_hitman' -ErrorAction SilentlyContinue)
    if ($targets.Count -ne 1) { throw 'Genau eine Edge-Instanz muss laufen: Hitman ueber Hitman-GPU-Aufnahme.cmd.' }
    $runs = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Hitman-Aufnahmen') -Directory | Sort-Object LastWriteTime -Descending)
    if ($runs.Count -eq 0) { throw 'Kein laufender Hitman-Aufnahmeordner gefunden.' }
    $runRoot = $runs[0].FullName
    $gui = Join-Path $PSScriptRoot 'RenderDoc_1.46_64\qrenderdoc.exe'
    $script = Join-Path $PSScriptRoot 'Hitman-Jetzt-Aufnehmen.py'
    # Give repeated captures their own control logs; do not replace prior results.
    $controlRoot = Join-Path $runRoot ('Trigger-' + (Get-Date -Format 'HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
    $null = New-Item -ItemType Directory -Path $controlRoot
    $log = Join-Path $controlRoot 'capture-trigger.log'
    $result = Join-Path $controlRoot 'capture-trigger-result.json'
    $env:HITMAN_CAPTURE_RUN = $controlRoot
    $env:HITMAN_CAPTURE_TARGET_PID = [string]$targets[0].Id
    Write-Host 'Direkte RenderDoc-Aufnahme: keine Screenshot-Taste erforderlich.' -ForegroundColor Cyan
    Write-Host 'Nach der Verbindungsbestaetigung bleiben 8 Sekunden, um zur fehlerhaften Flaeche in Xenia zu wechseln.'
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
    if (-not (Test-Path -LiteralPath $result)) { throw "RenderDoc hat kein Ergebnis geschrieben. Diagnoseordner: $controlRoot" }
    $data = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
    if (-not $data.success) { throw $data.error }
    Write-Host 'GPU-Aufnahme gespeichert. Xenia jetzt normal beenden und im Chat Bescheid geben.' -ForegroundColor Green
} catch {
    Write-Host ('Aufnahme fehlgeschlagen: ' + $_.Exception.Message) -ForegroundColor Red
}
Read-Host 'Enter zum Schliessen'
