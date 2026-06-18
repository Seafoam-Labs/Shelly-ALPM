using System.CommandLine;
using System.Diagnostics;
using Shelly.Utilities;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Utility;

public class FixPermissions : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("fix-permissions", "Fix permissions for Shelly directories");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new FixPermissions();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        RootElevator.EnsureRootExectuion();

        var user = ResolveInvokingUser();
        if (user is null)
        {
            console.WriteLine(Colorize("Could not determine invoking user (SUDO_USER not set).", ConsoleColor.Red));
            return;
        }

        var paths = GetExistingShellyPaths();
        if (paths.Count == 0)
        {
            console.WriteLine(Colorize("No directories to fix permissions for.", ConsoleColor.Green));
            return;
        }

        foreach (var path in paths)
        {
            var result = await ChownRecursiveAsync(user, path);
            console.WriteLine(result.IsSuccess
                ? Colorize($"Fixed ownership: {path}", ConsoleColor.Green)
                : Colorize($"Failed to fix ownership for {path}: {result.Error}", ConsoleColor.Red));
        }
    }

    public override async ValueTask ExecuteUiMode()
    {
        var user = ResolveInvokingUser();
        if (user is null)
        {
            UiFrames.Error("Could not determine invoking user (SUDO_USER not set).");
            return;
        }

        var paths = GetExistingShellyPaths();
        if (paths.Count == 0)
        {
            UiFrames.Info("No directories to fix permissions for.");
            return;
        }

        foreach (var path in paths)
        {
            var result = await ChownRecursiveAsync(user, path);
            if (result.IsSuccess)
                UiFrames.Info($"Fixed ownership: {path}");
            else
                UiFrames.Error($"Failed to fix ownership for {path}: {result.Error}");
        }
    }

    private static string? ResolveInvokingUser()
    {
        var user = Environment.GetEnvironmentVariable("SUDO_USER");
        return string.IsNullOrEmpty(user) || user == "root" ? null : user;
    }

    private static List<string> GetExistingShellyPaths()
    {
        string[] paths = [XdgPaths.ShellyConfig(), XdgPaths.ShellyCache(), XdgPaths.ShellyData()];
        return paths.Where(Directory.Exists).ToList();
    }

    private static async Task<ChownResult> ChownRecursiveAsync(string user, string path)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "chown",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        psi.ArgumentList.Add("-R");
        psi.ArgumentList.Add($"{user}:{user}");
        psi.ArgumentList.Add(path);

        try
        {
            using var proc = Process.Start(psi);
            if (proc is null) return ChownResult.Failure("Failed to start chown process.");

            await proc.WaitForExitAsync();
            if (proc.ExitCode == 0) return ChownResult.Success();

            var error = await proc.StandardError.ReadToEndAsync();
            return ChownResult.Failure($"chown exited with code {proc.ExitCode}: {error.Trim()}");
        }
        catch (Exception ex)
        {
            return ChownResult.Failure(ex.Message);
        }
    }

    private readonly record struct ChownResult(bool IsSuccess, string Error)
    {
        public static ChownResult Success()
        {
            return new ChownResult(true, string.Empty);
        }

        public static ChownResult Failure(string error)
        {
            return new ChownResult(false, error);
        }
    }
}