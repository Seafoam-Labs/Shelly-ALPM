using System;
using System.Runtime.InteropServices;

namespace PackageManager.Ostree;

internal static partial class OstreeReference
{
    public const string LibName = "ostree-1";
    public const string GioName = "gio-2.0";
    public const string GLibName = "glib-2.0";
    public const string GObjectName = "gobject-2.0";

    static OstreeReference()
    {
        NativeResolver.Initialize();
    }

    [LibraryImport(GioName, EntryPoint = "g_file_new_for_path",
        StringMarshalling = StringMarshalling.Utf8)]
    public static partial IntPtr GFileNewForPath(string path);

    [LibraryImport(GObjectName, EntryPoint = "g_object_unref")]
    public static partial void GObjectUnref(IntPtr obj);

    [LibraryImport(LibName, EntryPoint = "ostree_repo_new")]
    public static partial IntPtr RepoNew(IntPtr path);
    
    [LibraryImport(LibName, EntryPoint = "ostree_repo_list_refs",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RepoListRefs(
        IntPtr repo,
        string? prefix,
        out IntPtr outAllRefs,
        IntPtr cancellable,
        out IntPtr error);
    
    [StructLayout(LayoutKind.Sequential)]
    public struct GHashTableIter
    {
        public IntPtr Dummy1;
        public IntPtr Dummy2;
        public IntPtr Dummy3;
        public int Dummy4;
        public int Dummy5;
        public IntPtr Dummy6;
    }

    [LibraryImport(GLibName, EntryPoint = "g_hash_table_iter_init")]
    public static partial void GHashTableIterInit(
        out GHashTableIter iter,
        IntPtr hashTable);

    [LibraryImport(GLibName, EntryPoint = "g_hash_table_iter_next")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GHashTableIterNext(
        ref GHashTableIter iter,
        out IntPtr key,
        out IntPtr value);

    [LibraryImport(LibName, EntryPoint = "ostree_repo_open")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RepoOpen(
        IntPtr repo,
        IntPtr cancellable,
        out IntPtr error);
    
    [LibraryImport(LibName, EntryPoint = "ostree_repo_fsck_object",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RepoFsckObject(
        IntPtr repo,
        int objectType,
        string checksum,
        IntPtr cancellable,
        out IntPtr error);

    [LibraryImport(LibName, EntryPoint = "ostree_repo_resolve_rev",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RepoResolveRev(
        IntPtr repo,
        string rev,
        [MarshalAs(UnmanagedType.Bool)] bool allowNoent,
        out IntPtr outRev,
        IntPtr cancellable,
        out IntPtr error);

    [LibraryImport(GLibName, EntryPoint = "g_error_free")]
    public static partial void GErrorFree(IntPtr error);

    [LibraryImport(GLibName, EntryPoint = "g_free")]
    public static partial void GFree(IntPtr ptr);
    
    [LibraryImport(LibName,
        EntryPoint = "ostree_parse_refspec",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool OstreeParseRefspec(
        string refspec,
        out IntPtr outRemote,
        out IntPtr outRef,
        out IntPtr error);
    
    [LibraryImport(LibName,
        EntryPoint = "ostree_repo_set_ref_immediate",
        StringMarshalling = StringMarshalling.Utf8)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RepoSetRefImmediate(
        IntPtr repo,
        string? remote,
        string @ref,
        string? checksum,
        IntPtr cancellable,
        out IntPtr error);
    
    [LibraryImport(LibName, EntryPoint = "ostree_repo_prune")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RepoPrune(
        IntPtr repo,
        int flags, 
        int depth,
        out long outObjectsTotal,
        out long outObjectsPruned,
        out ulong outPrunedObjectSizeTotal,
        IntPtr cancellable,
        out IntPtr error);
}

