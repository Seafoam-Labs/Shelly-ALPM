using PackageManager.Alpm;
using PackageManager.Aur;
using Shelly_CLI.Configuration;
using Shelly_CLI.Utility;
using Spectre.Console;
using LineKey = Shelly_CLI.ConsoleLayouts.BottomBarRegion.LineKey;

namespace Shelly_CLI.ConsoleLayouts;

/// <summary>
/// pacman/makepkg-style single-stream renderer for AUR install/upgrade flows.
/// Top-to-bottom log, in-place progress bars pinned to the bottom line(s),
/// section banners ("::", "==&gt;"), no Live panels.
/// </summary>
public static class AurSinglePaneOutput
{
    public static async Task<bool> Output(
        AurPackageManager manager,
        Func<AurPackageManager, Task> operation,
        bool noConfirm = false)
    {
        var cfg = ConfigManager.ReadConfig();
        using var region = BottomBarRegion.CreateFromConfig(cfg);

        var hadError = false;
        var pendingPacfiles = new List<PendingPacfile>();
        var pacfileLock = new object();

        manager.PackageProgress += (_, args) =>
        {
            var statusColor = args.Status switch
            {
                PackageProgressStatus.Downloading => "yellow",
                PackageProgressStatus.Building => "blue",
                PackageProgressStatus.Installing => "cyan",
                PackageProgressStatus.Completed => "green",
                PackageProgressStatus.Failed => "red",
                _ => "white"
            };

            var msg = args.Message != null ? $" - {args.Message.EscapeMarkup()}" : "";
            var line =
                $"[bold]::[/] [{statusColor}]({args.CurrentIndex}/{args.TotalCount}) " +
                $"{args.Status.ToString().ToLowerInvariant()} {args.PackageName.EscapeMarkup()}[/]{msg}";

            if (args.Status == PackageProgressStatus.Completed
                || args.Status == PackageProgressStatus.Failed)
            {
                region.FinalizeStickiesWhere(k => k.Source == "progress" && k.Package == args.PackageName);
                region.WriteLine(line);
                region.PromoteBar(args.PackageName);
            }
            else
            {
                region.WriteEvent(
                    new LineKey("progress", args.PackageName, args.Status.ToString()),
                    line);

                if (args.Status == PackageProgressStatus.Building)
                {
                    region.WriteLine($"[bold]==>[/] Making package: [bold]{args.PackageName.EscapeMarkup()}[/]");
                }
            }
        };

        manager.Progress += (_, e) =>
        {
            var name = e.PackageName ?? "unknown";
            var pct = e.Percent ?? 0;
            region.UpdateBar(name, e.Current ?? 0, e.HowMany ?? 0, pct, e.ProgressType.ToString());
        };

        manager.BuildOutput += (_, e) =>
        {
            if (e.Percent.HasValue)
            {
                var bar = ProgressBarRenderer.RenderStatic(e.Percent.Value, 20);
                var msgPart = (e.ProgressMessage ?? "").EscapeMarkup();
                var rendered =
                    $"[bold]{e.PackageName.EscapeMarkup()}[/] [yellow]{bar} {e.Percent.Value,3}%[/] {msgPart}";
                var action = string.IsNullOrEmpty(e.ProgressMessage) ? "build" : e.ProgressMessage!;
                var key = new LineKey("build", e.PackageName ?? "", action);
                region.WriteEvent(key, rendered);

                if (e.Percent.Value >= 100)
                {
                    region.FinalizeSticky(key);
                }
                return;
            }

            var pkg = e.PackageName ?? "";
            region.FinalizeStickiesWhere(k => k.Source == "build" && k.Package == pkg);

            var line = e.Line ?? string.Empty;
            if (e.IsError)
            {
                region.WriteLine($"[red]{line.EscapeMarkup()}[/]");
            }
            else
            {
                if (line.StartsWith("error:", StringComparison.OrdinalIgnoreCase))
                    region.WriteLine($"[red]{line.EscapeMarkup()}[/]");
                else if (line.StartsWith("warning:", StringComparison.OrdinalIgnoreCase))
                    region.WriteLine($"[yellow]{line.EscapeMarkup()}[/]");
                else if (line.StartsWith("==>"))
                    region.WriteLine($"[bold green]{line.EscapeMarkup()}[/]");
                else if (line.StartsWith("  ->"))
                    region.WriteLine($"[bold blue]{line.EscapeMarkup()}[/]");
                else
                    region.WritePlain(line);
            }
        };

        manager.PackageOperation += (_, e) =>
        {
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
            hadError = true;
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

        manager.PkgbuildDiffRequest += (_, args) =>
        {
            region.SuspendForPrompt();
            try
            {
                AnsiConsole.MarkupLine($"[bold]:: PKGBUILD for {args.PackageName.EscapeMarkup()}:[/]");
                foreach (var line in AurSplitOutput.BuildUnifiedDiffLines(
                             args.OldPkgbuild ?? string.Empty,
                             args.NewPkgbuild ?? string.Empty))
                {
                    AnsiConsole.MarkupLine(line);
                }

                args.ProceedWithUpdate = noConfirm
                    || AnsiConsole.Confirm(":: Proceed with this PKGBUILD?", true);
            }
            finally
            {
                region.Resume();
            }
        };

        region.WriteLine("[bold]::[/] Synchronizing package databases...");

        try
        {
            await operation(manager);
        }
        catch (Exception ex)
        {
            hadError = true;
            region.WriteLine($"[red]error:[/] {ex.Message.EscapeMarkup()}");
        }

        region.WriteLine(hadError
            ? "[red]:: Transaction failed.[/]"
            : "[green]:: Transaction complete.[/]");

        // Region disposed via using; final cleanup happens here.
        region.Dispose();

        try
        {
            await PacfileFlusher.FlushAsync(pendingPacfiles, pacfileLock);
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[yellow]warning:[/] failed to store pacfiles: {ex.Message.EscapeMarkup()}");
        }

        return !hadError;
    }
}
