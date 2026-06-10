using PackageManager.Alpm;
using PackageManager.Local;
using PackageManager.Wire;
using Shelly_CLI.Configuration;
using Shelly_CLI.ConsoleLayouts;
using Shelly_CLI.Utility;
using Shelly.Utilities.Eventing;
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
                JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "No package specified"));
            else
                AnsiConsole.MarkupLine("[red]Error: No package specified[/]");

            return 1;
        }

        if (!File.Exists(settings.PackageLocation))
        {
            if (Program.IsUiMode)
                JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "Specified file does not exist."));
            else
                AnsiConsole.MarkupLine("[red]Error: Specified file does not exist.[/]");

            return 1;
        }

        RootElevator.EnsureRootExectuion();

        if (await FileInspector.IsArchPackage(settings.PackageLocation))
        {
            if (Program.IsUiMode) return await HandleUiModeInstall(settings);

            var isSuccess = await InitializeAndInstallLocalAlpmPackage(settings);
            if (isSuccess) return 0;

            AnsiConsole.MarkupLine("[red]Installation failed. See errors above.[/]");
            return 1;
        }

        if (await FileInspector.IsBinariesPackage(settings.PackageLocation))
        {
            if (Program.IsUiMode) return await HandleUiModeBinaryInstall(settings);

            return await HandleConsoleBinaryInstall(settings);
        }

        if (Program.IsUiMode)
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, "Unsupported local package format."));
        else
            AnsiConsole.MarkupLine("[red]Error: Unsupported local package format.[/]");

        return 1;
    }

    private static async Task<bool> InitializeAndInstallLocalAlpmPackage(InstallLocalPackageSettings settings)
    {
        var manager = new AlpmManager();
        AnsiConsole.MarkupLine("[yellow]Initializing ALPM...[/]");
        manager.Initialize();
        var result = await StandardSinglePaneOutput.Output(manager,
                x => x.InstallLocalPackage(Path.GetFullPath(settings.PackageLocation)), settings.NoConfirm);
        manager.Dispose();
        return result;
    }

    private static async Task<int> HandleUiModeInstall(InstallLocalPackageSettings settings)
    {
        using var manager = new AlpmManager();
        manager.Question += (_, args) => QuestionHandler.HandleQuestion(args, true, settings.NoConfirm);
        manager.Initialize();

        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            AlpmEvents.TransactionStart,
            $"Installing local package: {settings.PackageLocation}"));

        var ok = await UiModeOutput.Run(manager,
            m => m.InstallLocalPackage(Path.GetFullPath(settings.PackageLocation)));

        JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
            ok ? AlpmEvents.TransactionDone : AlpmEvents.TransactionFailed,
            ok ? "Installation complete." : "Installation failed."));
        return ok ? 0 : 1;
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
                    JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                        AlpmEvents.InformationalOutput, e.Message));
                    break;
                case LocalManagerMessageLevel.Warning:
                    JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                        AlpmEvents.InformationalOutput, $"Warning: {e.Message}"));
                    break;
                case LocalManagerMessageLevel.Error:
                    JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, e.Message));
                    break;
            }
        };

        var success = await localManager.InstallBinariesPackage(Path.GetFullPath(settings.PackageLocation));
        return success ? 0 : 1;
    }
}