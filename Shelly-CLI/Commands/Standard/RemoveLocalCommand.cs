using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class RemoveLocalCommand : AsyncCommand<PackageSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, PackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeRemove(settings);
        }

        var packageList = GetValidPackageList(settings.Packages);

        if (packageList.Count == 0)
        {
            AnsiConsole.MarkupLine("[red]Error: No packages specified[/]");
            return 1;
        }

        RootElevator.EnsureRootExectuion();

        AnsiConsole.MarkupLine(
            $"[yellow]Packages to remove:[/] {string.Join(", ", packageList.Select(p => p.EscapeMarkup()))}");

        if (!settings.NoConfirm && !AnsiConsole.Confirm("Do you want to proceed?"))
        {
            AnsiConsole.MarkupLine("[yellow]Operation cancelled.[/]");
            return 0;
        }

        var result = await LocalManager.RemoveBinaryPackages(packageList, uiMode: false);
        if (!result)
        {
            AnsiConsole.MarkupLine("[red]Removal failed. See errors above.[/]");
            return 1;
        }

        AnsiConsole.MarkupLine("[green]Packages removed successfully![/]");
        return 0;
    }

    private static async Task<int> HandleUiModeRemove(PackageSettings settings)
    {
        var packageList = GetValidPackageList(settings.Packages);

        if (packageList.Count == 0)
        {
            await Console.Error.WriteLineAsync("Error: No packages specified");
            return 1;
        }

        await Console.Error.WriteLineAsync($"Removing packages: {string.Join(", ", packageList)}");

        var result = await LocalManager.RemoveBinaryPackages(packageList, uiMode: true);
        if (!result)
        {
            await Console.Error.WriteLineAsync("Removal failed.");
            return 1;
        }

        await Console.Error.WriteLineAsync("Packages removed successfully!");
        return 0;
    }

    private static List<string> GetValidPackageList(string[] packages)
    {
        return packages
            .Where(p => p.StartsWith(LocalManager.InstallDir, StringComparison.OrdinalIgnoreCase))
            .Where(p => !p.TrimEnd('/').Equals(LocalManager.InstallDir, StringComparison.OrdinalIgnoreCase))
            .ToList();
    }
}
