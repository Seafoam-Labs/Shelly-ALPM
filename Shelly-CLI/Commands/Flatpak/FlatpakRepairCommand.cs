using System.Diagnostics.CodeAnalysis;
using PackageManager.Flatpak;
using PackageManager.Flatpak.Events;
using PackageManager.Ostree;
using PackageManager.Ostree.Enums;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Flatpak;

public class FlatpakRepair : Command
{
    public EventHandler<FlatpakEventArgs> FlatpakEvent;

    public override int Execute([NotNull] CommandContext context)
    {
        
        if (Program.IsUiMode)
        {
            return HandleUiModeRepair();
        }
        
        var flatpakManager = new FlatpakManager();
        var ostreeManager = new OstreeManager();
        var status = AnsiConsole.Status();

        List<OstreeRepositoryRef> invalidRefs = [];
        List<OstreeRepositoryRef> validRefs = [];
        
        // Step 1 - Scan all locally available refs, removing any that don't correspond to a deployed ref.

        var repositories = flatpakManager.GetRepositoryPaths();
        
        // Testing mechanism to see if it works.
        foreach (var repo in repositories)
        {
            var refs = ostreeManager.ListRefs(repo);

            if (refs.Count == 0)
            {
                continue;
            }
            
            var tree = new Tree(
                $"[yellow]Packages in repo:{repo}[/]");

            foreach (var reference in refs)
            {
                tree.AddNode(
                    $"[green]{reference.Remote}[/]: {reference.Ref}");
            }

            AnsiConsole.Write(tree);
            
        }

        var installed = flatpakManager.SearchInstalled();
        var installedRefs =
            installed
                .Select(x => x.FullRef)
                .ToHashSet();

        foreach (var repo in repositories)
        {
            var refs =
                ostreeManager.ListRefs(repo);

            foreach (var reference in refs)
            {
                if (!installedRefs.Contains(
                        reference.FullRef))
                {
                    AnsiConsole.MarkupLine(
                        $"[red]Orphan ref:[/] {reference.FullRef}");
                }
            }
        }
        
        // Step 2 - Verify each commit they point to, removing any invalid objects and noting any missing objects.

        foreach (var repo in repositories)
        {
            var refs = ostreeManager.ListRefs(repo);

            foreach (var reference in refs)
            {
                var commit = ostreeManager.GetCommitForRef(repo, reference.FullRef)!;

                reference.Commit = commit;
                
                if (string.IsNullOrWhiteSpace(commit))
                {
                    AnsiConsole.MarkupLine(
                        $"[red]Missing commit:[/] {reference.FullRef}");
                    
                    invalidRefs.Add(reference);
                    continue;
                }

                var fsck = ostreeManager.FsckCommit(repo, commit);

                if (fsck.Status == FsckStatus.Ok)
                {
                    
                    validRefs.Add(reference);
                }
                else
                {
                    AnsiConsole.MarkupLine(
                        $"[red]FSCK FAIL:[/] {reference.FullRef} ({fsck.Status})");
                    
                    invalidRefs.Add(reference);

                    if (fsck.MissingObjects.Count > 0)
                    {
                        AnsiConsole.MarkupLine(
                            $"  Missing: {string.Join(", ", fsck.MissingObjects)}");
                    }

                    if (fsck.InvalidObjects.Count > 0)
                    {
                        AnsiConsole.MarkupLine(
                            $"  Invalid: {string.Join(", ", fsck.InvalidObjects)}");
                    }

                    if (!string.IsNullOrWhiteSpace(fsck.ErrorMessage))
                    {
                        AnsiConsole.MarkupLine(
                            $"  Error: {fsck.ErrorMessage}");
                    }
                }
            }
        }        
        
        // Step 3 - Remove any refs that had an invalid object, and any non-partial refs that had missing objects.

        foreach (var reference in invalidRefs)
        {
            var installedRef = installed.FirstOrDefault(
                x => x.FullRef == reference.FullRef);

            if (installedRef != null)
            {
                var uninstallResult =
                    flatpakManager.UninstallAppFromRef(
                        installedRef);

                AnsiConsole.MarkupLine(
                    uninstallResult
                        ? $"[green]Uninstalled:[/] {Markup.Escape(reference.FullRef)}"
                        : $"[red]Failed uninstall:[/] {Markup.Escape(reference.FullRef)}");
            }
        }
        
        // Step 4 - Prune all objects not referenced by a ref, which gets rid of any possibly invalid non-scanned objects.
        foreach (var repo in repositories)
        {
            AnsiConsole.MarkupLine($"[yellow]Pruning repository:[/] {repo}");
            var result = ostreeManager.Prune(repo);
            if (result.Success)
            {
                if (result.ObjectsPruned > 0)
                {
                    AnsiConsole.MarkupLine(
                        $"[green]Pruned:[/] {result.ObjectsPruned}/{result.ObjectsTotal} objects ({result.PrunedBytes} bytes)");
                }
            }
            else
            {
                AnsiConsole.MarkupLine(
                    $"[red]Prune failed:[/] {result.ErrorMessage}");
            }        
        }
        
        // Step 5 - Enumerate all deployed refs and re-install any that are not in the repo (or are partial for a non-subdir deploy).
        
        var currentRefs =
            repositories
                .SelectMany(repo => ostreeManager.ListRefs(repo))
                .Select(x => x.FullRef)
                .ToHashSet();

        foreach (var installedRef in installed)
        {
            
            if (currentRefs.Contains(installedRef.FullRef))
            {
                continue;
            }
            
            AnsiConsole.MarkupLine(
                $"[yellow]Install required:[/] {installedRef.FullRef}");

            var success =
                flatpakManager.FlatpakRepairRestore(installedRef);

            if (success)
            {
                AnsiConsole.MarkupLine(
                    $"[green]Installed:[/] {installedRef.FullRef}");
            }
            else
            {
                AnsiConsole.MarkupLine(
                    $"[red]Failed install:[/] {installedRef.FullRef}");
            }
        }
        
        return 0;
    }
    
    private int HandleUiModeRepair()
    {
        var hasErrors = false;
        
        var flatpakManager = new FlatpakManager();
        var ostreeManager = new OstreeManager();

        List<OstreeRepositoryRef> invalidRefs = [];
        List<OstreeRepositoryRef> validRefs = [];
        
        // Step 1 - Scan all locally available refs, removing any that don't correspond to a deployed ref.

        
        FlatpakEvent?.Invoke(this,
            new FlatpakEventArgs(FlatpakEventEnum.Information, $"Working on Flatpak installation..."));
        
        var repositories = flatpakManager.GetRepositoryPaths();

        var installed = flatpakManager.SearchInstalled();
        var installedRefs =
            installed
                .Select(x => x.FullRef)
                .ToHashSet();

        foreach (var repo in repositories)
        {
            var refs =
                ostreeManager.ListRefs(repo);

            foreach (var reference in refs)
            {
                if (!installedRefs.Contains(
                        reference.FullRef))
                {
                    FlatpakEvent?.Invoke(this,
                        new FlatpakEventArgs(FlatpakEventEnum.Error, 
                            $"Orphan ref: {reference.FullRef}"));
                }
            }
        }
        
        // Step 2 - Verify each commit they point to, removing any invalid objects and noting any missing objects.

        foreach (var repo in repositories)
        {
            var refs = ostreeManager.ListRefs(repo);

            foreach (var reference in refs)
            {
                var commit = ostreeManager.GetCommitForRef(repo, reference.FullRef)!;

                reference.Commit = commit;
                
                if (string.IsNullOrWhiteSpace(commit))
                {
                    
                    FlatpakEvent?.Invoke(this,
                        new FlatpakEventArgs(FlatpakEventEnum.Error, 
                            $"Missing commit: {reference.FullRef}"));
                    
                    invalidRefs.Add(reference);
                    continue;
                }

                var fsck = ostreeManager.FsckCommit(repo, commit);

                if (fsck.Status == FsckStatus.Ok)
                {
                    
                    validRefs.Add(reference);
                }
                else
                {
                    invalidRefs.Add(reference);
                }
            }
        }        
        
        // Step 3 - Remove any refs that had an invalid object, and any non-partial refs that had missing objects.

        foreach (var reference in invalidRefs)
        {
            var installedRef = installed.FirstOrDefault(
                x => x.FullRef == reference.FullRef);

            if (installedRef != null)
            {
                var uninstallResult =
                    flatpakManager.UninstallAppFromRef(
                        installedRef);
                
                if (!uninstallResult)
                {
                    hasErrors = true;
                }
                
                var message = uninstallResult
                    ? $"Uninstalled: {reference.FullRef}"
                    : $"Failed uninstall: {reference.FullRef}";
                
                FlatpakEvent?.Invoke(
                    this,
                    new FlatpakEventArgs(
                        FlatpakEventEnum.Information,
                        message
                    )
                );
                
                
            }
        }
        
        // Step 4 - Prune all objects not referenced by a ref, which gets rid of any possibly invalid non-scanned objects.
        foreach (var repo in repositories)
        {
            var result = ostreeManager.Prune(repo);

            if (result.Success)
            {
                if (result.ObjectsPruned > 0)
                {
                    FlatpakEvent?.Invoke(this,
                        new FlatpakEventArgs(FlatpakEventEnum.Information, 
                            $"Pruning repository: {repo}"));
                }

            }
            
        }
        
        // Step 5 - Enumerate all deployed refs and re-install any that are not in the repo (or are partial for a non-subdir deploy).
        
        var currentRefs =
            repositories
                .SelectMany(repo => ostreeManager.ListRefs(repo))
                .Select(x => x.FullRef)
                .ToHashSet();

        foreach (var installedRef in installed)
        {
            
            if (currentRefs.Contains(installedRef.FullRef))
            {
                continue;
            }

            FlatpakEvent?.Invoke(this,
                new FlatpakEventArgs(FlatpakEventEnum.Information, 
                    $"Install required: {installedRef.Name}"));
            
            var success =
                flatpakManager.FlatpakRepairRestore(installedRef);

            var message = success 
                ? $"Installed: {installedRef.Name}"
                : $"Failed install: {installedRef.Name}";

            FlatpakEvent?.Invoke(
                this,
                new FlatpakEventArgs(
                    FlatpakEventEnum.Information,
                    message
                )
            );

            if (!success)
            {
                hasErrors = true;
            }
        }

        if (!hasErrors)
        {
            FlatpakEvent?.Invoke(
                this,
                new FlatpakEventArgs(
                    FlatpakEventEnum.Information,
                    "Flatpak installation repaired"
                )
            );
            return 0;
        }
        
        FlatpakEvent?.Invoke(
            this,
            new FlatpakEventArgs(
                FlatpakEventEnum.Warning,
                "Flatpak repair completed with errors"
            )
        );
        return 0;
    }

    
}