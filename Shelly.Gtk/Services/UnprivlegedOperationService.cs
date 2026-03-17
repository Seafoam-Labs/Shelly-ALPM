using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;


namespace Shelly.Gtk.Services;

public class UnprivilegedOperationService : IUnprivilegedOperationService
{
    private readonly string _cliPath;

    public UnprivilegedOperationService()
    {
        _cliPath = FindCliPath();
    }

    private static string FindCliPath()
    {
#if DEBUG
        var debugPath =
            Path.Combine("/home", Environment.GetEnvironmentVariable("USER")!,
                "RiderProjects/Shelly-ALPM/Shelly-CLI/bin/Debug/net10.0/linux-x64/shelly");
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

    public async Task<List<FlatpakPackageDto>> ListFlatpakPackages()
    {
        var result = await ExecuteUnprivilegedCommandAsync("List packages", "flatpak list", "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("[") && trimmedLine.EndsWith("]"))
                {
                    var updates = System.Text.Json.JsonSerializer.Deserialize(trimmedLine,
                        ShellyGtkJsonContext.Default.ListFlatpakPackageDto);
                    return updates ?? [];
                }
            }

            var allUpdates = System.Text.Json.JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                ShellyGtkJsonContext.Default.ListFlatpakPackageDto);
            return allUpdates ?? [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<List<FlatpakPackageDto>> ListFlatpakUpdates()
    {
        var result = await ExecuteUnprivilegedCommandAsync("List packages", "flatpak list-updates", "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("[") && trimmedLine.EndsWith("]"))
                {
                    var updates = System.Text.Json.JsonSerializer.Deserialize(trimmedLine,
                        ShellyGtkJsonContext.Default.ListFlatpakPackageDto);
                    return updates ?? [];
                }
            }

            var allUpdates = System.Text.Json.JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                ShellyGtkJsonContext.Default.ListFlatpakPackageDto);
            return allUpdates ?? [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<UnprivilegedOperationResult> RemoveFlatpakPackage(IEnumerable<string> packages)
    {
        var packageArgs = string.Join(" ", packages);
        return await ExecuteUnprivilegedCommandAsync("Remove packages", "flatpak remove", packageArgs);
    }

    public async Task<List<AppstreamApp>> ListAppstreamFlatpak()
    {
        var result =
            await ExecuteUnprivilegedCommandAsync("Get local appstream", "flatpak get-remote-appstream", "all",
                "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            var lines = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            foreach (var line in lines)
            {
                var trimmedLine = StripBom(line.Trim());
                if (trimmedLine.StartsWith("[") && trimmedLine.EndsWith("]"))
                {
                    var updates = System.Text.Json.JsonSerializer.Deserialize(trimmedLine,
                        ShellyGtkJsonContext.Default.ListAppstreamApp);
                    return updates ?? [];
                }
            }

            var allUpdates = System.Text.Json.JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                ShellyGtkJsonContext.Default.ListAppstreamApp);
            return allUpdates ?? [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
            return [];
        }
    }


    public async Task<UnprivilegedOperationResult> UpdateFlatpakPackage(string package)
    {
        return await ExecuteUnprivilegedCommandAsync("Update package", "flatpak update", package);
    }

    public async Task<UnprivilegedOperationResult> RemoveFlatpakPackage(string package)
    {
        return await ExecuteUnprivilegedCommandAsync("Remove package", "flatpak uninstall", package);
    }

    public async Task<UnprivilegedOperationResult> InstallFlatpakPackage(string package, bool user, string remote,
        string branch)
    {
        if (user)
        {
            return await ExecuteUnprivilegedCommandAsync("Install package", "flatpak install", package, "--user",
                "--remote", remote, "--branch", branch);
        }

        return await ExecuteUnprivilegedCommandAsync("Install package", "flatpak install", package, "--remote", remote,
            "--branch", branch);
    }

    public async Task<UnprivilegedOperationResult> FlatpakUpgrade()
    {
        return await ExecuteUnprivilegedCommandAsync("Upgrade flatpak", "flatpak upgrade");
    }

    public async Task<List<FlatpakRemoteDto>> FlatpakListRemotes()
    {
        var result = await ExecuteUnprivilegedCommandAsync("flatpak list remotes", "flatpak list-remotes", "-j");
        var json = StripBom(result.Output.Trim());
        return JsonSerializer.Deserialize<List<FlatpakRemoteDto>>(json,
            ShellyGtkJsonContext.Default.ListFlatpakRemoteDto) ?? [];
    }

    public async Task<UnprivilegedOperationResult> FlatpakSyncRemoteAppstream()
    {
        return await ExecuteUnprivilegedCommandAsync("Sync remote", "flatpak sync-remote-appstream");
    }

    public async Task<UnprivilegedOperationResult> FlatpakRemoveRemote(string remoteName, string scope)
    {
        if (scope == "user")
        {
            return await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak remove-remotes", remoteName,
                "--system", "false");
        }

        return await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak remove-remotes", remoteName, "--system",
            "true");
    }

    public async Task<UnprivilegedOperationResult> FlatpakAddRemote(string remoteName, string scope, string url)
    {
        if (scope == "user")
        {
            return await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak add-remotes", remoteName,
                "--remote-url", url, "--system", "false");
        }

        return await ExecuteUnprivilegedCommandAsync("Remove Remote", "flatpak add-remotes", remoteName, "--remote-url",
            url, "--system", "true");
    }

    public async Task<ulong> GetFlatpakAppDataAsync(string remote, string app, string arch)
    {
        try
        {
            var result =
                await ExecuteUnprivilegedCommandAsync("Sync remote", "flatpak app-remote-info", remote, app, arch,
                    "-j");
            var json = StripBom(result.Output.Trim());
            var remoteInfo =
                JsonSerializer.Deserialize<FlatpakRemoteRefInfo>(json,
                    ShellyGtkJsonContext.Default.FlatpakRemoteRefInfo);
            return remoteInfo!.DownloadSize;
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to get remote info: {ex.Message}");
        }

        return 0;
    }

    public async Task<UnprivilegedOperationResult> ExportSyncFile(string filePath, string name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return await ExecuteUnprivilegedCommandAsync("Export Sync", "utility export -o", filePath);
        }

        return await ExecuteUnprivilegedCommandAsync("Export Sync", "utility export -o", filePath, "-n", name);
    }

    public async Task<SyncModel> CheckForApplicationUpdates()
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
                            ShellyGtkJsonContext.Default.SyncModel);
                    return updates ?? new SyncModel();
                }
            }

            var allUpdates = System.Text.Json.JsonSerializer.Deserialize(StripBom(result.Output.Trim()),
                ShellyGtkJsonContext.Default.SyncModel);
            return allUpdates ?? new SyncModel();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse updates JSON: {ex.Message}");
            return new SyncModel();
        }
    }

    public async Task<List<FlatpakPackageDto>> SearchFlathubAsync(string query)
    {
        var result =
            await ExecuteUnprivilegedCommandAsync("Search Flathub", "flatpak search", query, "--json", "--limit",
                "100");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            var trimmedOutput = StripBom(result.Output.Trim());

            if (trimmedOutput.StartsWith("{"))
            {
                var response = System.Text.Json.JsonSerializer.Deserialize(trimmedOutput,
                    ShellyGtkJsonContext.Default.FlathubSearchResponse);

                if (response?.Hits == null) return [];

                return response.Hits.Select(hit => new FlatpakPackageDto
                {
                    Id = hit.AppId ?? hit.Id ?? string.Empty,
                    Name = hit.Name ?? string.Empty,
                    Summary = hit.Summary ?? string.Empty,
                    Description = hit.Description ?? string.Empty,
                    IconPath = hit.Icon
                }).ToList();
            }

            return [];
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse Flathub search JSON: {ex.Message}");
            return [];
        }
    }

    private async Task<UnprivilegedOperationResult> ExecuteUnprivilegedCommandAsync(string operationDescription,
        params string[] args)
    {
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
            if (e.Data != null)
            {
                // Filter out the password prompt from sudo

                // Check for ALPM question (with Shelly prefix)
                if (e.Data.StartsWith("[Shelly][ALPM_QUESTION]"))
                {
                    var questionText = e.Data.Substring("[Shelly][ALPM_QUESTION]".Length);
                    Console.Error.WriteLine($"[Shelly]Question received: {questionText}");

                    // Show dialog on UI thread and get response
                    //TODO: IMPLEMENT INTERACTION HERE 

                    // var response = await Dispatcher.UIThread.InvokeAsync(async () =>
                    // {
                    //     if (Application.Current?.ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop
                    //         && desktop.MainWindow != null)
                    //     {
                    //         var dialog = new QuestionDialog(questionText);
                    //         var result = await dialog.ShowDialog<bool>(desktop.MainWindow);
                    //         return result;
                    //     }
                    //
                    //     return true; // Default to yes if no window available
                    // });

                    // Send response to CLI via stdin
                    if (stdinWriter != null)
                    {
                        //await stdinWriter.WriteLineAsync(response ? "y" : "n");
                        await stdinWriter.WriteLineAsync("y");
                        await stdinWriter.FlushAsync();
                    }
                }
                else
                {
                    errorBuilder.AppendLine(e.Data);
                    Console.Error.WriteLine(e.Data);
                }
            }
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

    private static string StripBom(string input)
    {
        if (string.IsNullOrEmpty(input))
            return input;

        // UTF-8 BOM is 0xEF 0xBB 0xBF which appears as \uFEFF in .NET strings
        return input.TrimStart('\uFEFF');
    }
}