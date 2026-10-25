$ErrorActionPreference = 'Stop'
try {
    $capture = Get-ChildItem -LiteralPath $PSScriptRoot -Directory -Filter 'JC2-Aufnahme-*' | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'metadata.json')
    } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $capture) { throw 'Keine bestehende JC2-Aufnahme gefunden.' }
    $meta = Get-Content -LiteralPath (Join-Path $capture.FullName 'metadata.json') -Raw | ConvertFrom-Json
    $target = [Diagnostics.Process]::GetProcessById([int]$meta.process_id)
    if ($target.HasExited -or $target.ProcessName -ne 'xenia_edge') { throw 'Die aufgenommene JC2-Instanz laeuft nicht mehr.' }
    if ($target.StartTime.ToUniversalTime().ToString('o') -ne $meta.process_start_utc) { throw 'Andere Prozessinstanz; alte Adressen koennen nicht zugeordnet werden.' }
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'JC2-Diagnose.ps1') -Raw
    $match = [regex]::Match($source, "(?s)Add-Type -TypeDefinition @'\r?\n(using System;\r?\nusing System.IO;.*?)\r?\n'@")
    if (-not $match.Success -or -not $match.Groups[1].Value.Contains('class Jc2JitReader')) { throw 'Passender JIT-Leser fehlt.' }
    Add-Type -TypeDefinition $match.Groups[1].Value
    Write-Host 'Lese die JIT-Zuordnung derselben JC2-Instanz erneut. Xenia bitte offen lassen.' -ForegroundColor Cyan
    $result = [Jc2JitReader]::Capture([int]$meta.process_id, $capture.FullName)
    $meta.jit_snapshot = $result
    $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $capture.FullName 'metadata.json') -Encoding UTF8
    Write-Host ('Fertig: ' + $result) -ForegroundColor Green
} catch {
    Write-Host ('Nachlesen fehlgeschlagen: ' + $_.Exception.Message) -ForegroundColor Red
    [void](Read-Host 'Enter schliesst das Fenster'); exit 1
}
[void](Read-Host 'Enter schliesst das Fenster')
