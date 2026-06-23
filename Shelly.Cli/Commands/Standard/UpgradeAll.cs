using System.CommandLine;
using PackageManager.Alpm;
using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using PackageManager.Aur;
using PackageManager.Aur.Models;
using PackageManager.Flatpak;
using PackageManager.User;
using Shelly.Cli.Interactions;
using Shelly.Cli.Outputs;
using Shelly.Utilities;
using Shelly.Utilities.Enums;
using static System.Enum;
using static Shelly.Cli.Interactions.AnsiUtilities;
using static Shelly.Utilities.SizeUtilities;
using AurUpgrade = Shelly.Cli.Commands.Aur.Upgrade;
using FlatpakUpgrade = Shelly.Cli.Commands.Flatpak.Upgrade;
using AppImageUpgrade = Shelly.Cli.Commands.AppImage.AppImageUpgrade;

namespace Shelly.Cli.Commands.Standard;

public class UpgradeAll : GlobalSettingsCommand
{
    private static readonly Option<bool> NoRepoOption =
        new("--no-repo") { Description = "Skip the standard repository (ALPM) upgrade" };

    private static readonly Option<bool> NoAurOption =
        new("--no-aur") { Description = "Skip the AUR upgrade" };

    private static readonly Option<bool> NoFlatpakOption =
        new("--no-flatpak") { Description = "Skip the Flatpak upgrade" };

    private static readonly Option<bool> NoAppImageOption =
        new("--no-appimage") { Description = "Skip the AppImage upgrade" };

    public bool NoRepo { get; set; }

    public bool NoAur { get; set; }

    public bool NoFlatpak { get; set; }

    public bool NoAppImage { get; set; }
    

    public static Command Create()
    {
        var command = new Command("upgrade-all",
            "Upgrade all packages from every source (repo, AUR, Flatpak, AppImage)")
        {
            NoRepoOption,
            NoAurOption,
            NoFlatpakOption,
            NoAppImageOption
        };

        command.SetAction(async (parseResult, _) =>
        {
            var instance = new UpgradeAll
            {
                NoRepo = parseResult.GetValue(NoRepoOption),
                NoAur = parseResult.GetValue(NoAurOption),
                NoFlatpak = parseResult.GetValue(NoFlatpakOption),
                NoAppImage = parseResult.GetValue(NoAppImageOption)
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


        if (!UserIdentity.IsRoot())
        {
            var plan = await BuildPlanAsync();

            if (plan.IsEmpty)
            {
                console.WriteLine(Colorize("Everything is up to date.", ConsoleColor.Green));
                return;
            }

            RenderPlan(console, plan);

            if (!NoConfirm && !Confirm.Execute("Proceed with all upgrades?", false))
            {
                console.WriteLine(Colorize("Upgrade cancelled.", ConsoleColor.Red));
                return;
            }
            
            RootElevator.EnsureRootExectuion();
        }
        

        if (!NoRepo)
            await RunChild(new Upgrade(), console, true);
        if (!NoAur)
            await RunChild(new AurUpgrade(), console);
        if (!NoFlatpak)
            await RunFlatpakStep(console);
        if (!NoAppImage)
            await RunChild(new AppImageUpgrade(), console);

        console.WriteLine(Colorize("All upgrades complete.", ConsoleColor.Green));
    }

    public override async ValueTask ExecuteUiMode()
    {
        if (!UserIdentity.IsRoot())
        {
            var plan = await BuildPlanAsync();

            if (plan.IsEmpty)
            {
                UiFrames.Info("Everything is up to date.");
                return;
            }

            EmitPlan(plan);

            RootElevator.EnsureRootExectuion();
        }
        

        if (!NoRepo)
            await RunChild(new Upgrade(), null);
        if (!NoAur)
            await RunChild(new AurUpgrade(), null);
        if (!NoFlatpak)
            await RunFlatpakStep(null);
        if (!NoAppImage)
            await RunChild(new AppImageUpgrade(), null);
    }

    private sealed record UpgradePlan(
        List<AlpmPackageUpdateDto> Repo,
        List<AurUpdateDto> Aur,
        List<FlatpakPackageDto> Flatpak,
        List<AppImageUpdateDto> AppImage)
    {
        public bool IsEmpty => Repo.Count == 0 && Aur.Count == 0 && Flatpak.Count == 0 && AppImage.Count == 0;
    }

    private async ValueTask<UpgradePlan> BuildPlanAsync()
    {
        var repo = new List<AlpmPackageUpdateDto>();
        var aur = new List<AurUpdateDto>();
        var flatpak = new List<FlatpakPackageDto>();
        var appImage = new List<AppImageUpdateDto>();

        Console.WriteLine(Colorize("Building upgrade plan...", ConsoleColor.Yellow));
        if (!NoRepo)
        {
            Console.WriteLine(Colorize("Collecting Standard Packages for upgrade.", ConsoleColor.Yellow));
            try
            {
                var dbPath = XdgPaths.ShellyCache("db");
                Directory.CreateDirectory(dbPath);
                using var manager = new AlpmManager();
                manager.Initialize(useTempPath: true, tempPath: dbPath);
                manager.Sync();
                repo = manager.GetPackagesNeedingUpdate();
            }
            catch(Exception e)
            {
                Console.WriteLine(Colorize($"Error: {e.Message}", ConsoleColor.Red));
                if (Verbose)
                {
                    Console.WriteLine(Colorize(e.StackTrace ?? "No stacktrace found.", ConsoleColor.Red));
                }
            }

            if (repo.Count == 0)
            {
                Console.WriteLine(Colorize("No standard packages to upgrade.", ConsoleColor.Yellow));
            }
        }

        if (!NoAur)
        {
            Console.WriteLine(Colorize("Collecting AUR Packages", ConsoleColor.Yellow));
            try
            {
                var dbPath = XdgPaths.ShellyCache("db");
                Directory.CreateDirectory(dbPath);
                using var manager = new AurPackageManager();
                await manager.Initialize(useTempPath: true, tempPath: dbPath);
                aur = await manager.GetPackagesNeedingUpdate();
            }
            catch(Exception e)
            {
                Console.WriteLine(Colorize($"Error: {e.Message}", ConsoleColor.Red));
                if (Verbose)
                {
                    Console.WriteLine(Colorize(e.StackTrace ?? "No stacktrace found.", ConsoleColor.Red));
                }
            }

            if (aur.Count == 0)
            {
                Console.WriteLine(Colorize("No AUR packages to upgrade.", ConsoleColor.Yellow));
            }
        }

        if (!NoFlatpak)
        {
            Console.WriteLine(Colorize("Collecting Flatpak Apps", ConsoleColor.Yellow));
            try
            {
                flatpak = FlatpakManager.GetPackagesWithUpdates(true).OrderBy(p => p.Id).ToList();
            }
            catch(Exception e)
            {
                Console.WriteLine(Colorize($"Error: {e.Message}", ConsoleColor.Red));
                if (Verbose)
                {
                    Console.WriteLine(Colorize(e.StackTrace ?? "No stacktrace found.", ConsoleColor.Red));
                }
            }
            if (flatpak.Count == 0)
            {
                Console.WriteLine(Colorize("No Flatpak apps to upgrade.", ConsoleColor.Yellow));
            }
        }

        if (!NoAppImage)
        {
            Console.WriteLine(Colorize("Collecting AppImages", ConsoleColor.Yellow));
            try
            {
                var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
                var manager = new AppImageManagerV2(installPath);
                appImage = await manager.CheckForAppImageUpdates();
            }
            catch(Exception e)
            {
                Console.WriteLine(Colorize($"Error: {e.Message}", ConsoleColor.Red));
                if (Verbose)
                {
                    Console.WriteLine(Colorize(e.StackTrace ?? "No stacktrace found.", ConsoleColor.Red));
                }
            }
            if (appImage.Count == 0)
            {
                Console.WriteLine(Colorize("No AppImages to upgrade.", ConsoleColor.Yellow));
            }
        }

        return new UpgradePlan(repo, aur, flatpak, appImage);
    }

    private void RenderPlan(IShellyConsole console, UpgradePlan plan)
    {
        var config = ConfigManager.ReadConfig();
        var size = Parse<SizeDisplay>(config.FileSizeDisplay);

        console.WriteLine(Colorize("The following upgrades are planned:", ConsoleColor.Yellow));
        console.WriteLine();

        if (plan.Repo.Count > 0)
        {
            console.WriteLine(Colorize($"Repository ({plan.Repo.Count}):", ConsoleColor.Yellow));
            var headers = new[]
                { "Repository", "Package", "Old Version", "New Version", "Net Change", "Download Size" };
            var table = BasicTable.Execute(headers, plan.Repo, p => p.Repository,
                p => Colorize(p.Name, ConsoleColor.Cyan),
                p => Colorize(p.CurrentVersion, ConsoleColor.Cyan),
                p => Colorize(p.NewVersion, ConsoleColor.Cyan),
                p => Colorize(FormatSize(size, p.SizeDifference), ConsoleColor.Cyan),
                p => Colorize(FormatSize(size, p.DownloadSize), ConsoleColor.Cyan));
            console.Write(table);
            console.WriteLine();
            var downloadSize = FormatSize(size, plan.Repo.Sum(p => p.DownloadSize));
            console.WriteLine(Colorize($"Total Download Size: {downloadSize}", ConsoleColor.DarkGreen));
            var upgradeSize = FormatSize(size, plan.Repo.Sum(p => p.SizeDifference));
            console.WriteLine(Colorize($"Net Upgrade Size: {upgradeSize}", ConsoleColor.DarkGreen));
            console.WriteLine();
        }

        if (plan.Aur.Count > 0)
        {
            console.WriteLine(Colorize($"AUR ({plan.Aur.Count}):", ConsoleColor.Yellow));
            foreach (var pkg in plan.Aur)
                console.WriteLine($"  {pkg.Name}: {pkg.Version} -> {pkg.NewVersion}");
            console.WriteLine();
        }

        if (plan.Flatpak.Count > 0)
        {
            console.WriteLine(Colorize($"Flatpak ({plan.Flatpak.Count}):", ConsoleColor.Yellow));
            foreach (var pkg in plan.Flatpak)
                console.WriteLine($"  {pkg.Name} ({pkg.Id})");
            console.WriteLine();
        }

        if (plan.AppImage.Count > 0)
        {
            console.WriteLine(Colorize($"AppImage ({plan.AppImage.Count}):", ConsoleColor.Yellow));
            foreach (var pkg in plan.AppImage)
                console.WriteLine($"  {pkg.Name} -> {pkg.Version}");
            console.WriteLine();
        }
    }

    private void EmitPlan(UpgradePlan plan)
    {
        if (plan.Repo.Count > 0)
            UiFrames.Info($"{plan.Repo.Count} repository packages to upgrade.");
        if (plan.Aur.Count > 0)
            UiFrames.Info($"{plan.Aur.Count} AUR packages to upgrade.");
        if (plan.Flatpak.Count > 0)
            UiFrames.Info($"{plan.Flatpak.Count} Flatpak apps to upgrade.");
        if (plan.AppImage.Count > 0)
            UiFrames.Info($"{plan.AppImage.Count} AppImages to upgrade.");
    }


    private async ValueTask RunFlatpakStep(IShellyConsole? console)
    {
        if (!UiMode && RootElevator.TryGetCallingUser(out var user, out var home))
        {
            var args = BuildFlatpakArgs();
            var exitCode = RootElevator.RunFlatpakAsUser(user, home, args);

            if (exitCode != 0)
            {
                var message = $"Flatpak upgrade step failed (exit code {exitCode}).";
                if (console is not null)
                    console.WriteLine(Colorize(message, ConsoleColor.Red));
                else
                    UiFrames.Error(message);
            }

            return;
        }

        await RunChild(new FlatpakUpgrade(), console);
    }

    private List<string> BuildFlatpakArgs()
    {
        var args = new List<string> { "flatpak", "upgrade" };
        if (NoConfirm)
            args.Add("--no-confirm");
        if (JsonOutput)
            args.Add("--json");
        if (Verbose)
            args.Add("--verbose");
        return args;
    }

    private async ValueTask RunChild(GlobalSettingsCommand child, IShellyConsole? console, bool isStandardUpgrade = false)
    {
        child.NoConfirm = NoConfirm || isStandardUpgrade;
        child.UiMode = UiMode;
        child.JsonOutput = JsonOutput;
        child.Verbose = Verbose;

        try
        {
            if (UiMode)
                await child.ExecuteAsync(new SystemShellyConsole());
            else
                await child.ExecuteAsync(console!);
        }
        catch (Exception ex)
        {
            if (console is not null)
                console.WriteLine(Colorize($"Upgrade step failed: {ex.Message}", ConsoleColor.Red));
            else
                UiFrames.Error($"Upgrade step failed: {ex.Message}");
        }
    }
}

