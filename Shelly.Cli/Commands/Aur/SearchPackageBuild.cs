using System.CommandLine;
using System.Text.Json;
using PackageManager.Aur;
using Shelly.Cli.Interactions;
using Shelly.Cli.Models.Aur;

namespace Shelly.Cli.Commands.Aur;

public class SearchPackageBuild : GlobalSettingsCommand
{
    private string[] Packages { get; set; } = [];

    public static Command Create()
    {
        var packages = new Argument<string[]>("packages")
            { Description = "One or more AUR package names to fetch the PKGBUILD for", Arity = ArgumentArity.OneOrMore };

        var command = new Command("search-pkgbuild", "Fetch and display the PKGBUILD of AUR packages")
        {
            packages
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new SearchPackageBuild
            {
                Packages = parseResult.GetValue(packages) ?? []
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (Packages.Length == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("No packages specified.", ConsoleColor.Red));
            return;
        }

        using var manager = new AurPackageManager();
        await manager.Initialize();

        var builds = new List<PackageBuild>(Packages.Length);

        foreach (var package in Packages)
        {
            var pkgbuild = await manager.FetchPkgbuildAsync(package);
            builds.Add(new PackageBuild(package, pkgbuild));
        }

        if (UiMode)
        {
            JsonPackFrame.WriteToStdout(builds);
            return;
        }

        if (JsonOutput)
        {
            console.WriteLine(JsonSerializer.Serialize(builds, ShellyCliJsonContext.Default.ListPackageBuild));
            return;
        }

        foreach (var build in builds)
        {
            if (build.PkgBuild is null)
            {
                console.WriteLine(AnsiUtilities.Colorize($"Failed to get pkgbuild for: {build.PkgBuild}", ConsoleColor.Red));
                continue;
            }

            console.WriteLine(AnsiUtilities.Colorize($"Package build for: {build.Name}", ConsoleColor.Yellow));
            console.WriteLine(build.Name);
        }
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;
}
