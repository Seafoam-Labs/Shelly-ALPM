using PackageManager;
using PackageManager.Alpm.Pacfile;
using Shelly.Cli.Models.Pacfile;

namespace Shelly.Cli.Outputs;

internal static class PacfileFlusher
{
    public static async Task FlushAsync(List<PendingPacfile> pending, object gate)
    {
        PendingPacfile[] snapshot;
        lock (gate)
        {
            if (pending.Count == 0) return;
            snapshot = pending.ToArray();
            pending.Clear();
        }

        var storePath = ShellyDatastore.GetPacfileStoragePath();
        await using var manager = new PacfileManager(storePath);
        foreach (var item in snapshot)
        {
            if (!File.Exists(item.FileLocation)) continue;

            string text;
            try
            {
                text = await File.ReadAllTextAsync(item.FileLocation);
            }
            catch
            {
                continue;
            }

            var suffix = item.Kind == PacfileType.Pacnew ? ".pacnew" : ".pacsave";
            var pkg = string.IsNullOrWhiteSpace(item.PackageName) ? "unknown" : item.PackageName!;
            var name = $"{pkg}/{Path.GetFileName(item.FileLocation)}{suffix}@{item.CapturedUtc:yyyyMMddTHHmmssZ}";
            await manager.SavePacfile(new PacfileRecord(name, text));
        }
    }
}