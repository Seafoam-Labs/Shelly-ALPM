namespace Shelly.Cli.Models.Sync;

public sealed record Sync(SyncMetaData MetaData, List<SyncStandard> Packages, List<SyncAur> Aur, List<SyncFlatpak> Flatpak);