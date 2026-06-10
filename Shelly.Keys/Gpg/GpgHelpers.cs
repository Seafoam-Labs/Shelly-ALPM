using System.Diagnostics;
using Spectre.Console;

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
    
    public static async Task<int> RunGpgAsync(string dir, params string[] args)
    {
        var psi = new ProcessStartInfo("gpg")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            Environment =
            {
                ["LC_ALL"] = "C",
                ["GNUPGHOME"] = dir
            }
        };
        psi.ArgumentList.Add("--homedir"); psi.ArgumentList.Add(dir);
        psi.ArgumentList.Add("--no-permission-warning");
        psi.ArgumentList.Add("--batch");
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        var o = (await stdout).Trim(); var e = (await stderr).Trim();
        if (o.Length > 0) AnsiConsole.MarkupLine($"[grey]{Markup.Escape(o)}[/]");
        if (e.Length > 0) AnsiConsole.MarkupLine($"[grey]{Markup.Escape(e)}[/]");
        return p.ExitCode;
    }
    
    public static async Task<int> RunGpgStdinAsync(string dir, string stdin, params string[] args)
    {
        var psi = new ProcessStartInfo("gpg")
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            Environment =
            {
                ["LC_ALL"] = "C",
                ["GNUPGHOME"] = dir
            }
        };
        psi.ArgumentList.Add("--homedir"); psi.ArgumentList.Add(dir);
        psi.ArgumentList.Add("--no-permission-warning"); psi.ArgumentList.Add("--batch");
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var p = Process.Start(psi)!;
        await p.StandardInput.WriteAsync(stdin);
        p.StandardInput.Close();
        await p.WaitForExitAsync();
        return p.ExitCode;
    }
}