using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Shelly.Utilities;

public static class XdgPaths
{
    public static string ConfigHome() => Resolve("XDG_CONFIG_HOME", ".config");
    public static string CacheHome() => Resolve("XDG_CACHE_HOME", ".cache");
    public static string DataHome() => Resolve("XDG_DATA_HOME", Path.Combine(".local", "share"));
    public static string StateHome() => Resolve("XDG_STATE_HOME", Path.Combine(".local", "state"));

    public static string ShellyCache(params string[] parts) =>
        Path.Combine([CacheHome(), "Shelly", .. parts]);

    public static string ShellyData(params string[] parts) =>
        Path.Combine([DataHome(), "Shelly", .. parts]);

    public static string ShellyConfig(params string[] parts) =>
        Path.Combine([ConfigHome(), "shelly", .. parts]);

    /// <summary>
    /// Creates the directory if it doesn't exist and, when the current process is running as
    /// root via sudo, transfers ownership of the directory back to the invoking user so files
    /// written underneath remain accessible to non-root sessions.
    /// </summary>
    public static void EnsureDirectory(string path)
    {
        if (string.IsNullOrEmpty(path)) return;
        Directory.CreateDirectory(path);
        FixOwnershipIfRoot(path);
    }

    /// <summary>
    /// If the current process is running as root and SUDO_USER is set, recursively chown the
    /// given path back to the invoking user. No-op otherwise.
    /// </summary>
    public static void FixOwnershipIfRoot(string path)
    {
        if (string.IsNullOrEmpty(path)) return;
        if (Environment.GetEnvironmentVariable("USER") != "root") return;

        var user = Environment.GetEnvironmentVariable("SUDO_USER");
        if (string.IsNullOrEmpty(user) || user == "root") return;

        try
        {
            var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "chown",
                    Arguments = $"-R {user}:{user} \"{path}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };
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
        var sudoUser = Environment.GetEnvironmentVariable("SUDO_USER");
        if (!string.IsNullOrEmpty(sudoUser) && sudoUser != "root")
        {
            var home = GetHomeFromPasswd(sudoUser);
            if (!string.IsNullOrEmpty(home))
            {
                return home;
            }
        }

        var envHome = Environment.GetEnvironmentVariable("HOME");
        return !string.IsNullOrEmpty(envHome)
            ? envHome
            : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    }

    private static bool HasSudoUser()
    {
        var sudoUser = Environment.GetEnvironmentVariable("SUDO_USER");
        return !string.IsNullOrEmpty(sudoUser) && sudoUser != "root";
    }

    private static string Resolve(string envVar, string fallbackRel)
    {
        if (HasSudoUser()) return Path.Combine(InvokingUserHome(), fallbackRel);
        var v = Environment.GetEnvironmentVariable(envVar);
        if (!string.IsNullOrEmpty(v) && Path.IsPathRooted(v))
            return v;

        return Path.Combine(InvokingUserHome(), fallbackRel);
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
            var nameBytes = System.Text.Encoding.UTF8.GetByteCount(user) + 1;
            Span<byte> nameBuf = stackalloc byte[nameBytes];
            System.Text.Encoding.UTF8.GetBytes(user, nameBuf);
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
                    {
                        return GetHomeFromPasswdFile(user);
                    }

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
            Console.WriteLine("Failed to read /etc/passwd");
        }

        return null;
    }
}