using System;
using System.IO;
using System.Runtime.InteropServices;

// Read-only guest-memory access for the exact Homecoming executable.
public static class HomecomingReader {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer,
                                        UIntPtr size, out UIntPtr read);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    static byte[] Read(IntPtr process, uint address, int count) {
        var bytes = new byte[count];
        UIntPtr read;
        ulong host = 0x100000000UL + address;
        if (!ReadProcessMemory(process, new IntPtr((long)host), bytes,
                               new UIntPtr((uint)count), out read) || read.ToUInt64() != (ulong)count)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return bytes;
    }

    public static uint BE32(byte[] bytes, int offset) {
        return (uint)bytes[offset] << 24 | (uint)bytes[offset + 1] << 16 |
               (uint)bytes[offset + 2] << 8 | bytes[offset + 3];
    }

    public static void ReadRanges(int id, uint[] addresses, int[] counts, string directory) {
        if (IntPtr.Size != 8) throw new InvalidOperationException("64-bit PowerShell erforderlich.");
        if (addresses == null || counts == null || addresses.Length != counts.Length || addresses.Length > 128)
            throw new ArgumentException("Ungueltige Speicherbereichsliste.");
        long total = 0;
        for (int i = 0; i < counts.Length; i++) {
            if (counts[i] < 1 || counts[i] > 65536 || addresses[i] < 0x10000U ||
                (ulong)addresses[i] + (uint)counts[i] > 0xE0000000UL)
                throw new ArgumentException("Bereich ausserhalb des erlaubten Gastspeichers.");
            total += counts[i];
        }
        if (total > 4194304) throw new ArgumentException("Aufnahme groesser als 4 MiB.");
        IntPtr process = OpenProcess(0x410, false, id);
        if (process == IntPtr.Zero)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try {
            if (BE32(Read(process, 0x8219325C, 4), 0) != 0x810900E4U)
                throw new InvalidOperationException("Homecoming-Code oder Speicherbasis stimmen nicht ueberein.");
            for (int i = 0; i < addresses.Length; i++) {
                var bytes = Read(process, addresses[i], counts[i]);
                File.WriteAllBytes(Path.Combine(directory, "guest-" + addresses[i].ToString("X8") + "-" + counts[i] + ".bin"), bytes);
            }
        } finally { CloseHandle(process); }
    }
}
