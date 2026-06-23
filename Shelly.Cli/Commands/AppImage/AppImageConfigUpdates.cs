using System.CommandLine;
using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using Shelly.Utilities;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageConfigUpdates : GlobalSettingsCommand
{
    public required string AppImage { get; set; }

    public required string Url { get; set; }

    public required UpdateType Type { get; set; }

    private bool AllowPrerelease { get; set; }

    public static Command Create()
    {
        var appImage = new Argument<string>("appimage") { Description = "AppImage name to configure updates" };
        var url = new Argument<string>("url") { Description = "Update URL" };
        var type = new Argument<UpdateType>("type") { Description = "Update Type" };
        var prerelease = new Option<bool>("--prerelease", "-p") { Description = "Allow prerelease updates" };

        var command = new Command("configure-updates", "Configures the update settings for an AppImage")
            { appImage, url, type, prerelease };

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageConfigUpdates
            {
                AppImage = parseResult.GetValue(appImage)!,
                Url = parseResult.GetValue(url)!,
                Type = parseResult.GetValue(type),
                AllowPrerelease = parseResult.GetValue(prerelease)
            };
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

        if (string.IsNullOrEmpty(AppImage))
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: AppImage name is required)", ConsoleColor.Red));
            return;
        }

        if (string.IsNullOrEmpty(Url) && Type != UpdateType.None)
        {
            console.WriteLine(AnsiUtilities.Colorize("Error: Update URL is required", ConsoleColor.Red));
            return;
        }

        var matches = await GetAppImageMatches();
        if (matches.Count == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize($"No AppImage matching \"{AppImage}\" found in searched paths.",
                ConsoleColor.Red));
            return;
        }
        
        var manager = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");
        
        var success = await AppImageSinglePaneOutput.Output(console, manager,
            x => x.AppImageConfigureUpdates(Url, AppImage, Type, AllowPrerelease));
        
        if (success)
        {
            console.WriteLine(AnsiUtilities.Colorize($"Successfully configured updates for {AppImage}",
                ConsoleColor.Green));
            return;
        }

        console.WriteLine(AnsiUtilities.Colorize($"Failed to configure updates for {AppImage}. Is it installed?",
            ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        var matches = await GetAppImageMatches();
        if (matches.Count == 0)
        {
            UiFrames.Error($"No AppImage matching \"{AppImage}\" found in searched paths.");
            return;
        }

        var manager = new AppImageManagerV2(ConfigManager.ReadConfig().AppImageInstallPath ?? "");
        var success = await UiModeOutput.Run(manager,
            x => x.AppImageConfigureUpdates(Url, AppImage, Type, AllowPrerelease));

        if (success)
        {
            UiFrames.Info($"Successfully configured updates for {AppImage}");
        }
    }

    private async Task<List<string>> GetAppImageMatches()
    {
        var installDir = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var oldDefaultPath = XdgPaths.BinHome();
        var searchPaths = new List<string> { installDir };
        if (installDir != oldDefaultPath)
        {
            searchPaths.Add(oldDefaultPath);
        }

        var matches = new List<string>();
        foreach (var appImages in from path in searchPaths
                 where Directory.Exists(path)
                 select Directory.GetFiles(path, "*.AppImage", SearchOption.TopDirectoryOnly))
        {
            matches.AddRange(appImages.Where(f =>
                Path.GetFileName(f).Contains(AppImage, StringComparison.OrdinalIgnoreCase)));
        }

        return matches;
    }
}