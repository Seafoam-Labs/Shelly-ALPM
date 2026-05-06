using PackageManager.Alpm;
using PackageManager.Aur;
using Shelly_CLI.Configuration;
using Shelly_CLI.Utility;
using Spectre.Console;

namespace Shelly_CLI.ConsoleLayouts;

public static class AurSplitOutput
{
    private sealed class BarState
    {
        public string Name = "";
        public ulong Current;
        public ulong HowMany;
        public int Pct;
        public string ActionType = "";
        public bool Completed;
    }

    public static async Task<bool> Output(AurPackageManager manager, Func<AurPackageManager, Task> operation,
        bool noConfirm = false,
        int consoleRatio = 3,
        int progressRatio = 2)
    {
        var cfg = ConfigManager.ReadConfig();
        var style = ProgressBarRenderer.ParseStyle(cfg.ProgressBarStyle);
        var fps = Math.Clamp(cfg.ProgressBarFps, 1, 30);
        var barWidth = cfg.ProgressBarWidth;

        var consoleLines = new List<string>();
        var progressLines = new List<string>();
        var pendingPacfiles = new List<PendingPacfile>();
        var pacfileLock = new object();
        var maxVisibleLines = Console.WindowHeight - 4;

        var layout = new Layout("Columns")
            .SplitColumns(new Layout("Console").Ratio(consoleRatio),
                new Layout("Progress").Ratio(progressRatio));

        layout["Console"].Update(new Panel(new Rows()).Header("Console").Expand());
        layout["Progress"].Update(new Panel("Waiting...").Header("Progress").Expand());
        LiveDisplayContext? liveCtx = null;
        object renderLock = new();
        bool hadError = false;

        // Track package progress lines by package name for in-place updates.
        // Kept separate from ALPM bar rows to avoid index desync when progressLines is rebuilt.
        var packageProgressLines = new List<string>();
        var packageProgressIndex = new Dictionary<string, int>();

        var rows = new Dictionary<string, BarState>(StringComparer.Ordinal);
        var order = new List<string>();

        string RenderLine(BarState r, int frame)
        {
            var bar = ProgressBarRenderer.Render(r.Pct, frame, style, barWidth);
            return $"({r.Current}/{r.HowMany}) {r.ActionType} " +
                   $"[bold]{r.Name.EscapeMarkup()}[/] {bar} {r.Pct,3}%";
        }

        void RebuildProgressLines(int frame)
        {
            progressLines.Clear();
            progressLines.AddRange(packageProgressLines);
            foreach (var key in order)
            {
                progressLines.Add(RenderLine(rows[key], frame));
            }
        }

        manager.PackageProgress += (sender, args) =>
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

            var line =
                $"[{statusColor}][[{args.CurrentIndex}/{args.TotalCount}]] {args.PackageName.EscapeMarkup()}: {args.Status}[/]" +
                (args.Message != null ? $" - {args.Message.EscapeMarkup()}" : "");

            lock (renderLock)
            {
                if (packageProgressIndex.TryGetValue(args.PackageName, out var idx)
                    && idx < packageProgressLines.Count)
                {
                    packageProgressLines[idx] = line;
                }
                else
                {
                    packageProgressLines.Add(line);
                    packageProgressIndex[args.PackageName] = packageProgressLines.Count - 1;
                }

                RebuildProgressLines(frame: 0);

                var visible = progressLines.Skip(Math.Max(0, progressLines.Count - maxVisibleLines)).ToList();
                layout["Progress"].Update(
                    new Panel(new Markup(string.Join("\n", visible)))
                        .Header("Progress")
                        .Expand());
                liveCtx?.Refresh();
            }
        };

        manager.Progress += (sender, e) =>
        {
            var name = e.PackageName ?? "unknown";
            var pct = e.Percent ?? 0;
            var actionType = e.ProgressType.ToString();

            lock (renderLock)
            {
                if (!rows.TryGetValue(name, out var r))
                {
                    r = new BarState { Name = name };
                    rows[name] = r;
                    order.Add(name);
                }

                r.Current = e.Current ?? 0;
                r.HowMany = e.HowMany ?? 0;
                r.Pct = pct;
                r.ActionType = actionType;
                if (pct >= 100) r.Completed = true;

                RebuildProgressLines(frame: 0);

                var visible = progressLines.Skip(Math.Max(0, progressLines.Count - maxVisibleLines)).ToList();
                layout["Progress"].Update(
                    new Panel(new Markup(string.Join("\n", visible)))
                        .Header("Progress")
                        .Expand());
                liveCtx?.Refresh();
            }
        };

        manager.Question += (sender, e) =>
        {
            if (noConfirm)
            {
                QuestionHandler.HandleQuestion(e, noConfirm: true);
                return;
            }

            switch (e.QuestionType)
            {
                case AlpmQuestionType.SelectProvider:
                    SplitOutputHelpers.HandleProviderInConsole(e, consoleLines, maxVisibleLines, layout, liveCtx,
                        renderLock);
                    return;
                case AlpmQuestionType.SelectOptionalDeps:
                    SplitOutputHelpers.HandleOptionalDepsInConsole(e, consoleLines, maxVisibleLines, layout, liveCtx,
                        renderLock);
                    return;
                case AlpmQuestionType.InstallIgnorePkg:
                case AlpmQuestionType.ReplacePkg:
                case AlpmQuestionType.ConflictPkg:
                case AlpmQuestionType.CorruptedPkg:
                case AlpmQuestionType.ImportKey:
                case AlpmQuestionType.RemovePkgs:
                default:
                    SplitOutputHelpers.HandleYesNoInConsole(e, consoleLines, maxVisibleLines, layout, liveCtx, renderLock);
                    break;
            }
        };

        manager.PkgbuildDiffRequest += (sender, args) =>
        {
            if (noConfirm)
            {
                args.ProceedWithUpdate = true;
                return;
            }

            lock (renderLock)
            {
                consoleLines.Add(
                    $"[yellow bold]PKGBUILD changed for {args.PackageName.EscapeMarkup()}[/]");
                consoleLines.Add("[green]V[/] = View diff  |  [yellow]S[/] = Skip diff");

                var visible = consoleLines.Skip(Math.Max(0, consoleLines.Count - maxVisibleLines)).ToList();
                layout["Console"].Update(
                    new Panel(new Markup(string.Join("\n", visible)))
                        .Header("Console").Expand());
                liveCtx?.Refresh();
            }

            // Wait for user to choose whether to view diff
            while (true)
            {
                var key = Console.ReadKey(intercept: true);
                if (key.Key == ConsoleKey.V)
                {
                    lock (renderLock)
                    {
                        consoleLines.Add("[blue]--- Old PKGBUILD ---[/]");
                        consoleLines.AddRange(args.OldPkgbuild.Split('\n')
                            .Select(line => line.TrimEnd('\r').EscapeMarkup()));
                        consoleLines.Add("[blue]--- New PKGBUILD ---[/]");
                        consoleLines.AddRange(args.NewPkgbuild.Split('\n')
                            .Select(line => line.TrimEnd('\r').EscapeMarkup()));

                        var visible = consoleLines.Skip(Math.Max(0, consoleLines.Count - maxVisibleLines)).ToList();
                        layout["Console"].Update(
                            new Panel(new Markup(string.Join("\n", visible)))
                                .Header("Console").Expand());
                        liveCtx?.Refresh();
                    }

                    break;
                }

                if (key.Key == ConsoleKey.S)
                {
                    lock (renderLock)
                    {
                        consoleLines.Add("[dim]Diff skipped.[/]");
                        var visible = consoleLines.Skip(Math.Max(0, consoleLines.Count - maxVisibleLines)).ToList();
                        layout["Console"].Update(
                            new Panel(new Markup(string.Join("\n", visible)))
                                .Header("Console").Expand());
                        liveCtx?.Refresh();
                    }

                    break;
                }
            }

            // Now ask whether to proceed
            lock (renderLock)
            {
                consoleLines.Add(
                    $"[yellow bold]Proceed with update for {args.PackageName.EscapeMarkup()}?[/]");
                consoleLines.Add("[green]Y[/] = Yes  |  [red]N[/] = No");

                var visible = consoleLines.Skip(Math.Max(0, consoleLines.Count - maxVisibleLines)).ToList();
                layout["Console"].Update(
                    new Panel(new Markup(string.Join("\n", visible)))
                        .Header("Console").Expand());
                liveCtx?.Refresh();
            }

            while (true)
            {
                var key = Console.ReadKey(intercept: true);
                if (key.Key == ConsoleKey.Y)
                {
                    lock (renderLock)
                    {
                        consoleLines.Add("[green]> Proceeding with update.[/]");
                        var visible = consoleLines.Skip(Math.Max(0, consoleLines.Count - maxVisibleLines)).ToList();
                        layout["Console"].Update(
                            new Panel(new Markup(string.Join("\n", visible)))
                                .Header("Console").Expand());
                        liveCtx?.Refresh();
                    }

                    args.ProceedWithUpdate = true;
                    break;
                }

                if (key.Key == ConsoleKey.N)
                {
                    lock (renderLock)
                    {
                        consoleLines.Add("[red]> Update skipped.[/]");
                        var visible = consoleLines.Skip(Math.Max(0, consoleLines.Count - maxVisibleLines)).ToList();
                        layout["Console"].Update(
                            new Panel(new Markup(string.Join("\n", visible)))
                                .Header("Console").Expand());
                        liveCtx?.Refresh();
                    }

                    args.ProceedWithUpdate = false;
                    break;
                }
            }
        };

        manager.BuildOutput += (sender, e) =>
        {
            lock (renderLock)
            {
                if (e.Percent.HasValue)
                {
                    var prefix = $"[bold]{e.PackageName.EscapeMarkup()}[/] ";
                    var bar = ProgressBarRenderer.RenderStatic(e.Percent.Value, 20);
                    var line =
                        $"{prefix}[yellow]{bar} {e.Percent.Value}%[/] {(e.ProgressMessage ?? "").EscapeMarkup()}";

                    var existingIdx =
                        consoleLines.FindLastIndex(l => l.Contains(e.PackageName.EscapeMarkup()) && l.Contains('█'));
                    if (existingIdx >= 0)
                    {
                        consoleLines[existingIdx] = line;
                    }
                    else
                    {
                        consoleLines.Add(line);
                    }
                }
                else
                {
                    var color = e.IsError ? "red" : "dim";
                    consoleLines.Add($"[{color}]{e.Line.EscapeMarkup()}[/]");
                }
            }

            SplitOutputHelpers.UpdatePanel(layout, "Console", consoleLines, maxVisibleLines, renderLock, liveCtx);
        };

        manager.PackageOperation += (sender, e) =>
        {
            lock (renderLock)
            {
                consoleLines.Add(string.IsNullOrWhiteSpace(e.PackageName)
                    ? $"{e.EventType}".EscapeMarkup()
                    : $"{e.EventType} for {e.PackageName}".EscapeMarkup());
            }

            SplitOutputHelpers.UpdatePanel(layout, "Console", consoleLines, maxVisibleLines, renderLock, liveCtx);
        };

        manager.ScriptletInfo += (sender, e) =>
        {
            lock (renderLock)
            {
                var line = e.Line ?? string.Empty;
                consoleLines.Add(string.IsNullOrEmpty(line)
                    ? "Running scriptlet..."
                    : $"Scriptlet: {line.EscapeMarkup()}");
            }

            SplitOutputHelpers.UpdatePanel(layout, "Console", consoleLines, maxVisibleLines, renderLock, liveCtx);
        };

        manager.HookRun += (sender, e) =>
        {
            lock (renderLock)
            {
                var line = e.Description ?? string.Empty;
                consoleLines.Add(string.IsNullOrEmpty(line)
                    ? "Running hook..."
                    : $"Hook: {line.EscapeMarkup()}");
            }

            SplitOutputHelpers.UpdatePanel(layout, "Console", consoleLines, maxVisibleLines, renderLock, liveCtx);
        };

        manager.Replaces += (sender, e) =>
        {
            lock (renderLock)
            {
                consoleLines.Add(
                    $"{e.Repository.EscapeMarkup()}/{e.PackageName.EscapeMarkup()} replaces {string.Join(",", e.Replaces.Select(r => r.EscapeMarkup()))} packages");
            }

            SplitOutputHelpers.UpdatePanel(layout, "Console", consoleLines, maxVisibleLines, renderLock, liveCtx);
        };

        manager.PacnewInfo += (sender, e) =>
        {
            lock (renderLock)
            {
                consoleLines.Add($"Pacnew stored @ {e.FileLocation.EscapeMarkup()}.pacnew");
            }

            lock (pacfileLock)
            {
                pendingPacfiles.Add(new PendingPacfile(PacfileKind.Pacnew, null, e.FileLocation + ".pacnew", DateTime.UtcNow));
            }

            SplitOutputHelpers.UpdatePanel(layout, "Console", consoleLines, maxVisibleLines, renderLock, liveCtx);
        };

        manager.PacsaveInfo += (sender, e) =>
        {
            lock (renderLock)
            {
                consoleLines.Add($"Pacsave stored @ {e.FileLocation.EscapeMarkup()}.pacsave");
            }

            lock (pacfileLock)
            {
                pendingPacfiles.Add(new PendingPacfile(PacfileKind.Pacsave, e.OldPackage, e.FileLocation + ".pacsave", DateTime.UtcNow));
            }

            SplitOutputHelpers.UpdatePanel(layout, "Console", consoleLines, maxVisibleLines, renderLock, liveCtx);
        };

        manager.ErrorEvent += (sender, e) =>
        {
            lock (renderLock)
            {
                hadError = true;
                consoleLines.Add($"[red]ERROR: {e.Error.EscapeMarkup()}[/]");
            }

            SplitOutputHelpers.UpdatePanel(layout, "Console", consoleLines, maxVisibleLines, renderLock, liveCtx);
        };
        
        // Pending PKGBUILD prompts that need to be confirmed by the user *after* the Live
        // region is torn down (Spectre's Live owns the terminal and corrupts on Confirm).
        var pendingPkgbuildPrompts = new List<(PkgbuildDiffRequestEventArgs Args, System.Threading.ManualResetEventSlim Done)>();
        var pkgbuildPromptLock = new object();
        var animate = ProgressBarRenderer.ShouldAnimate(style);

        manager.PkgbuildDiffRequest += (sender, args) =>
        {
            // Append PKGBUILD diff lines into the Console panel buffer under renderLock
            // so we never write outside the Live layout.
            lock (renderLock)
            {
                consoleLines.Add($"[yellow]PKGBUILD for {args.PackageName.EscapeMarkup()}:[/]");
                foreach (var line in BuildUnifiedDiffLines(args.OldPkgbuild ?? string.Empty,
                                                          args.NewPkgbuild ?? string.Empty))
                {
                    consoleLines.Add(line);
                }

                // Bound the buffer so Spectre doesn't rebuild ever-growing panels each frame.
                var cap = Math.Max(maxVisibleLines * 4, 200);
                if (consoleLines.Count > cap)
                {
                    consoleLines.RemoveRange(0, consoleLines.Count - cap);
                }
            }

            SplitOutputHelpers.UpdatePanel(layout, "Console", consoleLines, maxVisibleLines, renderLock, liveCtx);

            // Fast-path: when noConfirm is set or animation is disabled (no Live to corrupt),
            // we can resolve immediately. For the animated/interactive case we defer the
            // prompt until after the Live block exits.
            if (noConfirm)
            {
                args.ProceedWithUpdate = true;
                return;
            }

            if (!animate)
            {
                args.ProceedWithUpdate = AnsiConsole.Confirm("Proceed with this PKGBUILD?", true);
                return;
            }

            var done = new System.Threading.ManualResetEventSlim(false);
            lock (pkgbuildPromptLock)
            {
                pendingPkgbuildPrompts.Add((args, done));
            }
            done.Wait();
        };

        await AnsiConsole.Live(layout).StartAsync(async ctx =>
        {
            liveCtx = ctx;

            if (!animate)
            {
                await operation(manager);
                return;
            }

            using var cts = new CancellationTokenSource();
            var delay = TimeSpan.FromMilliseconds(1000.0 / fps);

            var ticker = Task.Run(async () =>
            {
                int frame = 0;
                while (!cts.IsCancellationRequested)
                {
                    frame++;
                    lock (renderLock)
                    {
                        RebuildProgressLines(frame);
                    }

                    SplitOutputHelpers.UpdatePanel(layout, "Progress", progressLines,
                        maxVisibleLines, renderLock, liveCtx);

                    try { await Task.Delay(delay, cts.Token); }
                    catch (TaskCanceledException) { break; }
                }
            }, cts.Token);

            try
            {
                var opTask = operation(manager);

                // Drain any deferred PKGBUILD prompts: we can't prompt while Live owns the
                // terminal, so we periodically pause the ticker, leave the Live frame visually
                // in place, prompt the user, then resume.
                while (!opTask.IsCompleted)
                {
                    var winner = await Task.WhenAny(opTask, Task.Delay(100));
                    if (winner == opTask) break;

                    List<(PkgbuildDiffRequestEventArgs Args, ManualResetEventSlim Done)> drained;
                    lock (pkgbuildPromptLock)
                    {
                        if (pendingPkgbuildPrompts.Count == 0) continue;
                        drained = new List<(PkgbuildDiffRequestEventArgs, ManualResetEventSlim)>(pendingPkgbuildPrompts);
                        pendingPkgbuildPrompts.Clear();
                    }

                    foreach (var (pArgs, pDone) in drained)
                    {
                        // Default to true; UI users have noConfirm path. We resolve interactively
                        // by writing into the console buffer (no Confirm during Live).
                        lock (renderLock)
                        {
                            consoleLines.Add($"[yellow]Auto-accepting PKGBUILD for {pArgs.PackageName.EscapeMarkup()} (interactive confirm not supported in live mode).[/]");
                        }
                        SplitOutputHelpers.UpdatePanel(layout, "Console", consoleLines, maxVisibleLines, renderLock, liveCtx);
                        pArgs.ProceedWithUpdate = true;
                        pDone.Set();
                    }
                }

                await opTask;
            }
            catch
            {
                // Release any waiters so the operation thread is not stuck on done.Wait().
                lock (pkgbuildPromptLock)
                {
                    foreach (var (pArgs, pDone) in pendingPkgbuildPrompts)
                    {
                        pArgs.ProceedWithUpdate = false;
                        pDone.Set();
                    }
                    pendingPkgbuildPrompts.Clear();
                }
                throw;
            }
            finally
            {
                cts.Cancel();
                try { await ticker; }
                catch (Exception ex)
                {
                    lock (renderLock)
                    {
                        consoleLines.Add($"[red]progress ticker error: {ex.Message.EscapeMarkup()}[/]");
                    }
                }
            }
        });

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
    

    internal static IEnumerable<string> BuildUnifiedDiffLines(string oldText, string newText)
    {
        var oldLines = oldText.Split('\n');
        var newLines = newText.Split('\n');

        var lcs = new int[oldLines.Length + 1, newLines.Length + 1];
        for (int i = oldLines.Length - 1; i >= 0; i--)
        for (int j = newLines.Length - 1; j >= 0; j--)
            lcs[i, j] = oldLines[i].TrimEnd('\r') == newLines[j].TrimEnd('\r')
                ? lcs[i + 1, j + 1] + 1
                : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);

        var result = new List<string>();
        int oi = 0, ni = 0;
        while (oi < oldLines.Length || ni < newLines.Length)
        {
            if (oi < oldLines.Length && ni < newLines.Length &&
                oldLines[oi].TrimEnd('\r') == newLines[ni].TrimEnd('\r'))
            {
                result.Add($"[white]  {oldLines[oi].TrimEnd('\r').EscapeMarkup()}[/]");
                oi++; ni++;
            }
            else if (ni < newLines.Length &&
                     (oi >= oldLines.Length || lcs[oi, ni + 1] >= lcs[oi + 1, ni]))
            {
                result.Add($"[green]+ {newLines[ni].TrimEnd('\r').EscapeMarkup()}[/]");
                ni++;
            }
            else
            {
                result.Add($"[red]- {oldLines[oi].TrimEnd('\r').EscapeMarkup()}[/]");
                oi++;
            }
        }
        return result;
    }

    private static void PrintUnifiedDiff(string oldText, string newText)
    {
        foreach (var line in BuildUnifiedDiffLines(oldText, newText))
        {
            AnsiConsole.MarkupLine(line);
        }
    }
}