using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using PackageManager.Alpm.Package;

namespace PackageManager.Alpm;

public class AlpmPackage(IntPtr pkgPtr)
{
    public IntPtr PackagePtr { get; } = pkgPtr != IntPtr.Zero
        ? pkgPtr
        : throw new ArgumentException("Package pointer cannot be null", nameof(pkgPtr));

    public string Name
    {
        get
        {
            var namePtr = AlpmReference.GetPkgName(PackagePtr);
            return namePtr != IntPtr.Zero
                ? Marshal.PtrToStringUTF8(namePtr) ?? "unknown"
                : "unknown";
        }
    }

    public string Version
    {
        get
        {
            var versionPtr = AlpmReference.GetPkgVersion(PackagePtr);
            return versionPtr != IntPtr.Zero
                ? Marshal.PtrToStringUTF8(versionPtr) ?? "unknown"
                : "unknown";
        }
    }

    public long Size => AlpmReference.GetPkgSize(PackagePtr);
    public string Description => Marshal.PtrToStringUTF8(AlpmReference.GetPkgDesc(PackagePtr))!;

    public string Url => Marshal.PtrToStringUTF8(AlpmReference.GetPkgUrl(PackagePtr))!;

    public List<string> Replaces => GetDependencyList(AlpmReference.GetPkgReplaces(PackagePtr));

    public string Repository
    {
        get
        {
            IntPtr dbPtr = AlpmReference.GetPkgDb(PackagePtr);
            if (dbPtr == IntPtr.Zero)
            {
                return "local"; // Or handle as an installed/local package
            }

            IntPtr namePtr = AlpmReference.DbGetName(dbPtr);
            return Marshal.PtrToStringUTF8(namePtr) ?? string.Empty;
        }
    }

    public List<string> Licenses
    {
        get
        {
            var licenses = new List<string>();
            IntPtr currentPtr = AlpmReference.GetPkgLicenses(PackagePtr);

            while (currentPtr != IntPtr.Zero)
            {
                var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
                if (node.Data != IntPtr.Zero)
                {
                    var licenseName = Marshal.PtrToStringUTF8(node.Data);
                    if (!string.IsNullOrEmpty(licenseName))
                    {
                        licenses.Add(licenseName);
                    }
                }

                currentPtr = node.Next;
            }

            return licenses;
        }
    }

    public List<string> Groups
    {
        get
        {
            var groups = new List<string>();
            IntPtr currentPtr = AlpmReference.GetPkgGroups(PackagePtr);

            while (currentPtr != IntPtr.Zero)
            {
                var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
                if (node.Data != IntPtr.Zero)
                {
                    var groupName = Marshal.PtrToStringUTF8(node.Data);
                    if (!string.IsNullOrEmpty(groupName))
                    {
                        groups.Add(groupName);
                    }
                }

                currentPtr = node.Next;
            }

            return groups;
        }
    }

    public List<string> Provides => GetDependencyList(AlpmReference.GetPkgProvides(PackagePtr));

    public List<string> Depends => GetDependencyList(AlpmReference.GetPkgDepends(PackagePtr));

    public List<string> OptDepends => GetDependencyList(AlpmReference.GetPkgOptDepends(PackagePtr));

    public List<string> Conflicts => GetDependencyList(AlpmReference.GetPkgConflicts(PackagePtr));

    public string InstallReason =>
        Repository == "local" ? AlpmReference.GetPkgReason(PackagePtr).ToString() : "Not Installed";

    public DateTime BuildDate => DateTimeOffset.FromUnixTimeSeconds(AlpmReference.GetPkgBuildDate(PackagePtr)).DateTime;

    public DateTime? InstallDate
    {
        get
        {
            var timestamp = AlpmReference.GetPkgInstallDate(PackagePtr);
            if (timestamp == 0)
            {
                return null;
            }

            return DateTimeOffset.FromUnixTimeSeconds(timestamp).DateTime;
        }
    }

    public long DownloadSize => AlpmReference.GetPkgSize(PackagePtr);

    public long InstalledSize => AlpmReference.GetPkgISize(PackagePtr);

    public List<string> OptionalFor
    {
        get
        {
            var optionalFor = new List<string>();
            IntPtr currentPtr = AlpmReference.PkgComputeOptionalFor(PackagePtr);

            while (currentPtr != IntPtr.Zero)
            {
                var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
                if (node.Data != IntPtr.Zero)
                {
                    // These are simple package name strings
                    var pkgName = Marshal.PtrToStringUTF8(node.Data);
                    if (!string.IsNullOrEmpty(pkgName))
                    {
                        optionalFor.Add(pkgName);
                    }
                }

                currentPtr = node.Next;
            }

            return optionalFor;
        }
    }

    public static List<AlpmPackage> FromList(IntPtr listPtr)
    {
        var packages = new List<AlpmPackage>();
        var currentPtr = listPtr;
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                packages.Add(new AlpmPackage(node.Data));
            }

            currentPtr = node.Next;
        }

        return packages;
    }

    public AlpmPackageDto ToDto() => new()
    {
        //Todo: implement optionalfor and requiredby
        Name = Name,
        Version = Version,
        Size = Size,
        Description = Description,
        Url = Url,
        Repository = Repository,
        Replaces = Replaces,
        Conflicts = Conflicts,
        Depends = Depends,
        DownloadSize = DownloadSize,
        Groups = Groups,
        InstallDate = InstallDate,
        BuildDate = BuildDate,
        InstalledSize = InstalledSize,
        InstallReason = InstallReason,
        Licenses = Licenses,
        OptDepends = OptDepends,
        Provides = Provides,
        PackageFile = null // Commenting out till protobuff implementation  Repository == "local" ? Files : null,
    };

    public override string ToString()
    {
        return $"Package: {Name}, Version: {Version}, Size: {Size} bytes";
    }

    private static List<string> GetDependencyList(IntPtr listPtr)
    {
        var dependencies = new List<string>();
        var currentPtr = listPtr;
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                var depString = AlpmReference.DepComputeString(node.Data);
                if (depString != IntPtr.Zero)
                {
                    var str = Marshal.PtrToStringUTF8(depString);
                    if (!string.IsNullOrEmpty(str))
                    {
                        dependencies.Add(str);
                    }
                }
            }

            currentPtr = node.Next;
        }

        return dependencies;
    }

    private AlpmPackageTreeDto? _fileTree;

    public AlpmPackageTreeDto Files =>
        _fileTree ??= AlpmPackageFileTreeBuilder.BuildTree(
            AlpmFileListMarshaller.Enumerate(AlpmReference.GetPkgFiles(PackagePtr)));
}