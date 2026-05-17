using System;
using System.Runtime.InteropServices;
using Shelly.Keys.Gpgme.Interop;

namespace Shelly.Keys.Gpgme;

public sealed class GpgmeContext : IDisposable
{
    private GpgmeContextHandle _handle;
    private bool _disposed;

    internal GpgmeContextHandle Handle => _handle;

    static GpgmeContext()
    {
        GpgmeImports.gpgme_check_version(null);
    }
    public GpgmeContext()
    {
        uint err = GpgmeImports.gpgme_new(out _handle);
        GpgmeHelpers.ThrowIfErrorString(err);
    }

    public void SetEngineInfo(GpgmeNative.gpgme_protocol_t proto, string? fileName, string? homeDir)
    {
        var filePtr = IntPtr.Zero;
        var homePtr = IntPtr.Zero;
        try
        {
            filePtr = fileName is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(fileName);
            homePtr = homeDir  is null ? IntPtr.Zero : Marshal.StringToCoTaskMemUTF8(homeDir);

            var err = GpgmeImports.gpgme_ctx_set_engine_info(_handle, proto, filePtr, homePtr);
            GpgmeHelpers.ThrowIfErrorString(err);
        }
        finally
        {
            if (filePtr != IntPtr.Zero) Marshal.FreeCoTaskMem(filePtr);
            if (homePtr != IntPtr.Zero) Marshal.FreeCoTaskMem(homePtr);
        }
    }
    
    // Crypto operations
    public void Verify(GpgmeData sig, GpgmeData signedText, GpgmeData plain)
    {
        var err = GpgmeImports.gpgme_op_verify(_handle, sig.Handle, signedText.Handle, plain?.Handle ?? new GpgmeDataHandle());
        GpgmeHelpers.ThrowIfErrorString(err);
    }

    public void Sign(GpgmeData plain, GpgmeData sig, GpgmeNative.gpgme_sig_mode_t mode)
    {
        var err = GpgmeImports.gpgme_op_sign(_handle, plain.Handle, sig.Handle, mode);
        GpgmeHelpers.ThrowIfErrorString(err);
    }

    public string CheckVersion(string version)
    {
        var versionResp = GpgmeImports.gpgme_check_version(version);
        return GpgmeHelpers.PtrToStringUTF8(versionResp) ?? "Unknown Version";
    }
    
    // gpg-error code for "end of list"
    private const uint GPG_ERR_EOF = 16383;

    public static bool HasSecretKey(GpgmeContext ctx)
    {
        var err = GpgmeImports.gpgme_op_keylist_start(ctx.Handle, pattern: IntPtr.Zero, secret_only: 1);
        GpgmeHelpers.ThrowIfErrorString(err);

        try
        {
            err = GpgmeImports.gpgme_op_keylist_next(ctx.Handle, out IntPtr key);

            if (err == 0)
            {
                // Found one — release it and report true.
                GpgmeImports.gpgme_key_unref(key);
                return true;
            }

            // EOF means no secret keys present.
            if ((err & 0xFFFF) == GPG_ERR_EOF)
                return false;

            GpgmeHelpers.ThrowIfErrorString(err); // any other error
            return false;
        }
        finally
        {
            GpgmeImports.gpgme_op_keylist_end(ctx.Handle);
        }
    }

    private void Dispose(bool disposing)
    {
        if (!_disposed)
        {
            if (disposing)
            {
                _handle?.Dispose();
            }
            _disposed = true;
        }
    }

    public void Dispose()
    {
        Dispose(true);
        GC.SuppressFinalize(this);
    }
}
