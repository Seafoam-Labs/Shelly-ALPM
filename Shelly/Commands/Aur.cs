using ConsoleAppFramework;
using Shelly.Commands.AurCommands;
// ReSharper disable InvalidXmlDocComment
namespace Shelly.Commands;
[RegisterCommands("aur")]
internal class Aur
{
    /// <summary>
    /// Install one or more AUR packages
    /// </summary>
    /// <param name="packages">packages to install (space-separated)</param>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <param name="buildDeps">-o,install build dependencies only for the specified packages</param>
    /// <param name="makeDeps">-m,install make dependencies only for the specified packages</param>
    /// <returns></returns>
    public async Task<int> Install(ConsoleAppContext context, [Argument] string[] packages, bool noConfirm = false, bool buildDeps = false, bool makeDeps = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? await AurInstallCommands.InstallUiMode(packages, noConfirm, buildDeps, makeDeps)
            : await AurInstallCommands.InstallConsoleMode(packages, noConfirm, buildDeps, makeDeps);
    }

    /// <summary>
    /// Install a specific version of an AUR package by commit hash
    /// </summary>
    /// <param name="package">-p,package name to install</param>
    /// <param name="commit">-c,commit hash of the version to install</param>
    /// <returns></returns>
    public async Task<int> InstallVersion(ConsoleAppContext context, [Argument] string package, string commit)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? await AurInstallVersionCommands.InstallVersionUiMode(package, commit)
            : await AurInstallVersionCommands.InstallVersionConsoleMode(package, commit);
    }

    /// <summary>
    /// Search for AUR packages
    /// </summary>
    /// <param name="query">-q,search query</param>
    /// <param name="json">-j,output results in JSON format</param>
    /// <returns></returns>
    public async Task<int> Search(ConsoleAppContext context, [Argument] string query, bool json = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? await AurSearchCommands.SearchUiMode(query, json)
            : await AurSearchCommands.SearchConsoleMode(query, json);
    }

    /// <summary>
    /// Fetch the PKGBUILD for one or more AUR packages
    /// </summary>
    /// <param name="packages">packages to fetch PKGBUILD for (space-separated)</param>
    /// <returns></returns>
    public async Task<int> SearchPackageBuild(ConsoleAppContext context, [Argument] string[] packages)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? await AurSearchPackageBuildCommands.SearchPackageBuildUiMode(packages)
            : await AurSearchPackageBuildCommands.SearchPackageBuildConsoleMode(packages);
    }

    /// <summary>
    /// List installed AUR packages
    /// </summary>
    /// <returns></returns>
    public async Task<int> ListInstalled(ConsoleAppContext context)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? await AurListInstalledCommands.ListInstalledUiMode()
            : await AurListInstalledCommands.ListInstalledConsoleMode();
    }

    /// <summary>
    /// List AUR packages that have updates available
    /// </summary>
    /// <returns></returns>
    public async Task<int> ListUpdates(ConsoleAppContext context)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? await AurListUpdatesCommands.ListUpdatesUiMode()
            : await AurListUpdatesCommands.ListUpdatesConsoleMode();
    }

    /// <summary>
    /// Remove one or more AUR packages
    /// </summary>
    /// <param name="packages">packages to remove (space-separated)</param>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <returns></returns>
    public async Task<int> Remove(ConsoleAppContext context, [Argument] string[] packages, bool noConfirm = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? await AurRemoveCommands.RemoveUiMode(packages, noConfirm)
            : await AurRemoveCommands.RemoveConsoleMode(packages, noConfirm);
    }

    /// <summary>
    /// Update one or more AUR packages
    /// </summary>
    /// <param name="packages">packages to update (space-separated)</param>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <returns></returns>
    public async Task<int> Update(ConsoleAppContext context, [Argument] string[] packages, bool noConfirm = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? await AurUpdateCommands.UpdateUiMode(packages, noConfirm)
            : await AurUpdateCommands.UpdateConsoleMode(packages, noConfirm);
    }

    /// <summary>
    /// Upgrade all AUR packages that have updates available
    /// </summary>
    /// <param name="noConfirm">-n,proceed without asking for user confirmation</param>
    /// <returns></returns>
    public async Task<int> Upgrade(ConsoleAppContext context, bool noConfirm = false)
    {
        var globals = (GlobalOptions)context.GlobalOptions!;
        return globals.UiMode
            ? await AurUpgradeCommands.UpgradeUiMode(noConfirm)
            : await AurUpgradeCommands.UpgradeConsoleMode(noConfirm);
    }
}
