namespace Shelly.Cli.Models.Sync;

public sealed record SyncAur(string Name = "", string Version = "", string OldVersion = "", string DownloadSize = "");