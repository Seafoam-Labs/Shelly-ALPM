using System.Diagnostics.CodeAnalysis;
using ConsoleAppFramework;
using PackageManager.Alpm;
using Shelly.Commands.StandardCommands;
// ReSharper disable InvalidXmlDocComment
namespace Shelly.Commands;
[RegisterCommands]
[SuppressMessage("GenerateConsoleAppFramework", "CAF007:Command name is duplicated.")]
internal class Standard
{
    /// <summary>
    /// Synchronize package databases
    /// </summary>
    /// <param name="force">-f,force the sync of the package databases </param>
    /// <returns></returns>
    public int Sync(ConsoleAppContext context, bool force = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode ? SyncCommands.SyncUiMode(globals.Verbose, force) : SyncCommands.SyncConsoleMode(globals.Verbose, force);
    }
    /// <summary>
    /// Upgrades all system packages
    /// </summary>
    /// <param name="force">-f,force the sync of the package databases </param>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <returns></returns>
    public int Upgrade(ConsoleAppContext context, bool force = false, bool noConfirm = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? UpgradeCommands.UpgradeUiMode(globals.Verbose, force, noConfirm)
            : UpgradeCommands.UpgradeConsole(globals.Verbose, force, noConfirm);
    }

    /// <summary>
    /// Install one or more packages
    /// </summary>
    /// <param name="packages">packages to install (space-separated)</param>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <param name="buildDeps">-o,install build dependencies only for the specified packages</param>
    /// <param name="makeDeps">-m,install make dependencies only for the specified packages</param>
    /// <param name="noDeps">-d,install package without checking/installing dependencies</param>
    /// <returns></returns>
    public int Install(ConsoleAppContext context, [Argument] string[] packages, bool noConfirm = false, bool buildDeps = false, bool makeDeps = false, bool noDeps = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? InstallCommands.InstallUiMode(packages, globals.Verbose, noConfirm, buildDeps, makeDeps, noDeps)
            : InstallCommands.InstallConsoleMode(packages, globals.Verbose, noConfirm, buildDeps, makeDeps, noDeps);
    }

    /// <summary>
    /// Install a local package file (.pkg.tar.gz, .pkg.tar.xz, .pkg.tar.zst)
    /// </summary>
    /// <param name="location">-l,location of the .pkg.tar.gz(xz) to be installed</param>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <returns></returns>
    public int InstallLocal(ConsoleAppContext context, string? location = null, bool noConfirm = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? InstallLocalCommands.InstallLocalUiMode(location, globals.Verbose, noConfirm)
            : InstallLocalCommands.InstallLocalConsoleMode(location, globals.Verbose, noConfirm);
    }

    /// <summary>
    /// Remove one or more packages
    /// </summary>
    /// <param name="packages">packages to remove (space-separated)</param>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <param name="cascade">-c,removes all things the removed package(s) are dependent on that have no other uses</param>
    /// <param name="removeConfig">-r,removes any config files tied exclusively to the removed package(s)</param>
    /// <returns></returns>
    public int Remove(ConsoleAppContext context, [Argument] string[] packages, bool noConfirm = false, bool cascade = false, bool removeConfig = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? RemoveCommands.RemoveUiMode(packages, globals.Verbose, noConfirm, cascade, removeConfig)
            : RemoveCommands.RemoveConsoleMode(packages, globals.Verbose, noConfirm, cascade, removeConfig);
    }

    /// <summary>
    /// Update one or more packages
    /// </summary>
    /// <param name="packages">packages to update (space-separated)</param>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <returns></returns>
    public int Update(ConsoleAppContext context, [Argument] string[] packages, bool noConfirm = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? UpdateCommands.UpdateUiMode(packages.ToList(), globals.Verbose)
            : UpdateCommands.UpdateConsoleMode(packages.ToList(), globals.Verbose, noConfirm);
    }

    /// <summary>
    /// List installed packages
    /// </summary>
    /// <param name="filter">-f,filter packages by name (case-insensitive substring match)</param>
    /// <param name="sort">-s,sort results by: name, size</param>
    /// <param name="order">-o,sort order: ascending, descending</param>
    /// <param name="page">-p,the page to render</param>
    /// <param name="take">-t,the number of packages to render per page</param>
    /// <param name="json">-j,output results in JSON format</param>
    /// <returns></returns>
    public int ListInstalled(ConsoleAppContext context, string? filter = null, string sort = "name", string order = "ascending", int page = 1, int take = 100, bool json = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? ListInstalledCommands.ListInstalledUiMode(globals.Verbose, filter, sort, order, page, take, json)
            : ListInstalledCommands.ListInstalledConsoleMode(globals.Verbose, filter, sort, order, page, take, json);
    }

    /// <summary>
    /// List packages that have updates available
    /// </summary>
    /// <param name="json">-j,output results in JSON format</param>
    /// <returns></returns>
    public int ListUpdates(ConsoleAppContext context, bool json = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? ListUpdatesCommands.ListUpdatesUiMode(globals.Verbose, json)
            : ListUpdatesCommands.ListUpdatesConsoleMode(globals.Verbose, json);
    }

    /// <summary>
    /// List available packages from repositories
    /// </summary>
    /// <param name="filter">-f,filter packages by name (case-insensitive substring match)</param>
    /// <param name="sort">-s,sort results by: name, size</param>
    /// <param name="order">-o,sort order: ascending, descending</param>
    /// <param name="page">-p,the page to render</param>
    /// <param name="take">-t,the number of packages to render per page</param>
    /// <param name="json">-j,output results in JSON format</param>
    /// <param name="sync">-y,synchronize package databases before listing</param>
    /// <returns></returns>
    public int ListAvailable(ConsoleAppContext context, string? filter = null, string sort = "name", string order = "ascending", int page = 1, int take = 100, bool json = false, bool sync = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? ListAvailableCommands.ListAvailableUiMode(globals.Verbose, filter, sort, order, page, take, json, sync)
            : ListAvailableCommands.ListAvailableConsoleMode(globals.Verbose, filter, sort, order, page, take, json, sync);
    }

    /// <summary>
    /// List configured repositories
    /// </summary>
    /// <returns></returns>
    public int ListRepos(ConsoleAppContext context)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? ListReposCommands.ListReposUiMode()
            : ListReposCommands.ListReposConsoleMode();
    }

    /// <summary>
    /// Show detailed information about a package
    /// </summary>
    /// <param name="packages">package name to get information for</param>
    /// <param name="installed">-i,search installed packages</param>
    /// <param name="repository">-r,search repository of available packages</param>
    /// <returns></returns>
    public int PackageInfo(ConsoleAppContext context, [Argument] string[] packages, bool installed = false, bool repository = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? PackageInfoCommands.PackageInfoUiMode(packages, globals.Verbose, installed, repository)
            : PackageInfoCommands.PackageInfoConsoleMode(packages, globals.Verbose, installed, repository);
    }

    /// <summary>
    /// Downgrade a package to a previous version
    /// </summary>
    /// <param name="packages">package name to downgrade</param>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <param name="oldest">-o,installs the oldest matched version</param>
    /// <param name="latest">-l,installs the newest matched version</param>
    /// <returns></returns>
    public int Downgrade(ConsoleAppContext context, [Argument] string[] packages, bool noConfirm = false, bool oldest = false, bool latest = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? DowngradeCommands.DowngradeUiMode(packages, globals.Verbose, noConfirm, oldest, latest)
            : DowngradeCommands.DowngradeConsoleMode(packages, globals.Verbose, noConfirm, oldest, latest);
    }

    /// <summary>
    /// Show Arch Linux news from the RSS feed
    /// </summary>
    /// <param name="all">-a,shows all arch news instead of only new items</param>
    /// <returns></returns>
    public async Task<int> ArchNews(ConsoleAppContext context, bool all = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return await ArchNewsCommands.ShowArchNews(globals.Verbose, all);
    }

    /// <summary>
    /// Install an AppImage
    /// </summary>
    /// <param name="location">-l,location of the .AppImage to be installed</param>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <returns></returns>
    public async Task<int> AppImageInstall(ConsoleAppContext context, string? location = null, bool noConfirm = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return await AppImageInstallCommands.InstallAppImage(location, globals.Verbose, globals.UiMode, noConfirm);
    }

    /// <summary>
    /// Show the current version of Shelly
    /// </summary>
    /// <returns></returns>
    public int Version(ConsoleAppContext context)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return VersionCommands.ShowVersion(globals.UiMode);
    }
}
