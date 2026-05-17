using System.Diagnostics;

namespace Shelly.Gtk.Services;

public class FingerprintAuthDetector : IFingerprintAuthDetector
{
    private static readonly string[] DefaultSearchRoots =
    [
        "/etc/pam.d",
        "/usr/lib/pam.d",
    ];

    private static readonly string[] DefaultServiceNames =
    [
        "sudo",
        "sudo-i",
        "polkit-1",
        "systemd-run0",
        "login",
        "system-auth",
        "system-login",
    ];

    private static readonly string[] SudoAffectingNames =
    [
        "sudo",
        "sudo-i",
        "system-auth",
        "system-login",
    ];

    private readonly string[] _searchRoots;
    private readonly string[] _serviceNames;

    public FingerprintAuthDetector() : this(DefaultSearchRoots, DefaultServiceNames)
    {
    }

    public FingerprintAuthDetector(string[] searchRoots, string[] serviceNames)
    {
        _searchRoots = searchRoots;
        _serviceNames = serviceNames;
    }

    public FingerprintDetectionResult Detect()
    {
        var hits = new List<string>();
        var visited = new HashSet<string>(StringComparer.Ordinal);

        var directSudoHit = FindDirectSudoFprintdLine();
        if (directSudoHit != null && !hits.Contains(directSudoHit)) hits.Add(directSudoHit);

        foreach (var svc in _serviceNames)
        {
            ScanService(svc, visited, hits);
        }

        var sudoHit = directSudoHit != null || hits.Any(IsSudoAffecting);
        var serviceActive = FprintdServiceActive();
        return new FingerprintDetectionResult(sudoHit || serviceActive, serviceActive, hits);
    }

    private string? FindDirectSudoFprintdLine()
    {
        foreach (var dir in _searchRoots)
        {
            var path = Path.Combine(dir, "sudo");
            if (!File.Exists(path)) continue;

            try
            {
                foreach (var raw in File.ReadAllLines(path))
                {
                    var line = raw.TrimStart();
                    if (line.Length > 0 && line[0] == '-') line = line.Substring(1).TrimStart();
                    if (line.Length == 0 || line.StartsWith('#')) continue;

                    var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length < 3) continue;
                    if (!string.Equals(parts[0], "auth", StringComparison.Ordinal)) continue;
                    if (!line.Contains("pam_fprintd.so", StringComparison.Ordinal)) continue;

                    return path;
                }
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to read pam file {path} {e}");
            }
        }

        return null;
    }

    private void ScanService(string serviceName, HashSet<string> visited, List<string> hits)
    {
        if (!visited.Add(serviceName)) return;

        foreach (var dir in _searchRoots)
        {
            var path = Path.Combine(dir, serviceName);
            if (!File.Exists(path)) continue;

            try
            {
                foreach (var raw in File.ReadAllLines(path))
                {
                    var line = raw.TrimStart();
                    if (line.Length > 0 && line[0] == '-') line = line.Substring(1).TrimStart();
                    if (line.Length == 0 || line.StartsWith('#')) continue;

                    if (line.Contains("pam_fprintd.so", StringComparison.Ordinal))
                    {
                        if (!hits.Contains(path)) hits.Add(path);
                        continue;
                    }

                    var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                    for (var i = 0; i + 1 < parts.Length; i++)
                    {
                        if (parts[i] == "include" || parts[i] == "substack")
                        {
                            ScanService(parts[i + 1], visited, hits);
                            break;
                        }
                    }
                }
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to read pam file {path} {e}");
            }
        }
    }

    private static bool IsSudoAffecting(string path)
    {
        var name = Path.GetFileName(path);
        foreach (var n in SudoAffectingNames)
        {
            if (string.Equals(name, n, StringComparison.Ordinal)) return true;
        }
        return false;
    }

    public virtual bool FprintdServiceActive()
    {
        try
        {
            var psi = new ProcessStartInfo("systemctl")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            psi.ArgumentList.Add("is-active");
            psi.ArgumentList.Add("--quiet");
            psi.ArgumentList.Add("fprintd.service");
            using var p = Process.Start(psi);
            if (p == null) return false;
            p.WaitForExit(2000);
            return p.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }
}
