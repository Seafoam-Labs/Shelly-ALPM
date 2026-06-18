using System.CommandLine;
using PackageManager.Flatpak;
using PackageManager.Ostree;
using PackageManager.Ostree.Enums;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Flatpak;

public class Repair : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("repair", "Repairs Flatpak Installation");

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Repair();
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

        var flatpakManager = new FlatpakManager();
        var ostreeManager = new OstreeManager();

        List<OstreeRepositoryRef> invalidRefs = [];

        var repositories = flatpakManager.GetRepositoryPaths();

        foreach (var repo in repositories)
        {
            var refs = ostreeManager.ListRefs(repo);
            if (refs.Count == 0) continue;

            console.WriteLine(Colorize($"Packages in repo:{repo}", ConsoleColor.Yellow));
            foreach (var reference in refs)
                console.WriteLine($"{Colorize(reference.Remote, ConsoleColor.Green)}: {reference.Ref}");
        }

        var installed = flatpakManager.SearchInstalled();
        var installedRefs = installed.Select(x => x.FullRef).ToHashSet();

        foreach (var repo in repositories)
        {
            var refs = ostreeManager.ListRefs(repo);
            foreach (var reference in refs)
                if (!installedRefs.Contains(reference.FullRef))
                    console.WriteLine(Colorize($"Orphan ref: {reference.FullRef}", ConsoleColor.Red));
        }

        foreach (var repo in repositories)
        {
            var refs = ostreeManager.ListRefs(repo);
            foreach (var reference in refs)
            {
                var commit = ostreeManager.GetCommitForRef(repo, reference.FullRef)!;
                reference.Commit = commit;

                if (string.IsNullOrWhiteSpace(commit))
                {
                    console.WriteLine(Colorize($"Missing commit: {reference.FullRef}", ConsoleColor.Red));
                    invalidRefs.Add(reference);
                    continue;
                }

                var fsck = ostreeManager.FsckCommit(repo, commit);
                if (fsck.Status == FsckStatus.Ok) continue;

                console.WriteLine(Colorize($"FSCK FAIL: {reference.FullRef} ({fsck.Status})", ConsoleColor.Red));
                invalidRefs.Add(reference);

                if (fsck.MissingObjects.Count > 0)
                    console.WriteLine($"  Missing: {string.Join(", ", fsck.MissingObjects)}");
                if (fsck.InvalidObjects.Count > 0)
                    console.WriteLine($"  Invalid: {string.Join(", ", fsck.InvalidObjects)}");
                if (!string.IsNullOrWhiteSpace(fsck.ErrorMessage))
                    console.WriteLine($"  Error: {fsck.ErrorMessage}");
            }
        }

        foreach (var reference in invalidRefs)
        {
            var installedRef = installed.FirstOrDefault(x => x.FullRef == reference.FullRef);
            if (installedRef == null) continue;

            var uninstallResult = flatpakManager.UninstallAppFromRef(installedRef);
            console.WriteLine(uninstallResult
                ? Colorize($"Uninstalled: {reference.FullRef}", ConsoleColor.Green)
                : Colorize($"Failed uninstall: {reference.FullRef}", ConsoleColor.Red));
        }

        foreach (var repo in repositories)
        {
            console.WriteLine(Colorize($"Pruning repository: {repo}", ConsoleColor.Yellow));
            var result = ostreeManager.Prune(repo);
            if (result.Success)
            {
                if (result.ObjectsPruned > 0)
                    console.WriteLine(Colorize(
                        $"Pruned: {result.ObjectsPruned}/{result.ObjectsTotal} objects ({result.PrunedBytes} bytes)",
                        ConsoleColor.Green));
            }
            else
            {
                console.WriteLine(Colorize($"Prune failed: {result.ErrorMessage}", ConsoleColor.Red));
            }
        }

        var currentRefs = repositories
            .SelectMany(repo => ostreeManager.ListRefs(repo))
            .Select(x => x.FullRef)
            .ToHashSet();

        foreach (var installedRef in installed)
        {
            if (currentRefs.Contains(installedRef.FullRef)) continue;

            console.WriteLine(Colorize($"Install required: {installedRef.FullRef}", ConsoleColor.Yellow));
            var success = flatpakManager.FlatpakRepairRestore(installedRef);
            console.WriteLine(success
                ? Colorize($"Installed: {installedRef.FullRef}", ConsoleColor.Green)
                : Colorize($"Failed install: {installedRef.FullRef}", ConsoleColor.Red));
        }
    }

    public override ValueTask ExecuteUiMode()
    {
        var hasErrors = false;

        var flatpakManager = new FlatpakManager();
        var ostreeManager = new OstreeManager();

        List<OstreeRepositoryRef> invalidRefs = [];

        UiFrames.Info("Working on Flatpak installation...");

        var repositories = flatpakManager.GetRepositoryPaths();

        var installed = flatpakManager.SearchInstalled();
        var installedRefs = installed.Select(x => x.FullRef).ToHashSet();

        foreach (var repo in repositories)
        {
            var refs = ostreeManager.ListRefs(repo);
            foreach (var reference in refs)
                if (!installedRefs.Contains(reference.FullRef))
                    UiFrames.Error($"Orphan ref: {reference.FullRef}");
        }

        foreach (var repo in repositories)
        {
            var refs = ostreeManager.ListRefs(repo);
            foreach (var reference in refs)
            {
                var commit = ostreeManager.GetCommitForRef(repo, reference.FullRef)!;
                reference.Commit = commit;

                if (string.IsNullOrWhiteSpace(commit))
                {
                    UiFrames.Error($"Missing commit: {reference.FullRef}");
                    invalidRefs.Add(reference);
                    continue;
                }

                var fsck = ostreeManager.FsckCommit(repo, commit);
                if (fsck.Status != FsckStatus.Ok) invalidRefs.Add(reference);
            }
        }

        foreach (var reference in invalidRefs)
        {
            var installedRef = installed.FirstOrDefault(x => x.FullRef == reference.FullRef);
            if (installedRef == null) continue;

            var uninstallResult = flatpakManager.UninstallAppFromRef(installedRef);
            if (!uninstallResult) hasErrors = true;

            UiFrames.Info(uninstallResult
                ? $"Uninstalled: {reference.FullRef}"
                : $"Failed uninstall: {reference.FullRef}");
        }

        foreach (var repo in repositories)
        {
            var result = ostreeManager.Prune(repo);
            if (result.Success && result.ObjectsPruned > 0)
                UiFrames.Info($"Pruning repository: {repo}");
        }

        var currentRefs = repositories
            .SelectMany(repo => ostreeManager.ListRefs(repo))
            .Select(x => x.FullRef)
            .ToHashSet();

        foreach (var installedRef in installed)
        {
            if (currentRefs.Contains(installedRef.FullRef)) continue;

            UiFrames.Info($"Install required: {installedRef.Name}");
            var success = flatpakManager.FlatpakRepairRestore(installedRef);
            UiFrames.Info(success ? $"Installed: {installedRef.Name}" : $"Failed install: {installedRef.Name}");
            if (!success) hasErrors = true;
        }

        if (!hasErrors)
            UiFrames.Info("Flatpak installation repaired");
        else
            UiFrames.Info("Flatpak repair completed with errors", Shelly.Utilities.Eventing.AlpmEvents.TransactionFailed);

        return ValueTask.CompletedTask;
    }
}
