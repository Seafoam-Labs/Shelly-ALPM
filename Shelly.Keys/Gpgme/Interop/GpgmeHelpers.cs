using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Shelly.Keys.Gpgme.Interop;

internal static class GpgmeHelpers
{
    public static string? PtrToStringUTF8(IntPtr ptr)
    {
        return Marshal.PtrToStringUTF8(ptr);
    }
    
    public static void ThrowIfError(uint errorCode)
    {
        if (errorCode != (uint)GpgmeNative.gpg_err_code_t.GPG_ERR_NO_ERROR)
        {
            throw new Exceptions.GpgmeException(errorCode);
        }
    }
    
    public static void ThrowIfErrorString(uint err)
    {
        if (err == 0) return;
        var code   = err & 0xFFFF;
        var source = (err >> 24) & 0xFF;
        var msg    = Marshal.PtrToStringUTF8(GpgmeImports.gpgme_strerror(err));
        var src    = Marshal.PtrToStringUTF8(GpgmeImports.gpgme_strsource(err));
        throw new InvalidOperationException(
            $"GPGME error {err} (0x{err:X8}) source={src}({source}) code={code}: {msg}");
    }
}
