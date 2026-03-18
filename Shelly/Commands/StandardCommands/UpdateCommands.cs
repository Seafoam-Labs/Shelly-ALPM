using PackageManager.Alpm;

namespace Shelly.Commands.StandardCommands;

internal static class UpdateCommands
{
    internal static int UpdateUiMode(List<string> packages, bool verbose = false, bool force = false)
    {
        var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFilePath());
        return 0;
    }
}