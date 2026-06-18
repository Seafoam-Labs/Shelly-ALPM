using System.CommandLine;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Config;

public class ConfigParallel : GlobalSettingsCommand
{
    private int DownloadCount { get; set; }

    public static Command Create()
    {
        var downloadCount = new Argument<int>("downloadCount") { Description = "The number of parallel downloads" };

        var command = new Command("parallel", "Set the number of parallel downloads") { downloadCount };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new ConfigParallel
            {
                DownloadCount = parseResult.GetValue(downloadCount)
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

        if (ConfigManager.UpdateConfig("ParallelDownloadCount", DownloadCount.ToString()))
            console.WriteLine(Colorize($"Set parallel downloads to {DownloadCount}", ConsoleColor.Green));
        else
            console.WriteLine(Colorize("Failed to set parallel downloads.", ConsoleColor.Red));
    }

    public override ValueTask ExecuteUiMode()
    {
        if (ConfigManager.UpdateConfig("ParallelDownloadCount", DownloadCount.ToString()))
            UiFrames.Info($"Set parallel downloads to {DownloadCount}");
        else
            UiFrames.Error("Failed to set parallel downloads.");

        return ValueTask.CompletedTask;
    }
}
