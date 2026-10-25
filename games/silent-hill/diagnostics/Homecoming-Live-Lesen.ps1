$ErrorActionPreference = 'Stop'
try {
    $instances = @(Get-CimInstance Win32_Process -Filter "Name='xenia_canary.exe'" |
        Where-Object { $_.CommandLine -match 'Homecoming' })
    if ($instances.Count -ne 1) { throw 'Genau eine laufende Homecoming-Instanz erforderlich.' }
    $gameProcess = Get-Process -Id $instances[0].ProcessId
    $processStart = $gameProcess.StartTime.ToUniversalTime()
    Add-Type -Path (Join-Path $PSScriptRoot 'HomecomingReader.cs')
    $queue = Join-Path $PSScriptRoot 'Homecoming-Live'
    New-Item -ItemType Directory -Force -Path $queue | Out-Null
    [HomecomingReader]::ReadRanges($gameProcess.Id, [uint32[]]@([Convert]::ToUInt32('8256B858', 16)), [int[]]@(4), $queue)
    [pscustomobject]@{process_id=$gameProcess.Id;process_start_utc=$processStart.ToString('o');started_utc=[DateTime]::UtcNow.ToString('o')} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $queue 'ready.json') -Encoding UTF8
    Write-Host 'Homecoming-Speicherleser aktiv. Dieses Fenster und das Spiel offen lassen. Ende mit Ctrl+C.' -ForegroundColor Green
    while (-not $gameProcess.HasExited) {
        foreach ($requestFile in @(Get-ChildItem -LiteralPath $queue -Filter '*.request.json')) {
            $requestId = $requestFile.Name.Replace('.request.json', '')
            $parsedId = [guid]::Empty
            if (-not [guid]::TryParseExact($requestId, 'N', [ref]$parsedId)) { continue }
            $output = Join-Path $queue $requestId
            if (Test-Path -LiteralPath (Join-Path $output 'done.json')) { continue }
            New-Item -ItemType Directory -Force -Path $output | Out-Null
            try {
                $gameProcess.Refresh()
                if ($gameProcess.HasExited -or $gameProcess.StartTime.ToUniversalTime() -ne $processStart) { throw 'Homecoming-Prozess hat sich geaendert.' }
                $request = Get-Content -LiteralPath $requestFile.FullName -Raw | ConvertFrom-Json
                [uint32[]]$addresses = @($request.ranges | ForEach-Object { [Convert]::ToUInt32($_.address, 16) })
                [int[]]$counts = @($request.ranges | ForEach-Object { $_.count })
                [HomecomingReader]::ReadRanges($gameProcess.Id, $addresses, $counts, $output)
                $gameProcess.Refresh()
                if ($gameProcess.HasExited -or $gameProcess.StartTime.ToUniversalTime() -ne $processStart) { throw 'Homecoming-Prozess hat sich geaendert.' }
                [pscustomobject]@{process_id=$gameProcess.Id;captured_utc=[DateTime]::UtcNow.ToString('o');ranges=$addresses.Count;error=$null} |
                    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'done.json') -Encoding UTF8
            } catch {
                [pscustomobject]@{error=$_.Exception.Message} | ConvertTo-Json |
                    Set-Content -LiteralPath (Join-Path $output 'done.json') -Encoding UTF8
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
        }
        Start-Sleep -Milliseconds 200
        $gameProcess.Refresh()
    }
} catch {
    Write-Host ('Leser fehlgeschlagen: ' + $_.Exception.Message) -ForegroundColor Red
    Read-Host 'Enter zum Schliessen'
} finally {
    if ($queue) { Remove-Item -LiteralPath (Join-Path $queue 'ready.json') -Force -ErrorAction SilentlyContinue }
}
