using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.Linq;
using PackageManager.Alpm;
using PackageManager.Aur;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurInstallCommand : AsyncCommand<AurInstallSettings>
{
    public override async Task<int> ExecuteAsync([NotNull] CommandContext context, [NotNull] AurInstallSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeInstall(settings);
        }
        
        AurPackageManager? manager = null;
        if (settings.Packages.Length == 0)
        {
            AnsiConsole.MarkupLine("[red]No packages specified.[/]");
            return 1;
        }

        var packageList = settings.Packages.ToList();

        AnsiConsole.MarkupLine($"[yellow]AUR packages to install:[/] {string.Join(", ", packageList)}");

        if (!Program.IsUiMode)
        {
            if (!AnsiConsole.Confirm("Do you want to proceed?"))
            {
                AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
                return 0;
            }
        }

        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true);
            object renderLock = new();

            manager.PackageProgress += (sender, args) =>
            {
                lock (renderLock)
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

                    AnsiConsole.MarkupLine(
                        $"[{statusColor}][[{args.CurrentIndex}/{args.TotalCount}]] {args.PackageName}: {args.Status}[/]" +
                        (args.Message != null ? $" - {args.Message.EscapeMarkup()}" : ""));
                }
            };

            manager.Question += (sender, args) =>
            {
                lock (renderLock)
                {
                    AnsiConsole.WriteLine();
                    // Handle SelectProvider and ConflictPkg differently - they need a selection, not yes/no
                    QuestionHandler.HandleQuestion(args,Program.IsUiMode,settings.NoConfirm);
                }
            };
            

            if (settings.BuildDepsOn)
            {
                if (settings.Packages.Length > 1)
                {
                    AnsiConsole.MarkupLine("[yellow]Cannot build dependencies for multiple packages at once.[/]");
                    return 0;
                }

                if (settings.MakeDepsOn)
                {
                    AnsiConsole.MarkupLine("[yellow]Installing dependencies (including make dependencies)...[/]");
                    await manager.InstallDependenciesOnly(packageList.First(), true);
                    AnsiConsole.MarkupLine("[green]Dependencies installed successfully![/]");
                    return 0;
                }

                AnsiConsole.MarkupLine("[yellow]Installing dependencies...[/]");
                await manager.InstallDependenciesOnly(packageList.First(), false);
                AnsiConsole.MarkupLine("[green]Dependencies installed successfully![/]");
                return 0;
            }

            AnsiConsole.MarkupLine($"[yellow]Installing AUR packages: {string.Join(", ", settings.Packages)}[/]");
            var progressTable = new Table().AddColumns("Package", "Progress", "Status", "Stage");
            await AnsiConsole.Live(progressTable).AutoClear(false)
                .StartAsync(async ctx =>
                {
                    var rowIndex = new Dictionary<string, int>();

                    manager.Progress += (sender, args) =>
                    {
                        lock (renderLock)
                        {
                            var name = args.PackageName ?? "unknown";
                            var pct = args.Percent ?? 0;
                            var bar = new string('█', pct / 5) + new string('░', 20 - pct / 5);
                            var actionType = args.ProgressType;

                            if (!rowIndex.TryGetValue(name, out var idx))
                            {
                                progressTable.AddRow(
                                    $"[blue]{Markup.Escape(name)}[/]",
                                    $"[green]{bar}[/]",
                                    $"{pct}%",
                                    $"{actionType}"
                                );
                                rowIndex[name] = rowIndex.Count;
                            }
                            else
                            {
                                progressTable.UpdateCell(idx, 1, $"[green]{bar}[/]");
                                progressTable.UpdateCell(idx, 2, $"{pct}%");
                                progressTable.UpdateCell(idx, 3, $"{actionType}");
                            }

                            ctx.Refresh();
                        }
                    };
                    await manager.InstallPackages(packageList);
                });
            var missingPackages = await GetMissingPackages(manager, packageList);
            if (missingPackages.Count > 0)
            {
                AnsiConsole.MarkupLine(
                    $"[red]Installation failed:[/] {string.Join(", ", missingPackages)}");
                return 1;
            }

            AnsiConsole.MarkupLine("[green]Installation complete.[/]");

           return 0;
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Installation failed:[/] {ex.Message.EscapeMarkup()}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    private static async Task<int> HandleUiModeInstall(AurInstallSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            Console.Error.WriteLine("Error: No packages specified");
            return 1;
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true);

            var packageList = settings.Packages.ToList();

            // Handle package progress events
            manager.PackageProgress += (sender, args) =>
            {
                Console.Error.WriteLine($"[{args.CurrentIndex}/{args.TotalCount}] {args.PackageName}: {args.Status}" +
                    (args.Message != null ? $" - {args.Message}" : ""));
            };

            // Handle progress events
            manager.Progress += (sender, args) =>
            {
                Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%");
            };

            // Handle questions
            manager.Question += (sender, args) =>
            {
                QuestionHandler.HandleQuestion(args, true, settings.NoConfirm);
            };

            // Handle build dependencies only mode
            if (settings.BuildDepsOn)
            {
                if (settings.Packages.Length > 1)
                {
                    Console.Error.WriteLine("Cannot build dependencies for multiple packages at once.");
                    return 1;
                }

                if (settings.MakeDepsOn)
                {
                    Console.Error.WriteLine("Installing dependencies (including make dependencies)...");
                    await manager.InstallDependenciesOnly(packageList.First(), true);
                    Console.Error.WriteLine("Dependencies installed successfully!");
                    return 0;
                }

                Console.Error.WriteLine("Installing dependencies...");
                await manager.InstallDependenciesOnly(packageList.First(), false);
                Console.Error.WriteLine("Dependencies installed successfully!");
                return 0;
            }

            Console.Error.WriteLine($"Installing AUR packages: {string.Join(", ", packageList)}");
            await manager.InstallPackages(packageList);
            var missingPackages = await GetMissingPackages(manager, packageList);
            if (missingPackages.Count > 0)
            {
                Console.Error.WriteLine(
                    $"Installation failed: Failed to install AUR package(s): {string.Join(", ", missingPackages)}");
                return 1;
            }

            Console.Error.WriteLine("Installation complete.");

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Installation failed: {ex.Message}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    private static async Task<List<string>> GetMissingPackages(AurPackageManager manager, List<string> packageList)
    {
        var installedPackages = await manager.GetInstalledPackages();
        var installedPackageNames = installedPackages
            .Select(package => package.Name)
            .ToHashSet(StringComparer.Ordinal);

        return packageList
            .Where(packageName => !installedPackageNames.Contains(packageName))
            .ToList();
    }
}
