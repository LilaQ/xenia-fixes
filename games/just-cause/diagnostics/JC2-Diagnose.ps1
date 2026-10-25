[CmdletBinding()]
param([ValidateRange(10,60)][int]$CaptureSeconds = 15, [switch]$Elevated)
$ErrorActionPreference = 'Stop'
$traceStarted = $false
$traceName = 'XGC_JC2_' + [Guid]::NewGuid().ToString('N').Substring(0,8)
$consoleHandle = [IntPtr]::Zero
$targetProcess = $null
$runDir = $null
$failure = $null
$traceSaved = $false
$rows = New-Object 'System.Collections.Generic.List[object]'
$warnings = New-Object 'System.Collections.Generic.List[string]'

# Windows' CPU recorder needs elevation. No service, driver or startup entry is installed.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($Elevated) { throw 'Administratorrechte fehlen nach dem Neustart.' }
    try {
        $args = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -CaptureSeconds ' + $CaptureSeconds + ' -Elevated'
        $child = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -Verb RunAs -PassThru -Wait
        exit $child.ExitCode
    } catch { Write-Host "Diagnose nicht gestartet: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Jc2ProbeNative {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint id);
  [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr thread, out IntPtr text);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public static string ThreadName(uint id) {
    IntPtr h = OpenThread(0x0800, false, id);
    if (h == IntPtr.Zero) return "";
    IntPtr text = IntPtr.Zero;
    try {
      if (GetThreadDescription(h, out text) < 0 || text == IntPtr.Zero) return "";
      return Marshal.PtrToStringUni(text) ?? "";
    } catch (EntryPointNotFoundException) { return ""; }
    finally { if (text != IntPtr.Zero) LocalFree(text); CloseHandle(h); }
  }
}
'@
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class Jc2JitReader {
  [StructLayout(LayoutKind.Sequential)] struct MemoryInfo {
    public ulong BaseAddress, AllocationBase;
    public uint AllocationProtect, Padding1;
    public ulong RegionSize;
    public uint State, Protect, Type, Padding2;
  }
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, UIntPtr size, out UIntPtr read);
  [DllImport("kernel32.dll", SetLastError=true)] static extern UIntPtr VirtualQueryEx(IntPtr process, IntPtr address, out MemoryInfo info, UIntPtr length);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public static string Capture(int id, string directory) {
    if (IntPtr.Size != 8) throw new InvalidOperationException("64-bit PowerShell erforderlich.");
    IntPtr process = OpenProcess(0x410, false, id); // query + read only
    if (process == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    int functions = 0; ulong maxHost = 0, total = 0;
    byte[] block = new byte[1048576];
    try {
      using (var map = new StreamWriter(Path.Combine(directory,"jit-map.csv"))) {
        map.WriteLine("guest_address,host_address");
        ulong at = 0x80000000, end = 0xA0000000;
        while (at < end) {
          MemoryInfo info;
          if (VirtualQueryEx(process, new IntPtr((long)at), out info, new UIntPtr(48)).ToUInt64() == 0 || info.RegionSize == 0) throw new InvalidOperationException("JIT-Adressbereich nicht abfragbar.");
          ulong next = Math.Min(end, info.BaseAddress + info.RegionSize);
          if (next <= at) throw new InvalidOperationException("Ungueltiger Speicherbereich.");
          bool readable = info.State == 0x1000 && (info.Protect & (0x100|1)) == 0;
          if (readable) {
            for (ulong part = at; part < next; part += (ulong)block.Length) {
              int length = (int)Math.Min((ulong)block.Length, next - part);
              total += (ulong)length;
              if (total > 134217728) throw new InvalidOperationException("Diagnose-Limit fuer JIT-Tabelle erreicht.");
              UIntPtr got;
              if (!ReadProcessMemory(process,new IntPtr((long)part),block,new UIntPtr((uint)length),out got) || got.ToUInt64() != (ulong)length) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
              for (int offset=0; offset+4<=length; offset+=4) {
                uint host = BitConverter.ToUInt32(block, offset);
                if (host >= 0xA0001000 && host < 0xDFFFFFFF) {
                  map.WriteLine((part+(ulong)offset).ToString("X8")+","+host.ToString("X8"));
                  functions++; if (host>maxHost) maxHost=host;
                }
              }
            }
          }
          at=next;
        }
      }
      if (functions==0) throw new InvalidOperationException("Keine direkte JIT-Tabelle gefunden; dieser Build benutzt moeglicherweise andere Adressen.");
      ulong dumpEnd = (maxHost + 1048576 + 65535) & ~65535UL;
      if (dumpEnd > 0xB0000000UL) throw new InvalidOperationException("JIT-Map gespeichert, aber Code uebersteigt das 256-MB-Diagnoselimit.");
      using (var output=File.Create(Path.Combine(directory,"jit-code.bin"))) {
        for (ulong at=0xA0000000; at<dumpEnd; at+=(ulong)block.Length) {
          int length=(int)Math.Min((ulong)block.Length,dumpEnd-at);
          UIntPtr got;
          if (!ReadProcessMemory(process,new IntPtr((long)at),block,new UIntPtr((uint)length),out got) || got.ToUInt64()!=(ulong)length) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
          output.Write(block,0,length);
        }
      }
      return functions+" Funktionen, "+total+" Tabellenbytes, JIT-Basis A0000000";
    } finally { CloseHandle(process); }
  }
}
'@
$consoleHandle = [Jc2ProbeNative]::GetConsoleWindow()
$wprPath = Join-Path $env:SystemRoot 'System32\wpr.exe'
function Invoke-Recorder([string[]]$RecorderArguments) {
    $ErrorActionPreference = 'Continue'
    $output = @(& $wprPath @RecorderArguments 2>&1 | ForEach-Object { $_.ToString() })
    $code = $LASTEXITCODE
    Add-Content -LiteralPath (Join-Path $runDir 'recorder.log') -Encoding UTF8 -Value ((Get-Date -Format o) + ' wpr ' + ($RecorderArguments -join ' '))
    if ($output.Count) { Add-Content -LiteralPath (Join-Path $runDir 'recorder.log') -Encoding UTF8 -Value $output }
    return [PSCustomObject]@{ Code = $code; Output = $output }
}
function Get-ThreadSnapshot($Process) {
    $Process.Refresh()
    $threadRows = @{}
    foreach ($thread in $Process.Threads) {
        try {
            $tid = [int]$thread.Id
            $state = $thread.ThreadState.ToString()
            $reason = if ($state -eq 'Wait') { $thread.WaitReason.ToString() } else { '' }
            $threadRows[$tid] = [PSCustomObject]@{
                id = $tid; id_hex = ('{0:X8}' -f $tid)
                name = [Jc2ProbeNative]::ThreadName([uint32]$tid)
                cpu_ms = $thread.TotalProcessorTime.TotalMilliseconds
                kernel_ms = $thread.PrivilegedProcessorTime.TotalMilliseconds
                state = $state; wait_reason = $reason
            }
        } catch { } # Threads may exit between enumeration and inspection.
    }
    return $threadRows
}

try {
    if (-not (Test-Path -LiteralPath $wprPath)) { throw 'Windows Performance Recorder (wpr.exe) fehlt.' }
    $candidates = @(Get-CimInstance Win32_Process -Filter "Name='xenia_edge.exe'" | Where-Object {
        $_.CommandLine -match 'Just Cause 2'
    })
    if ($candidates.Count -ne 1) { throw 'Bitte genau eine JC2-Instanz aus LaunchBox starten und zur Stelle mit niedrigen FPS gehen.' }
    $targetId = [int]$candidates[0].ProcessId
    $targetProcess = [Diagnostics.Process]::GetProcessById($targetId)
    $targetStarted = $targetProcess.StartTime.ToUniversalTime().ToString('o')
    $runDir = Join-Path $PSScriptRoot ('JC2-Aufnahme-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $traceName.Substring(8))
    $meta = [ordered]@{}
    New-Item -ItemType Directory -Path $runDir | Out-Null
    $meta = [ordered]@{
        process_id = $targetId; process_start_utc = $targetStarted; command = $candidates[0].CommandLine
        cpu_percent_basis = '100 percent equals one fully occupied logical CPU, not the whole machine'
        duration_requested_seconds = $CaptureSeconds; recording_instance = $traceName
        cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed)
        gpu = @(Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion)
        power_plan = ((& "$env:SystemRoot\System32\powercfg.exe" /getactivescheme) -join ' ')
        cpu_trace_saved = $false; gpu_counter_available = $false
    }
    Write-Host 'JC2 muss bereits an der Stelle mit niedrigen FPS laufen.' -ForegroundColor Cyan
    Write-Host "Enter startet $CaptureSeconds Sekunden Messung. Das Fenster minimiert sich automatisch."
    Write-Host 'Danach einfach im Spiel bleiben; es wird nichts an Xenia geaendert.'
    [void](Read-Host)
    $targetProcess.Refresh()
    if ($targetProcess.HasExited) { throw 'JC2 wurde vor der Aufnahme beendet.' }
    $gpuAvailable = $true
    try {
        $gpuWarmup = @(Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Filter "Name LIKE 'pid_${targetId}[_]%'" -OperationTimeoutSec 3)
        $meta.gpu_counter_available = $true
    } catch { $gpuAvailable = $false; $warnings.Add('GPU-Zaehler nicht verfuegbar: ' + $_.Exception.Message) }
    $startResult = Invoke-Recorder @('-start','CPU','-instancename',$traceName)
    if ($startResult.Code -ne 0) { throw ('CPU-Recorder konnte nicht starten. ' + ($startResult.Output -join ' ')) }
    $traceStarted = $true
    if ($consoleHandle -ne [IntPtr]::Zero) { [void][Jc2ProbeNative]::ShowWindow($consoleHandle, 6) }
    if ($targetProcess.MainWindowHandle -ne [IntPtr]::Zero) { [void][Jc2ProbeNative]::SetForegroundWindow($targetProcess.MainWindowHandle) }
    try {
        $meta.jit_snapshot = [Jc2JitReader]::Capture($targetId, $runDir)
        Write-Host ('JIT-Tabelle gesichert: ' + $meta.jit_snapshot)
    } catch { $warnings.Add('JIT-Snapshot fehlgeschlagen: ' + $_.Exception.Message) }
    $previous = Get-ThreadSnapshot $targetProcess
    $previousProcessMs = $targetProcess.TotalProcessorTime.TotalMilliseconds
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $previousAt = $watch.Elapsed.TotalMilliseconds
    while ($watch.Elapsed.TotalSeconds -lt $CaptureSeconds) {
        Start-Sleep -Milliseconds 1000
        $targetProcess.Refresh()
        if ($targetProcess.HasExited) { $warnings.Add('JC2 waehrend der Aufnahme beendet.'); break }
        $current = Get-ThreadSnapshot $targetProcess
        $at = $watch.Elapsed.TotalMilliseconds
        $interval = $at - $previousAt
        $cpuMs = $targetProcess.TotalProcessorTime.TotalMilliseconds
        $threadSamples = @(
            foreach ($tid in $current.Keys) {
                $t = $current[$tid]
                if ($previous.ContainsKey($tid)) {
                    [PSCustomObject]@{
                        id = $tid; id_hex = $t.id_hex; name = $t.name
                        cpu_percent_one_core = [Math]::Round(100 * [Math]::Max(0, $t.cpu_ms - $previous[$tid].cpu_ms) / $interval, 2)
                        kernel_percent_one_core = [Math]::Round(100 * [Math]::Max(0, $t.kernel_ms - $previous[$tid].kernel_ms) / $interval, 2)
                        state = $t.state; wait_reason = $t.wait_reason
                    }
                }
            }
        )
        $gpu = @()
        if ($gpuAvailable) {
            try {
                $gpu = @(Get-CimInstance -ClassName Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Filter "Name LIKE 'pid_${targetId}[_]%'" -OperationTimeoutSec 3 | Select-Object Name, UtilizationPercentage)
            } catch { $gpuAvailable = $false; $warnings.Add('GPU-Zaehler fehlgeschlagen: ' + $_.Exception.Message) }
        }
        $rows.Add([PSCustomObject]@{
            elapsed_seconds = [Math]::Round($at / 1000, 3)
            interval_ms = [Math]::Round($interval, 2)
            process_cpu_percent_one_core = [Math]::Round(100 * [Math]::Max(0, $cpuMs - $previousProcessMs) / $interval, 2)
            working_set_mb = [Math]::Round($targetProcess.WorkingSet64 / 1MB, 1)
            threads = @($threadSamples | Sort-Object cpu_percent_one_core -Descending)
            gpu_engines = $gpu
        })
        $previous = $current; $previousAt = $at; $previousProcessMs = $cpuMs
    }
    if (-not $targetProcess.HasExited) {
        try { $meta.jit_snapshot = [Jc2JitReader]::Capture($targetId, $runDir) }
        catch { $warnings.Add('Finaler JIT-Snapshot fehlgeschlagen: ' + $_.Exception.Message) }
    }
} catch {
    $failure = $_.Exception.Message
} finally {
    if ($consoleHandle -ne [IntPtr]::Zero) { [void][Jc2ProbeNative]::ShowWindow($consoleHandle, 9) }
    if ($traceStarted) {
        Write-Host 'Aufnahme beendet, Windows speichert die CPU-Spuren...'
        try {
            $etlPath = Join-Path $runDir 'cpu.etl'
            $stopResult = Invoke-Recorder @('-stop',$etlPath,'JC2 gameplay performance','-skipPdbGen','-instancename',$traceName)
            if ($stopResult.Code -ne 0) { throw ($stopResult.Output -join ' ') }
            $traceSaved = (Test-Path -LiteralPath $etlPath) -and ((Get-Item -LiteralPath $etlPath).Length -gt 0)
            if (-not $traceSaved) { throw 'Windows hat keine gueltige Trace-Datei gespeichert.' }
            $traceStarted = $false
        } catch {
            $warnings.Add('CPU-Spuren konnten nicht gespeichert werden: ' + $_.Exception.Message)
            # Cancel only the unique instance created by this invocation; leave other recordings alone.
            [void](Invoke-Recorder @('-cancel','-instancename',$traceName))
            $traceStarted = $false
        }
    }
    if ($runDir) {
        $meta.cpu_trace_saved = $traceSaved
        $meta.error = $failure
        $meta.warnings = @($warnings.ToArray())
        $meta.samples_recorded = $rows.Count
        $meta.finished_utc = [DateTime]::UtcNow.ToString('o')
        $meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir 'metadata.json') -Encoding UTF8
        ConvertTo-Json -InputObject @($rows.ToArray()) -Depth 10 | Set-Content -LiteralPath (Join-Path $runDir 'samples.json') -Encoding UTF8
        $edgeDir = Split-Path -Parent $PSScriptRoot
        $sourceLog = Join-Path $edgeDir 'xenia.log'
        if (Test-Path -LiteralPath $sourceLog) {
            $inputLog = $null; $outputLog = $null
            try {
                $inputLog = New-Object IO.FileStream($sourceLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                $outputLog = [IO.File]::Create((Join-Path $runDir 'xenia.log'))
                $inputLog.CopyTo($outputLog)
            } catch { Write-Host ('Logkopie nicht verfuegbar: ' + $_.Exception.Message) -ForegroundColor Yellow }
            finally { if ($outputLog) { $outputLog.Dispose() }; if ($inputLog) { $inputLog.Dispose() } }
        }
    }
}
if ($failure) { Write-Host "Fehler: $failure" -ForegroundColor Red }
elseif (-not $traceSaved) { Write-Host 'Nur Zaehler gespeichert; CPU-Spuren fehlen. Bitte diese Meldung weitergeben.' -ForegroundColor Yellow }
elseif (-not $meta.jit_snapshot) { Write-Host 'CPU-Spuren gespeichert, aber JIT-Tabelle fehlt. Bitte JC2 offen lassen und die Warnung weitergeben.' -ForegroundColor Yellow }
else { Write-Host 'Messung fertig. Daten sind auf der Freigabe gespeichert. JC2 kann offen bleiben.' -ForegroundColor Green }
if ($runDir) { Write-Host $runDir }
[void](Read-Host 'Enter schliesst die Diagnose')
if ($failure -or -not $traceSaved) { exit 1 }
