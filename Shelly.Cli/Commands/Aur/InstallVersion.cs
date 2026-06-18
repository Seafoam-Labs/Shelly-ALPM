using System.CommandLine;
using PackageManager.Aur;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;

namespace Shelly.Cli.Commands.Aur;

public class InstallVersion : GlobalSettingsCommand
{
    private bool Check { get; set; }

    private string Package { get; set; } = string.Empty;

    private string Commit { get; set; } = string.Empty;

    public static Command Create()
    {
        var check = new Option<bool>("--check")
            { Description = "Run the check() function during AUR package builds (disabled by default)" };
        var package = new Argument<string>("package")
            { Description = "Name of the AUR package to install" };
        var commit = new Argument<string>("commit")
            { Description = "Git commit hash specifying the exact version to install" };

        var command = new Command("install-version", "Install a specific version of an AUR package")
        {
            check, package, commit
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new InstallVersion
            {
                Check = parseResult.GetValue(check),
                Package = parseResult.GetValue(package) ?? string.Empty,
                Commit = parseResult.GetValue(commit) ?? string.Empty
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

        if (string.IsNullOrWhiteSpace(Package))
        {
            console.WriteLine(AnsiUtilities.Colorize("No package specified.", ConsoleColor.Red));
            return;
        }

        if (string.IsNullOrWhiteSpace(Commit))
        {
            console.WriteLine(AnsiUtilities.Colorize("No commit specified.", ConsoleColor.Red));
            return;
        }

        RootElevator.EnsureRootExectuion();

        using var manager = new AurPackageManager();
        await manager.Initialize(root: true, noCheck: !Check);

        console.WriteLine(AnsiUtilities.Colorize(
            $"Installing AUR package {Package} at commit {Commit}", ConsoleColor.Yellow));

        var result = await AurSinglePaneOutput.Output(console, manager,
            m => m.InstallPackageVersion(Package, Commit), NoConfirm);

        console.WriteLine(result
            ? AnsiUtilities.Colorize("Installation complete.", ConsoleColor.Green)
            : AnsiUtilities.Colorize("Installation failed. See errors above.", ConsoleColor.Red));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (string.IsNullOrWhiteSpace(Package))
        {
            UiFrames.Error("No package specified");
            return;
        }

        if (string.IsNullOrWhiteSpace(Commit))
        {
            UiFrames.Error("No commit specified");
            return;
        }

        using var manager = new AurPackageManager();
        await manager.Initialize(root: true, noCheck: !Check);

        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);
        manager.PkgbuildDiffRequest += (_, args) => QuestionHandler.HandleQuestion(args, true, NoConfirm);

        UiFrames.TxStart($"Installing AUR package {Package} at commit {Commit}");
        var ok = await UiModeOutput.Run(manager, m => m.InstallPackageVersion(Package, Commit));
        UiFrames.TxFinish(ok, "Installation complete.", "Installation failed.");
    }
}
