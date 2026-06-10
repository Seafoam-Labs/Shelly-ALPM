namespace PackageManager.Ostree;

public class OstreePruneResult
{
    public bool Success { get; set; }

    public long ObjectsTotal { get; set; }

    public long ObjectsPruned { get; set; }

    public ulong PrunedBytes { get; set; }

    public string? ErrorMessage { get; set; }
}