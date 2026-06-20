using System.CommandLine;
using PackageManager.Alpm;
using PackageManager.Local;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using static System.CommandLine.ArgumentArity;
using static Shelly.Cli.Interactions.AnsiUtilities;

namespace Shelly.Cli.Commands.Standard;

public class Remove : GlobalSettingsCommand
{
    private bool Cascade { get; set; }

    private bool OptDeps { get; set; }

    private bool Ripple { get; set; }

    private bool RemoveConfig { get; set; }

    private bool Local { get; set; }

    private string[] Packages { get; set; } = [];

    public static Command Create()
    {
        var cascade = new Option<bool>("--cascade", "-c")
        {
            Description = "Removes all things the removed package(s) are dependent on that have no other uses (default: true)",
            DefaultValueFactory = _ => true
        };
        var optDeps = new Option<bool>("--opt-deps", "-o")
            { Description = "Removes optional dependencies installed with the package, that don't depend on other packages" };
        var ripple = new Option<bool>("--ripple", "-i")
            { Description = "Removes packages that depend on the package being removed" };
        var removeConfig = new Option<bool>("--remove-config", "-r")
            { Description = "Removes any files in your ~/.config that can be tied exclusively to the removed package(s). EXPERIMENTAL" };
        var local = new Option<bool>("--local", "-l")
            { Description = "Force removal as a locally-installed binary package" };
        var packages = new Argument<string[]>("packages")
            { Description = "The packages to remove (repo names or local binary packages)", Arity = ZeroOrMore };

        var command = new Command("remove", "Remove packages (repo or local binary)")
        {
            cascade, optDeps, ripple, removeConfig, local, packages
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Remove
            {
                Cascade = parseResult.GetValue(cascade),
                OptDeps = parseResult.GetValue(optDeps),
                Ripple = parseResult.GetValue(ripple),
                RemoveConfig = parseResult.GetValue(removeConfig),
                Local = parseResult.GetValue(local),
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
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        if (Packages.Length == 0)
        {
            console.WriteLine(Colorize("Error: No packages specified", ConsoleColor.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();

        var (repo, local) = PartitionPackages();

        console.WriteLine(Colorize($"Packages to remove: {string.Join(", ", Packages)}", ConsoleColor.Yellow));

        if (!NoConfirm && !Confirm.Execute("Do you want to proceed?"))
        {
            console.WriteLine(Colorize("Operation cancelled.", ConsoleColor.Yellow));
            return;
        }

        if (repo.Count > 0)
            await RemoveRepoPackages(repo, console);

        if (local.Count > 0)
            await RemoveLocalPackages(local, console);

        if (RemoveConfig)
            HandleConfigRemoval(Packages, console);
    }

    private (List<string> Repo, List<string> Local) PartitionPackages()
    {
        if (Local) return ([], Packages.ToList());

        var installedBinaries = LocalManager.GetInstalledBinaryPackages()
            .Select(p => p.Name)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        var repo = new List<string>();
        var local = new List<string>();
        foreach (var name in Packages)
            (installedBinaries.Contains(name) ? local : repo).Add(name);

        return (repo, local);
    }

    private async Task RemoveRepoPackages(List<string> packages, IShellyConsole console)
    {
        using var manager = new AlpmManager();
        console.WriteLine(Colorize("Initializing ALPM...", ConsoleColor.Yellow));
        manager.Initialize(true);

        console.WriteLine(Colorize("Removing packages...", ConsoleColor.Yellow));

        var flags = AlpmTransFlag.None;
        if (Cascade)
            flags |= AlpmTransFlag.NoSave | AlpmTransFlag.Recurse;
        else if (Ripple)
            flags |= AlpmTransFlag.Cascade;

        var result = await StandardSinglePaneOutput.Output(console, manager,
            x => x.RemovePackages(packages, flags, OptDeps), NoConfirm);

        if (!result)
        {
            console.WriteLine(Colorize("Removal failed. See errors above.", ConsoleColor.Red));
            return;
        }

        console.WriteLine(Colorize("Packages removed successfully!", ConsoleColor.Green));
    }

    private static async Task RemoveLocalPackages(List<string> packages, IShellyConsole console)
    {
        var localManager = new LocalManager();
        localManager.Message += (_, e) =>
        {
            var color = e.Level switch
            {
                LocalManagerMessageLevel.Info => ConsoleColor.Cyan,
                LocalManagerMessageLevel.Warning => ConsoleColor.Yellow,
                LocalManagerMessageLevel.Error => ConsoleColor.Red,
                LocalManagerMessageLevel.Success => ConsoleColor.Green,
                _ => ConsoleColor.White
            };
            console.WriteLine(Colorize(e.Message, color));
        };

        await localManager.RemoveBinaryPackages(packages);
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Packages.Length == 0)
        {
            UiFrames.Error("No packages specified");
            return;
        }

        var (repo, local) = PartitionPackages();

        if (repo.Count > 0)
            await RemoveRepoPackagesUi(repo);

        if (local.Count > 0)
            await RemoveLocalPackagesUi(local);

        if (RemoveConfig)
            HandleConfigRemoval(Packages, null);
    }

    private async Task RemoveRepoPackagesUi(List<string> packages)
    {
        var flags = AlpmTransFlag.None;
        if (Cascade)
            flags |= AlpmTransFlag.NoSave | AlpmTransFlag.Recurse;
        else if (Ripple)
            flags |= AlpmTransFlag.Cascade;

        using var manager = new AlpmManager();
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
        manager.Initialize(true);

        UiFrames.TxStart($"Removing packages: {string.Join(", ", packages)}");

        var ok = await UiModeOutput.Run(manager, m => m.RemovePackages(packages, flags, OptDeps));

        UiFrames.TxFinish(ok, "Packages removed successfully!", "Removal failed.");
    }

    private static async Task RemoveLocalPackagesUi(List<string> packageList)
    {
        var localManager = new LocalManager();
        localManager.Message += (_, e) =>
        {
            switch (e.Level)
            {
                case LocalManagerMessageLevel.Info:
                case LocalManagerMessageLevel.Success:
                    UiFrames.Info(e.Message);
                    break;
                case LocalManagerMessageLevel.Warning:
                    UiFrames.Info($"Warning: {e.Message}");
                    break;
                case LocalManagerMessageLevel.Error:
                    UiFrames.Error(e.Message);
                    break;
            }
        };

        await localManager.RemoveBinaryPackages(packageList);
    }

    private static void HandleConfigRemoval(string[] packageNames, IShellyConsole? console)
    {
        foreach (var package in packageNames)
        {
            var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), package);
            try
            {
                Directory.Delete(path, true);
            }
            catch (Exception)
            {
                console?.WriteLine(Colorize($"Failed to find directory for {package} moving on", ConsoleColor.Yellow));
            }
        }
    }
}