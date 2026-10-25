using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Jc2ThreadReader {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int id);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenThread(uint access, bool inherit, uint id);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint SuspendThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetThreadContext(IntPtr thread, IntPtr context);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, UIntPtr size, out UIntPtr read);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll")] static extern int GetThreadDescription(IntPtr thread, out IntPtr text);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
  public static string ThreadName(uint id) {
    IntPtr handle=OpenThread(0x0800,false,id);
    if(handle==IntPtr.Zero) return "";
    IntPtr text=IntPtr.Zero;
    try {
      if(GetThreadDescription(handle,out text)<0 || text==IntPtr.Zero) return "";
      return Marshal.PtrToStringUni(text) ?? "";
    } catch(EntryPointNotFoundException) { return ""; }
    finally { if(text!=IntPtr.Zero) LocalFree(text); CloseHandle(handle); }
  }
  public class Sample {
    public uint HostThread, GuestThread;
    public int StackBytes;
    public string NativePC, Context;
    public uint LR, CTR;
    public ulong[] Registers;
  }
  static byte[] Read(IntPtr process, ulong address, int count) {
    var bytes = new byte[count]; UIntPtr got;
    return ReadProcessMemory(process, new IntPtr((long)address), bytes,
      new UIntPtr((uint)count), out got) && got.ToUInt64() == (ulong)count ? bytes : null;
  }
  static ulong U64(byte[] b, int at) { return BitConverter.ToUInt64(b, at); }
  public static uint BE32(byte[] b, int at) {
    return (uint)b[at]<<24 | (uint)b[at+1]<<16 | (uint)b[at+2]<<8 | b[at+3];
  }
  public static bool ValidLiveReadCode(byte[] tu0, byte[] tu1) {
    bool baseGame=tu0!=null && tu0.Length==8 && BE32(tu0,0)==0x8163000CU && BE32(tu0,4)==0x2B0B0000U;
    bool updatedGame=tu1!=null && tu1.Length==20 && BE32(tu1,0)==0x3D408352U &&
      BE32(tu1,4)==0x817F0008U && BE32(tu1,8)==0x3FC08326U &&
      BE32(tu1,12)==0x812AB20CU && BE32(tu1,16)==0x7F095840U;
    return baseGame || updatedGame;
  }
  public static bool ValidContext(byte[] b, bool updatedGame=false) {
    if (b == null || b.Length < 0xAA8 || U64(b,0xA90) != 0x100000000UL) return false;
    uint sp=(uint)U64(b,0x30), lr=(uint)U64(b,0x130);
    return sp>=0x40000000 && sp<0x80000000 && (sp&15)==0 && lr>=0x82000000 && lr<(updatedGame ? 0x84000000U : 0x83000000U);
  }
  static byte[] GuestRead(IntPtr process, uint address, int count) {
    return Read(process,0x100000000UL+address+(address>=0xE0000000U ? 0x1000UL : 0),count);
  }
  public static bool ValidLiveRange(uint address, int count) {
    if(count<=0 || count>65536) return false;
    ulong end=(ulong)address+(uint)count;
    return (address>=0x40000000U && end<=0x80000000UL) ||
      (address>=0x82000000U && end<=0x84000000UL) ||
      (address>=0xA0000000U && end<=0xE0000000UL);
  }
  static byte[] ReadGuestSlice(IntPtr process, uint address, int count, bool allowGpu=false) {
    bool useful=(address>=0x40000000 && address<0x80000000) || (address>=0x82000000 && address<0x84000000);
    // Only the signature-checked live reader may inspect GPU physical-memory
    // aliases. Thread-context pointer following retains its original bounds.
    if(allowGpu && ValidLiveRange(address,count)) useful=true;
    if (!useful || count<=0 || (ulong)address+(uint)count>0x100000000UL) return null;
    var bytes=GuestRead(process,address,count);
    // Guest stacks can end at the next page boundary. Preserve their readable
    // prefix instead of dropping the entire stack when its guard page follows.
    if (bytes==null) bytes=GuestRead(process,address,Math.Min(count,4096-(int)(address&4095)));
    return bytes;
  }
  static void WriteGuest(string directory, uint address, byte[] bytes) {
    if(bytes!=null) File.WriteAllBytes(Path.Combine(directory,"guest-"+address.ToString("X8")+"-"+bytes.Length+".bin"),bytes);
  }
  static int DumpGuest(IntPtr process, string directory, uint address, int count, bool allowGpu=false) {
    var bytes=ReadGuestSlice(process,address,count,allowGpu);
    WriteGuest(directory,address,bytes);
    return bytes==null ? 0 : bytes.Length;
  }
  static Dictionary<uint,byte[]> ReadGameState(IntPtr process) {
    var result=new Dictionary<uint,byte[]>();
    var globals=ReadGuestSlice(process,0x82F20000,0x3000);
    result[0x82F20000]=globals;
    result[0x82EE8000]=ReadGuestSlice(process,0x82EE8000,0x3000);
    if(globals==null || globals.Length<0x3000) return result;
    // Managers referenced by the main-loop transition and loading checks.
    for(int offset=0x280;offset<=0x2C0;offset+=4) {
      uint address=BE32(globals,offset);
      if(address<0x40000000 || address>=0x80000000) continue;
      result[address]=ReadGuestSlice(process,address,0x4000);
    }
    uint world=BE32(globals,0x2A4);
    byte[] worldBytes;
    if(result.TryGetValue(world,out worldBytes) && worldBytes!=null && worldBytes.Length>=0x3598) {
      uint actor=BE32(worldBytes,0x3590);
      result[actor]=ReadGuestSlice(process,actor,0x2000);
    }
    return result;
  }
  public static void ReadRanges(int id, uint[] addresses, int[] counts, string directory) {
    if(addresses==null || counts==null || addresses.Length!=counts.Length || addresses.Length>128)
      throw new ArgumentException("Ungueltige Anzahl Speicherbereiche.");
    long total=0;
    for(int i=0;i<counts.Length;i++) {
      if(counts[i]<=0 || counts[i]>65536) throw new ArgumentException("Bereich muss 1 bis 65536 Bytes umfassen.");
      if(!ValidLiveRange(addresses[i],counts[i])) throw new ArgumentException("Bereich liegt ausserhalb des erlaubten JC2-Gastspeichers.");
      total+=counts[i];
    }
    if(total>4194304) throw new ArgumentException("Aufnahme groesser als 4 MiB.");
    IntPtr process=OpenProcess(0x410,false,id);
    if(process==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    try {
      // These signatures are outside the FPS patch locations.
      var baseCode=GuestRead(process,0x826E8BE8,8);
      var updatedCode=GuestRead(process,0x82BE5274,20);
      if(!ValidLiveReadCode(baseCode,updatedCode))
        throw new InvalidOperationException("JC2-Code und Speicherbasis stimmen nicht ueberein.");
      for(int i=0;i<addresses.Length;i++) DumpGuest(process,directory,addresses[i],counts[i],true);
    } finally { CloseHandle(process); }
  }
  public static Sample[] Capture(int id, uint[] threadIds, string directory) {
    if (IntPtr.Size!=8) throw new InvalidOperationException("64-bit PowerShell erforderlich.");
    if(threadIds==null || threadIds.Length!=6 || new HashSet<uint>(threadIds).Count!=6)
      throw new ArgumentException("Genau sechs unterschiedliche Gast-CPU-Threads erforderlich.");
    IntPtr process=OpenProcess(0x410,false,id);
    if (process==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    var samples=new List<Sample>(); var handles=new Dictionary<uint,IntPtr>();
    IntPtr raw=Marshal.AllocHGlobal(1232+15);
    IntPtr native=new IntPtr((raw.ToInt64()+15)&~15L);
    var seen=new HashSet<string>();
    Dictionary<uint,byte[]> gameState=null;
    try {
      var check=GuestRead(process,0x826E8BE8,8);
      var updatedCode=GuestRead(process,0x82BE5274,20);
      bool updatedGame=ValidLiveReadCode(null,updatedCode);
      if (!ValidLiveReadCode(check,updatedCode))
        throw new InvalidOperationException("JC2-Code und erwartete Speicherbasis stimmen nicht ueberein.");
      foreach(uint tid in threadIds) {
        IntPtr h=OpenThread(0x0A,false,tid); // suspend/resume + get-context only
        if (h==IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        handles.Add(tid,h);
      }
      for(int round=0;round<100;round++) {
        foreach(var pair in handles) {
          byte[] context=null, stack=null; ulong pointer=0, pc=0;
          Marshal.WriteInt32(native,48,0x100003); // AMD64 control + integer registers
          uint old=SuspendThread(pair.Value);
          if(old==UInt32.MaxValue) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
          try {
            if(GetThreadContext(pair.Value,native)) {
              pointer=(ulong)Marshal.ReadInt64(native,168); // RSI is PPCContext in Edge's JIT
              pc=(ulong)Marshal.ReadInt64(native,248);
              if(pointer!=0) context=Read(process,pointer,0xAA8);
              if(ValidContext(context,updatedGame)) {
                uint pausedSP=(uint)U64(context,0x30);
                stack=ReadGuestSlice(process,pausedSP,4096);
                if(!updatedGame && gameState==null && BitConverter.ToUInt32(context,0xA58)==6)
                  gameState=ReadGameState(process);
              }
            }
          } finally {
            if(ResumeThread(pair.Value)==UInt32.MaxValue)
              throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
          }
          if(!ValidContext(context,updatedGame)) continue;
          uint lr=(uint)U64(context,0x130), sp=(uint)U64(context,0x30);
          string key=pointer.ToString("X")+":"+lr.ToString("X")+":"+sp.ToString("X");
          if(!seen.Add(key)) continue;
          var registers=new ulong[32];
          for(int r=0;r<32;r++) registers[r]=U64(context,0x28+r*8);
          samples.Add(new Sample { HostThread=pair.Key, GuestThread=BitConverter.ToUInt32(context,0xA58),
            NativePC=pc.ToString("X"),Context=pointer.ToString("X"),LR=lr,CTR=(uint)U64(context,0x128),Registers=registers });
          // File I/O happens only after the host thread has been resumed.
          string sampleDir=Path.Combine(directory,"sample-"+samples.Count);
          Directory.CreateDirectory(sampleDir);
          File.WriteAllBytes(Path.Combine(sampleDir,"context.bin"),context);
          WriteGuest(sampleDir,sp,stack);
          samples[samples.Count-1].StackBytes=stack==null ? 0 : stack.Length;
          for(int r=3;r<32;r++) {
            uint address=(uint)registers[r];
            if(address!=sp) DumpGuest(process,sampleDir,address,1024);
          }
        }
        System.Threading.Thread.Sleep(5);
      }
      if(gameState!=null) {
        string stateDir=Path.Combine(directory,"game-state");
        Directory.CreateDirectory(stateDir);
        foreach(var entry in gameState) WriteGuest(stateDir,entry.Key,entry.Value);
      }
      // TU0 manager layouts are not applicable to the updated executable.
      if(!updatedGame) {
        DumpGuest(process,directory,0x82EEA5B8,256);
        DumpGuest(process,directory,0x82F20200,512);
        var root=GuestRead(process,0x82F2029C,4);
        if(root!=null) {
          uint manager=BE32(root,0); DumpGuest(process,directory,manager,256);
          var link=GuestRead(process,manager+12,4);
          if(link!=null) DumpGuest(process,directory,BE32(link,0),2048);
        }
      }
      if(samples.Count==0) throw new InvalidOperationException("Kein passender Gastkontext erfasst; keine Threadzuordnung verfuegbar.");
      if(!samples.Exists(s => s.GuestThread==6 && s.StackBytes>0))
        throw new InvalidOperationException("Hauptthread-Stack fehlt in der Aufnahme.");
      return samples.ToArray();
    } finally {
      foreach(var h in handles.Values) CloseHandle(h);
      Marshal.FreeHGlobal(raw); CloseHandle(process);
    }
  }
}
