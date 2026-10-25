[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$folder = $null
$phase = 'Prozess suchen'
$transcriptStarted = $false
try {
    if (-not [Environment]::Is64BitProcess) { throw 'Bitte mit 64-bit PowerShell starten.' }
    $candidates = @(Get-CimInstance Win32_Process -Filter "Name='xenia_edge.exe'" | Where-Object {
        $_.CommandLine -match 'e1af0902|C23A2E881D177A2631416513A91DC539B348C07D58'
    })
    if ($candidates.Count -ne 1) { throw 'Bitte genau eine XXL-Instanz aus LaunchBox starten und bis zum Menue warten.' }
    $targetId = [int]$candidates[0].ProcessId
    $target = [Diagnostics.Process]::GetProcessById($targetId)
    $startTime = $target.StartTime.ToUniversalTime().ToString('o')
    Write-Host 'Kurzer Codevergleich fuer XXL. Spiel und LaunchBox koennen offen bleiben.' -ForegroundColor Cyan
    Write-Host 'Nur Lesen: keine Config-Aenderung, kein Patch, kein Performance Recorder.'
    $folder = Join-Path $PSScriptRoot ('Codecheck-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $folder | Out-Null
    Start-Transcript -LiteralPath (Join-Path $folder 'codecheck.log') -Force | Out-Null
    $transcriptStarted = $true
    $phase = 'C# Leser kompilieren'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class XxlJitReader {
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
                if (host >= 0xA0001000 && host < 0xA4000000) {
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
      ulong dumpEnd = Math.Min(0xA4000000UL, (maxHost + 1048576 + 65535) & ~65535UL);
      using (var output=File.Create(Path.Combine(directory,"jit-code.bin"))) {
        for (ulong at=0xA0000000; at<dumpEnd; at+=(ulong)block.Length) {
          int length=(int)Math.Min((ulong)block.Length,dumpEnd-at);
          UIntPtr got;
          if (!ReadProcessMemory(process,new IntPtr((long)at),block,new UIntPtr((uint)length),out got) || got.ToUInt64()!=(ulong)length) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
          output.Write(block,0,length);
        }
      }
      int readEntries = 0, unavailable = 0;
      // Only compiled guest instruction entries, not arbitrary process memory.
      // Fixed bases are checked against RuntimeHost's known patched entry.
      byte[] check = new byte[4]; UIntPtr checkRead;
      if (!ReadProcessMemory(process, new IntPtr(0x2823570D0L), check,
          new UIntPtr(4), out checkRead) || checkRead.ToUInt64() != 4 ||
          check[0] != 0x7C || check[1] != 0x66 || check[2] != 0x1B || check[3] != 0x78)
        throw new InvalidOperationException("Erwartete XXL-Runtime und Speicherbasis nicht gefunden; kein Gastcode gelesen.");
      using (var code = new StreamWriter(Path.Combine(directory,"guest-entries.csv"))) {
        code.WriteLine("guest_address,host_address,kernel_bytes,user_bytes");
        foreach (string line in File.ReadLines(Path.Combine(directory,"jit-map.csv"))) {
          if (line.StartsWith("guest_address,")) continue;
          string[] entry = line.Split(',');
          uint guest = Convert.ToUInt32(entry[0],16);
          // The recorded CLR/XNA code lives in this virtual kernel range.
          if (guest < 0x82000000 || guest >= 0x85000000) continue;
          byte[] instructions = new byte[32]; UIntPtr got;
          string kernel = "", user = "";
          if (ReadProcessMemory(process,new IntPtr((long)(0x200000000UL+guest)),
              instructions,new UIntPtr(32),out got) && got.ToUInt64()==32)
            kernel = BitConverter.ToString(instructions).Replace("-","");
          if (ReadProcessMemory(process,new IntPtr((long)(0x400000000UL+guest)),
              instructions,new UIntPtr(32),out got) && got.ToUInt64()==32)
            user = BitConverter.ToString(instructions).Replace("-","");
          code.WriteLine(entry[0]+","+entry[1]+","+kernel+","+user);
          if (kernel.Length==0) unavailable++; else readEntries++;
        }
      }
      if (readEntries==0) throw new InvalidOperationException("Keine Gastcode-Eintraege lesbar.");
      // The fixed indirection table ends at A0000000. CLR methods outside
      // it use a separate dynamic-call cache. Recover syscall PCs directly
      // from the verified x64 backend's StoreContext(scratch, pc + 4) sequence.
      byte[] nativeCode = File.ReadAllBytes(Path.Combine(directory,"jit-code.bin"));
      int dynamicSites = 0, translatedSites = 0;
      var seen = new System.Collections.Generic.HashSet<uint>();
      using (var sites = new StreamWriter(Path.Combine(directory,"dynamic-sites.csv"))) {
        sites.WriteLine("guest_pc,host_store,physical_address,page_status,physical_bytes,user_bytes");
        for (int i=0; i+27<=nativeCode.Length; i++) {
          if (nativeCode[i]!=0xC7 || nativeCode[i+1]!=0x86 ||
              BitConverter.ToUInt32(nativeCode,i+2)!=0xA68 ||
              nativeCode[i+10]!=0x89 || nativeCode[i+11]!=0xBE ||
              BitConverter.ToUInt32(nativeCode,i+12)!=0xA6C ||
              nativeCode[i+16]!=0x48 || nativeCode[i+17]!=0xB9) continue;
          uint resume = BitConverter.ToUInt32(nativeCode,i+6);
          // Only the actual CLR-generated code range observed in this build.
          if (resume<0xBE000004 || resume>=0xC0000000 || (resume&3)!=0) continue;
          uint pc=resume-4; if (!seen.Add(pc)) continue;
          if (++dynamicSites>256) throw new InvalidOperationException("Zu viele dynamische Codepunkte fuer diesen Check.");
          uint physical; string status;
          byte[] mapped=ReadUserCode(process,pc,out physical,out status);
          byte[] shown=ReadBytes(process,0x400000000UL+pc,32);
          if (mapped!=null) translatedSites++;
          sites.WriteLine(pc.ToString("X8")+","+(0xA0000000UL+(uint)i).ToString("X8")+","+
            physical.ToString("X8")+","+status+","+Hex(mapped)+","+Hex(shown));
        }
      }
      if (dynamicSites==0 || translatedSites==0)
        throw new InvalidOperationException("Dynamische CLR-Codepunkte fehlen oder sind nicht lesbar; bitte Meldung weitergeben.");
      return functions+" JIT-Funktionen, "+readEntries+" statische Eintraege, "+translatedSites+"/"+dynamicSites+" dynamische CLR-Codepunkte";
    } finally { CloseHandle(process); }
  }

  static string Hex(byte[] bytes) { return bytes==null ? "" : BitConverter.ToString(bytes).Replace("-",""); }
  static byte[] ReadBytes(IntPtr process, ulong address, int count) {
    var bytes=new byte[count]; UIntPtr got;
    return ReadProcessMemory(process,new IntPtr((long)address),bytes,new UIntPtr((uint)count),out got)
      && got.ToUInt64()==(ulong)count ? bytes : null;
  }
  static ulong KernelHost(uint address) { return 0x200000000UL+address+(address>=0xE0000000 ? 0x1000UL : 0UL); }
  static uint Big32(byte[] b) { return (uint)b[0]<<24 | (uint)b[1]<<16 | (uint)b[2]<<8 | b[3]; }
  static byte[] ReadUserCode(IntPtr process,uint pc,out uint physical,out string status) {
    physical=0; status="no_descriptor";
    // Descriptor address is verified in the installed build's XXL startup log.
    const uint descriptor=0xFFCA5000;
    var kindBytes=ReadBytes(process,KernelHost(descriptor+0x840+(pc>>28)),1);
    if(kindBytes==null) return null;
    uint mask,entry;
    if((kindBytes[0]&1)!=0) {
      mask=0xFFFFFF;
      var b=ReadBytes(process,KernelHost(descriptor+0x400+(pc>>24)*4),4);
      if(b==null){status="no_large_entry";return null;} entry=Big32(b);
    } else {
      bool small=(kindBytes[0]&2)==0; mask=small ? 0xFFFU : 0xFFFFU;
      uint tableOffset=small ? (pc>>23)*2 : 0x800+(pc>>27)*2;
      var frame=ReadBytes(process,KernelHost(descriptor+tableOffset),2);
      if(frame==null){status="no_table_read";return null;}
      uint table=((uint)frame[0]<<8|frame[1])<<13;
      if(table==0 || table>=0x20000000){status="invalid_table";return null;}
      uint index=(pc>>(small ? 12 : 16))&0x7FF;
      var b=ReadBytes(process,0x300000000UL+table+index*4,4);
      if(b==null){status="no_entry_read";return null;} entry=Big32(b);
    }
    if(entry==0){status="no_entry";return null;}
    physical=(entry&~mask)+(pc&mask);
    ulong host;
    if(unchecked(physical-0x40000000)<0xA0000000U) host=KernelHost(unchecked(physical-0x40000000));
    else if(physical<0x20000000) host=0x300000000UL+physical;
    else {status="unusable_frame";return null;}
    // Every requested instruction site is word-aligned. Keep the read in its page.
    int count=(int)Math.Min(32U,(mask+1)-(pc&mask));
    var code=ReadBytes(process,host,count);status=code==null ? "unreadable_frame" : "mapped";return code;
  }
}

'@
    $phase = 'Laufendes Xenia-Log lesen'
    $logPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'xenia.log'
    # A running logger already holds a write handle. The new reader must
    # explicitly permit that handle; ReadAllText uses FileShare.Read only.
    $logStream = [IO.File]::Open($logPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $logReader = New-Object IO.StreamReader($logStream)
        try { $log = $logReader.ReadToEnd() } finally { $logReader.Dispose() }
    } finally { $logStream.Dispose() }
    if ($log -notmatch 'user mode page table at FFCA5000' -or $log -notmatch 'virtual membase 0x200000000') { throw 'Erwartete XXL-Speicherstruktur fehlt im aktuellen Log.' }
    $phase = 'JIT und Gastcode lesen'
    $result = [XxlJitReader]::Capture($targetId,$folder)
    $target.Refresh()
    if ($target.HasExited) { throw 'XXL wurde waehrend des Codechecks beendet. Bitte Aufnahme wiederholen.' }
    if ($target.StartTime.ToUniversalTime().ToString('o') -ne $startTime) { throw 'Prozess hat sich geaendert.' }
    $meta = [ordered]@{ process_id=$targetId; process_start_utc=$startTime; command=$candidates[0].CommandLine; result=$result; completed_utc=(Get-Date).ToUniversalTime().ToString('o') }
    $meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $folder 'metadata.json') -Encoding UTF8
    Write-Host 'Codecheck fertig. Daten auf der Freigabe gespeichert.' -ForegroundColor Green
    Write-Host $result
    Write-Host $folder
    [void](Read-Host 'Enter schliesst das Fenster')
} catch {
    $failure = $_
    Write-Host ('Codecheck fehlgeschlagen [' + $phase + ']: ' + $failure.Exception.Message) -ForegroundColor Red
    if ($folder) {
        try {
            @('Phase: ' + $phase, $failure.ToString(), $failure.ScriptStackTrace, $failure.Exception.ToString()) |
                Set-Content -LiteralPath (Join-Path $folder 'error.txt') -Encoding UTF8
        } catch { Write-Host 'Fehlerdatei konnte nicht gespeichert werden.' -ForegroundColor Yellow }
    }
    [void](Read-Host 'Enter schliesst das Fenster')
    exit 1
} finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
}
