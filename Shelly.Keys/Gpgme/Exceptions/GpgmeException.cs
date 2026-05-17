using System;
using Shelly.Keys.Gpgme.Interop;

namespace Shelly.Keys.Gpgme.Exceptions;

/// <summary>
/// Exception thrown when a GPGME operation fails.
/// </summary>
public class GpgmeException : Exception
{
    public uint ErrorCode { get; }

    public GpgmeException(uint errorCode)
        : base(GetErrorMessage(errorCode))
    {
        ErrorCode = errorCode;
    }

    private static string GetErrorMessage(uint errorCode)
    {
        var errorStringPtr = GpgmeImports.gpgme_strerror(errorCode);
        var sourceStringPtr = GpgmeImports.gpgme_strsource(errorCode);

        var errorString = GpgmeHelpers.PtrToStringUTF8(errorStringPtr) ?? "Unknown Error";
        var sourceString = GpgmeHelpers.PtrToStringUTF8(sourceStringPtr) ?? "Unknown Source";

        return $"{sourceString}: {errorString} (Code: {errorCode})";
    }
}
