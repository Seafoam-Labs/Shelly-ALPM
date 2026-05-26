using System;
using static PackageManager.Alpm.AlpmReference;

namespace PackageManager.Alpm.Utilities;

public static class PackageUtilities
{
    public static bool IsPackageInstalled(IntPtr handle, string name)
    {
        var localDb = GetLocalDb(handle);
        if (localDb == IntPtr.Zero)
        {
            return false;
        }
        var pkg = DbGetPkg(localDb, name);
        return pkg != IntPtr.Zero;
    }
}