namespace PackageManager.AppImage.Events.EventArgs;

public class AppImageProgressEventArgs(string appName, long? totalBytes, long downloadedBytes, double? progressPercentage) : System.EventArgs
{
    public string AppName { get; } = appName;
    public long? TotalBytes { get; } = totalBytes;
    public long DownloadedBytes { get; } = downloadedBytes;
    public double? ProgressPercentage { get; } = progressPercentage;
}
