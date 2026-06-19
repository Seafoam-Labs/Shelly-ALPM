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

    /// <summary>
    /// The number of bytes in one unit of the given SizeDisplay.
    /// </summary>
    private static double UnitFactor(SizeDisplay sizeDisplay) => sizeDisplay switch
    {
        SizeDisplay.Bytes => 1.0,
        SizeDisplay.Megabytes => 1048576.0, // 1024 * 1024
        SizeDisplay.Gigabytes => 1073741824.0, // 1024 * 1024 * 1024
        _ => 1.0
    };

    public static double ConvertSize(SizeDisplay sizeDisplay, ulong? bytes)
        => (bytes ?? 0) / UnitFactor(sizeDisplay);
}