using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;

namespace PackageManager;

public static class NativeResolver
{
    private static bool _isInitialized;
    private static readonly Lock Lock = new();
    private static readonly Dictionary<string, bool> AvailabilityCache = new();

    public static void Initialize()
    {
        if (_isInitialized) return;

        lock (Lock)
        {
            if (_isInitialized) return;

            NativeLibrary.SetDllImportResolver(typeof(NativeResolver).Assembly, Resolve);
            _isInitialized = true;
        }
    }

    public static bool IsLibraryAvailable(string libraryName)
    {
        Initialize();

        lock (Lock)
        {
            if (AvailabilityCache.TryGetValue(libraryName, out var available))
                return available;

            var handle = Resolve(libraryName, typeof(NativeResolver).Assembly, null);
            var isAvailable = handle != IntPtr.Zero;
            AvailabilityCache[libraryName] = isAvailable;
            return isAvailable;
        }
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        return libraryName switch
        {
            "alpm" => ResolveAlpm(assembly, searchPath),
            "flatpak" => ResolveFlatpak(assembly, searchPath),
            "glib-2.0" => ResolveGLib(assembly, searchPath),
            "gobject-2.0" => ResolveGObject(assembly, searchPath),
            "archive" => ResolveArchive(assembly, searchPath),
            "libzstd" => ResolveZstd(assembly, searchPath),
            "ostree-1" => ResolveOstree(assembly, searchPath),
            _ => IntPtr.Zero
        };
    }

    private static IntPtr ResolveArchive(Assembly assembly, DllImportSearchPath? searchPath)
    {
        string[] versions = ["libarchive.so.13", "libarchive.so"];
        return TryLoad(versions, assembly, searchPath);
    }

    private static IntPtr ResolveAlpm(Assembly assembly, DllImportSearchPath? searchPath)
    {
        string[] versions =
        [
            "libalpm.so.16.0.1", "libalpm.so.16", "libalpm.so.15", "libalpm.so.14", "libalpm.so.13", "libalpm.so"
        ];
        return TryLoad(versions, assembly, searchPath);
    }

    private static IntPtr ResolveFlatpak(Assembly assembly, DllImportSearchPath? searchPath)
    {
        string[] versions = ["libflatpak.so.0", "libflatpak.so"];
        return TryLoad(versions, assembly, searchPath);
    }

    private static IntPtr ResolveGLib(Assembly assembly, DllImportSearchPath? searchPath)
    {
        string[] versions = ["libglib-2.0.so.0", "libglib-2.0.so"];
        return TryLoad(versions, assembly, searchPath);
    }

    private static IntPtr ResolveGObject(Assembly assembly, DllImportSearchPath? searchPath)
    {
        string[] versions = ["libgobject-2.0.so.0", "libgobject-2.0.so"];
        return TryLoad(versions, assembly, searchPath);
    }

    private static IntPtr ResolveZstd(Assembly assembly, DllImportSearchPath? searchPath)
    {
        string[] versions = ["libzstd.so.1", "libzstd.so"];
        return TryLoad(versions, assembly, searchPath);
    }

    private static IntPtr ResolveOstree(Assembly assembly, DllImportSearchPath? searchPath)
    {
        string[] versions =
        [
            "libostree-1.so.1", "libostree-1.so", "libostree.so.0", "libostree.so"
        ];

        return TryLoad(versions, assembly, searchPath);
    }

    private static IntPtr TryLoad(string[] versions, Assembly assembly, DllImportSearchPath? searchPath)
    {
        foreach (var version in versions)
        {
            if (NativeLibrary.TryLoad(version, assembly, searchPath, out var handle))
                return handle;
        }

        return IntPtr.Zero;
    }
}