// Only process lifetime management. Telegram transport is the unchanged official TG WS Proxy.
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace ZapretTgWs {
    public sealed class Runner : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo {
            public uint Size;
            public string Reserved, Desktop, Title;
            public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
            public ushort ShowWindow, ReservedSize;
            public IntPtr ReservedData, StdInput, StdOutput, StdError;
        }
        [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes,string name);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimits limits,uint size);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string file,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inheritHandles,uint flags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInfo process);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
        [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle,uint timeout);
        [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
        [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process,uint code);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenJobObject(uint access,bool inherit,string name);
        [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool result);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process,uint flags,StringBuilder path,ref int length);
        [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr process,out long created,out long exited,out long kernel,out long user);
        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process,int kind,IntPtr buffer,int length,out int needed);
        [DllImport("shell32.dll",CharSet=CharSet.Unicode)] static extern IntPtr CommandLineToArgvW(string command,out int count);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
        [DllImport("iphlpapi.dll")] static extern uint GetExtendedTcpTable(IntPtr table,ref int size,bool order,uint family,uint kind,uint reserved);
        [StructLayout(LayoutKind.Sequential)] struct UnicodeString { public ushort Length, MaxLength; public IntPtr Buffer; }
        IntPtr _job, _process;
        public uint ProcessId { get; private set; }
        public string JobName { get; private set; }
        Runner() { }
        public static Runner Start(string executable,string directory,string appData) {
            Runner runner=new Runner();ProcessInfo process=new ProcessInfo();IntPtr environment=IntPtr.Zero;bool resumed=false;
            try {
                runner.JobName="Local\\zapret-tgws-"+Guid.NewGuid().ToString("N");
                runner._job=CreateJobObject(IntPtr.Zero,runner.JobName);
                if(runner._job==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                ExtendedLimits limits=new ExtendedLimits();limits.Basic.Flags=0x2000; // KILL_ON_JOB_CLOSE
                if(!SetInformationJobObject(runner._job,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimits)))) throw new Win32Exception(Marshal.GetLastWin32Error());
                SortedDictionary<string,string> values=new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
                foreach(DictionaryEntry entry in Environment.GetEnvironmentVariables()) values[(string)entry.Key]=(string)entry.Value;
                values["APPDATA"]=appData;
                StringBuilder block=new StringBuilder();foreach(KeyValuePair<string,string> pair in values) block.Append(pair.Key).Append('=').Append(pair.Value).Append('\0');block.Append('\0');
                environment=Marshal.StringToHGlobalUni(block.ToString());
                StartupInfo startup=new StartupInfo();startup.Size=(uint)Marshal.SizeOf(typeof(StartupInfo));
                // Suspended creation prevents the PyInstaller bootloader spawning an unowned child first.
                if(!CreateProcess(executable,new StringBuilder("\""+executable+"\""),IntPtr.Zero,IntPtr.Zero,false,0x08000404,environment,directory,ref startup,out process)) throw new Win32Exception(Marshal.GetLastWin32Error());
                runner._process=process.Process;runner.ProcessId=process.ProcessId;
                if(!AssignProcessToJobObject(runner._job,process.Process)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if(ResumeThread(process.Thread)==0xffffffff) throw new Win32Exception(Marshal.GetLastWin32Error());
                resumed=true;return runner;
            } catch {
                if(process.Process!=IntPtr.Zero && !resumed) TerminateProcess(process.Process,1);
                runner.Dispose();throw;
            } finally {
                if(process.Thread!=IntPtr.Zero) CloseHandle(process.Thread);
                if(environment!=IntPtr.Zero) Marshal.FreeHGlobal(environment);
            }
        }
        public int Wait() {
            if(_process==IntPtr.Zero) throw new ObjectDisposedException("Runner");
            if(WaitForSingleObject(_process,0xffffffff)!=0) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint code;if(!GetExitCodeProcess(_process,out code)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return unchecked((int)code);
        }
        public static bool OwnsListener(string jobName,int port) {
            if(string.IsNullOrEmpty(jobName) || !System.Text.RegularExpressions.Regex.IsMatch(jobName,@"\ALocal\\zapret-tgws-[a-f0-9]{32}\z") || port<1 || port>65535) return false;
            IntPtr job=OpenJobObject(4,false,jobName), table=IntPtr.Zero;
            if(job==IntPtr.Zero) return false;
            try {
                int size=0;GetExtendedTcpTable(IntPtr.Zero,ref size,false,2,3,0);
                if(size<4 || size>8*1024*1024) return false;
                table=Marshal.AllocHGlobal(size);
                if(GetExtendedTcpTable(table,ref size,false,2,3,0)!=0) return false;
                int count=Marshal.ReadInt32(table);
                if(count<0 || count>(size-4)/24) return false;
                for(int i=0;i<count;i++) {
                    int row=4+i*24;
                    // OWNER_PID_LISTENER already restricts the table to listening sockets.
                    if(Marshal.ReadInt32(table,row+4)!=0x0100007f) continue;
                    int boundPort=(Marshal.ReadByte(table,row+8)<<8)|Marshal.ReadByte(table,row+9);
                    if(boundPort!=port) continue;
                    IntPtr process=OpenProcess(0x1000,false,unchecked((uint)Marshal.ReadInt32(table,row+20)));
                    if(process==IntPtr.Zero) return false;
                    try {bool owned;return IsProcessInJob(process,job,out owned) && owned;}
                    finally {CloseHandle(process);}
                }
                return false;
            } finally {if(table!=IntPtr.Zero) Marshal.FreeHGlobal(table);CloseHandle(job);}
        }
        public static bool IsWrapper(uint pid,long ticks,string executable,string script) {return CheckWrapper(pid,ticks,executable,script,false);}
        public static bool StopWrapper(uint pid,long ticks,string executable,string script) {return CheckWrapper(pid,ticks,executable,script,true);}
        public static bool MatchesCommand(uint pid,long ticks,string executable,string expectedCommand) {
            IntPtr process=OpenProcess(0x1000,false,pid), memory=IntPtr.Zero, actualArgs=IntPtr.Zero, expectedArgs=IntPtr.Zero;
            if(process==IntPtr.Zero) return false;
            try {
                long created,exited,kernel,user;
                if(!GetProcessTimes(process,out created,out exited,out kernel,out user) || DateTime.FromFileTimeUtc(created).ToLocalTime().Ticks!=ticks) return false;
                StringBuilder image=new StringBuilder(32768);int capacity=image.Capacity;
                if(!QueryFullProcessImageName(process,0,image,ref capacity) || !string.Equals(image.ToString(),executable,StringComparison.OrdinalIgnoreCase)) return false;
                int needed;NtQueryInformationProcess(process,60,IntPtr.Zero,0,out needed);
                if(needed<Marshal.SizeOf(typeof(UnicodeString)) || needed>65536) return false;
                memory=Marshal.AllocHGlobal(needed);
                if(NtQueryInformationProcess(process,60,memory,needed,out needed)<0) return false;
                UnicodeString command=(UnicodeString)Marshal.PtrToStructure(memory,typeof(UnicodeString));
                if(command.Buffer==IntPtr.Zero || command.Length<2 || command.Length>65534) return false;
                int actualCount, expectedCount;
                actualArgs=CommandLineToArgvW(Marshal.PtrToStringUni(command.Buffer,command.Length/2),out actualCount);
                expectedArgs=CommandLineToArgvW(expectedCommand,out expectedCount);
                if(actualArgs==IntPtr.Zero || expectedArgs==IntPtr.Zero || actualCount!=expectedCount) return false;
                for(int i=0;i<actualCount;i++) {
                    string actual=Marshal.PtrToStringUni(Marshal.ReadIntPtr(actualArgs,i*IntPtr.Size));
                    string expected=Marshal.PtrToStringUni(Marshal.ReadIntPtr(expectedArgs,i*IntPtr.Size));
                    if(!string.Equals(actual,expected,i==0?StringComparison.OrdinalIgnoreCase:StringComparison.Ordinal)) return false;
                }
                return true;
            } catch {return false;}
            finally {if(actualArgs!=IntPtr.Zero) LocalFree(actualArgs);if(expectedArgs!=IntPtr.Zero) LocalFree(expectedArgs);if(memory!=IntPtr.Zero) Marshal.FreeHGlobal(memory);CloseHandle(process);}
        }
        public static string ExecutableFromCommand(string command) {
            IntPtr argv=IntPtr.Zero;
            try {int count;argv=CommandLineToArgvW(command,out count);return argv!=IntPtr.Zero && count>0?Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv)):null;}
            finally {if(argv!=IntPtr.Zero) LocalFree(argv);}
        }
        static bool CheckWrapper(uint pid,long ticks,string executable,string script,bool stop) {
            IntPtr process=OpenProcess(0x1000u|(stop?1u:0u),false,pid), memory=IntPtr.Zero, argv=IntPtr.Zero;
            if(process==IntPtr.Zero) return false;
            try {
                long created,exited,kernel,user;
                if(!GetProcessTimes(process,out created,out exited,out kernel,out user) || DateTime.FromFileTimeUtc(created).ToLocalTime().Ticks!=ticks) return false;
                StringBuilder image=new StringBuilder(32768);int capacity=image.Capacity;
                if(!QueryFullProcessImageName(process,0,image,ref capacity) || !string.Equals(image.ToString(),executable,StringComparison.OrdinalIgnoreCase)) return false;
                int needed;NtQueryInformationProcess(process,60,IntPtr.Zero,0,out needed);
                if(needed<Marshal.SizeOf(typeof(UnicodeString)) || needed>65536) return false;
                memory=Marshal.AllocHGlobal(needed);
                if(NtQueryInformationProcess(process,60,memory,needed,out needed)<0) return false;
                UnicodeString command=(UnicodeString)Marshal.PtrToStructure(memory,typeof(UnicodeString));
                if(command.Buffer==IntPtr.Zero || command.Length<2 || command.Length>65534) return false;
                string text=Marshal.PtrToStringUni(command.Buffer,command.Length/2);int count;
                argv=CommandLineToArgvW(text,out count);
                if(argv==IntPtr.Zero || count!=7) return false;
                string[] expected={null,"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",script};
                for(int i=1;i<count;i++) if(!string.Equals(Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv,i*IntPtr.Size)),expected[i],StringComparison.OrdinalIgnoreCase)) return false;
                // Termination uses the same handle whose creation time/image/command were verified.
                return !stop || TerminateProcess(process,1);
            } catch {return false;}
            finally {if(argv!=IntPtr.Zero) LocalFree(argv);if(memory!=IntPtr.Zero) Marshal.FreeHGlobal(memory);CloseHandle(process);}
        }
        public void Dispose() {
            if(_job!=IntPtr.Zero) {CloseHandle(_job);_job=IntPtr.Zero;}
            if(_process!=IntPtr.Zero) {CloseHandle(_process);_process=IntPtr.Zero;}
        }
    }
}
