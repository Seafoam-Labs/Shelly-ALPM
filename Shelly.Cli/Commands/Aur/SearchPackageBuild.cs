using System.CommandLine;
using PackageManager.Aur;
using Shelly.Cli.Interactions;

namespace Shelly.Cli.Commands.Aur;

public class SearchPackageBuild : GlobalSettingsCommand
{
    private string[] Package { get; set; } = Array.Empty<string>();

    public static Command Create()
    {
        var package = new Argument<string[]>("packages")
            { Description = "One or more AUR package names to fetch the PKGBUILD for", Arity = ArgumentArity.OneOrMore };

        var command = new Command("search-pkgbuild", "Fetch and display the PKGBUILD of AUR packages")
        {
            package
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new SearchPackageBuild
            {
                Package = parseResult.GetValue(package) ?? Array.Empty<string>()
            };
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        return command;
    }

    public override async ValueTask ExecuteAsync(IShellyConsole console)
    {
        if (Package.Length == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("No packages specified.", ConsoleColor.Red));
            return;
        }

        using var manager = new AurPackageManager();
        await manager.Initialize();

        if (UiMode || JsonOutput)
        {
            var builds = new List<PackageBuild>();
            foreach (var package in Package)
                builds.Add(new PackageBuild(package, await manager.FetchPkgbuildAsync(package)));

            JsonPackFrame.WriteToStdout(builds);
            return;
        }

        foreach (var package in Package)
        {
            var pkgbuild = await manager.FetchPkgbuildAsync(package);

            if (pkgbuild == null)
            {
                console.WriteLine(AnsiUtilities.Colorize($"Failed to get pkgbuild for: {package}", ConsoleColor.Red));
            }
            else
            {
                console.WriteLine(AnsiUtilities.Colorize($"Package build for: {package}", ConsoleColor.Yellow));
                console.WriteLine(pkgbuild);
            }
        }
    }

    public override ValueTask ExecuteUiMode() => ValueTask.CompletedTask;

    private sealed record PackageBuild(string Package, string? Build);
}
