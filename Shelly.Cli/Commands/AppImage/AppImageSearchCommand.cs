using System.CommandLine;
using PackageManager.AppImage;
using PackageManager.AppImage.AppImageV2;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Enums;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Commands.AppImage;

public partial class AppImageList : GlobalSettingsCommand
{
    public static Command Create()
    {
        var command = new Command("list", "Lists all AppImages");

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            var instance = new AppImageList();
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

        var displaySize = Enum.Parse<SizeDisplay>(ConfigManager.ReadConfig().FileSizeDisplay);
        console.WriteLine(BasicTable.Execute(["Name", "Version", "Size", "Update Info"],
            await GetAppImagesFromLocalDb(), c => c.Name,
            c => c.Version,
            c => SizeUtilities.FormatSize(displaySize, c.SizeOnDisk),
            c => string.IsNullOrEmpty(c.UpdateURl)
                ? string.IsNullOrEmpty(c.RepoOwner) ? "" : $"{c.RepoOwner}/{c.RepoOwner}"
                : c.UpdateURl));
    }

    public override async ValueTask ExecuteUiMode()
    {
        JsonPackFrame.WriteToStdout(await GetAppImagesFromLocalDb());
    }

    private static async Task<List<AppImageDtoV2>> GetAppImagesFromLocalDb()
    {
        var installPath = ConfigManager.ReadConfig().AppImageInstallPath ?? XdgPaths.BinHome();
        var manager = new AppImageManagerV2(installPath);
        return await manager.GetAppImagesFromLocalDb();
    }
}