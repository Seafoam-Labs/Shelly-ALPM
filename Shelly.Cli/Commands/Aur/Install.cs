using System.CommandLine;
using PackageManager.Aur;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;

namespace Shelly.Cli.Commands.Aur;

public class Install : GlobalSettingsCommand
{
    private bool BuildDeps { get; set; }

    private bool MakeDeps { get; set; }

    private bool UseChroot { get; set; }

    private bool Check { get; set; }

    private string[] Package { get; set; } = Array.Empty<string>();

    public static Command Create()
    {
        var buildDeps = new Option<bool>("--build-deps", "-o")
            { Description = "Install build dependencies only for the specified AUR packages" };
        var makeDeps = new Option<bool>("--make-deps", "-m")
            { Description = "Install make dependencies only for the specified AUR packages" };
        var chroot = new Option<bool>("--chroot", "-c")
            { Description = "Build packages in a clean chroot environment using makechrootpkg" };
        var check = new Option<bool>("--check")
            { Description = "Run the check() function during AUR package builds (disabled by default)" };
        var package = new Argument<string[]>("packages")
            { Description = "One or more AUR package names to operate on (space-separated)", Arity = ArgumentArity.ZeroOrMore };

        var command = new Command("install", "Install AUR packages")
        {
            buildDeps, makeDeps, chroot, check, package
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new Install
            {
                BuildDeps = parseResult.GetValue(buildDeps),
                MakeDeps = parseResult.GetValue(makeDeps),
                UseChroot = parseResult.GetValue(chroot),
                Check = parseResult.GetValue(check),
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
        if (UiMode)
        {
            await ExecuteUiMode();
            return;
        }

        if (Package.Length == 0)
        {
            console.WriteLine(AnsiUtilities.Colorize("No packages specified.", ConsoleColor.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();

        var packageList = Package.ToList();

        console.WriteLine(AnsiUtilities.Colorize(
            $"AUR packages to install: {string.Join(", ", packageList)}", ConsoleColor.Yellow));

        if (!NoConfirm && !Confirm.Execute("Do you want to proceed?"))
        {
            console.WriteLine(AnsiUtilities.Colorize("Operation cancelled.", ConsoleColor.Yellow));
            return;
        }

        using var manager = new AurPackageManager();
        await manager.Initialize(root: true, useChroot: UseChroot, noCheck: !Check);

        if (BuildDeps)
        {
            if (packageList.Count > 1)
            {
                console.WriteLine(AnsiUtilities.Colorize(
                    "Cannot build dependencies for multiple packages at once.", ConsoleColor.Yellow));
                return;
            }

            console.WriteLine(AnsiUtilities.Colorize(
                MakeDeps ? "Installing dependencies (including make dependencies)..." : "Installing dependencies...",
                ConsoleColor.Yellow));

            var depsResult = await AurSinglePaneOutput.Output(console, manager,
                m => m.InstallDependenciesOnly(packageList.First(), MakeDeps), NoConfirm);

            console.WriteLine(depsResult
                ? AnsiUtilities.Colorize("Dependencies installed successfully!", ConsoleColor.Green)
                : AnsiUtilities.Colorize("Dependency installation failed. See errors above.", ConsoleColor.Red));
            return;
        }

        console.WriteLine(AnsiUtilities.Colorize(
            $"Installing AUR packages: {string.Join(", ", packageList)}", ConsoleColor.Yellow));

        var result = await AurSinglePaneOutput.Output(console, manager,
            m => m.InstallPackages(packageList), NoConfirm);

        console.WriteLine(result
            ? AnsiUtilities.Colorize("Installation complete.", ConsoleColor.Green)
            : AnsiUtilities.Colorize("Installation failed. See errors above.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (Package.Length == 0)
        {
            UiFrames.Error("No packages specified");
            return;
        }

        using var manager = new AurPackageManager();
        await manager.Initialize(root: true, useChroot: UseChroot, noCheck: !Check);

        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
        manager.PkgbuildDiffRequest += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);

        var packageList = Package.ToList();

        if (BuildDeps)
        {
            if (packageList.Count > 1)
            {
                UiFrames.Error("Cannot build dependencies for multiple packages at once.");
                return;
            }

            UiFrames.TxStart("Installing dependencies...");
            var depsOk = await UiModeOutput.Run(manager,
                m => m.InstallDependenciesOnly(packageList.First(), MakeDeps));
            UiFrames.TxFinish(depsOk, "Dependencies installed successfully!", "Dependency installation failed.");
            return;
        }

        UiFrames.TxStart($"Installing AUR packages: {string.Join(", ", packageList)}");
        var ok = await UiModeOutput.Run(manager, m => m.InstallPackages(packageList));
        UiFrames.TxFinish(ok, "Installation complete.", "Installation failed.");
    }
}
