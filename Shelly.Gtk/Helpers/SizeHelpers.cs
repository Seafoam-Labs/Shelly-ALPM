namespace Shelly.Gtk.Helpers;

public static class SizeHelpers
{
    public static string FormatSize(long bytes)
    {
        string[] suffixes = ["B", "KB", "MB", "GB", "TB"];
        var i = 0;
        double dblSByte = bytes;
        while (i < suffixes.Length - 1 && Math.Abs(bytes) >= 1024)
        {
            dblSByte = bytes / 1024.0;
            i++;
            bytes /= 1024;
        }

        return $"{dblSByte:0.##} {suffixes[i]}";
    }
}