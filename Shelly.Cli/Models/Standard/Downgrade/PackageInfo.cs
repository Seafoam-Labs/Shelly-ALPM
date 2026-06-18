namespace Shelly.Cli.Models.Standard.Downgrade;

public sealed record PackageInfo(string Name, string Filename, Location Location, bool IsInstalled, string? Uri = null);