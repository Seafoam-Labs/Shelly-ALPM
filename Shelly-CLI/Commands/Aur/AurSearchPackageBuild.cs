using System.Diagnostics.CodeAnalysis;
using System.Text.Json;
using PackageManager.Aur;
using PackageManager.Wire;
using Shelly_CLI.Commands.Aur.Models;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Aur;

public class AurSearchPackageBuild : AsyncCommand<AurPackageSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, AurPackageSettings settings)
    {
        if (Program.IsUiMode)
        {
            return await HandleUiModeListPackageBuilds(settings);
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize();

            foreach (var package in settings.Packages)
            {
                var pkgbuild = manager.FetchPkgbuildAsync(package).GetAwaiter().GetResult();

                if (pkgbuild == null)
                {
                    AnsiConsole.MarkupLine($"[red]Failed to get pkgbuild for: {package.EscapeMarkup()}[/]");
                }
                else
                {
                    AnsiConsole.MarkupLine($"[yellow]Package build for: {package.EscapeMarkup()}[/]");
                    AnsiConsole.MarkupLine($"{pkgbuild.EscapeMarkup()}");
                }
            }

            return 0;
        }
        catch (Exception ex)
        {
            AnsiConsole.MarkupLine($"[red]Failed to get pkgbuild[/] {ex.Message.EscapeMarkup()}");
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }

    private static async Task<int> HandleUiModeListPackageBuilds(AurPackageSettings settings)
    {
        if (settings.Packages.Length == 0)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "No packages specified"));
            return 1;
        }

        AurPackageManager? manager = null;
        try
        {
            manager = new AurPackageManager();
            await manager.Initialize(root: true);

            var packageBuild = (from package in settings.Packages
                let pkgbuild = manager.FetchPkgbuildAsync(package).GetAwaiter().GetResult()
                select new PackageBuild(package, pkgbuild)).ToList();

            JsonPackFrame.WriteToStdout(packageBuild);
            return 0;
        }
        catch (Exception ex)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, $"Failed to fetch pkgbuild: {ex.Message}"));
            return 1;
        }
        finally
        {
            manager?.Dispose();
        }
    }
}