// Build with the Windows .NET Framework C# compiler. No SketchUp DLLs are bundled.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

internal static class ModelSizeWorker {
    [StructLayout(LayoutKind.Sequential)] internal struct Ref { public IntPtr ptr; }
    private const string Api = "SketchUpAPI.dll";
    [DllImport("kernel32", CharSet=CharSet.Unicode)] static extern bool SetDllDirectory(string path);
    [DllImport("kernel32")] static extern uint SetErrorMode(uint mode);
    [DllImport("kernel32", SetLastError=true)] static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int type, ref JobLimits limits, uint length);
    [DllImport("kernel32", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int type, ref JobLimits limits, uint length, IntPtr returned);
    [DllImport("kernel32", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr handle);
    [StructLayout(LayoutKind.Sequential)] struct MemoryStatus {
        public uint Length, Load;
        public ulong TotalPhysical, AvailablePhysical, TotalPage, AvailablePage, TotalVirtual, AvailableVirtual, Extended;
    }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct JobLimits {
        public BasicLimits Basic;
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    private static IntPtr memoryJob;
    private static ulong MemoryBudget() {
        MemoryStatus memory = new MemoryStatus { Length = (uint)Marshal.SizeOf(typeof(MemoryStatus)) };
        if (!GlobalMemoryStatusEx(ref memory)) throw new System.ComponentModel.Win32Exception();
        if (memory.AvailablePhysical < 768UL * 1024 * 1024) throw new IOException("可用内存不足，请先释放内存再读取模型。");
        ulong budget = Math.Min(6UL * 1024 * 1024 * 1024, memory.AvailablePhysical / 2);
        memoryJob = CreateJobObject(IntPtr.Zero, null);
        if (memoryJob == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        JobLimits limits = new JobLimits();
        limits.Basic.Flags = 0x100; // JOB_OBJECT_LIMIT_PROCESS_MEMORY
        limits.ProcessMemory = (UIntPtr)budget;
        uint size = (uint)Marshal.SizeOf(typeof(JobLimits));
        if (!SetInformationJobObject(memoryJob, 9, ref limits, size) || !AssignProcessToJobObject(memoryJob, Process.GetCurrentProcess().Handle)) throw new System.ComponentModel.Win32Exception();
        JobLimits actual = new JobLimits();
        if (!QueryInformationJobObject(memoryJob, 9, ref actual, size, IntPtr.Zero) || actual.ProcessMemory.ToUInt64() != budget || (actual.Basic.Flags & 0x100) == 0) throw new IOException("后台内存保护未能启动。");
        return budget;
    }
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern void SUInitialize();
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern void SUTerminate();
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUModelCreateFromFile(ref Ref model, byte[] path);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUModelRelease(ref Ref model);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUModelGetEntities(Ref model, out Ref entities);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUModelGetEntitiesByPersistentIDs(Ref model, UIntPtr count, long[] ids, [Out] Ref[] entities);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern Ref SUComponentDefinitionFromEntity(Ref entity);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUComponentDefinitionGetEntities(Ref definition, out Ref entities);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUComponentDefinitionGetName(Ref definition, ref Ref name);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern Ref SUComponentDefinitionToEntity(Ref definition);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUComponentDefinitionSaveToFile(Ref definition, byte[] path, int version);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUEntitiesGetNumGroups(Ref entities, out UIntPtr count);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUEntitiesGetGroups(Ref entities, UIntPtr count, [Out] Ref[] groups, out UIntPtr actual);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUEntitiesGetNumInstances(Ref entities, out UIntPtr count);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUEntitiesGetInstances(Ref entities, UIntPtr count, [Out] Ref[] instances, out UIntPtr actual);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern Ref SUGroupToComponentInstance(Ref group);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUComponentInstanceGetDefinition(Ref instance, out Ref definition);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUComponentInstanceGetName(Ref instance, ref Ref name);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUComponentInstanceIsLocked(Ref instance, out byte locked);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern Ref SUComponentInstanceToEntity(Ref instance);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern Ref SUComponentInstanceToDrawingElement(Ref instance);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUDrawingElementGetHidden(Ref element, out byte hidden);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUEntityGetPersistentID(Ref entity, out long id);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUStringCreate(ref Ref value);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUStringRelease(ref Ref value);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUStringGetUTF8Length(Ref value, out UIntPtr length);
    [DllImport(Api, CallingConvention=CallingConvention.Cdecl)] static extern int SUStringGetUTF8(Ref value, UIntPtr length, [Out] byte[] buffer, out UIntPtr actual);

    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 1048576 };
    private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
    private static string session;
    private static Ref model;
    private static int parent;
    private static readonly Dictionary<string, Ref> Definitions = new Dictionary<string, Ref>();
    private static readonly Dictionary<string, List<Dictionary<string, object>>> Levels = new Dictionary<string, List<Dictionary<string, object>>>();
    private static readonly Dictionary<string, long> Sizes = new Dictionary<string, long>();
    private static byte[] PathBytes(string value) { return Encoding.UTF8.GetBytes(value + "\0"); }
    private static void Check(int result) { if (result != 0) throw new InvalidOperationException("SketchUp 文件接口返回错误 " + result); }
    private static string Id(Ref entity) { long id; Check(SUEntityGetPersistentID(entity, out id)); return id.ToString(CultureInfo.InvariantCulture); }
    private delegate int NameGetter(Ref entity, ref Ref name);
    private static string Name(Ref entity, NameGetter getter) {
        Ref str = new Ref(); Check(SUStringCreate(ref str));
        try {
            Check(getter(entity, ref str)); UIntPtr length; Check(SUStringGetUTF8Length(str, out length));
            int len = checked((int)length.ToUInt64());
            if (len > 65536) throw new InvalidOperationException("对象名称过长。");
            byte[] data = new byte[len + 1]; UIntPtr actual;
            Check(SUStringGetUTF8(str, (UIntPtr)data.Length, data, out actual));
            return Utf8.GetString(data, 0, len);
        } finally { SUStringRelease(ref str); }
    }
    private static Ref Definition(string id) {
        Ref value;
        if (Definitions.TryGetValue(id, out value)) return value;
        long pid;
        if (!long.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out pid) || pid <= 0) throw new InvalidOperationException("组件编号无效。");
        Ref[] found = new Ref[1]; Check(SUModelGetEntitiesByPersistentIDs(model, (UIntPtr)1, new long[] { pid }, found));
        value = SUComponentDefinitionFromEntity(found[0]);
        if (value.ptr == IntPtr.Zero) throw new InvalidOperationException("已保存文件中没有此组件，请保存并刷新。");
        Definitions[id] = value; return value;
    }
    private static Dictionary<string, object> Node(Ref instance, bool group) {
        Ref definition; Check(SUComponentInstanceGetDefinition(instance, out definition));
        string id = Id(SUComponentDefinitionToEntity(definition)); Definitions[id] = definition;
        byte hidden, locked;
        Check(SUDrawingElementGetHidden(SUComponentInstanceToDrawingElement(instance), out hidden));
        Check(SUComponentInstanceIsLocked(instance, out locked));
        return new Dictionary<string, object> {
            {"id", Id(SUComponentInstanceToEntity(instance))}, {"definition_id", id},
            {"name", Name(instance, SUComponentInstanceGetName)}, {"definition_name", Name(definition, SUComponentDefinitionGetName)},
            {"kind", group ? "群组" : "组件"}, {"hidden", hidden != 0}, {"locked", locked != 0}
        };
    }
    private static List<Dictionary<string, object>> Level(string id) {
        List<Dictionary<string, object>> result;
        if (Levels.TryGetValue(id, out result)) return result;
        Ref entities;
        if (id == "") Check(SUModelGetEntities(model, out entities));
        else Check(SUComponentDefinitionGetEntities(Definition(id), out entities));
        result = new List<Dictionary<string, object>>();
        UIntPtr count, actual;
        Check(SUEntitiesGetNumGroups(entities, out count));
        if (count.ToUInt64() > 0) {
            Ref[] groups = new Ref[checked((int)count.ToUInt64())];
            Check(SUEntitiesGetGroups(entities, count, groups, out actual));
            for (int i = 0; i < checked((int)actual.ToUInt64()); i++) result.Add(Node(SUGroupToComponentInstance(groups[i]), true));
        }
        Check(SUEntitiesGetNumInstances(entities, out count));
        if (count.ToUInt64() > 0) {
            Ref[] instances = new Ref[checked((int)count.ToUInt64())];
            Check(SUEntitiesGetInstances(entities, count, instances, out actual));
            for (int i = 0; i < checked((int)actual.ToUInt64()); i++) result.Add(Node(instances[i], false));
        }
        result.Sort(delegate(Dictionary<string, object> a, Dictionary<string, object> b) {
            return long.Parse((string)a["id"], CultureInfo.InvariantCulture).CompareTo(long.Parse((string)b["id"], CultureInfo.InvariantCulture));
        });
        Levels[id] = result; return result;
    }
    private static void Write(object value) {
        string temp = Path.Combine(session, "response.tmp"), target = Path.Combine(session, "response.json");
        File.WriteAllText(temp, Json.Serialize(value), Utf8);
        if (File.Exists(target)) throw new IOException("尚有未读取的后台结果。");
        File.Move(temp, target);
    }
    private static Dictionary<string, object> Run(Dictionary<string, object> command) {
        string operation = (string)command["operation"], id = (string)command["definition_id"];
        Dictionary<string, object> result = new Dictionary<string, object> { {"ok", true}, {"request_id", command["request_id"]}, {"operation", operation}, {"definition_id", id} };
        if (operation == "list") {
            int offset = Convert.ToInt32(command["offset"], CultureInfo.InvariantCulture);
            List<Dictionary<string, object>> nodes = Level(id);
            if (offset < 0 || offset > nodes.Count) throw new InvalidOperationException("目录页码已过期。");
            int take = Math.Min(100, nodes.Count - offset);
            result["nodes"] = nodes.GetRange(offset, take); result["total"] = nodes.Count;
            result["offset"] = offset; result["next"] = offset + take;
        } else if (operation == "measure") {
            long bytes;
            bool force = command.ContainsKey("force") && command["force"] is bool && (bool)command["force"];
            if (force || !Sizes.TryGetValue(id, out bytes)) {
                string file = Path.Combine(session, "measurement.skp");
                // SDK model_version.h aliases Current to SU2021 (14).
                try { Check(SUComponentDefinitionSaveToFile(Definition(id), PathBytes(file), 14)); bytes = new FileInfo(file).Length; }
                finally { if (File.Exists(file)) File.Delete(file); }
                Sizes[id] = bytes;
            }
            result["bytes"] = bytes;
        } else throw new InvalidOperationException("未知后台任务。");
        return result;
    }
    private static bool ParentAlive() {
        try { using (Process process = Process.GetProcessById(parent)) return !process.HasExited; }
        catch (ArgumentException) { return false; }
    }
    private static void Snapshot(string source) {
        FileInfo before = new FileInfo(source); long bytes = before.Length, ticks = before.LastWriteTimeUtc.Ticks;
        using (FileStream input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (FileStream output = new FileStream(Path.Combine(session, "snapshot.skp"), FileMode.CreateNew, FileAccess.Write, FileShare.None)) input.CopyTo(output);
        FileInfo after = new FileInfo(source);
        if (after.Length != bytes || after.LastWriteTimeUtc.Ticks != ticks) throw new IOException("文件正在保存，请保存完成后刷新。");
    }
    [STAThread] public static int Main(string[] args) {
        bool initialized = false;
        try {
            if (args.Length != 4) return 2;
            session = Path.GetFullPath(args[0]); string dll = Path.GetFullPath(args[1]), source = Path.GetFullPath(args[2]);
            parent = int.Parse(args[3], CultureInfo.InvariantCulture);
            SetErrorMode(0x0001 | 0x0002 | 0x8000);
            try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal; } catch (System.ComponentModel.Win32Exception) { }
            ulong budget = MemoryBudget();
            if (!File.Exists(dll) || Path.GetFileName(dll) != Api) throw new IOException("未找到 SketchUp 文件接口。");
            SetDllDirectory(Path.GetDirectoryName(dll));
            Snapshot(source);
            if (!ParentAlive()) return 0;
            SUInitialize(); initialized = true;
            Check(SUModelCreateFromFile(ref model, PathBytes(Path.Combine(session, "snapshot.skp"))));
            Write(new Dictionary<string, object> { {"ok", true}, {"ready", true}, {"source_bytes", new FileInfo(Path.Combine(session, "snapshot.skp")).Length}, {"memory_limit", budget} });
            string request = Path.Combine(session, "request.json");
            while (ParentAlive()) {
                if (!File.Exists(request)) { Thread.Sleep(40); continue; }
                if (new FileInfo(request).Length > 16384) throw new IOException("后台请求过大。");
                Dictionary<string, object> command = Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(request, Utf8));
                File.Delete(request);
                try { Write(Run(command)); }
                catch (Exception error) { Write(new Dictionary<string, object> { {"ok", false}, {"request_id", command["request_id"]}, {"error", error.Message} }); }
            }
            return 0;
        } catch (Exception error) {
            try { if (session != null) Write(new Dictionary<string, object> { {"ok", false}, {"error", error.Message} }); } catch (Exception) { }
            return 1;
        } finally {
            if (model.ptr != IntPtr.Zero) SUModelRelease(ref model);
            if (initialized) SUTerminate();
            if (memoryJob != IntPtr.Zero) CloseHandle(memoryJob);
        }
    }
}
