namespace PackageManager.Ostree.Enums;

public enum OstreeRepoPruneFlags
{
    None = 0,
    NoPrune = 1 << 0,
    RefsOnly = 1 << 1,
    CommitOnly = 1 << 2,
}