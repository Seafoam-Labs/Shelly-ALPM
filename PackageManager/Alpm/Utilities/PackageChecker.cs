using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;

namespace PackageManager.Alpm.Utilities;

public static class PackageChecker
{
    public static bool IsStillNeededByOther(IntPtr localPkgPtr, HashSet<string> removedSet)
    {
        return Walk(AlpmReference.PkgComputeRequiredBy(localPkgPtr)).Any(consumer => !removedSet.Contains(consumer)) ||
               Walk(AlpmReference.PkgComputeOptionalFor(localPkgPtr)).Any(consumer => !removedSet.Contains(consumer));
    }

    private static IEnumerable<string> Walk(IntPtr listPtr)
    {
        var cur = listPtr;
        while (cur != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(cur);
            if (node.Data != IntPtr.Zero)
            {
                var s = Marshal.PtrToStringUTF8(node.Data);
                if (!string.IsNullOrEmpty(s)) yield return s;
            }

            cur = node.Next;
        }
    }
}