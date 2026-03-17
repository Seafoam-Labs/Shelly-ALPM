using System;

namespace PackageManager.Alpm;

public enum AlpmRetrieveType
{
    DatabaseRetrieve,
    PackageRetrieve
}

public enum AlpmRetrieveStatus
{
    Start,
    Done,
    Failed
}

public class AlpmRetrieveEventArgs(AlpmRetrieveType retrieveType, AlpmRetrieveStatus status) : EventArgs
{
    public AlpmRetrieveType RetrieveType { get; } = retrieveType;
    public AlpmRetrieveStatus Status { get; } = status;
}
