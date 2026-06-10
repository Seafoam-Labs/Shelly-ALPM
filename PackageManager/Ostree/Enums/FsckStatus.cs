namespace PackageManager.Ostree.Enums;

public enum FsckStatus
{
    Ok,
    MissingObjects,
    InvalidObjects,
    CorruptedCommit,
    PartialCommit,
    UnknownError
}