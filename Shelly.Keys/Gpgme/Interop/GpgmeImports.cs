using System;
using System.Runtime.InteropServices;

namespace Shelly.Keys.Gpgme.Interop;

internal static partial class GpgmeImports
{
    private const string LibraryName = GpgmeNative.LibraryName;

    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr gpgme_check_version(string? req_version);

    [LibraryImport(LibraryName)]
    public static partial uint gpgme_new(out GpgmeContextHandle ctx);

    [LibraryImport(LibraryName)]
    public static partial void gpgme_release(IntPtr ctx);

    [LibraryImport(LibraryName)]
    public static partial uint gpgme_ctx_set_engine_info(GpgmeContextHandle ctx, GpgmeNative.gpgme_protocol_t proto, IntPtr file_name, IntPtr  home_dir);

    // Data operations
    [LibraryImport(LibraryName)]
    public static partial uint gpgme_data_new_from_mem(out GpgmeDataHandle data, IntPtr buffer, UIntPtr size, int copy);

    [LibraryImport(LibraryName)]
    public static partial uint gpgme_data_new_from_fd(out GpgmeDataHandle data, int fd);

    [LibraryImport(LibraryName)]
    public static partial void gpgme_data_release(IntPtr data);

    [LibraryImport(LibraryName)]
    public static partial IntPtr gpgme_data_read(GpgmeDataHandle data, IntPtr buffer, UIntPtr size);

    [LibraryImport(LibraryName)]
    public static partial IntPtr gpgme_data_write(GpgmeDataHandle data, IntPtr buffer, UIntPtr size);

    [LibraryImport(LibraryName)]
    public static partial long gpgme_data_seek(GpgmeDataHandle data, long offset, int whence);

    // Key operations
    [LibraryImport(LibraryName)]
    public static partial uint gpgme_op_keylist_start(GpgmeContextHandle ctx, IntPtr pattern, int secret_only);

    [LibraryImport(LibraryName)]
    public static partial uint gpgme_op_keylist_next(GpgmeContextHandle ctx, out IntPtr key);

    [LibraryImport(LibraryName)]
    public static partial uint gpgme_op_keylist_end(GpgmeContextHandle ctx);

    [LibraryImport(LibraryName)]
    public static partial void gpgme_key_unref(IntPtr key);

    // Crypto operations
    [LibraryImport(LibraryName)]
    public static partial uint gpgme_op_verify(GpgmeContextHandle ctx, GpgmeDataHandle sig, GpgmeDataHandle signed_text, GpgmeDataHandle plain);

    [LibraryImport(LibraryName)]
    public static partial uint gpgme_op_sign(GpgmeContextHandle ctx, GpgmeDataHandle plain, GpgmeDataHandle sig, GpgmeNative.gpgme_sig_mode_t mode);

    [LibraryImport(LibraryName)]
    public static partial uint gpgme_op_encrypt(GpgmeContextHandle ctx, IntPtr recp, GpgmeNative.gpgme_protocol_t flags, GpgmeDataHandle plain, GpgmeDataHandle ciph);

    [LibraryImport(LibraryName)]
    public static partial uint gpgme_op_decrypt(GpgmeContextHandle ctx, GpgmeDataHandle ciph, GpgmeDataHandle plain);

    // Key generation
    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    public static partial uint gpgme_op_createkey(
        GpgmeContextHandle ctx,
        string userid,
        string? algo,
        IntPtr reserved,
        ulong expires,
        IntPtr extrakey,
        uint flags);

    [LibraryImport(LibraryName)]
    public static partial IntPtr gpgme_op_genkey_result(GpgmeContextHandle ctx);
    
    // Error handling from libgpg-error (often linked implicitly or explicitly)
    [LibraryImport(LibraryName)]
    public static partial IntPtr gpgme_strerror(uint err);

    [LibraryImport(LibraryName)]
    public static partial IntPtr gpgme_strsource(uint err);
    
    [LibraryImport(LibraryName)]
    public static partial uint gpgme_engine_check_version(GpgmeNative.gpgme_protocol_t proto);
}
