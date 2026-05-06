using PackageManager.Alpm;
using Shelly_CLI.Configuration;
using Shelly_CLI.Utility;
using Spectre.Console;

namespace Shelly_CLI.ConsoleLayouts;


public static class StandardSinglePaneOutput
{
    public static async Task<bool> Output(
        IAlpmManager manager,
        Func<IAlpmManager, Task<bool>> operation,
        bool noConfirm = false)
    {
        var cfg = ConfigManager.ReadConfig();
        using var region = BottomBarRegion.CreateFromConfig(cfg);

        var pendingPacfiles = new List<PendingPacfile>();
        var pacfileLock = new object();

        // One-shot section banners.
        var emittedRetrieving = false;
        var emittedProcessing = false;

        manager.Progress += (_, e) =>
        {
            var name = e.PackageName ?? "unknown";
            var pct = e.Percent ?? 0;
            var actionType = e.ProgressType.ToString();

            if (!emittedRetrieving
                && actionType.StartsWith("Download", StringComparison.OrdinalIgnoreCase))
            {
                emittedRetrieving = true;
                region.WriteLine("[bold]::[/] Retrieving packages...");
            }

            region.UpdateBar(name, e.Current ?? 0, e.HowMany ?? 0, pct, actionType);
        };

        manager.PackageOperation += (_, e) =>
        {
            if (!emittedProcessing)
            {
                emittedProcessing = true;
                region.WriteLine("[bold]::[/] Processing package changes...");
            }

            region.WriteLine(string.IsNullOrWhiteSpace(e.PackageName)
                ? $":: {e.EventType}".EscapeMarkup()
                : $":: {e.EventType} for {e.PackageName}".EscapeMarkup());
        };

        manager.ScriptletInfo += (_, e) =>
        {
            var line = e.Line ?? string.Empty;
            region.WriteLine(string.IsNullOrEmpty(line)
                ? "[dim]Running scriptlet...[/]"
                : $"[dim]Scriptlet: {line.EscapeMarkup()}[/]");
        };

        manager.HookRun += (_, e) =>
        {
            var line = e.Description ?? string.Empty;
            region.WriteLine(string.IsNullOrEmpty(line)
                ? "[dim]Running hook...[/]"
                : $"[dim]Hook: {line.EscapeMarkup()}[/]");
        };

        manager.Replaces += (_, e) =>
        {
            region.WriteLine($":: {e.Repository.EscapeMarkup()}/{e.PackageName.EscapeMarkup()} replaces " +
                             $"{string.Join(",", e.Replaces.Select(r => r.EscapeMarkup()))}");
        };

        manager.PacnewInfo += (_, e) =>
        {
            region.WriteLine($"[yellow]:: pacnew stored @ {e.FileLocation.EscapeMarkup()}.pacnew[/]");
            lock (pacfileLock)
            {
                pendingPacfiles.Add(new PendingPacfile(PacfileKind.Pacnew, null,
                    e.FileLocation + ".pacnew", DateTime.UtcNow));
            }
        };

        manager.PacsaveInfo += (_, e) =>
        {
            region.WriteLine($"[yellow]:: pacsave stored @ {e.FileLocation.EscapeMarkup()}.pacsave[/]");
            lock (pacfileLock)
            {
                pendingPacfiles.Add(new PendingPacfile(PacfileKind.Pacsave, e.OldPackage,
                    e.FileLocation + ".pacsave", DateTime.UtcNow));
            }
        };

        manager.ErrorEvent += (_, e) =>
        {
            region.WriteLine($"[red]error:[/] {e.Error.EscapeMarkup()}");
        };

        manager.Question += (_, e) =>
        {
            if (noConfirm)
            {
                QuestionHandler.HandleQuestion(e, uiMode: false, noConfirm: true);
                return;
            }

            region.SuspendForPrompt();
            try
            {
                QuestionHandler.HandleQuestion(e, uiMode: false, noConfirm: false);
            }
            finally
            {
                region.Resume();
            }
        };

        region.WriteLine("[bold]::[/] Synchronizing package databases...");

        var result = false;
        try
        {
            result = await operation(manager);
        }
        catch (Exception ex)
        {
            region.WriteLine($"[red]error:[/] {ex.Message.EscapeMarkup()}");
            result = false;
        }

        region.WriteLine(result
            ? "[green]:: Transaction complete.[/]"
            : "[red]:: Transaction failed.[/]");

        region.Dispose();

        try
        {
            await PacfileFlusher.FlushAsync(pendingPacfiles, pacfileLock);
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[yellow]warning:[/] failed to store pacfiles: {ex.Message.EscapeMarkup()}");
        }

        return result;
    }
}
