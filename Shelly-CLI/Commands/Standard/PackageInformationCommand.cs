using PackageManager.Alpm;
using PackageManager.Wire;
using Shelly.Utilities.Eventing;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly_CLI.Commands.Standard;

public class PackageInformationCommand : Command<PackageInformationSettings>
{
    public override int Execute(CommandContext context, PackageInformationSettings settings)
    {
        if (Program.IsUiMode || settings.JsonOutput)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(
                EventLevel.Error, "Package information is not supported in UI mode yet"));
            return 1;
        }

        if (settings.Packages.Length > 1)
        {
            Console.WriteLine("Only one package at a time is currently supported.");
            return 0;
        }

        var manager = new AlpmManager();
        AlpmPackageDto? package;
        if (settings.SearchInstalled)
        {
            var installedPackages = manager.GetInstalledPackages();
            package = installedPackages.FirstOrDefault(x => x.Name == settings.Packages[0]);
        }
        else if (settings.SearchRepository)
        {
            var available = manager.GetAvailablePackages();
            package = available.FirstOrDefault(x => x.Name == settings.Packages[0]);
        }
        else
        {
            Console.WriteLine("No search source specified");
            return 0;
        }

        if (package is null)
        {
            AnsiConsole.MarkupLine($"[red]No package named {settings.Packages[0].EscapeMarkup()} found[/]");
            return 0;
        }

        AnsiConsole.MarkupLine($"[green]Name: {package.Name.EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Version: {package.Version.EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Description: {package.Description.EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]URL: {package.Url.EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Licenses: {string.Join(',', package.Licenses).EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Groups: {string.Join(',', package.Groups).EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Provides: {string.Join(',', package.Provides).EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Depends On: {string.Join(',', package.Depends).EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Optional Depends: {string.Join(',', package.OptDepends).EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Required By: {string.Join(',', package.RequiredBy).EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Conflicts With: {string.Join(',', package.Conflicts).EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Replaces: {string.Join(',', package.Replaces).EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Installed Size: {package.InstalledSize} bytes[/]");
        AnsiConsole.MarkupLine($"[blue]Build Date: {package.BuildDate.ToLongDateString().EscapeMarkup()}[/]");
        var installDate = package.InstallDate.HasValue
            ? package.InstallDate.Value.ToLongDateString()
            : "Not Installed";
        AnsiConsole.MarkupLine($"[blue]Install Date: {installDate.EscapeMarkup()}[/]");
        AnsiConsole.MarkupLine($"[blue]Install Reason: {package.InstallReason}[/]");
        return 0;
    }
}