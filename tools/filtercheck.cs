// C# 5 / .NET Framework. Validation only: never calls WinDivertOpen.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace ZapretFilter {
    public sealed class Result {
        public readonly bool Ok;
        public readonly string Error;
        public readonly uint Position;
        public Result(bool ok, string error, uint position) { Ok=ok; Error=error; Position=position; }
    }
    public static class Compiler {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
        private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
        [DllImport("kernel32.dll", CharSet=CharSet.Ansi, ExactSpelling=true, SetLastError=true)]
        private static extern IntPtr GetProcAddress(IntPtr module, string name);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool FreeLibrary(IntPtr module);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private delegate bool Compile(IntPtr filter, int layer, IntPtr compiled, uint length, out IntPtr error, out uint position);

        public static Result Check(string dllPath, string filter) {
            if (String.IsNullOrWhiteSpace(filter)) return new Result(false, "empty filter", 0);
            int nul=filter.IndexOf('\0');
            if (nul>=0) return new Result(false, "embedded NUL in filter", (uint)nul);
            if (filter.Length>1048576) return new Result(false, "filter exceeds byte limit", 0);
            return CheckBytes(dllPath,new UTF8Encoding(false,true).GetBytes(filter));
        }

        public static Result CheckBytes(string dllPath, byte[] bytes) {
            if (bytes==null || bytes.Length==0) return new Result(false, "empty filter", 0);
            if (bytes.Length>1048576) return new Result(false, "filter exceeds byte limit", 0);
            int nul=Array.IndexOf(bytes,(byte)0);
            if (nul>=0) return new Result(false, "embedded NUL in filter", (uint)nul);
            IntPtr module=LoadLibraryExW(Path.GetFullPath(dllPath),IntPtr.Zero,0x00000100|0x00000800);
            if (module==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"WinDivert DLL load failed");
            IntPtr buffer=IntPtr.Zero;
            try {
                IntPtr address=GetProcAddress(module,"WinDivertHelperCompileFilter");
                if (address==IntPtr.Zero) throw new MissingMethodException("WinDivertHelperCompileFilter is unavailable");
                var compile=(Compile)Marshal.GetDelegateForFunctionPointer(address,typeof(Compile));
                buffer=Marshal.AllocHGlobal(bytes.Length+1);
                Marshal.Copy(bytes,0,buffer,bytes.Length);
                Marshal.WriteByte(buffer,bytes.Length,0);
                IntPtr error; uint position;
                bool ok=compile(buffer,0,IntPtr.Zero,0,out error,out position);
                // Copy native error text before unloading its owning module.
                string text=ok ? "" : (error==IntPtr.Zero ? "filter rejected" : Marshal.PtrToStringAnsi(error));
                return new Result(ok,text,position);
            } finally {
                if (buffer!=IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                FreeLibrary(module);
            }
        }
    }
}
