using PackageManager.Alpm;
using Shelly.Utilities.Eventing;

namespace Shelly_CLI.Utility;

internal static class AlpmProgressTypeMapper
{
    public static ProgressType ToProgressType(this AlpmProgressType type) => type switch
    {
        AlpmProgressType.AddStart        => ProgressType.AddStart,
        AlpmProgressType.UpgradeStart    => ProgressType.UpgradeStart,
        AlpmProgressType.DowngradeStart  => ProgressType.DowngradeStart,
        AlpmProgressType.ReinstallStart  => ProgressType.ReinstallStart,
        AlpmProgressType.RemoveStart     => ProgressType.RemoveStart,
        AlpmProgressType.ConflictsStart  => ProgressType.ConflictsStart,
        AlpmProgressType.DiskspaceStart  => ProgressType.DiskspaceStart,
        AlpmProgressType.IntegrityStart  => ProgressType.IntegrityStart,
        AlpmProgressType.LoadStart       => ProgressType.LoadStart,
        AlpmProgressType.KeyringStart    => ProgressType.KeyringStart,
        AlpmProgressType.PackageDownload => ProgressType.PackageDownload,
        AlpmProgressType.MakepkgBuild    => ProgressType.MakepkgBuild,
        AlpmProgressType.MakepkgPackage  => ProgressType.MakepkgPackage,
        AlpmProgressType.AurDownload     => ProgressType.AurDownload,
        _ => throw new ArgumentOutOfRangeException(nameof(type), type, "Unknown AlpmProgressType")
    };
}