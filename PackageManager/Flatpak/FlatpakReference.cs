using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

[assembly: InternalsVisibleTo("PackageManager.Tests")]

namespace PackageManager.Flatpak;

internal static partial class FlatpakReference
{
    public const string LibName = "flatpak";
    public const string GLibName = "glib-2.0";
    public const string GObjectName = "gobject-2.0";

    #region Installations

    [LibraryImport(LibName, EntryPoint = "flatpak_get_system_installations",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr GetSystemInstallations(IntPtr cancellable, out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_installation_new_user",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstallationNewUser(IntPtr cancellable, out IntPtr error);
    
    [LibraryImport(LibName, EntryPoint = "flatpak_installation_list_installed_refs",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstallationListInstalledRefs(IntPtr installation, IntPtr cancellable,
        out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_installation_list_remote_refs_sync",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstallationListRemoteRefsSync(IntPtr installation, string remoteName,
        IntPtr cancellable, out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_installation_fetch_remote_ref_sync",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstallationFetchRemoteRefsSync(IntPtr installation, string remoteName, int kind, string name,
        string arch, string branch, IntPtr cancellable,
        out IntPtr error);
        
    [LibraryImport(LibName, EntryPoint = "flatpak_remote_ref_get_installed_size",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial ulong RemoteRefGetInstalledSize(IntPtr installation);
    
    [LibraryImport(LibName, EntryPoint = "flatpak_remote_ref_get_download_size",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial ulong RemoteRefGetDownloadSize(IntPtr installation);
  
    [LibraryImport(LibName, EntryPoint = "flatpak_installation_new_system",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr FlatpakInstallationNewSystem(IntPtr cancellable, out IntPtr error);
    
    [LibraryImport(LibName, EntryPoint = "flatpak_installation_list_unused_refs",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstallationListUnusedRefs(IntPtr installation, string? arch,
        IntPtr cancellable, out IntPtr error);
    
    [LibraryImport(LibName, EntryPoint = "flatpak_installation_update_remote_sync",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool InstallationUpdateRemoteSync(IntPtr installation, string remoteName,
        IntPtr cancellable, out IntPtr error);
    
    [LibraryImport(LibName, EntryPoint = "flatpak_installation_modify_remote",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool FlatpakInstallationModifyRemote(IntPtr installation, IntPtr remote,
        IntPtr cancellable, out IntPtr error);
    
    #endregion

    #region Refs

    [LibraryImport(LibName, EntryPoint = "flatpak_ref_get_name", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr RefGetName(IntPtr @ref);

    [LibraryImport(LibName, EntryPoint = "flatpak_ref_get_arch", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr RefGetArch(IntPtr @ref);

    [LibraryImport(LibName, EntryPoint = "flatpak_ref_get_branch", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr RefGetBranch(IntPtr @ref);

    [LibraryImport(LibName, EntryPoint = "flatpak_installed_ref_get_appdata_name",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstalledRefGetAppDataName(IntPtr @ref);

    [LibraryImport(LibName, EntryPoint = "flatpak_installed_ref_get_appdata_summary",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstalledRefGetAppDataSummary(IntPtr @ref);

    [LibraryImport(LibName, EntryPoint = "flatpak_installed_ref_get_appdata_version",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstalledRefGetAppDataVersion(IntPtr @ref);

    [LibraryImport(LibName, EntryPoint = "flatpak_installed_ref_get_origin",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstalledRefGetOrigin(IntPtr @ref);

    [LibraryImport(LibName, EntryPoint = "flatpak_installation_launch", StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool InstallationLaunch(IntPtr installation, string name, string? arch, string? branch,
        string? commit, IntPtr cancellable, out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_instance_get_child_pid", StringMarshalling = StringMarshalling.Utf8)]
    public static partial int InstanceGetChildPid(IntPtr instance);

    [LibraryImport(LibName, EntryPoint = "flatpak_instance_get_all", StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool InstanceIsActive(IntPtr instance);

    [LibraryImport(LibName, EntryPoint = "flatpak_instance_get_all", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstanceGetAll();

    [LibraryImport(LibName, EntryPoint = "flatpak_instance_get_app", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstanceGetApp(IntPtr instance);

    [LibraryImport(LibName, EntryPoint = "flatpak_installation_list_installed_refs_for_update",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstanceGetUpdates(IntPtr instance, IntPtr cancellable, out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_installed_ref_get_latest_commit",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstalledGetLatestCommit(IntPtr installation);

    [LibraryImport(LibName, EntryPoint = "flatpak_ref_get_kind", StringMarshalling = StringMarshalling.Utf8)]
    public static partial int RefGetKind(IntPtr instance);

    [Flags]
    public enum FlatpakLaunchFlags : uint
    {
        None = 0,
        FlatpakLaunchFlagsDoNotReap = 1
    }

    #endregion

    #region GLib/GObject

    [LibraryImport(GObjectName, EntryPoint = "g_object_unref")]
    public static partial void GObjectUnref(IntPtr @object);

    [LibraryImport(GLibName, EntryPoint = "g_ptr_array_unref")]
    public static partial void GPtrArrayUnref(IntPtr array);

    [LibraryImport(GLibName, EntryPoint = "g_error_free")]
    public static partial void GErrorFree(IntPtr error);

    [LibraryImport("gio-2.0", EntryPoint = "g_file_get_path", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr GFileGetPath(IntPtr file);

    [LibraryImport("gio-2.0", EntryPoint = "g_file_new_for_path", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr GFileNewForPath(string path);

    #endregion

    #region Remotes

    [LibraryImport(LibName, EntryPoint = "flatpak_installation_list_remotes",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr InstallationListRemotes(IntPtr installation, IntPtr cancellable, out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_remote_get_name", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr RemoteGetName(IntPtr remote);
    
    [LibraryImport(LibName, EntryPoint = "flatpak_installation_update_appstream_sync",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool InstallationUpdateAppstreamSync(IntPtr installation, string remoteName, string? arch,
        [MarshalAs(UnmanagedType.Bool)] out bool outChanged, IntPtr cancellable, out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_installation_add_remote",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool InstallationAddRemote(IntPtr installation, IntPtr remote, [MarshalAs(UnmanagedType.Bool)] bool ifNeeded,
        IntPtr cancellable, out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_installation_remove_remote",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool InstallationRemoveRemote(IntPtr installation, string remoteName,
        IntPtr cancellable, out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_remote_new", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr RemoteNew(string name);

    [LibraryImport(LibName, EntryPoint = "flatpak_remote_get_url", StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr RemoteGetUrl(IntPtr remote);

    [LibraryImport(LibName, EntryPoint = "flatpak_remote_get_gpg_verify", StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RemoteGetGpgVerify(IntPtr remote);

    [LibraryImport(LibName, EntryPoint = "flatpak_remote_set_url", StringMarshalling = StringMarshalling.Utf8)]
    public static partial void RemoteSetUrl(IntPtr remote, string url);

    [LibraryImport(LibName, EntryPoint = "flatpak_remote_set_gpg_verify", StringMarshalling = StringMarshalling.Utf8)]
    public static partial void RemoteSetGpgVerify(IntPtr remote, [MarshalAs(UnmanagedType.Bool)] bool gpgVerify);

    [LibraryImport(LibName, EntryPoint = "flatpak_installation_modify_remote",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool InstallationModifyRemote(IntPtr installation, IntPtr remote,
        IntPtr cancellable, out IntPtr error);

    #endregion

    #region Transaction

    [LibraryImport(LibName, EntryPoint = "flatpak_transaction_new_for_installation",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr TransactionNewForInstallation(IntPtr installation, IntPtr cancellable,
        out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_transaction_add_install", StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool TransactionAddInstall(IntPtr transaction, string remote, string @ref, IntPtr subpaths,
        out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_transaction_add_uninstall",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool TransactionAddUninstall(IntPtr transaction, string @ref, out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "flatpak_transaction_add_update", StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool TransactionAddUpdate(IntPtr transaction, string @ref, IntPtr subpaths, string? commit,
        out IntPtr error);


    [LibraryImport(LibName, EntryPoint = "flatpak_transaction_run", StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool TransactionRun(IntPtr transaction, IntPtr cancellable, out IntPtr error);

    #endregion

    #region Transaction Progress

    [LibraryImport(LibName, EntryPoint = "flatpak_transaction_progress_get_is_estimating")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool TransactionProgressGetIsEstimating(IntPtr progress);

    [LibraryImport(LibName, EntryPoint = "flatpak_transaction_progress_get_progress")]
    public static partial int TransactionProgressGetProgress(IntPtr progress);

    [LibraryImport(LibName, EntryPoint = "flatpak_transaction_progress_get_status")]
    public static partial IntPtr TransactionProgressGetStatus(IntPtr progress);

    [LibraryImport(LibName, EntryPoint = "flatpak_transaction_progress_set_update_frequency")]
    public static partial void TransactionProgressSetUpdateFrequency(IntPtr progress, uint updateInterval);
    #endregion

    #region GObject Signals

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void TransactionProgressCallback(IntPtr transaction, IntPtr progress, IntPtr userData);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void TransactionNewOperationCallback(IntPtr transaction, IntPtr operation, IntPtr progress, IntPtr userData);

    [LibraryImport(GObjectName, EntryPoint = "g_signal_connect_data", StringMarshalling = StringMarshalling.Utf8)]
    public static partial ulong GSignalConnectData(IntPtr instance, string detailedSignal, IntPtr handler,
        IntPtr data, IntPtr destroyData, int connectFlags);

    #endregion

    public const int FlatpakRefKindApp = 0;
    public const int FlatpakRefKindRuntime = 1;

    // This static constructor sets up the resolver
    static FlatpakReference()
    {
        NativeResolver.Initialize();
    }

    public static string GetErrorMessage(IntPtr errorPtr)
    {
        if (errorPtr == IntPtr.Zero)
            return "Unknown error";

        try
        {
            var offset = 8;
            var messagePtr = Marshal.ReadIntPtr(errorPtr, offset);

            if (messagePtr == IntPtr.Zero)
                return "Error message is null";

            var message = Marshal.PtrToStringUTF8(messagePtr);
            return message ?? "Unknown error";
        }
        catch (Exception ex)
        {
            return $"Failed to read error message: {ex.Message}";
        }
    }
}