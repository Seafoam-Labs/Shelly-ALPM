using PackageManager.Flatpak;
using PackageManager.Flatpak.Events;
using Pastel;
using Shelly.Cli.Commands;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Outputs;

public class FlatpakSinglePaneOutput
{
    public static async Task<bool> Output(
        IShellyConsole console,
        FlatpakManager manager,
        Func<FlatpakManager, Task<bool>> operation,
        bool noConfirm = false)
    {
        var ansi = AnsiUtilities.SupportsAnsi;

        var cfg = ConfigManager.ReadConfig();
        using var region = BottomBarRegion.CreateFromConfig(cfg, console);

        // One-shot section banner.
        var emittedRetrieving = false;

        string Color(string text, ConsoleColor color) => ansi ? text.Pastel(color) : text;

        manager.FlatpakProgressEvent += (_, e) =>
        {
            var name = e.Name ?? "unknown";
            var pct = e.Percentage ?? 0;
            var action = e.Status ?? string.Empty;
            
            if (!emittedRetrieving
                && action.StartsWith("Download", StringComparison.OrdinalIgnoreCase))
            {
                emittedRetrieving = true;
            }

            region.UpdateBar(name, (ulong)(e.Percentage ?? 0), 100, pct, action);
        };

        manager.FlatpakEvent += (_, e) =>
        {
            switch (e.EventType)
            {
                case FlatpakEventEnum.Error:
                    region.WriteLine(Color($"error: {e.Message}", ConsoleColor.Red));
                    break;
                case FlatpakEventEnum.Information:
                case FlatpakEventEnum.Warning:
                    break;
                case FlatpakEventEnum.Success:
                    region.WriteLine(Color($"{e.Message}", ConsoleColor.Green));
                    break;
                default:
                    throw new ArgumentOutOfRangeException();
            }
        };

        bool result;
        try
        {
            result = await operation(manager);
        }
        catch (Exception ex)
        {
            region.WriteLine(Color($"error: {ex.Message}", ConsoleColor.Red));
            result = false;
        }

        // Dispose region (finalize stickies, clear bars, join ticker) before flushing pacfiles.
        region.Dispose();
        return result;
    }
}