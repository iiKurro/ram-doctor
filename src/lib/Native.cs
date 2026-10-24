using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace RamDoc
{
    public class PoolTagRow
    {
        public string Tag;
        public bool Printable;
        public uint PagedAllocs;
        public uint PagedFrees;
        public ulong PagedUsed;
        public uint NonPagedAllocs;
        public uint NonPagedFrees;
        public ulong NonPagedUsed;
    }

    // Read-only helpers. Nothing here writes to the system.
    public static class Native
    {
        [DllImport("ntdll.dll")]
        static extern int NtQuerySystemInformation(int infoClass, IntPtr buffer, int length, out int returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetExitCodeProcess(IntPtr handle, out uint code);

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);

        // NTSTATUS of the last pool-tag query (0 = success, 0xC0000022 = access denied).
        public static int LastPoolStatus;

        // SystemPoolTagInformation (class 22) - the same data PoolMon shows. Needs admin.
        public static List<PoolTagRow> GetPoolTags()
        {
            List<PoolTagRow> rows = new List<PoolTagRow>();
            int size = 1 << 20;
            for (int attempt = 0; attempt < 10; attempt++)
            {
                IntPtr buf = Marshal.AllocHGlobal(size);
                try
                {
                    int ret;
                    int st = NtQuerySystemInformation(22, buf, size, out ret);
                    LastPoolStatus = st;
                    if (st == unchecked((int)0xC0000004))
                    {
                        size = Math.Max(size * 2, ret + (1 << 16));
                        continue;
                    }
                    if (st != 0) return rows;

                    bool x64 = IntPtr.Size == 8;
                    int count = Marshal.ReadInt32(buf);
                    int baseOff = x64 ? 8 : 4;
                    int entry = x64 ? 40 : 28;
                    for (int i = 0; i < count; i++)
                    {
                        int o = baseOff + i * entry;
                        PoolTagRow r = new PoolTagRow();
                        char[] chars = new char[4];
                        bool printable = true;
                        for (int k = 0; k < 4; k++)
                        {
                            byte b = Marshal.ReadByte(buf, o + k);
                            if (b < 0x20 || b > 0x7E) { printable = false; chars[k] = '.'; }
                            else chars[k] = (char)b;
                        }
                        r.Tag = new string(chars);
                        r.Printable = printable;
                        r.PagedAllocs = (uint)Marshal.ReadInt32(buf, o + 4);
                        r.PagedFrees = (uint)Marshal.ReadInt32(buf, o + 8);
                        if (x64)
                        {
                            r.PagedUsed = (ulong)Marshal.ReadInt64(buf, o + 16);
                            r.NonPagedAllocs = (uint)Marshal.ReadInt32(buf, o + 24);
                            r.NonPagedFrees = (uint)Marshal.ReadInt32(buf, o + 28);
                            r.NonPagedUsed = (ulong)Marshal.ReadInt64(buf, o + 32);
                        }
                        else
                        {
                            r.PagedUsed = (uint)Marshal.ReadInt32(buf, o + 12);
                            r.NonPagedAllocs = (uint)Marshal.ReadInt32(buf, o + 16);
                            r.NonPagedFrees = (uint)Marshal.ReadInt32(buf, o + 20);
                            r.NonPagedUsed = (uint)Marshal.ReadInt32(buf, o + 24);
                        }
                        rows.Add(r);
                    }
                    return rows;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            return rows;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct UnicodeString { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }

        [StructLayout(LayoutKind.Sequential)]
        struct ProcessIdInfo { public IntPtr ProcessId; public UnicodeString ImageName; }

        [DllImport("ntdll.dll", EntryPoint = "NtQuerySystemInformation")]
        static extern int NtQueryProcessId(int infoClass, ref ProcessIdInfo info, int length, out int returnLength);

        // Image path of a PID straight from the kernel, no process handle needed (works for
        // terminated-but-still-referenced "zombie" processes too). Returns "" if unknown.
        public static string GetImageName(uint pid)
        {
            IntPtr mem = Marshal.AllocHGlobal(1024);
            try
            {
                ProcessIdInfo info = new ProcessIdInfo();
                info.ProcessId = (IntPtr)pid;
                info.ImageName.Length = 0;
                info.ImageName.MaximumLength = 1024;
                info.ImageName.Buffer = mem;
                int ret;
                int st = NtQueryProcessId(88, ref info, Marshal.SizeOf(typeof(ProcessIdInfo)), out ret);
                if (st != 0 || info.ImageName.Length == 0) return "";
                return Marshal.PtrToStringUni(info.ImageName.Buffer, info.ImageName.Length / 2);
            }
            catch { return ""; }
            finally { Marshal.FreeHGlobal(mem); }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern uint QueryDosDevice(string deviceName, System.Text.StringBuilder target, int max);

        // \Device\HarddiskVolume3\Windows\x.exe  ->  C:\Windows\x.exe  (unchanged if no drive matches)
        public static string NtToDosPath(string nt)
        {
            if (string.IsNullOrEmpty(nt) || !nt.StartsWith("\\Device\\", StringComparison.OrdinalIgnoreCase)) return nt;
            for (char c = 'A'; c <= 'Z'; c++)
            {
                System.Text.StringBuilder sb = new System.Text.StringBuilder(1024);
                if (QueryDosDevice(c.ToString() + ":", sb, 1024) == 0) continue;
                string dev = sb.ToString();
                int z = dev.IndexOf('\0');
                if (z >= 0) dev = dev.Substring(0, z);
                if (dev.Length > 0 && nt.StartsWith(dev + "\\", StringComparison.OrdinalIgnoreCase))
                    return c.ToString() + ":" + nt.Substring(dev.Length);
            }
            return nt;
        }

        // Walks every PID (they are multiples of 4) and asks the kernel directly whether a process
        // exists. Result codes:  A = opened fine and still running (live)
        //                        D = access denied (protected process, OR a terminated "zombie"
        //                            that the kernel keeps alive because someone holds a handle)
        // A live process that is missing from the normal process lists is the rootkit signal.
        public static List<string> ProbePids(uint maxPid)
        {
            List<string> found = new List<string>();
            for (uint pid = 4; pid <= maxPid; pid += 4)
            {
                IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
                if (h == IntPtr.Zero)
                {
                    if (Marshal.GetLastWin32Error() == 5) found.Add(pid.ToString() + ":D");
                    continue;
                }
                uint code;
                if (GetExitCodeProcess(h, out code) && code == 259) found.Add(pid.ToString() + ":A"); // STILL_ACTIVE
                CloseHandle(h);
            }
            return found;
        }

        // For each 4-char pool tag, lists which of the given driver files contain that tag as raw
        // bytes. This is how people map a leaking pool tag to the driver that owns it (heuristic).
        public static Dictionary<string, List<string>> FindTagsInFiles(string[] files, string[] tags)
        {
            Dictionary<string, List<string>> result = new Dictionary<string, List<string>>();
            Dictionary<byte, List<string>> byFirst = new Dictionary<byte, List<string>>();
            bool[] first = new bool[256];
            foreach (string t in tags)
            {
                if (t == null || t.Length != 4) continue;
                result[t] = new List<string>();
                byte f = (byte)t[0];
                if (!byFirst.ContainsKey(f)) byFirst[f] = new List<string>();
                byFirst[f].Add(t);
                first[f] = true;
            }
            foreach (string file in files)
            {
                byte[] data;
                try
                {
                    FileInfo fi = new FileInfo(file);
                    if (!fi.Exists || fi.Length > 80L * 1024 * 1024) continue;
                    data = File.ReadAllBytes(file);
                }
                catch { continue; }

                HashSet<string> hit = new HashSet<string>();
                int end = data.Length - 3;
                for (int i = 0; i < end; i++)
                {
                    byte b = data[i];
                    if (!first[b]) continue;
                    foreach (string t in byFirst[b])
                    {
                        if (data[i + 1] == (byte)t[1] && data[i + 2] == (byte)t[2] && data[i + 3] == (byte)t[3])
                            hit.Add(t);
                    }
                }
                foreach (string t in hit) result[t].Add(file);
            }
            return result;
        }
    }
}
