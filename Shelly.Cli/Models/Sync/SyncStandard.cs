namespace Shelly.Cli.Models.Sync;

public sealed record SyncStandard(string Name = "", string Version = "", string OldVersion = "", string DownloadSize = "");