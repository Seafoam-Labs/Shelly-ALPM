using Shelly.Cli.Commands;
using PackageManager.Alpm;
using Pastel;
using Shelly.Cli.Interactions;
using Shelly.Cli.Models.Pacfile;
using PackageManager.Alpm.Pacfile;


namespace Shelly.Cli.Outputs;

public static class StandardSinglePaneOutput
{
    public static async Task<bool> Output(
        IShellyConsole console,
        IAlpmManager manager,
        Func<IAlpmManager, Task<bool>> operation,
        bool noConfirm = false)
    {
        var ansi = AnsiUtilities.SupportsAnsi;

        var pendingPacfiles = new List<PendingPacfile>();
        var pacfileLock = new object();

        var cfg = ConfigManager.ReadConfig();
        using var region = BottomBarRegion.CreateFromConfig(cfg, console);

        // One-shot section banner.
        var emittedRetrieving = false;

        string Color(string text, ConsoleColor color) => ansi ? text.Pastel(color) : text;

        manager.Progress += (_, e) =>
        {
            var name = e.PackageName ?? "unknown";
            var pct = e.Percent ?? 0;
            var action = e.ProgressType.ToString();

            if (!emittedRetrieving
                && action.StartsWith("Download", StringComparison.OrdinalIgnoreCase))
            {
                emittedRetrieving = true;
                region.WriteLine(Color(":: Retrieving packages...", ConsoleColor.White));
            }

            region.UpdateBar(name, e.Current ?? 0, e.HowMany ?? 0, pct, action);
        };

        manager.ScriptletInfo += (_, e) =>
        {
            var line = e.Line.TrimEnd();
            region.WriteLine(Color(
                string.IsNullOrEmpty(line) ? "Running scriptlet..." : $"Scriptlet: {line}",
                ConsoleColor.DarkGray));
        };

        manager.HookRun += (_, e) =>
        {
            var line = e.Description ?? string.Empty;
            region.WriteLine(Color(
                string.IsNullOrEmpty(line) ? "Running hook..." : $"Hook: {line}",
                ConsoleColor.DarkGray));
        };

        manager.Replaces += (_, e) =>
        {
            region.WriteLine(Color(
                $":: {e.Repository}/{e.PackageName} replaces {string.Join(",", e.Replaces)}",
                ConsoleColor.White));
        };

        manager.PacnewInfo += (_, e) =>
        {
            region.WriteLine(Color($":: pacnew stored @ {e.FileLocation}.pacnew", ConsoleColor.Yellow));
            lock (pacfileLock)
            {
                pendingPacfiles.Add(new PendingPacfile(
                    PacfileType.Pacnew, null, e.FileLocation + ".pacnew", DateTime.UtcNow));
            }
        };

        manager.PacsaveInfo += (_, e) =>
        {
            region.WriteLine(Color($":: pacsave stored @ {e.FileLocation}.pacsave", ConsoleColor.Yellow));
            lock (pacfileLock)
            {
                pendingPacfiles.Add(new PendingPacfile(
                    PacfileType.Pacsave, e.OldPackage, e.FileLocation + ".pacsave", DateTime.UtcNow));
            }
        };

        manager.ErrorEvent += (_, e) =>
        {
            region.WriteLine(Color($"error: {e.Error}", ConsoleColor.Red));
        };

        manager.Question += (_, e) =>
        {
            region.RunInteractive(() => QuestionHandler.HandleQuestion(e, uiMode: false, noConfirm: noConfirm));
        };

        region.WriteLine(Color(":: Synchronizing package databases...", ConsoleColor.White));

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

        region.WriteLine(result
            ? Color(":: Transaction complete.", ConsoleColor.Green)
            : Color(":: Transaction failed.", ConsoleColor.Red));

        // Dispose region (finalize stickies, clear bars, join ticker) before flushing pacfiles.
        region.Dispose();

        try
        {
            await PacfileFlusher.FlushAsync(pendingPacfiles, pacfileLock);
        }
        catch (Exception ex)
        {
            console.Output.WriteLine(Color($"warning: failed to store pacfiles: {ex.Message}", ConsoleColor.Yellow));
        }

        return result;
    }
}
