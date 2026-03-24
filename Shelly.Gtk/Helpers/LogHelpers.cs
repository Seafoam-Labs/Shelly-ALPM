using System.Text;
using Shelly.Gtk.Services;

namespace Shelly.Gtk.Helpers;

public static class LogHelpers
{
     public static string BuildFailureSummary(OperationResult result)
    {
        var summarySource = !string.IsNullOrWhiteSpace(result.Error) ? result.Error : result.Output;
        if (string.IsNullOrWhiteSpace(summarySource))
        {
            return string.Empty;
        }

        var lines = summarySource
            .Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .TakeLast(8);

        return string.Join(Environment.NewLine, lines);
    }

    public static string BuildInstallLog(IReadOnlyCollection<string> selectedPackages, OperationResult result, string packageType)
    {
        var stringBuilder = new StringBuilder();
        stringBuilder.AppendLine($"Shelly {packageType} install log");
        stringBuilder.AppendLine($"Generated: {DateTimeOffset.Now:O}");
        stringBuilder.AppendLine($"Packages: {string.Join(", ", selectedPackages)}");
        stringBuilder.AppendLine($"Exit Code: {result.ExitCode}");
        stringBuilder.AppendLine($"Success: {result.Success}");
        stringBuilder.AppendLine();
        stringBuilder.AppendLine("=== STDERR ===");
        stringBuilder.AppendLine(string.IsNullOrWhiteSpace(result.Error) ? "<empty>" : result.Error.TrimEnd());
        stringBuilder.AppendLine();
        stringBuilder.AppendLine("=== STDOUT ===");
        stringBuilder.AppendLine(string.IsNullOrWhiteSpace(result.Output) ? "<empty>" : result.Output.TrimEnd());
        return stringBuilder.ToString();
    }

    public static string CreateSuggestedLogFileName(IReadOnlyCollection<string> selectedPackages, string packageType)
    {
        var packageName = selectedPackages.FirstOrDefault() ?? $"{packageType}-package";
        if (selectedPackages.Count > 1)
        {
            packageName = $"{packageName}-{selectedPackages.Count - 1}-more";
        }

        packageName = Path.GetInvalidFileNameChars().Aggregate(packageName, (current, invalidCharacter) => current.Replace(invalidCharacter, '-'));

        return $"{DateTime.Now:yyyyMMddHHmmss}_{packageType}-install_{packageName}.log";
    }
}