using PackageManager.Alpm;
using PackageManager.Aur;
using Shelly_CLI.Configuration;
using Shelly_CLI.Utility;
using Spectre.Console;

namespace Shelly_CLI.ConsoleLayouts;

/// <summary>
///     pacman/makepkg-style single-stream renderer for AUR install/upgrade flows.
///     Top-to-bottom log, in-place progress bars pinned to the bottom line(s),
///     section banners ("::", "==&gt;"), no Live panels.
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

        manager.InformationalEvent += (_, args) =>
        {
            // Discrete labeled stages (formerly PackageProgress)
            var stage = args.EventType switch
            {
                AlpmEventType.AurDownloadStart => ("downloading", "yellow", false),
                AlpmEventType.AurBuildStart => ("building", "blue", false),
                AlpmEventType.AurInstallStart => ("installing", "cyan", false),
                AlpmEventType.AurCleanupStart => ("cleaning", "magenta", false),
                AlpmEventType.AurPackageCompleted => ("completed", "green", true),
                AlpmEventType.AurPackageFailed => ("failed", "red", true),
                _ => (null, null, false)
            };

            if (stage.Item1 != null)
            {
                var pkg = args.PackageName ?? "";
                var idx = args.CurrentIndex ?? 0;
                var total = args.TotalCount ?? 0;
                var msg = !string.IsNullOrEmpty(args.Message) ? $" - {args.Message.EscapeMarkup()}" : "";
                var line =
                    $"[bold]::[/] [{stage.Item2}]({idx}/{total}) " +
                    $"{stage.Item1} {pkg.EscapeMarkup()}[/]{msg}";

                if (stage.Item3)
                {
                    region.FinalizeStickiesWhere(k => k.Source == "progress" && k.Package == pkg);
                    region.WriteLine(line);
                    region.PromoteBar(pkg);
                }
                else
                {
                    region.WriteEvent(new BottomBarRegion.LineKey("progress", pkg, stage.Item1), line);
                    if (args.EventType == AlpmEventType.AurBuildStart)
                        region.WriteLine($"[bold]==>[/] Making package: [bold]{pkg.EscapeMarkup()}[/]");
                }

                return;
            }

            // Raw makepkg log lines (formerly BuildOutput w/o percent)
            if (args.EventType is AlpmEventType.AurBuildOutput or AlpmEventType.AurBuildError)
            {
                var pkg = args.PackageName ?? "";
                region.FinalizeStickiesWhere(k => k.Source == "build" && k.Package == pkg);
                var line = args.Message;
                if (args.EventType == AlpmEventType.AurBuildError)
                    region.WriteLine($"[red]{line.EscapeMarkup()}[/]");
                else if (line.StartsWith("error:", StringComparison.OrdinalIgnoreCase))
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

        manager.Progress += (_, e) =>
        {
            var name = e.PackageName ?? "unknown";
            var pct = e.Percent ?? 0;

            // Makepkg progress (formerly BuildOutput w/ percent) — render its own bar
            if (e.ProgressType == AlpmProgressType.MakepkgBuild)
            {
                var bar = ProgressBarRenderer.RenderStatic(pct, 20);
                var msgPart = (e.Message ?? "").EscapeMarkup();
                var rendered = $"[bold]{name.EscapeMarkup()}[/] [yellow]{bar} {pct,3}%[/] {msgPart}";
                var action = string.IsNullOrEmpty(e.Message) ? "build" : e.Message!;
                var key = new BottomBarRegion.LineKey("build", name, action);
                region.WriteEvent(key, rendered);
                if (pct >= 100) region.FinalizeSticky(key);
                return;
            }

            region.UpdateBar(name, e.Current ?? 0, e.HowMany ?? 0, pct, e.ProgressType.ToString());
        };

        manager.ScriptletInfo += (_, e) =>
        {
            var line = e.Line;
            region.WriteLine(string.IsNullOrEmpty(line)
                ? "[dim]Running scriptlet...[/]"
                : $"[dim]Scriptlet: {line.EscapeMarkup()}[/]");
        };

        manager.HookRun += (_, e) =>
        {
            var line = e.Description;
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
                QuestionHandler.HandleQuestion(e, false, true);
                return;
            }

            region.SuspendForPrompt();
            try
            {
                QuestionHandler.HandleQuestion(e);
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
                QuestionHandler.HandleQuestion(args, false, noConfirm);
                if (!args.ProceedWithUpdate)
                    region.WriteLine("[yellow] Cancelled because of pkgbuild diff.[/]");
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