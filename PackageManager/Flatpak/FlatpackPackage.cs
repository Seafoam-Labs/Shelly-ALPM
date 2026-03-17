using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using PackageManager.Alpm;
using PackageManager.Utilities;

namespace PackageManager.Flatpak;

public class FlatpackPackage(IntPtr pkgPtr)
{

    public string Id => PtrToStringSafe(FlatpakReference.RefGetName(pkgPtr));
    public string Arch => PtrToStringSafe(FlatpakReference.RefGetArch(pkgPtr));
    public string Branch => PtrToStringSafe(FlatpakReference.RefGetBranch(pkgPtr));
    public string Name => PtrToStringSafe(FlatpakReference.InstalledRefGetAppDataName(pkgPtr)) is { Length: > 0 } name ? name : Id;
    public string Summary => PtrToStringSafe(FlatpakReference.InstalledRefGetAppDataSummary(pkgPtr));
    public string LastCommit => PtrToStringSafe(FlatpakReference.InstalledGetLatestCommit(pkgPtr));
    public string Version => PtrToStringSafe(FlatpakReference.InstalledRefGetAppDataVersion(pkgPtr)) is { Length: > 0 } ver ? ver : Branch;
    public string Origin => PtrToStringSafe(FlatpakReference.InstalledRefGetOrigin(pkgPtr));

    public int Kind => FlatpakReference.RefGetKind(pkgPtr);
    
    private static string PtrToStringSafe(IntPtr ptr)
    {
        return ptr == IntPtr.Zero ? string.Empty : Marshal.PtrToStringUTF8(ptr) ?? string.Empty;
    }
    
    public static List<FlatpackPackage> FromList(IntPtr listPtr)
    {
        var packages = new List<FlatpackPackage>();
        var currentPtr = listPtr;
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<FlatpakList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                packages.Add(new FlatpackPackage(node.Data));
            }

            currentPtr = node.Next;
        }

        return packages;
    }

    public FlatpakPackageDto ToDto() => new FlatpakPackageDto
    {
        Id = Id,
        Branch = Branch,
        Name = Name,
        Arch = Arch,
        Summary = Summary,
        Version = Version,
        LatestCommit = LastCommit,
        Kind = Kind,
        remote = Origin
    };

    public override string ToString()
    {
        return $"Package: {Id}, Version: {Version}, Arch: {Arch}, Branch: {Branch}, Name: {Name}, Summary: {Summary}";
    }

}