using System.CommandLine;
using System.CommandLine.Help;
using Shelly.Cli.Commands;
using Shelly.Cli.Commands.AppImage;
using Shelly.Cli.Commands.Config;
using Shelly.Cli.Commands.Keyring;
using Shelly.Cli.Commands.Standard;
using Shelly.Cli.Commands.Utility;
using Shelly.Cli.Shortcodes;
using static Shelly.Cli.Interactions.AnsiUtilities;
using AurUpgrade = Shelly.Cli.Commands.Aur.Upgrade;
using AurInstall = Shelly.Cli.Commands.Aur.Install;
using AurInstallVersion = Shelly.Cli.Commands.Aur.InstallVersion;
using AurRemove = Shelly.Cli.Commands.Aur.Remove;
using AurUpdate = Shelly.Cli.Commands.Aur.Update;
using AurListInstalled = Shelly.Cli.Commands.Aur.ListInstalled;
using AurListUpdates = Shelly.Cli.Commands.Aur.ListUpdates;
using AurSearch = Shelly.Cli.Commands.Aur.Search;
using AurSearchPackageBuild = Shelly.Cli.Commands.Aur.SearchPackageBuild;
using FlatpakInstall = Shelly.Cli.Commands.Flatpak.Install;
using FlatpakUpdate = Shelly.Cli.Commands.Flatpak.Update;
using FlatpakList = Shelly.Cli.Commands.Flatpak.List;
using FlatpakListUpdates = Shelly.Cli.Commands.Flatpak.ListUpdates;
using FlatpakRunning = Shelly.Cli.Commands.Flatpak.Running;
using FlatpakRepair = Shelly.Cli.Commands.Flatpak.Repair;
using FlatpakRemove = Shelly.Cli.Commands.Flatpak.Remove;
using FlatpakRun = Shelly.Cli.Commands.Flatpak.Run;
using FlatpakKill = Shelly.Cli.Commands.Flatpak.Kill;
using FlatpakSearch = Shelly.Cli.Commands.Flatpak.Search;
using FlatpakSyncRemoteAppStream = Shelly.Cli.Commands.Flatpak.SyncRemoteAppStream;
using FlatpakGetRemoteAppStream = Shelly.Cli.Commands.Flatpak.GetRemoteAppStream;
using FlatpakUpgrade = Shelly.Cli.Commands.Flatpak.Upgrade;
using FlatpakListRemotes = Shelly.Cli.Commands.Flatpak.ListRemotes;
using FlatpakAddRemote = Shelly.Cli.Commands.Flatpak.AddRemote;
using FlatpakRemoveRemote = Shelly.Cli.Commands.Flatpak.RemoveRemote;
using FlatpakInstallRefFile = Shelly.Cli.Commands.Flatpak.InstallRefFile;
using FlatpakInstallBundle = Shelly.Cli.Commands.Flatpak.InstallBundle;
using FlatpakAppRemoteInfo = Shelly.Cli.Commands.Flatpak.AppRemoteInfo;

namespace Shelly.Cli;

public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true;
            Console.WriteLine();
            Console.WriteLine(Colorize("Operation Cancelled...Exiting", ConsoleColor.Yellow));
            Environment.Exit(130);
        };

        var root = BuildRootCommand();

        try
        {
            var translated = ShortcodeTranslator.Translate(args);
            return await root.Parse(translated).InvokeAsync();
        }
        catch (ShortcodeException ex)
        {
            await Console.Error.WriteLineAsync(ex.Message);
            return 1;
        }
    }

    public static RootCommand BuildRootCommand()
    {
        var root = new RootCommand("Shelly CLI");

        GlobalOptions.AddToRoot(root);

        root.Add(Query.Create());
        root.Add(Install.Create());
        root.Add(Upgrade.Create());
        root.Add(UpgradeAll.Create());
        root.Add(DowngradePackage.Create());
        root.Add(Ignore.Create());
        root.Add(ArchNews.Create());
        root.Add(CacheClean.Create());
        root.Add(CheckPackageUpdateNonRoot.Create());
        root.Add(ListUpdates.Create());
        root.Add(Export.Create());
        root.Add(FixPermissions.Create());
        root.Add(Mark.Create());
        root.Add(PurifyPackages.Create());
        root.Add(Remove.Create());
        root.Add(Sync.Create());
        root.Add(Update.Create());
        root.Add(Docs.Create());
        root.Add(CompletionsCommand.Create());

        var appImage = new Command("appimage", "Manage AppImages")
        {
            AppImageInstall.Create(),
            AppImageRemove.Create(),
            AppImageList.Create(),
            AppImageUpgrade.Create(),
            AppImageSyncMeta.Create(),
            AppImageGetUpdates.Create(),
            AppImageConfigUpdates.Create(),
            AppImageUpdateManagerVersion.Create()
        };
        root.Add(appImage);

        var config = new Command("config", "Manage shelly configuration")
        {
            ConfigGet.Create(),
            ConfigSet.Create(),
            ConfigList.Create(),
            ConfigReset.Create(),
            ConfigParallel.Create()
        };
        root.Add(config);

        var aur = new Command("aur", "Manage AUR packages")
        {
            AurInstall.Create(),
            AurInstallVersion.Create(),
            AurRemove.Create(),
            AurUpdate.Create(),
            AurUpgrade.Create(),
            AurListInstalled.Create(),
            AurListUpdates.Create(),
            AurSearch.Create(),
            AurSearchPackageBuild.Create()
        };
        root.Add(aur);

        root.Add(Keyring.Create());

        var flatpak = new Command("flatpak", "Manage flatpak")
        {
            FlatpakInstall.Create(),
            FlatpakUpdate.Create(),
            FlatpakList.Create(),
            FlatpakListUpdates.Create(),
            FlatpakRunning.Create(),
            FlatpakRepair.Create(),
            FlatpakRemove.Create(),
            FlatpakRun.Create(),
            FlatpakKill.Create(),
            FlatpakSearch.Create(),
            FlatpakSyncRemoteAppStream.Create(),
            FlatpakGetRemoteAppStream.Create(),
            FlatpakUpgrade.Create(),
            FlatpakListRemotes.Create(),
            FlatpakAddRemote.Create(),
            FlatpakRemoveRemote.Create(),
            FlatpakInstallRefFile.Create(),
            FlatpakInstallBundle.Create(),
            FlatpakAppRemoteInfo.Create()
        };
        root.Add(flatpak);

        root.Description = "Shelly — a modern, unified package manager for Arch Linux. " +
                           "Install, update, search, and manage standard (ALPM) packages, " +
                           "the AUR, Flatpaks, and AppImages from a single command-line interface.";

        root.SetAction(async (parseResult, _) =>
        {
            var instance = new UpgradeAll();
            GlobalOptions.Apply(instance, parseResult);
            await instance.ExecuteAsync(new SystemShellyConsole());
            return 0;
        });

        var helpOption = root.Options.OfType<HelpOption>().FirstOrDefault();
        if (helpOption is { Action: HelpAction defaultHelp })
            helpOption.Action = new ShortcodeHelpAction(defaultHelp);

        return root;
    }
}