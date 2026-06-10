namespace Shelly.Keys.Gpgme.Interop;

public sealed record ImportResult(
    int Considered,
    int Imported,
    int Unchanged,
    int NewSignatures,
    int NewSubKeys,
    int NewUserIds,
    int NewRevocations,
    int SecretImported,
    int SecretUnchanged,
    int NotImported,
    IntPtr Imports,
    int SkippedV3Keys);
    