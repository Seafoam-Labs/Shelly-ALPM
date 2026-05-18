using PackageManager.Alpm;
using PackageManager.Local;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class InstallLocalPackageCommand : AsyncCommand<InstallLocalPackageSettings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, InstallLocalPackageSettings settings)
    {
        if (string.IsNullOrWhiteSpace(settings.PackageLocation))
        {
            if (Program.IsUiMode)
                await Console.Error.WriteLineAsync("Error: No package specified");
            else
                AnsiConsole.MarkupLine("[red]Error: No package specified[/]");

            return 1;
        }

        if (!File.Exists(settings.PackageLocation))
        {
            if (Program.IsUiMode)
                await Console.Error.WriteLineAsync("Error: Specified file does not exist.");
            else
                AnsiConsole.MarkupLine("[red]Error: Specified file does not exist.[/]");

            return 1;
        }

        RootElevator.EnsureRootExectuion();

        if (await LocalManager.IsArchPackage(settings.PackageLocation))
        {
            if (Program.IsUiMode) return await HandleUiModeInstall(settings);

            var isSuccess = await InitializeAndInstallLocalAlpmPackage(settings);
            if (isSuccess) return 0;

            AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
            return 1;
        }

        if (await LocalManager.IsBinariesPackage(settings.PackageLocation))
        {
            if (Program.IsUiMode) return await HandleUiModeBinaryInstall(settings);

            return await HandleConsoleBinaryInstall(settings);
        }

        if (Program.IsUiMode)
            await Console.Error.WriteLineAsync("Error: Unsupported local package format.");
        else
            AnsiConsole.MarkupLine("[red]Error: Unsupported local package format.[/]");

        return 1;
    }

    private static async Task<bool> InitializeAndInstallLocalAlpmPackage(InstallLocalPackageSettings settings)
    {
        var manager = new AlpmManager();
        AnsiConsole.MarkupLine("[yellow]Initializing ALPM...[/]");
        manager.Initialize();
        var cfg = ConfigManager.ReadConfig();
        var useSinglePane = settings.SinglePane
                            || string.Equals(cfg.OutputMode, "singlepane", StringComparison.OrdinalIgnoreCase)
                            || Console.IsOutputRedirected;
        var result = useSinglePane
            ? await StandardSinglePaneOutput.Output(manager,
                x => x.InstallLocalPackage(Path.GetFullPath(settings.PackageLocation)), settings.NoConfirm)
            : await SplitOutput.Output(manager, x => x.InstallLocalPackage(Path.GetFullPath(settings.PackageLocation)),
                settings.NoConfirm);
        manager.Dispose();
        return result;
    }

    private static async Task<int> HandleUiModeInstall(InstallLocalPackageSettings settings)
    {
        using var manager = new AlpmManager();
        var hadError = false;

        manager.Question += (_, args) => { QuestionHandler.HandleQuestion(args, true, settings.NoConfirm); };

        manager.Progress += (_, args) => { Console.Error.WriteLine($"{args.PackageName}: {args.Percent}%"); };

        manager.ErrorEvent += (_, e) =>
        {
            Console.Error.WriteLine($"[ALPM_ERROR]{e.Error}");
            hadError = true;
        };

        await Console.Error.WriteLineAsync("Initializing ALPM...");
        manager.Initialize();

        await Console.Error.WriteLineAsync($"Installing local package: {settings.PackageLocation}");
        var result = await manager.InstallLocalPackage(Path.GetFullPath(settings.PackageLocation));
        if (!result || hadError)
        {
            await Console.Error.WriteLineAsync("Installation failed.");
            return 1;
        }

        await Console.Error.WriteLineAsync("Installation complete.");
        return 0;
    }

    private static async Task<int> HandleConsoleBinaryInstall(InstallLocalPackageSettings settings)
    {
        var localManager = new LocalManager();

        localManager.Message += (_, e) =>
        {
            switch (e.Level)
            {
                case LocalManagerMessageLevel.Info:
                    AnsiConsole.MarkupLine($"[cyan]{e.Message.EscapeMarkup()}[/]");
                    break;
                case LocalManagerMessageLevel.Warning:
                    AnsiConsole.MarkupLine($"[yellow]{e.Message.EscapeMarkup()}[/]");
                    break;
                case LocalManagerMessageLevel.Error:
                    AnsiConsole.MarkupLine($"[red]{e.Message.EscapeMarkup()}[/]");
                    break;
                case LocalManagerMessageLevel.Success:
                    AnsiConsole.MarkupLine($"[green]{e.Message.EscapeMarkup()}[/]");
                    break;
            }
        };

        var success = await localManager.InstallBinariesPackage(Path.GetFullPath(settings.PackageLocation));
        return success ? 0 : 1;
    }

    private static async Task<int> HandleUiModeBinaryInstall(InstallLocalPackageSettings settings)
    {
        var localManager = new LocalManager();

        localManager.Message += (_, e) =>
        {
            switch (e.Level)
            {
                case LocalManagerMessageLevel.Info:
                case LocalManagerMessageLevel.Success:
                    Console.Error.WriteLine(e.Message);
                    break;
                case LocalManagerMessageLevel.Warning:
                    Console.Error.WriteLine($"Warning: {e.Message}");
                    break;
                case LocalManagerMessageLevel.Error:
                    Console.Error.WriteLine($"Error: {e.Message}");
                    break;
            }
        };

        var success = await localManager.InstallBinariesPackage(Path.GetFullPath(settings.PackageLocation));
        return success ? 0 : 1;
    }
}