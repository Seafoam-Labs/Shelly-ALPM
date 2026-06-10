using System;
using System.Runtime.InteropServices;

namespace Shelly.Keys.Gpgme.Interop;

/// <summary>
/// Native types and enumerations for libgpgme.
/// </summary>
public static class GpgmeNative
{
    public const string LibraryName = "gpgme";

    [StructLayout(LayoutKind.Sequential)]
    public struct gpgme_ctx_t
    {
        public IntPtr handle;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct gpgme_data_t
    {
        public IntPtr handle;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct gpgme_key_t
    {
        public IntPtr handle;
    }

    // gpg_error_t is typically an unsigned integer (uint)
    public enum gpg_err_code_t : uint
    {
        GPG_ERR_NO_ERROR = 0,
        GPG_ERR_GENERAL = 1,
        GPG_ERR_UNKNOWN_PACKET = 2,
        GPG_ERR_UNKNOWN_VERSION = 3,
        GPG_ERR_PUBKEY_ALGO = 4,
        GPG_ERR_DIGEST_ALGO = 5,
        GPG_ERR_BAD_PUBKEY = 6,
        GPG_ERR_BAD_SECKEY = 7,
        GPG_ERR_BAD_SIGNATURE = 8,
        GPG_ERR_NO_PUBKEY = 9,
        GPG_ERR_CHECKSUM = 10,
        GPG_ERR_BAD_PASSPHRASE = 11,
        GPG_ERR_CANCELED = 99,
        GPG_ERR_EOF = 16383
    }
    
    public enum gpgme_protocol_t : int
    {
        GPGME_PROTOCOL_OpenPGP = 0,
        GPGME_PROTOCOL_CMS = 1,
        GPGME_PROTOCOL_GPGCONF = 2,
        GPGME_PROTOCOL_ASSUAN = 3,
        GPGME_PROTOCOL_G13 = 4,
        GPGME_PROTOCOL_UISERVER = 5,
        GPGME_PROTOCOL_SPAWN = 6,
        GPGME_PROTOCOL_DEFAULT = 254,
        GPGME_PROTOCOL_UNKNOWN = 255
    }

    public enum gpgme_sig_mode_t : int
    {
        GPGME_SIG_MODE_NORMAL = 0,
        GPGME_SIG_MODE_DETACH = 1,
        GPGME_SIG_MODE_CLEAR = 2
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct gpgme_signature_t
    {
        public IntPtr next;
        public IntPtr summary;
        public IntPtr fpr;
        public uint status;
        public uint timestamp;
        public uint exp_timestamp;
        public uint wrong_key_usage;
        public uint pka_trust;
        public uint chain_model;
        public uint validities;
    }
    
    [StructLayout(LayoutKind.Sequential)]
    internal struct GpgmeGenkeyResult
    {
        public uint bitfield;   // primary:1, sub:1, uid:1, ... packed
        public IntPtr fpr;      // const char *
        public IntPtr pubkey;
        public IntPtr seckey;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct GpgmeImportResult
    {
        public int considered;
        public int no_user_id;
        public int imported;
        public int imported_rsa;
        public int unchanged;
        public int new_user_ids;
        public int new_sub_keys;
        public int new_signatures;
        public int new_revocations;
        public int secret_read;
        public int secret_imported;
        public int secret_unchanged;
        public int not_imported;
        public IntPtr imports;        // gpgme_import_status_t (linked list head)
        public int skipped_v3_keys;
    }

}
