using ConsoleAppFramework;
using Shelly.Commands.FlatpakCommands;
// ReSharper disable InvalidXmlDocComment
namespace Shelly.Commands;
[RegisterCommands("flatpak")]
internal class Flatpak
{
    /// <summary>
    /// Install a Flatpak application
    /// </summary>
    /// <param name="package">Flatpak application ID (e.g., com.spotify.Client)</param>
    /// <param name="user">install to user scope instead of system scope</param>
    /// <param name="remote">-r,remote to install from (e.g., flathub, flathub-beta)</param>
    /// <param name="branch">-b,branch to install (e.g., stable, beta). Defaults to stable</param>
    /// <returns></returns>
    public int Install(ConsoleAppContext context, [Argument] string package, bool user = false, string? remote = null, string branch = "stable")
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakInstallCommands.InstallUiMode(package, user, remote, branch)
            : FlatpakInstallCommands.InstallConsoleMode(package, user, remote, branch);
    }
    /// <summary>
    /// Install a Flatpak application from a .flatpakref file
    /// </summary>
    /// <param name="refFilePath">path to the .flatpakref file</param>
    /// <param name="system">install system-wide</param>
    /// <returns></returns>
    public int InstallFromRef(ConsoleAppContext context, [Argument] string refFilePath, bool system = true)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakInstallFromRefCommands.InstallFromRefUiMode(refFilePath, system)
            : FlatpakInstallFromRefCommands.InstallFromRefConsoleMode(refFilePath, system);
    }
    /// <summary>
    /// Remove a Flatpak application
    /// </summary>
    /// <param name="package">Flatpak application ID (e.g., com.spotify.Client)</param>
    /// <param name="removeUnused">remove unused dependencies after uninstalling</param>
    /// <returns></returns>
    public int Remove(ConsoleAppContext context, [Argument] string package, bool removeUnused = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakRemoveCommands.RemoveUiMode(package, removeUnused)
            : FlatpakRemoveCommands.RemoveConsoleMode(package, removeUnused);
    }
    /// <summary>
    /// List installed Flatpak applications
    /// </summary>
    /// <param name="json">-j,output results in JSON format</param>
    /// <returns></returns>
    public int List(ConsoleAppContext context, bool json = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakListCommands.ListUiMode(json)
            : FlatpakListCommands.ListConsoleMode(json);
    }
    /// <summary>
    /// List Flatpak applications that have updates available
    /// </summary>
    /// <param name="json">-j,output results in JSON format</param>
    /// <returns></returns>
    public int ListUpdates(ConsoleAppContext context, bool json = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakListUpdatesCommands.ListUpdatesUiMode(json)
            : FlatpakListUpdatesCommands.ListUpdatesConsoleMode(json);
    }
    /// <summary>
    /// List configured Flatpak remotes
    /// </summary>
    /// <param name="json">-j,output results in JSON format</param>
    /// <returns></returns>
    public int ListRemotes(ConsoleAppContext context, bool json = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakListRemotesCommands.ListRemotesUiMode(json)
            : FlatpakListRemotesCommands.ListRemotesConsoleMode(json);
    }
    /// <summary>
    /// Search for Flatpak applications across all configured remotes
    /// </summary>
    /// <param name="query">search query</param>
    /// <param name="json">-j,output results in JSON format</param>
    /// <param name="limit">-l,maximum number of search results to display per page</param>
    /// <param name="page">-p,page number for paginated results (starts at 1)</param>
    /// <returns></returns>
    public async Task<int> Search(ConsoleAppContext context, [Argument] string query, bool json = false, int limit = 21, int page = 1)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? await FlatpakSearchCommands.SearchUiMode(query, json, limit, page)
            : await FlatpakSearchCommands.SearchConsoleMode(query, json, limit, page);
    }
    /// <summary>
    /// Update a specific Flatpak application
    /// </summary>
    /// <param name="package">Flatpak application ID (e.g., com.spotify.Client)</param>
    /// <returns></returns>
    public int Update(ConsoleAppContext context, [Argument] string package)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakUpdateCommands.UpdateUiMode(package)
            : FlatpakUpdateCommands.UpdateConsoleMode(package);
    }
    /// <summary>
    /// Upgrade all Flatpak applications
    /// </summary>
    /// <returns></returns>
    public int Upgrade(ConsoleAppContext context)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakUpgradeCommands.UpgradeUiMode()
            : FlatpakUpgradeCommands.UpgradeConsoleMode();
    }
    /// <summary>
    /// Run a Flatpak application
    /// </summary>
    /// <param name="package">Flatpak application ID (e.g., com.spotify.Client)</param>
    /// <returns></returns>
    public int Run(ConsoleAppContext context, [Argument] string package)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakRunCommands.RunUiMode(package)
            : FlatpakRunCommands.RunConsoleMode(package);
    }
    /// <summary>
    /// List currently running Flatpak instances
    /// </summary>
    /// <returns></returns>
    public int Running(ConsoleAppContext context)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakRunningCommands.RunningUiMode()
            : FlatpakRunningCommands.RunningConsoleMode();
    }
    /// <summary>
    /// Kill a running Flatpak application
    /// </summary>
    /// <param name="package">Flatpak application ID (e.g., com.spotify.Client)</param>
    /// <returns></returns>
    public int Kill(ConsoleAppContext context, [Argument] string package)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakKillCommands.KillUiMode(package)
            : FlatpakKillCommands.KillConsoleMode(package);
    }
    /// <summary>
    /// Add a Flatpak remote
    /// </summary>
    /// <param name="remoteName">Flatpak remote name (e.g., flathub)</param>
    /// <param name="remoteUrl">-u,URL of the remote</param>
    /// <param name="system">-s,install system-wide</param>
    /// <param name="gpgVerify">-g,enable GPG verification</param>
    /// <returns></returns>
    public int AddRemote(ConsoleAppContext context, [Argument] string remoteName, string remoteUrl, bool system = true, bool gpgVerify = true)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakAddRemoteCommands.AddRemoteUiMode(remoteName, remoteUrl, system, gpgVerify)
            : FlatpakAddRemoteCommands.AddRemoteConsoleMode(remoteName, remoteUrl, system, gpgVerify);
    }
    /// <summary>
    /// Remove a Flatpak remote
    /// </summary>
    /// <param name="remoteName">Flatpak remote name (e.g., flathub)</param>
    /// <param name="system">-s,remove system-wide</param>
    /// <returns></returns>
    public int RemoveRemote(ConsoleAppContext context, [Argument] string remoteName, bool system = true)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakRemoveRemoteCommands.RemoveRemoteUiMode(remoteName, system)
            : FlatpakRemoveRemoteCommands.RemoveRemoteConsoleMode(remoteName, system);
    }
    /// <summary>
    /// Sync appstream data from all configured remotes
    /// </summary>
    /// <returns></returns>
    public int SyncAppStream(ConsoleAppContext context)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakSyncAppStreamCommands.SyncAppStreamUiMode()
            : FlatpakSyncAppStreamCommands.SyncAppStreamConsoleMode();
    }
    /// <summary>
    /// Get available apps from a remote's appstream data
    /// </summary>
    /// <param name="appStreamName">remote name or 'all' to retrieve all appstreams</param>
    /// <returns></returns>
    public int GetRemote(ConsoleAppContext context, [Argument] string appStreamName)
    {
        return FlatpakGetRemoteCommands.GetRemote(appStreamName);
    }
    /// <summary>
    /// Get remote size information for a Flatpak application
    /// </summary>
    /// <param name="remote">remote name</param>
    /// <param name="id">application ID</param>
    /// <param name="branch">branch name</param>
    /// <param name="json">-j,output results in JSON format</param>
    /// <returns></returns>
    public int GetAppRemoteInfo(ConsoleAppContext context, [Argument] string remote, [Argument] string id, [Argument] string branch, bool json = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? FlatpakGetAppRemoteInfoCommands.GetAppRemoteInfoUiMode(remote, id, branch, json)
            : FlatpakGetAppRemoteInfoCommands.GetAppRemoteInfoConsoleMode(remote, id, branch, json);
    }
}
