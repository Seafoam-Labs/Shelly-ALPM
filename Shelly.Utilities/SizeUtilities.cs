using Shelly.Utilities.Enums;

namespace Shelly.Utilities;

public static class SizeUtilities
{
    public static string FormatSize(SizeDisplay sizeDisplay, double bytes)
    {
        return sizeDisplay switch
        {
            SizeDisplay.Bytes => $"{bytes:0} B",
            SizeDisplay.Megabytes => $"{bytes / 1048576.0:F2} MiB",
            SizeDisplay.Gigabytes => $"{bytes / 1073741824.0:F2} GiB",
            _ => $"{bytes:0} B"
        };
    }
}