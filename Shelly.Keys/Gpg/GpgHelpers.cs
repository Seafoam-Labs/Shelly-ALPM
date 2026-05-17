using System.Diagnostics;

namespace Shelly.Keys.Gpg;

public static class GpgHelpers
{
    public static async Task<string> GetMasterFingerprintAsync(string homeDir)
    {
        var psi = new ProcessStartInfo("gpg")
        {
            ArgumentList =
            {
                "--homedir", homeDir,
                "--no-permission-warning",
                "--batch",
                "--list-secret-keys",
                "--with-colons",
            },
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        using var p = Process.Start(psi)
                      ?? throw new InvalidOperationException("Failed to start gpg");
        var stdout = await p.StandardOutput.ReadToEndAsync();
        await p.WaitForExitAsync();

        foreach (var line in stdout.Split('\n'))
        {
            if (!line.StartsWith("fpr:")) continue;
            var parts = line.Split(':');
            if (parts.Length >= 10 && !string.IsNullOrEmpty(parts[9]))
                return parts[9];
        }
        throw new InvalidOperationException("No master key fingerprint found");
    }
}