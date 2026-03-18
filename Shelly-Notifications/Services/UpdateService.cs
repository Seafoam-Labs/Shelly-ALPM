using System.Diagnostics;
using System.Text;
using Shelly_Notifications.DbusHandlers;
using Shelly_Notifications.Models;

namespace Shelly_Notifications.Services;

public class UpdateService(DBusMenuHandler? menuHandler = null)
{
    public async Task<int> CheckForUpdates()
    {
        var result = await ExecuteUnprivilegedCommandAsync("Get Available Updates", "utility updates -a -l --json");
        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("{") && trimmedLine.EndsWith("}"))
                {
                    var updates =
                        System.Text.Json.JsonSerializer.Deserialize(trimmedLine,
                            NotificationJsonContext.Default.SyncModel);
                    if (updates != null)
                    {
                        menuHandler?.NotifyChildrenDisplayChanged(updates);
                        return updates.Aur.Count + updates.Flatpaks.Count + updates.Packages.Count;
                    }
                }
            }

            var allUpdates = System.Text.Json.JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                NotificationJsonContext.Default.SyncModel);

            if (allUpdates != null)
            {
                menuHandler?.NotifyChildrenDisplayChanged(allUpdates);
                return allUpdates.Aur.Count + allUpdates.Flatpaks.Count + allUpdates.Packages.Count;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
            return 0;
        }

        return 0;
    }

    private static string StripBom(string input)
    {
        if (string.IsNullOrEmpty(input))
            return input;

        // UTF-8 BOM is 0xEF 0xBB 0xBF which appears as \uFEFF in .NET strings
        return input.TrimStart('\uFEFF');
    }

    private string _cliPath;

    private async Task<UnprivilegedOperationResult> ExecuteUnprivilegedCommandAsync(string operationDescription,
        params string[] args)
    {
        _cliPath = FindCliPath();

        var arguments = string.Join(" ", args);
        var fullCommand = $"{_cliPath} {arguments}";

        Console.WriteLine($"Executing privileged command: {fullCommand}");

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = _cliPath,
                Arguments = arguments,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                CreateNoWindow = true
            }
        };

        var outputBuilder = new StringBuilder();
        var errorBuilder = new StringBuilder();
        StreamWriter? stdinWriter = null;

        process.OutputDataReceived += (sender, e) =>
        {
            if (e.Data != null)
            {
                outputBuilder.AppendLine(e.Data);
                Console.WriteLine(e.Data);
            }
        };

        process.ErrorDataReceived += async (sender, e) =>
        {
            errorBuilder.AppendLine(e.Data);
            Console.Error.WriteLine(e.Data);
        };

        try
        {
            process.Start();
            stdinWriter = process.StandardInput;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            await process.WaitForExitAsync();

            // Close stdin after process exits
            stdinWriter.Close();

            var success = process.ExitCode == 0;

            return new UnprivilegedOperationResult
            {
                Success = success,
                Output = outputBuilder.ToString(),
                Error = errorBuilder.ToString(),
                ExitCode = process.ExitCode
            };
        }
        catch (Exception ex)
        {
            return new UnprivilegedOperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = ex.Message,
                ExitCode = -1
            };
        }
    }

    private static string UserPath
    {
        get
        {
            // If running via pkexec, get original user's home
            var pkexecUid = Environment.GetEnvironmentVariable("PKEXEC_UID");
            if (pkexecUid != null)
            {
                var process = Process.Start(new ProcessStartInfo
                {
                    FileName = "getent",
                    Arguments = $"passwd {pkexecUid}",
                    RedirectStandardOutput = true,
                    UseShellExecute = false
                });
                process?.WaitForExit();
                var output = process?.StandardOutput.ReadLine();
                var home = output?.Split(':')[5];
                if (!string.IsNullOrEmpty(home)) return home;
            }

            return Environment.GetEnvironmentVariable("HOME")
                   ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }
    }

    private static string FindCliPath()
    {
#if DEBUG
        var home = UserPath;
        if (home == null)
        {
            throw new InvalidOperationException("HOME environment variable is not set.");
        }

        var debugPath =
            Path.Combine(home!, "RiderProjects/Shelly-ALPM/Shelly-CLI/bin/Debug/net10.0/linux-x64/shelly");
        Console.Error.WriteLine($"Debug path: {debugPath}");
#endif

        // Check common installation paths
        var possiblePaths = new[]
        {
#if DEBUG
            debugPath,
#endif
            "/usr/bin/shelly",
            "/usr/local/bin/shelly",
            Path.Combine(AppContext.BaseDirectory, "shelly"),
            Path.Combine(AppContext.BaseDirectory, "Shelly"),
            // Development path - relative to UI executable
            Path.Combine(Path.GetDirectoryName(AppContext.BaseDirectory) ?? "", "Shelly", "Shelly"),
        };

        foreach (var path in possiblePaths)
        {
            if (File.Exists(path))
            {
                return path;
            }
        }

        // Fallback to assuming it's in PATH
        return "shelly";
    }
}

public class UnprivilegedOperationResult
{
    public bool Success { get; init; }
    public string Output { get; init; } = string.Empty;
    public string Error { get; init; } = string.Empty;
    public int ExitCode { get; init; }
}