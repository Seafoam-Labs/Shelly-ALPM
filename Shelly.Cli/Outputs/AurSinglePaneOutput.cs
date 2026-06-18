using PackageManager.Alpm;
using PackageManager.Alpm.Pacfile;
using PackageManager.Aur;
using Pastel;
using Shelly.Cli.Commands;
using Shelly.Cli.Interactions;
using Shelly.Cli.Models.Pacfile;
using Shelly.Utilities;

namespace Shelly.Cli.Outputs;

public static class AurSinglePaneOutput
{
    public static async Task<bool> Output(
        IShellyConsole console,
        AurPackageManager manager,
        Func<AurPackageManager, Task> operation,
        bool noConfirm = false)
    {
        var ansi = AnsiUtilities.SupportsAnsi;

        var cfg = ConfigManager.ReadConfig();
        using var region = BottomBarRegion.CreateFromConfig(cfg, console);

        var hadError = false;
        var pendingPacfiles = new List<PendingPacfile>();
        var pacfileLock = new object();

        string Color(string text, ConsoleColor color) => ansi ? text.Pastel(color) : text;

        manager.InformationalEvent += (_, args) =>
        {
            var stage = args.EventType switch
            {
                AlpmEventType.AurDownloadStart => ("downloading", ConsoleColor.Yellow, false),
                AlpmEventType.AurBuildStart => ("building", ConsoleColor.Blue, false),
                AlpmEventType.AurInstallStart => ("installing", ConsoleColor.Cyan, false),
                AlpmEventType.AurCleanupStart => ("cleaning", ConsoleColor.Magenta, false),
                AlpmEventType.AurPackageCompleted => ("completed", ConsoleColor.Green, true),
                AlpmEventType.AurPackageFailed => ("failed", ConsoleColor.Red, true),
                _ => (null, ConsoleColor.Gray, false)
            };

            if (stage.Item1 != null)
            {
                var pkg = args.PackageName ?? "";
                var idx = args.CurrentIndex ?? 0;
                var total = args.TotalCount ?? 0;
                var msg = !string.IsNullOrEmpty(args.Message) ? $" - {args.Message}" : "";
                var line = Color($":: ({idx}/{total}) {stage.Item1} {pkg}{msg}", stage.Item2);

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
                        region.WriteLine(Color($"==> Making package: {pkg}", ConsoleColor.Green));
                }

                return;
            }

            if (args.EventType is AlpmEventType.AurBuildOutput or AlpmEventType.AurBuildError)
            {
                var pkg = args.PackageName ?? "";
                region.FinalizeStickiesWhere(k => k.Source == "build" && k.Package == pkg);
                var line = args.Message ?? "";
                if (args.EventType == AlpmEventType.AurBuildError)
                    region.WriteLine(Color(line, ConsoleColor.Red));
                else if (line.StartsWith("error:", StringComparison.OrdinalIgnoreCase))
                    region.WriteLine(Color(line, ConsoleColor.Red));
                else if (line.StartsWith("warning:", StringComparison.OrdinalIgnoreCase))
                    region.WriteLine(Color(line, ConsoleColor.Yellow));
                else if (line.StartsWith("==>"))
                    region.WriteLine(Color(line, ConsoleColor.Green));
                else if (line.StartsWith("  ->"))
                    region.WriteLine(Color(line, ConsoleColor.Blue));
                else
                    region.WritePlain(line);
            }
        };

        manager.Progress += (_, e) =>
        {
            var name = e.PackageName ?? "unknown";
            var pct = e.Percent ?? 0;

            if (e.ProgressType == AlpmProgressType.MakepkgBuild)
            {
                var bar = ProgressBarRenderer.RenderStatic(pct, 20);
                var msgPart = e.Message ?? "";
                var rendered = Color($"{name} {bar} {pct,3}% {msgPart}", ConsoleColor.Yellow);
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
            hadError = true;
            region.WriteLine(Color($"error: {e.Error}", ConsoleColor.Red));
        };

        manager.Question += (_, e) =>
        {
            region.RunInteractive(() => QuestionHandler.HandleQuestion(e, uiMode: false, noConfirm: noConfirm));
        };

        manager.PkgbuildDiffRequest += (_, args) =>
        {
            region.RunInteractive(() =>
            {
                QuestionHandler.HandleQuestion(args, false, noConfirm);
                if (!args.ProceedWithUpdate)
                    region.WriteLine(Color("Cancelled because of pkgbuild diff.", ConsoleColor.Yellow));
            });
        };

        region.WriteLine(Color(":: Synchronizing package databases...", ConsoleColor.White));

        try
        {
            await operation(manager);
        }
        catch (Exception ex)
        {
            hadError = true;
            region.WriteLine(Color($"error: {ex.Message}", ConsoleColor.Red));
        }

        region.WriteLine(hadError
            ? Color(":: Transaction failed.", ConsoleColor.Red)
            : Color(":: Transaction complete.", ConsoleColor.Green));

        region.Dispose();

        try
        {
            await PacfileFlusher.FlushAsync(pendingPacfiles, pacfileLock);
        }
        catch (Exception ex)
        {
            console.Output.WriteLine(Color($"warning: failed to store pacfiles: {ex.Message}", ConsoleColor.Yellow));
        }

        return !hadError;
    }
}
