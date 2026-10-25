$ErrorActionPreference='Stop'
try {
 $processes=@(Get-CimInstance Win32_Process -Filter "Name='xenia_edge.exe'" | Where-Object {$_.CommandLine -match 'Just Cause 2'})
 if($processes.Count-ne 1){throw 'Genau eine laufende Just-Cause-2-Instanz erforderlich.'}
 $gameProcess=Get-Process -Id $processes[0].ProcessId
 $processStart=$gameProcess.StartTime.ToUniversalTime()
 Add-Type -Path (Join-Path $PSScriptRoot 'Jc2ThreadReader.cs')
 $queue=Join-Path $PSScriptRoot 'JC2-Live'
 New-Item -ItemType Directory -Force -Path $queue|Out-Null
 [pscustomobject]@{process_id=$gameProcess.Id;process_start_utc=$processStart.ToString('o');started_utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $queue 'ready.json') -Encoding UTF8
 Write-Host 'JC2-Speicherleser aktiv. Dieses Fenster und Xenia offen lassen. Ende mit Ctrl+C.' -ForegroundColor Green
 while(-not $gameProcess.HasExited) {
  foreach($requestFile in @(Get-ChildItem -LiteralPath $queue -Filter '*.request.json')) {
   $requestId=$requestFile.Name.Replace('.request.json','')
   $parsedId=[guid]::Empty
   if(-not [guid]::TryParseExact($requestId,'N',[ref]$parsedId)){continue}
   $output=Join-Path $queue $requestId
   if(Test-Path -LiteralPath (Join-Path $output 'done.json')){continue}
   New-Item -ItemType Directory -Force -Path $output|Out-Null
   try {
    if($gameProcess.HasExited -or $gameProcess.StartTime.ToUniversalTime()-ne $processStart){throw 'JC2-Prozess hat sich geaendert.'}
    $request=Get-Content -LiteralPath $requestFile.FullName -Raw|ConvertFrom-Json
    $rangeCount=0;$contextCount=0
    if($request.capture_threads -eq $true) {
     if($request.ranges){throw 'Threadaufnahme und Bereichslesung getrennt anfordern.'}
     $gameProcess.Refresh()
     [uint32[]]$threads=@($gameProcess.Threads|Where-Object {[Jc2ThreadReader]::ThreadName([uint32]$_.Id)-match '^Guest CPU [0-5]$'}|ForEach-Object {[uint32]$_.Id})
     if($threads.Count-ne 6){throw 'Die sechs Edge-CPU-Threads wurden nicht gefunden.'}
     Write-Host 'Lese Gast-Thread-Stacks. Einzelne CPU-Threads werden kurz pausiert und sofort fortgesetzt.'
     $samples=[Jc2ThreadReader]::Capture($gameProcess.Id,$threads,$output)
     $samples|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $output 'threads.json') -Encoding UTF8
     $contextCount=$samples.Count
    } else {
     [uint32[]]$addresses=@($request.ranges|ForEach-Object {[Convert]::ToUInt32($_.address,16)})
     [int[]]$counts=@($request.ranges|ForEach-Object {$_.count})
     [Jc2ThreadReader]::ReadRanges($gameProcess.Id,$addresses,$counts,$output)
     $rangeCount=$addresses.Count
    }
    if($gameProcess.HasExited -or $gameProcess.StartTime.ToUniversalTime()-ne $processStart){throw 'JC2-Prozess hat sich waehrend der Aufnahme geaendert.'}
    [pscustomobject]@{process_id=$gameProcess.Id;captured_utc=[DateTime]::UtcNow.ToString('o');ranges=$rangeCount;contexts=$contextCount;error=$null}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $output 'done.json') -Encoding UTF8
    Write-Host ('Gelesen: '+$requestId+' ('+$rangeCount+' Bereiche, '+$contextCount+' Kontexte)')
   } catch {
    [pscustomobject]@{error=$_.Exception.Message}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $output 'done.json') -Encoding UTF8
    Write-Host $_.Exception.Message -ForegroundColor Red
   }
  }
  Start-Sleep -Milliseconds 250
  $gameProcess.Refresh()
 }
 Write-Host 'Xenia ist beendet. Leser beendet.'
} catch {
 Write-Host ('Leser fehlgeschlagen: '+$_.Exception.Message) -ForegroundColor Red
 Read-Host 'Enter zum Schliessen'
} finally {
 if($queue){Remove-Item -LiteralPath (Join-Path $queue 'ready.json') -Force -ErrorAction SilentlyContinue}
}
