using PackageManager.Alpm.Pacfile;

namespace Shelly.Cli.Models.Pacfile;

internal sealed record PendingPacfile(PacfileType Kind, string? PackageName, string FileLocation, DateTime CapturedUtc);