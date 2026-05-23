using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using static PackageManager.Alpm.AlpmReference;

namespace PackageManager.Alpm.Utilities;

public static class PackageListBuilder
{
    public static List<IntPtr> Build(nint handle, List<string> packageNames)
    {
        List<IntPtr> pkgPtrs = [];
        foreach (var packageName in packageNames)
        {
            // Find the package in sync databases
            IntPtr pkgPtr = IntPtr.Zero;
            var syncDbsPtr = GetSyncDbs(handle);
            var currentPtr = syncDbsPtr;
            List<IntPtr> groupPkgs = null;
            while (currentPtr != IntPtr.Zero)
            {
                var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
                if (node.Data != IntPtr.Zero)
                {
                    pkgPtr = DbGetPkg(node.Data, packageName);
                    if (pkgPtr != IntPtr.Zero) break;

                    //Group search next
                    var groupCachePtr = DbGetGroupCache(node.Data);
                    var groupNode = groupCachePtr;
                    while (groupNode != IntPtr.Zero)
                    {
                        var groupNodeData = Marshal.PtrToStructure<AlpmList>(groupNode);
                        if (groupNodeData.Data != IntPtr.Zero)
                        {
                            var group = Marshal.PtrToStructure<AlpmPackageGroup>(groupNodeData.Data);
                            var groupName = Marshal.PtrToStringUTF8(group.Name);
                            try
                            {
                                if (groupName!.Equals(packageName, StringComparison.OrdinalIgnoreCase))
                                {
                                    groupPkgs = new List<IntPtr>();
                                    var pkgNode = group.Packages;
                                    while (pkgNode != IntPtr.Zero)
                                    {
                                        var pkg = Marshal.PtrToStructure<AlpmList>(pkgNode);
                                        if (pkg.Data != IntPtr.Zero)
                                        {
                                            groupPkgs.Add(pkg.Data);
                                        }

                                        pkgNode = pkg.Next;
                                    }

                                    break;
                                }
                            }
                            catch (Exception ex)
                            {
                                Console.Error.WriteLine($"[DEBUG_LOG] Exception: {ex.Message}");
                            }
                        }

                        groupNode = groupNodeData.Next;
                    }

                    if (groupPkgs != null)
                    {
                        break;
                    }

                    var pkgCache = DbGetPkgCache(node.Data);
                    pkgPtr = PkgFindSatisfier(pkgCache, packageName);
                    if (pkgPtr != IntPtr.Zero)
                    {
                        break;
                    }
                }

                currentPtr = node.Next;
            }

            if (pkgPtr == IntPtr.Zero && groupPkgs == null)
            {
                Console.Error.WriteLine($"[ALPM_ERROR]Package '{packageName}' not found in any sync database.");
                throw new Exception($"Package '{packageName}' not found in any sync database.");
            }

            if (pkgPtr != IntPtr.Zero)
            {
                pkgPtrs.Add(pkgPtr);
            }

            if (groupPkgs != null)
            {
                pkgPtrs.AddRange(groupPkgs);
            }
        }

        return pkgPtrs;
    }

    public static bool IsAvailableInSyncDbs(nint handle, string packageName)
    {
        var currentPtr = GetSyncDbs(handle);
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                if (DbGetPkg(node.Data, packageName) != IntPtr.Zero) return true;

                var groupNode = DbGetGroupCache(node.Data);
                while (groupNode != IntPtr.Zero)
                {
                    var groupListNode = Marshal.PtrToStructure<AlpmList>(groupNode);
                    if (groupListNode.Data != IntPtr.Zero)
                    {
                        var group = Marshal.PtrToStructure<AlpmPackageGroup>(groupListNode.Data);
                        var groupName = Marshal.PtrToStringUTF8(group.Name);
                        if (groupName != null &&
                            groupName.Equals(packageName, StringComparison.OrdinalIgnoreCase))
                        {
                            return true;
                        }
                    }
                    groupNode = groupListNode.Next;
                }

                if (PkgFindSatisfier(DbGetPkgCache(node.Data), packageName) != IntPtr.Zero)
                    return true;
            }
            currentPtr = node.Next;
        }
        return false;
    }
}