$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$edgeRoot = Split-Path -Parent $PSScriptRoot
$launchBoxRoot = Split-Path -Parent (Split-Path -Parent $edgeRoot)
$renderDoc = Join-Path $PSScriptRoot 'RenderDoc_1.46_64\renderdoccmd.exe'
$xenia = Join-Path $edgeRoot 'xenia_edge_hitman.exe'
$sourceConfig = Join-Path $edgeRoot 'config\games\Hitman_ Absolution [9a38cae0].toml'
$game = Join-Path $launchBoxRoot 'Games\Microsoft Xbox 360\Hitman Absolution [USA][ENG][Rev 1]\Hitman - Absolution (USA) (Rev 1).iso'

try {
    foreach ($required in @($renderDoc, $xenia, $sourceConfig, $game)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Datei fehlt: $required"
        }
    }
    $running = @(Get-Process -Name 'xenia_edge','xenia_edge_hitman','xenia_canary' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        throw 'Bitte zuerst die laufenden Xenia-Instanzen beenden. LaunchBox darf offen bleiben.'
    }

    $runRoot = Join-Path $PSScriptRoot ('Hitman-Aufnahmen\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $null = New-Item -ItemType Directory -Path $runRoot
    $shaderRoot = Join-Path $runRoot 'shaders'
    $null = New-Item -ItemType Directory -Path $shaderRoot
    $diagnosticConfig = Join-Path $runRoot 'Hitman-Capture.toml'
    Copy-Item -LiteralPath $sourceConfig -Destination (Join-Path $runRoot 'Hitman-Original.toml')
    $text = [IO.File]::ReadAllText($sourceConfig)
    foreach ($setting in @('fullscreen','dump_shaders','log_file','gpu')) {
        if ([regex]::Matches($text, '(?m)^' + $setting + '\s*=').Count -ne 1) {
            throw "Unerwartete Config-Struktur bei $setting. Original bleibt unveraendert."
        }
    }
    $text = [regex]::Replace($text, '(?m)^(fullscreen\s*=\s*)\w+', '${1}false')
    # The water fault also occurs on D3D12. Use it only for the capture clone:
    # forcing the RenderDoc Vulkan layer currently fails at instance creation.
    $text = [regex]::Replace($text, '(?m)^(gpu\s*=\s*)"[^"]+"', '${1}"d3d12"')
    $shaderPath = $shaderRoot.Replace('\','/')
    $xeniaLogPath = (Join-Path $runRoot 'xenia.log').Replace('\','/')
    $text = [regex]::Replace($text, '(?m)^dump_shaders\s*=.*$', ('dump_shaders = "' + $shaderPath + '"'))
    $text = [regex]::Replace($text, '(?m)^log_file\s*=.*$', ('log_file = "' + $xeniaLogPath + '"'))
    [IO.File]::WriteAllText($diagnosticConfig, $text, (New-Object Text.UTF8Encoding($false)))

    Write-Host 'HITMAN: D3D12-GPU-Aufnahme mit dem vorhandenen Edge-Build' -ForegroundColor Cyan
    Write-Host 'Nur dieser Diagnosestart verwendet D3D12. Die normale Spielconfig bleibt unveraendert.'
    Write-Host '1. Mit deinem Xbox-Controller Spielstand laden und die fehlerhafte Flaeche ansehen.'
    Write-Host '2. Hitman-Jetzt-Aufnehmen.cmd im selben Ordner starten. Keine Screenshot-Taste noetig.'
    Write-Host '   Nach der Verbindung in 8 Sekunden zur fehlerhaften Flaeche wechseln. Das zweite Fenster bestaetigt die Datei.'
    Write-Host '3. Xenia normal beenden. Dieses Fenster bleibt bis zum Abschluss offen.'
    Write-Host "Ausgabe: $runRoot"
    Write-Host 'Der 60-FPS-Patch bleibt fuer diesen Vergleich im bisherigen Zustand.'
    Write-Host ''

    $capturePrefix = Join-Path $runRoot 'Hitman'
    $arguments = 'capture --working-dir "{0}" --capture-file "{1}" --wait-for-exit "{2}" --config="{3}" --log_file="{5}" --portable "{4}"' -f $edgeRoot, $capturePrefix, $xenia, $diagnosticConfig, $game, (Join-Path $runRoot 'xenia.log')
    $process = Start-Process -FilePath $renderDoc -ArgumentList $arguments -WorkingDirectory $edgeRoot -RedirectStandardOutput (Join-Path $runRoot 'renderdoc-stdout.log') -RedirectStandardError (Join-Path $runRoot 'renderdoc-stderr.log') -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "RenderDoc-Start fehlgeschlagen (Exit $($process.ExitCode)). Logs: $runRoot"
    }
    $captures = @(Get-ChildItem -LiteralPath $runRoot -Filter '*.rdc' -File)
    if ($captures.Count -eq 0) {
        throw "Keine GPU-Aufnahme gefunden. Bitte Hitman-Jetzt-Aufnehmen.cmd waehrend des Spiels verwenden. Logs: $runRoot"
    }
    foreach ($capture in $captures) {
        if ($capture.Length -eq 0) { throw "Leere Aufnahme: $($capture.FullName)" }
        Write-Host ("Aufnahme gespeichert: {0} ({1:N1} MiB)" -f $capture.Name, ($capture.Length / 1MB)) -ForegroundColor Green
    }
    Write-Host 'Fertig. Bitte im Chat Bescheid geben; die Dateien liegen bereits auf der Freigabe.' -ForegroundColor Green
} catch {
    Write-Host ("Aufnahme fehlgeschlagen: " + $_.Exception.Message) -ForegroundColor Red
    Read-Host 'Enter zum Schliessen'
    exit 1
}
Read-Host 'Enter zum Schliessen'
