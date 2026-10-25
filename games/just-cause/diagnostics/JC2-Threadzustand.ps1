$ErrorActionPreference = 'Stop'
$folder = $null
try {
    if (-not [Environment]::Is64BitProcess) { throw '64-bit PowerShell erforderlich.' }
    $candidates = @(Get-CimInstance Win32_Process -Filter "Name='xenia_edge.exe'" | Where-Object { $_.CommandLine -match 'Just Cause 2' })
    if ($candidates.Count -ne 1) { throw 'Bitte genau eine JC2-Instanz im haengenden Ladebildschirm offen lassen.' }
    $targetId = [int]$candidates[0].ProcessId
    $target = [Diagnostics.Process]::GetProcessById($targetId)
    $startTime = $target.StartTime.ToUniversalTime().ToString('o')
    # Reuse the already installed thread-name helper and JIT reader without running WPR.
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'JC2-Diagnose.ps1') -Raw
    $blocks = [regex]::Matches($source, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
    if ($blocks.Count -ne 2) { throw 'Die bekannten Diagnose-Helfer fehlen.' }
    foreach ($block in $blocks) { Add-Type -TypeDefinition $block.Groups[1].Value }
    Add-Type -Path (Join-Path $PSScriptRoot 'Jc2ThreadReader.cs')
    $threads = @($target.Threads | Where-Object { [Jc2ProbeNative]::ThreadName([uint32]$_.Id) -match '^Guest CPU [0-5]$' } | ForEach-Object { [uint32]$_.Id })
    if ($threads.Count -ne 6) { throw 'Die sechs Edge-CPU-Threads wurden nicht gefunden.' }
    $folder = Join-Path $PSScriptRoot ('JC2-Zustand-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $folder | Out-Null
    Write-Host 'Lese JC2-Threadzustand. Einzelne CPU-Threads werden fuer die Registerlesung kurz pausiert und sofort fortgesetzt.' -ForegroundColor Cyan
    $samples = [Jc2ThreadReader]::Capture($targetId, [uint32[]]$threads, $folder)
    $samples | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $folder 'threads.json') -Encoding UTF8
    $jit = [Jc2JitReader]::Capture($targetId, $folder)
    if ($target.HasExited -or $target.StartTime.ToUniversalTime().ToString('o') -ne $startTime) { throw 'Xenia wurde waehrend der Aufnahme beendet.' }
    [ordered]@{ process_id=$targetId; process_start_utc=$startTime; command=$candidates[0].CommandLine; jit_snapshot=$jit; contexts=$samples.Count } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $folder 'metadata.json') -Encoding UTF8
    Write-Host ('Fertig: ' + $samples.Count + ' Kontextaufnahmen. Xenia bitte offen lassen.') -ForegroundColor Green
} catch {
    if ($folder) { $_.Exception.ToString() | Set-Content -LiteralPath (Join-Path $folder 'error.log') -Encoding UTF8 }
    Write-Host ('Threadaufnahme fehlgeschlagen: ' + $_.Exception.Message) -ForegroundColor Red
    [void](Read-Host 'Enter schliesst das Fenster'); exit 1
}
[void](Read-Host 'Enter schliesst das Fenster')
