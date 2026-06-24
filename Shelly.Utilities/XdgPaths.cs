using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Shelly.Utilities;

public static partial class XdgPaths
{
    public static string ConfigHome() => Resolve("XDG_CONFIG_HOME", ".config");
    public static string CacheHome() => Resolve("XDG_CACHE_HOME", ".cache");
    public static string DataHome() => Resolve("XDG_DATA_HOME", Path.Combine(".local", "share"));
    public static string StateHome() => Resolve("XDG_STATE_HOME", Path.Combine(".local", "state"));
    public static string BinHome() => Resolve("XDG_BIN_HOME", Path.Combine(".local", "bin"));

    public static string ShellyCache(params string[] parts) => Path.Combine([CacheHome(), "Shelly", .. parts]);

    public static string ShellyData(params string[] parts) => Path.Combine([DataHome(), "Shelly", .. parts]);

    public static string ShellyConfig(params string[] parts) => Path.Combine([ConfigHome(), "shelly", .. parts]);

    public static void EnsureDirectory(string path)
    {
        if (string.IsNullOrEmpty(path)) return;
        Directory.CreateDirectory(path);
        FixOwnershipIfRoot(path);
    }

    public static void FixOwnershipIfRoot(string path)
    {
        if (string.IsNullOrEmpty(path) || !IsRoot()) return;

        var user = GetInvokingUserName();
        if (string.IsNullOrEmpty(user) || user == "root") return;

        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = "chown",
                UseShellExecute = false,
                CreateNoWindow = true
            };
            process.StartInfo.ArgumentList.Add("-R");
            process.StartInfo.ArgumentList.Add($"{user}:");
            process.StartInfo.ArgumentList.Add(path);
            process.Start();
            process.WaitForExit(5000);
        }
        catch
        {
            // best-effort
        }
    }

    public static string InvokingUserHome()
    {
        var invokingUser = GetInvokingUserName();
        if (!string.IsNullOrEmpty(invokingUser) && invokingUser != "root")
        {
            var home = GetHomeFromPasswd(invokingUser);
            if (!string.IsNullOrEmpty(home))
                return home;
        }

        var envHome = Environment.GetEnvironmentVariable("HOME");
        return !string.IsNullOrEmpty(envHome)
            ? envHome
            : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    }

    private static string Resolve(string envVar, string fallbackRel)
    {
        var v = Environment.GetEnvironmentVariable(envVar);
        if (!string.IsNullOrEmpty(v) && Path.IsPathRooted(v))
            return v;

        return Path.Combine(InvokingUserHome(), fallbackRel);
    }

    private static string? GetInvokingUserName()
    {
        var sudoUser = Environment.GetEnvironmentVariable("SUDO_USER");
        if (!string.IsNullOrEmpty(sudoUser) && sudoUser != "root") return sudoUser;

        var pkexecUid = Environment.GetEnvironmentVariable("PKEXEC_UID");
        return string.IsNullOrWhiteSpace(pkexecUid) ? null : GetUserNameByUid(pkexecUid);
    }

    private static string? GetUserNameByUid(string uid)
    {
        try
        {
            foreach (var line in File.ReadLines("/etc/passwd"))
            {
                var parts = line.Split(':');
                if (parts.Length >= 3 && parts[2] == uid) return parts[0];
            }
        }
        catch
        {
            // best-effort
        }

        return null;
    }

    [LibraryImport("libc")]
    private static partial uint getuid();

    private static bool IsRoot() => getuid() == 0;

    [DllImport("libc", EntryPoint = "getpwnam_r", SetLastError = true)]
    private static extern unsafe int getpwnam_r(
        byte* name,
        Passwd* pwd,
        byte* buf,
        nuint buflen,
        Passwd** result);

    private static unsafe string? GetHomeFromPasswd(string user)
    {
        try
        {
            var nameBytes = Encoding.UTF8.GetByteCount(user) + 1;
            Span<byte> nameBuf = stackalloc byte[nameBytes];
            Encoding.UTF8.GetBytes(user, nameBuf);
            nameBuf[nameBytes - 1] = 0;

            const int bufSize = 4096;
            var buf = Marshal.AllocHGlobal(bufSize);
            try
            {
                Passwd pwd;
                Passwd* result;
                fixed (byte* namePtr = nameBuf)
                {
                    var rc = getpwnam_r(namePtr, &pwd, (byte*)buf, bufSize, &result);
                    if (rc != 0 || result == null)
                        return GetHomeFromPasswdFile(user);

                    return pwd.pw_dir == null ? null : Marshal.PtrToStringUTF8((IntPtr)pwd.pw_dir);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buf);
            }
        }
        catch
        {
            return GetHomeFromPasswdFile(user);
        }
    }

    private static string? GetHomeFromPasswdFile(string user)
    {
        try
        {
            foreach (var line in File.ReadLines("/etc/passwd"))
            {
                var parts = line.Split(':');
                if (parts.Length >= 6 && parts[0] == user)
                    return parts[5];
            }
        }
        catch
        {
            // best-effort
        }

        return null;
    }

    [StructLayout(LayoutKind.Sequential)]
    private unsafe struct Passwd
    {
        public byte* pw_name;
        public byte* pw_passwd;
        public uint pw_uid;
        public uint pw_gid;
        public byte* pw_gecos;
        public byte* pw_dir;
        public byte* pw_shell;
    }
}