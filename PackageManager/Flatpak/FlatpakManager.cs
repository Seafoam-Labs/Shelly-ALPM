using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace PackageManager.Flatpak;

public class FlatpakManager : IDisposable
{
    /// <summary>
    /// Searches installed flatpak apps
    /// </summary>
    /// <returns>Returns a list of FlatpakPackageDto</returns>
    public List<FlatpakPackageDto> SearchInstalled()
    {
        var packages = new List<FlatpakPackageDto>();

        if (!NativeResolver.IsLibraryAvailable(FlatpakReference.LibName))
        {
            return packages;
        }

        // Get system installations
        var installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr error);
        if (error == IntPtr.Zero && installationsPtr != IntPtr.Zero)
        {
            try
            {
                var dataPtr = Marshal.ReadIntPtr(installationsPtr);
                var length = Marshal.ReadInt32(installationsPtr + IntPtr.Size);

                for (var i = 0; i < length; i++)
                {
                    var installationPtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                    if (installationPtr != IntPtr.Zero)
                    {
                        AddPackagesFromInstallation(installationPtr, packages);
                    }
                }
            }
            finally
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
            }
        }

        // Get user installation
        var userInstallationPtr = FlatpakReference.InstallationNewUser(IntPtr.Zero, out IntPtr userError);
        if (userError != IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(userError);
        }
        else if (userInstallationPtr != IntPtr.Zero)
        {
            try
            {
                AddPackagesFromInstallation(userInstallationPtr, packages);
            }
            finally
            {
                FlatpakReference.GObjectUnref(userInstallationPtr);
            }
        }

        return packages;
    }

    /// <summary>
    /// Helper method to add packages from an installation to the list
    /// </summary>
    private void AddPackagesFromInstallation(IntPtr installationPtr, List<FlatpakPackageDto> packages)
    {
        var refsPtr = FlatpakReference.InstallationListInstalledRefs(
            installationPtr, IntPtr.Zero, out IntPtr refsError);

        if (refsError != IntPtr.Zero || refsPtr == IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(refsError);
            return;
        }

        try
        {
            var refsDataPtr = Marshal.ReadIntPtr(refsPtr);
            var refsLength = Marshal.ReadInt32(refsPtr + IntPtr.Size);

            for (var j = 0; j < refsLength; j++)
            {
                var refPtr = Marshal.ReadIntPtr(refsDataPtr + j * IntPtr.Size);
                if (refPtr == IntPtr.Zero) continue;

                var package = new FlatpackPackage(refPtr);
                packages.Add(package.ToDto());
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(refsPtr);
        }
    }

    /// <summary>
    /// Launches a flatpak application by its app ID or friendly name.
    /// </summary>
    /// <param name="nameOrId">The application ID (e.g., "org.mozilla.firefox") or friendly name (e.g., "Firefox")</param>
    /// <returns>True if launch was successful</returns>
    public bool LaunchApp(string nameOrId)
    {
        var installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr error);

        if (error != IntPtr.Zero || installationsPtr == IntPtr.Zero)
        {
            return false;
        }

        try
        {
            var dataPtr = Marshal.ReadIntPtr(installationsPtr);
            var length = Marshal.ReadInt32(installationsPtr + IntPtr.Size);

            for (var i = 0; i < length; i++)
            {
                var installationPtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                if (installationPtr == IntPtr.Zero) continue;

                var match = FindInstalledApp(installationPtr, nameOrId);

                if (match == null) continue;
                var success = FlatpakReference.InstallationLaunch(
                    installationPtr,
                    match.Id,
                    match.Arch,
                    match.Branch,
                    null, // commit
                    IntPtr.Zero, // cancellable
                    out var launchError);

                if (success && launchError == IntPtr.Zero)
                {
                    return true;
                }
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(installationsPtr);
        }

        return false;
    }

    /// <summary>
    /// Finds an installed app by ID or friendly name within an installation.
    /// </summary>
    private FlatpakPackageDto? FindInstalledApp(IntPtr installationPtr, string nameOrId)
    {
        var refsPtr = FlatpakReference.InstallationListInstalledRefs(
            installationPtr, IntPtr.Zero, out IntPtr refsError);

        if (refsError != IntPtr.Zero || refsPtr == IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(refsError);
            FlatpakReference.GObjectUnref(installationPtr);
            return null;
        }

        try
        {
            var refsDataPtr = Marshal.ReadIntPtr(refsPtr);
            var refsLength = Marshal.ReadInt32(refsPtr + IntPtr.Size);

            for (var j = 0; j < refsLength; j++)
            {
                var refPtr = Marshal.ReadIntPtr(refsDataPtr + j * IntPtr.Size);
                if (refPtr == IntPtr.Zero) continue;

                var package = new FlatpackPackage(refPtr);

                if (string.Equals(package.Id, nameOrId, StringComparison.OrdinalIgnoreCase) ||
                    package.Id.Contains(nameOrId, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(package.Name, nameOrId, StringComparison.OrdinalIgnoreCase) ||
                    package.Name.Contains(nameOrId, StringComparison.OrdinalIgnoreCase))
                {
                    return package.ToDto();
                }
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(refsPtr);
        }

        return null;
    }

    /// <summary>
    /// Kills a running flatpak application by its app ID.
    /// </summary>
    /// <param name="appId">The application ID to kill</param>
    /// <returns>True if at least one instance was killed</returns>
    public string KillApp(string appId)
    {
        var flatpakInstanceDtos = GetRunningInstances();

        var isRunning = flatpakInstanceDtos.Any(instance =>
            string.Equals(instance.AppId, appId, StringComparison.OrdinalIgnoreCase));


        if (flatpakInstanceDtos.Count == 0 || !isRunning)
        {
            return "Failed to find running instance of " + appId + ".";
        }

        var pid = flatpakInstanceDtos.Where(x => x.AppId == appId).Select(x => x.Pid).FirstOrDefault();

        if (pid <= 0) return "Failed to kill instance of " + appId + "." + pid;
        try
        {
            var process = System.Diagnostics.Process.GetProcessById(pid);

            process.Kill(true);
            return "Killed";
        }
        catch (Exception e)
        {
            Console.WriteLine(e);
        }

        return "Failed to kill instance of " + appId + "." + pid;
    }

    /// <summary>
    /// Gets all currently running flatpak instances.
    /// </summary>
    /// <returns>List of running app IDs with their PIDs</returns>
    public List<FlatpakInstanceDto> GetRunningInstances()
    {
        var instances = new List<FlatpakInstanceDto>();

        var instancesPtr = FlatpakReference.InstanceGetAll();

        if (instancesPtr == IntPtr.Zero)
        {
            return instances;
        }

        try
        {
            var dataPtr = Marshal.ReadIntPtr(instancesPtr);
            var length = Marshal.ReadInt32(instancesPtr + IntPtr.Size);

            for (var i = 0; i < length; i++)
            {
                var instancePtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                if (instancePtr == IntPtr.Zero) continue;

                if (FlatpakReference.InstanceIsActive(instancePtr))
                {
                    instances.Add(new FlatpakInstanceDto
                    {
                        AppId = PtrToStringSafe(FlatpakReference.InstanceGetApp(instancePtr)),
                        Pid = FlatpakReference.InstanceGetChildPid(instancePtr)
                    });
                }
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(instancesPtr);
        }

        return instances;
    }

    /// <summary>
    /// Installs a flatpak package from a remote repository.
    /// </summary>
    /// <param name="appId">The application ID (e.g., "org.mozilla.firefox")</param>
    /// <param name="remoteName">The remote name (e.g., "flathub"). If null, will try the first available remote.</param>
    /// <param name="isUser">Whether to install to user installation (true) or system installation (false)</param>
    /// <param name="branch"></param>
    /// <returns>A result message indicating success or failure</returns>
    public string InstallApp(string appId, string? remoteName = null, bool isUser = false, string branch = "stable")
    {
        IntPtr installationPtr;
        IntPtr installationsPtr = IntPtr.Zero;

        if (isUser)
        {
            installationPtr = FlatpakReference.InstallationNewUser(IntPtr.Zero, out IntPtr userError);
            if (userError != IntPtr.Zero || installationPtr == IntPtr.Zero)
            {
                FlatpakReference.GErrorFree(userError);
                return "Failed to get user installation.";
            }
        }
        else
        {
            installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr error);

            if (error != IntPtr.Zero || installationsPtr == IntPtr.Zero)
            {
                FlatpakReference.GErrorFree(error);
                FlatpakReference.GPtrArrayUnref(installationsPtr);
                return "Failed to get system installations.";
            }

            var dataPtr = Marshal.ReadIntPtr(installationsPtr);
            int length = Marshal.ReadInt32(installationsPtr + IntPtr.Size);

            if (length == 0)
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
                return "No flatpak installations found.";
            }

            installationPtr = Marshal.ReadIntPtr(dataPtr);
            if (installationPtr == IntPtr.Zero)
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
                return "Installation pointer is invalid.";
            }
        }

        try
        {
            var remote = remoteName ?? GetFirstRemote(installationPtr);
            if (string.IsNullOrEmpty(remote))
            {
                return "No remote repository configured. Add a remote like 'flathub' first.";
            }

            var refString = $"app/{appId}/{GetCurrentArch()}/{branch}";

            var transactionPtr = FlatpakReference.TransactionNewForInstallation(
                installationPtr, IntPtr.Zero, out IntPtr transactionError);
            
            FlatpakReference.InstallationUpdateRemoteSync(
                installationPtr, remote, IntPtr.Zero, out IntPtr updateError);

            if (transactionError != IntPtr.Zero || transactionPtr == IntPtr.Zero)
            {
                return "Failed to create installation transaction.";
            }

            try
            {
                // Connect to new-operation signal to hook progress callbacks
                var newOpCallback = new FlatpakReference.TransactionNewOperationCallback(OnNewOperation);
                var newOpCallbackPtr = Marshal.GetFunctionPointerForDelegate(newOpCallback);
                FlatpakReference.GSignalConnectData(transactionPtr, "new-operation", newOpCallbackPtr,
                    IntPtr.Zero, IntPtr.Zero, 0);

                var addSuccess = FlatpakReference.TransactionAddInstall(
                    transactionPtr, remote, refString, IntPtr.Zero, out IntPtr addError);

                if (!addSuccess || addError != IntPtr.Zero)
                {
                    var errorMsg = FlatpakReference.GetErrorMessage(addError);
                    FlatpakReference.GErrorFree(addError);
                    return $"Failed to add {appId} to installation queue: {errorMsg}";
                }

                var runSuccess = FlatpakReference.TransactionRun(
                    transactionPtr, IntPtr.Zero, out IntPtr runError);

                if (!runSuccess || runError != IntPtr.Zero)
                {
                    var errorMsg = FlatpakReference.GetErrorMessage(runError);
                    FlatpakReference.GErrorFree(runError);
                    return $"Installation of {appId} failed: {errorMsg}";
                }

                var scope = isUser ? "user" : "system";
                return $"Successfully installed {appId} from {remote} to {scope}.";
            }
            finally
            {
                FlatpakReference.GObjectUnref(transactionPtr);
            }
        }
        finally
        {
            if (isUser)
            {
                FlatpakReference.GObjectUnref(installationPtr);
            }
            else if (installationsPtr != IntPtr.Zero)
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
            }
        }
    }

    /// <summary>
    /// Gets the first configured remote for an installation.
    /// </summary>
    private string? GetFirstRemote(IntPtr installationPtr)
    {
        IntPtr remotesPtr = FlatpakReference.InstallationListRemotes(
            installationPtr, IntPtr.Zero, out IntPtr error);

        if (error != IntPtr.Zero || remotesPtr == IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(error);
            FlatpakReference.GPtrArrayUnref(remotesPtr);
            return null;
        }

        try
        {
            var dataPtr = Marshal.ReadIntPtr(remotesPtr);
            var length = Marshal.ReadInt32(remotesPtr + IntPtr.Size);

            if (length > 0)
            {
                IntPtr remotePtr = Marshal.ReadIntPtr(dataPtr);
                if (remotePtr != IntPtr.Zero)
                {
                    return PtrToStringSafe(FlatpakReference.RemoteGetName(remotePtr));
                }
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(remotesPtr);
        }

        return null;
    }

    public string UninstallApp(string nameOrId, bool removeUnused = false)
    {
        // Try system installations first
        var installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr error);
        if (error == IntPtr.Zero && installationsPtr != IntPtr.Zero)
        {
            try
            {
                var dataPtr = Marshal.ReadIntPtr(installationsPtr);
                var length = Marshal.ReadInt32(installationsPtr + IntPtr.Size);

                for (var i = 0; i < length; i++)
                {
                    var installationPtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                    if (installationPtr == IntPtr.Zero) continue;

                    var match = FindInstalledApp(installationPtr, nameOrId);
                    if (match != null)
                    {
                        return UninstallFromInstallation(installationPtr, match, nameOrId, removeUnused, false);
                    }
                }
            }
            finally
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
            }
        }
        else if (error != IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(error);
        }

        // Try user installation
        var userInstallationPtr = FlatpakReference.InstallationNewUser(IntPtr.Zero, out IntPtr userError);
        if (userError != IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(userError);
            return $"Could not find installed app matching '{nameOrId}'.";
        }

        if (userInstallationPtr == IntPtr.Zero)
        {
            return $"Could not find installed app matching '{nameOrId}'.";
        }

        try
        {
            var match = FindInstalledApp(userInstallationPtr, nameOrId);
            if (match == null)
            {
                return $"Could not find installed app matching '{nameOrId}'.";
            }

            return UninstallFromInstallation(userInstallationPtr, match, nameOrId, removeUnused, true);
        }
        finally
        {
            FlatpakReference.GObjectUnref(userInstallationPtr);
        }
    }

    private string UninstallFromInstallation(IntPtr installationPtr, FlatpakPackageDto match,
        string nameOrId, bool removeUnused, bool isUser)
    {
        var kindString = match.Kind == FlatpakReference.FlatpakRefKindApp ? "app" : "runtime";
        var refString = $"{kindString}/{match.Id}/{match.Arch}/{match.Branch}";

        var transactionPtr = FlatpakReference.TransactionNewForInstallation(
            installationPtr, IntPtr.Zero, out IntPtr transactionError);

        if (transactionError != IntPtr.Zero || transactionPtr == IntPtr.Zero)
        {
            return "Failed to create uninstallation transaction.";
        }

        try
        {
            var newOpCallback = new FlatpakReference.TransactionNewOperationCallback(OnNewOperation);
            var newOpCallbackPtr = Marshal.GetFunctionPointerForDelegate(newOpCallback);
            FlatpakReference.GSignalConnectData(transactionPtr, "new-operation", newOpCallbackPtr,
                IntPtr.Zero, IntPtr.Zero, 0);

            var addSuccess = FlatpakReference.TransactionAddUninstall(
                transactionPtr, refString, out IntPtr addError);

            if (!addSuccess || addError != IntPtr.Zero)
            {
                var errorMsg = FlatpakReference.GetErrorMessage(addError);
                FlatpakReference.GErrorFree(addError);
                return $"Failed to add {nameOrId} to uninstallation queue: {errorMsg}";
            }

            var runSuccess = FlatpakReference.TransactionRun(
                transactionPtr, IntPtr.Zero, out IntPtr runError);

            if (!runSuccess || runError != IntPtr.Zero)
            {
                var errorMsg = FlatpakReference.GetErrorMessage(runError);
                FlatpakReference.GErrorFree(runError);
                return $"Uninstallation of {nameOrId} failed: {errorMsg}";
            }

            var scope = isUser ? "user" : "system";
            var result = $"Successfully uninstalled {match.Name} ({match.Id}) from {scope}.";

            // Remove unused dependencies if requested
            if (removeUnused)
            {
                result += RemoveUnusedDependencies(installationPtr);
            }

            return result;
        }
        finally
        {
            FlatpakReference.GObjectUnref(transactionPtr);
        }
    }

    private string RemoveUnusedDependencies(IntPtr installationPtr)
    {
        var unusedRefsPtr = FlatpakReference.InstallationListUnusedRefs(
            installationPtr, null, IntPtr.Zero, out IntPtr error);

        if (error != IntPtr.Zero || unusedRefsPtr == IntPtr.Zero)
        {
            if (error != IntPtr.Zero)
            {
                FlatpakReference.GErrorFree(error);
            }

            return " No unused dependencies found.";
        }

        try
        {
            var dataPtr = Marshal.ReadIntPtr(unusedRefsPtr);
            var length = Marshal.ReadInt32(unusedRefsPtr + IntPtr.Size);

            if (length == 0)
            {
                return " No unused dependencies found.";
            }

            var transactionPtr = FlatpakReference.TransactionNewForInstallation(
                installationPtr, IntPtr.Zero, out IntPtr transactionError);

            if (transactionError != IntPtr.Zero || transactionPtr == IntPtr.Zero)
            {
                if (transactionError != IntPtr.Zero)
                {
                    FlatpakReference.GErrorFree(transactionError);
                }

                return " Failed to create transaction for removing unused dependencies.";
            }

            try
            {
                var removedCount = 0;
                for (var i = 0; i < length; i++)
                {
                    var refPtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                    if (refPtr == IntPtr.Zero) continue;

                    // Build the ref string: kind/name/arch/branch
                    var namePtr = FlatpakReference.RefGetName(refPtr);
                    var archPtr = FlatpakReference.RefGetArch(refPtr);
                    var branchPtr = FlatpakReference.RefGetBranch(refPtr);
                    var kind = FlatpakReference.RefGetKind(refPtr);

                    var name = Marshal.PtrToStringUTF8(namePtr);
                    var arch = Marshal.PtrToStringUTF8(archPtr);
                    var branch = Marshal.PtrToStringUTF8(branchPtr);

                    if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(arch) || string.IsNullOrEmpty(branch))
                        continue;

                    var kindString = kind == FlatpakReference.FlatpakRefKindApp ? "app" : "runtime";
                    var refString = $"{kindString}/{name}/{arch}/{branch}";

                    var addSuccess = FlatpakReference.TransactionAddUninstall(
                        transactionPtr, refString, out IntPtr addError);

                    if (addSuccess && addError == IntPtr.Zero)
                    {
                        removedCount++;
                    }
                    else if (addError != IntPtr.Zero)
                    {
                        FlatpakReference.GErrorFree(addError);
                    }
                }

                if (removedCount > 0)
                {
                    var runSuccess = FlatpakReference.TransactionRun(
                        transactionPtr, IntPtr.Zero, out IntPtr runError);

                    if (!runSuccess || runError != IntPtr.Zero)
                    {
                        if (runError != IntPtr.Zero)
                        {
                            FlatpakReference.GErrorFree(runError);
                        }

                        return $" Failed to remove {removedCount} unused dependencies.";
                    }

                    return $" Removed {removedCount} unused dependencies.";
                }

                return " No unused dependencies to remove.";
            }
            finally
            {
                FlatpakReference.GObjectUnref(transactionPtr);
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(unusedRefsPtr);
        }
    }

    /*
    /// <summary>
    /// Uninstalls a flatpak application by its app ID or friendly name.
    /// </summary>
    /// <param name="nameOrId">The application ID (e.g., "org.mozilla.firefox") or friendly name</param>
    /// <returns>A result message indicating success or failure</returns>
    public string UninstallApp(string nameOrId)
    {
        var installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr error);

        if (error != IntPtr.Zero || installationsPtr == IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(error);
            FlatpakReference.GPtrArrayUnref(installationsPtr);
            return "Failed to get system installations.";
        }

        try
        {
            var dataPtr = Marshal.ReadIntPtr(installationsPtr);
            var length = Marshal.ReadInt32(installationsPtr + IntPtr.Size);

            for (var i = 0; i < length; i++)
            {
                var installationPtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                if (installationPtr == IntPtr.Zero) continue;

                var match = FindInstalledApp(installationPtr, nameOrId);

                if (match == null) continue;
                var refString = $"app/{match.Id}/{match.Arch}/{match.Branch}";

                var transactionPtr = FlatpakReference.TransactionNewForInstallation(
                    installationPtr, IntPtr.Zero, out IntPtr transactionError);

                if (transactionError != IntPtr.Zero || transactionPtr == IntPtr.Zero)
                {
                    return "Failed to create uninstallation transaction.";
                }

                try
                {
                    // Connect to new-operation signal to hook progress callbacks
                    var newOpCallback = new FlatpakReference.TransactionNewOperationCallback(OnNewOperation);
                    var newOpCallbackPtr = Marshal.GetFunctionPointerForDelegate(newOpCallback);
                    FlatpakReference.GSignalConnectData(transactionPtr, "new-operation", newOpCallbackPtr,
                        IntPtr.Zero, IntPtr.Zero, 0);

                    var addSuccess = FlatpakReference.TransactionAddUninstall(
                        transactionPtr, refString, out IntPtr addError);

                    if (!addSuccess || addError != IntPtr.Zero)
                    {
                        return $"Failed to add {nameOrId} to uninstallation queue.";
                    }

                    var runSuccess = FlatpakReference.TransactionRun(
                        transactionPtr, IntPtr.Zero, out IntPtr runError);

                    if (!runSuccess || runError != IntPtr.Zero)
                    {
                        return $"Uninstallation of {nameOrId} failed. You may need elevated permissions.";
                    }

                    return $"Successfully uninstalled {match.Name} ({match.Id}).";
                }
                finally
                {
                    FlatpakReference.GObjectUnref(transactionPtr);
                }
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(installationsPtr);
        }

        return $"Could not find installed app matching '{nameOrId}'.";
    }
    */

    /// <summary>
    /// Updates a flatpak application by its app ID or friendly name.
    /// </summary>
    /// <param name="nameOrId">The application ID (e.g., "org.mozilla.firefox") or friendly name</param>
    /// <returns>A result message indicating success or failure</returns>
    public string UpdateApp(string nameOrId)
    {
        var installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr error);

        if (error != IntPtr.Zero || installationsPtr == IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(error);
            FlatpakReference.GPtrArrayUnref(installationsPtr);
            return "Failed to get system installations.";
        }

        try
        {
            var dataPtr = Marshal.ReadIntPtr(installationsPtr);
            var length = Marshal.ReadInt32(installationsPtr + IntPtr.Size);

            for (var i = 0; i < length; i++)
            {
                var installationPtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                if (installationPtr == IntPtr.Zero) continue;

                var match = FindInstalledApp(installationPtr, nameOrId);

                if (match == null) continue;
                var refString = BuildRefString(match);

                var transactionPtr = FlatpakReference.TransactionNewForInstallation(
                    installationPtr, IntPtr.Zero, out IntPtr transactionError);

                if (transactionError != IntPtr.Zero || transactionPtr == IntPtr.Zero)
                {
                    return "Failed to create update transaction.";
                }

                try
                {
                    // Connect to new-operation signal to hook progress callbacks
                    var newOpCallback = new FlatpakReference.TransactionNewOperationCallback(OnNewOperation);
                    var newOpCallbackPtr = Marshal.GetFunctionPointerForDelegate(newOpCallback);
                    FlatpakReference.GSignalConnectData(transactionPtr, "new-operation", newOpCallbackPtr,
                        IntPtr.Zero, IntPtr.Zero, 0);

                    var addSuccess = FlatpakReference.TransactionAddUpdate(
                        transactionPtr, refString, IntPtr.Zero, null, out IntPtr addError);

                    if (!addSuccess || addError != IntPtr.Zero)
                    {
                        var response = FlatpakReference.GetErrorMessage(addError);
                        return
                            $"Failed to add {nameOrId} to update queue. Error: {response} App may already be up to date.";
                    }

                    var runSuccess = FlatpakReference.TransactionRun(
                        transactionPtr, IntPtr.Zero, out IntPtr runError);

                    if (!runSuccess || runError != IntPtr.Zero)
                    {
                        return $"Update of {nameOrId} failed. You may need elevated permissions.";
                    }

                    return $"Successfully updated {match.Name} ({match.Id}).";
                }
                finally
                {
                    FlatpakReference.GObjectUnref(transactionPtr);
                }
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(installationsPtr);
        }

        return $"Could not find installed app matching '{nameOrId}'.";
    }

    /// <summary>
    /// Updates all flatpak installations
    /// </summary>
    /// <returns>A result message indicating success or failure</returns>
    public string UpdateAllFlatpak()
    {
        var installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out var error);

        if (error != IntPtr.Zero || installationsPtr == IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(error);
            FlatpakReference.GPtrArrayUnref(installationsPtr);
            return "Failed to get system installations.";
        }

        try
        {
            var dataPtr = Marshal.ReadIntPtr(installationsPtr);

            var installationPtr = Marshal.ReadIntPtr(dataPtr);

            var transactionPtr = FlatpakReference.TransactionNewForInstallation(
                installationPtr, IntPtr.Zero, out IntPtr transactionError);

            var packagesWithUpdates = GetPackagesWithUpdates();

            if (transactionError != IntPtr.Zero || transactionPtr == IntPtr.Zero)
            {
                return "Failed to create update transaction.";
            }

            foreach (var packageDto in packagesWithUpdates)
            {
                var refString = BuildRefString(packageDto);

                var addSuccess = FlatpakReference.TransactionAddUpdate(
                    transactionPtr, refString, IntPtr.Zero, null, out IntPtr addError);

                if (addSuccess && addError == IntPtr.Zero) continue;
                var response = FlatpakReference.GetErrorMessage(addError);
                return
                    $"Failed to add {packageDto.Id} to update queue. Error: {response} App may already be up to date.";
            }


            var newOpCallback = new FlatpakReference.TransactionNewOperationCallback(OnNewOperation);
            var newOpCallbackPtr = Marshal.GetFunctionPointerForDelegate(newOpCallback);
            FlatpakReference.GSignalConnectData(transactionPtr, "new-operation", newOpCallbackPtr,
                IntPtr.Zero, IntPtr.Zero, 0);

            var runSuccess = FlatpakReference.TransactionRun(
                transactionPtr, IntPtr.Zero, out IntPtr runError);

            if (!runSuccess || runError != IntPtr.Zero)
            {
                return $"Full system update failed";
            }

            return $"Successfully updated {packagesWithUpdates.Count} packages.";
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(installationsPtr);
        }
    }

    public List<FlatpakRemoteDto> ListRemotesWithDetails()
    {
        var remotesDto = new List<FlatpakRemoteDto>();

        if (!NativeResolver.IsLibraryAvailable(FlatpakReference.LibName))
        {
            return [];
        }

        var installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr error);
        if (error == IntPtr.Zero && installationsPtr != IntPtr.Zero)
        {
            try
            {
                var dataPtr = Marshal.ReadIntPtr(installationsPtr);
                var length = Marshal.ReadInt32(installationsPtr + IntPtr.Size);

                for (var i = 0; i < length; i++)
                {
                    var installationPtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                    if (installationPtr != IntPtr.Zero)
                    {
                        AddRemotesFromInstallation(installationPtr, remotesDto, "system");
                    }
                }
            }
            finally
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
            }
        }

        var userInstallationPtr = FlatpakReference.InstallationNewUser(IntPtr.Zero, out IntPtr userError);
        if (userError != IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(userError);
        }
        else if (userInstallationPtr != IntPtr.Zero)
        {
            try
            {
                AddRemotesFromInstallation(userInstallationPtr, remotesDto, "user");
            }
            finally
            {
                FlatpakReference.GObjectUnref(userInstallationPtr);
            }
        }

        return remotesDto;
    }

    /// <summary>
    /// Helper method to add remotes from an installation to the list
    /// </summary>
    private void AddRemotesFromInstallation(IntPtr installationPtr, List<FlatpakRemoteDto> remotes, string type)
    {
        var remotesPtr = FlatpakReference.InstallationListRemotes(
            installationPtr, IntPtr.Zero, out IntPtr error);

        if (error != IntPtr.Zero || remotesPtr == IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(error);
            return;
        }

        try
        {
            var remotesDataPtr = Marshal.ReadIntPtr(remotesPtr);
            var remotesLength = Marshal.ReadInt32(remotesPtr + IntPtr.Size);

            for (var i = 0; i < remotesLength; i++)
            {
                var remotePtr = Marshal.ReadIntPtr(remotesDataPtr + i * IntPtr.Size);
                if (remotePtr == IntPtr.Zero) continue;
                var remoteName = PtrToStringSafe(FlatpakReference.RemoteGetName(remotePtr));
                var remoteUrl = PtrToStringSafe(FlatpakReference.RemoteGetUrl(remotePtr));

                remotes.Add(new FlatpakRemoteDto
                {
                    Name = remoteName,
                    Scope = type,
                    Url = remoteUrl
                });
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(remotesPtr);
        }
    }

    /// <summary>
    /// Adds a remote repository to an installation.
    /// </summary>
    /// <param name="remoteName">The name for the remote (e.g., "flathub")</param>
    /// <param name="remoteUrl">The URL for the remote repository</param>
    /// <param name="isSystemWide">Whether to add to system installation (true) or user installation (false)</param>
    /// <param name="gpgVerify">Whether to verify GPG signatures (default: true)</param>
    /// <returns>A result message indicating success or failure</returns>
    public string AddRemote(string remoteName, string remoteUrl, bool isSystemWide = false, bool gpgVerify = true)
    {
        if (!NativeResolver.IsLibraryAvailable(FlatpakReference.LibName))
        {
            return "Flatpak library is not available.";
        }

        IntPtr installationPtr;
        IntPtr installationsPtr = IntPtr.Zero;

        if (isSystemWide)
        {
            installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr sysError);
            if (sysError != IntPtr.Zero || installationsPtr == IntPtr.Zero)
            {
                FlatpakReference.GErrorFree(sysError);
                if (installationsPtr != IntPtr.Zero)
                {
                    FlatpakReference.GPtrArrayUnref(installationsPtr);
                }

                return "Failed to get system installation.";
            }

            var dataPtr = Marshal.ReadIntPtr(installationsPtr);
            installationPtr = Marshal.ReadIntPtr(dataPtr);

            if (installationPtr == IntPtr.Zero)
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
                return "System installation pointer is invalid.";
            }
        }
        else
        {
            installationPtr = FlatpakReference.InstallationNewUser(IntPtr.Zero, out IntPtr userError);
            if (userError != IntPtr.Zero || installationPtr == IntPtr.Zero)
            {
                FlatpakReference.GErrorFree(userError);
                return "Failed to get user installation.";
            }
        }

        try
        {
            var actualUrl = remoteUrl;
            var actualGpgVerify = gpgVerify;
            
            if (remoteUrl.EndsWith(".flatpakrepo", StringComparison.OrdinalIgnoreCase))
            {
                var repoConfig = DownloadAndParseFlatpakrepo(remoteUrl);
                if (repoConfig == null || string.IsNullOrEmpty(repoConfig.Url))
                {
                    return $"Failed to download or parse .flatpakrepo file from: {remoteUrl}";
                }

                actualUrl = repoConfig.Url;
                actualGpgVerify = repoConfig.GpgVerify ?? gpgVerify;

                Console.Error.WriteLine($"Parsed .flatpakrepo: URL={actualUrl}, GPGVerify={actualGpgVerify}");
            }
            
            var remotePtr = FlatpakReference.RemoteNew(remoteName);
            if (remotePtr == IntPtr.Zero)
            {
                return "Failed to create remote object.";
            }

            FlatpakReference.RemoteSetUrl(remotePtr, actualUrl);
            FlatpakReference.RemoteSetGpgVerify(remotePtr, actualGpgVerify);

            try
            {
                var result = FlatpakReference.FlatpakInstallationModifyRemote(
                    installationPtr, remotePtr, IntPtr.Zero, out IntPtr error);

                if (error != IntPtr.Zero || result == false)
                {
                    Console.WriteLine($"Failed to modify remote: {FlatpakReference.GetErrorMessage(error)}");
                    if (error != IntPtr.Zero)
                    {
                        FlatpakReference.GErrorFree(error);
                    }
                }

                var success = FlatpakReference.InstallationAddRemote(
                    installationPtr, remotePtr, true, IntPtr.Zero, out error);

                if (!success || error != IntPtr.Zero)
                {
                    var errorMsg = FlatpakReference.GetErrorMessage(error);
                    FlatpakReference.GErrorFree(error);
                    return $"Failed to add remote '{remoteName}': {errorMsg}";
                }

                var scope = isSystemWide ? "system" : "user";

                if (remoteUrl.EndsWith(".flatpakrepo", StringComparison.OrdinalIgnoreCase))
                {
                    var configuredUrl = PtrToStringSafe(FlatpakReference.RemoteGetUrl(remotePtr));
                    if (!string.IsNullOrEmpty(configuredUrl))
                    {
                        actualUrl = configuredUrl;
                    }
                }

                return $"Successfully added remote '{remoteName}' to {scope} installation with URL: {actualUrl}";
            }
            finally
            {
                FlatpakReference.GObjectUnref(remotePtr);
            }
        }
        finally
        {
            if (isSystemWide)
            {
                if (installationsPtr != IntPtr.Zero)
                {
                    FlatpakReference.GPtrArrayUnref(installationsPtr);
                }
            }
            else
            {
                FlatpakReference.GObjectUnref(installationPtr);
            }
        }
    }

    /// <summary>
    /// Modifies a remote repository's settings.
    /// </summary>
    /// <param name="remoteName">The name of the remote to modify (e.g., "elementary")</param>
    /// <param name="gpgVerify">Whether to verify GPG signatures</param>
    /// <param name="isSystemWide">Whether to modify system installation (true) or user installation (false)</param>
    /// <returns>A result message indicating success or failure</returns>
    public string ModifyRemote(string remoteName, bool gpgVerify, bool isSystemWide = false)
    {
        if (!NativeResolver.IsLibraryAvailable(FlatpakReference.LibName))
        {
            return "Flatpak library is not available.";
        }

        IntPtr installationPtr;
        IntPtr installationsPtr = IntPtr.Zero;

        if (isSystemWide)
        {
            installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr sysError);
            if (sysError != IntPtr.Zero || installationsPtr == IntPtr.Zero)
            {
                FlatpakReference.GErrorFree(sysError);
                if (installationsPtr != IntPtr.Zero)
                {
                    FlatpakReference.GPtrArrayUnref(installationsPtr);
                }

                return "Failed to get system installation.";
            }

            var dataPtr = Marshal.ReadIntPtr(installationsPtr);
            installationPtr = Marshal.ReadIntPtr(dataPtr);

            if (installationPtr == IntPtr.Zero)
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
                return "System installation pointer is invalid.";
            }
        }
        else
        {
            installationPtr = FlatpakReference.InstallationNewUser(IntPtr.Zero, out IntPtr userError);
            if (userError != IntPtr.Zero || installationPtr == IntPtr.Zero)
            {
                FlatpakReference.GErrorFree(userError);
                return "Failed to get user installation.";
            }
        }

        try
        {
            // Get the existing remote
            var remotesPtr = FlatpakReference.InstallationListRemotes(
                installationPtr, IntPtr.Zero, out IntPtr remotesError);

            if (remotesError != IntPtr.Zero || remotesPtr == IntPtr.Zero)
            {
                FlatpakReference.GErrorFree(remotesError);
                return $"Failed to list remotes.";
            }

            try
            {
                var remotesDataPtr = Marshal.ReadIntPtr(remotesPtr);
                var remotesLength = Marshal.ReadInt32(remotesPtr + IntPtr.Size);

                IntPtr targetRemotePtr = IntPtr.Zero;
                for (var i = 0; i < remotesLength; i++)
                {
                    var remotePtr = Marshal.ReadIntPtr(remotesDataPtr + i * IntPtr.Size);
                    if (remotePtr == IntPtr.Zero) continue;

                    var name = PtrToStringSafe(FlatpakReference.RemoteGetName(remotePtr));
                    if (name == remoteName)
                    {
                        targetRemotePtr = remotePtr;
                        break;
                    }
                }

                if (targetRemotePtr == IntPtr.Zero)
                {
                    return $"Remote '{remoteName}' not found.";
                }

                // Modify the remote's GPG verification setting
                FlatpakReference.RemoteSetGpgVerify(targetRemotePtr, gpgVerify);

                var success = FlatpakReference.InstallationModifyRemote(
                    installationPtr, targetRemotePtr, IntPtr.Zero, out IntPtr error);

                if (!success || error != IntPtr.Zero)
                {
                    var errorMsg = FlatpakReference.GetErrorMessage(error);
                    FlatpakReference.GErrorFree(error);
                    return $"Failed to modify remote '{remoteName}': {errorMsg}";
                }

                var scope = isSystemWide ? "system" : "user";
                var gpgStatus = gpgVerify ? "enabled" : "disabled";
                return
                    $"Successfully modified remote '{remoteName}' in {scope} installation. GPG verification: {gpgStatus}";
            }
            finally
            {
                FlatpakReference.GPtrArrayUnref(remotesPtr);
            }
        }
        finally
        {
            if (installationsPtr != IntPtr.Zero)
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
            }
        }
    }

    /// <summary>
    /// Removes a remote repository from an installation.
    /// </summary>
    /// <param name="remoteName">The name of the remote to remove (e.g., "flathub-beta")</param>
    /// <param name="isSystemWide">Whether to remove from system installation (true) or user installation (false)</param>
    /// <returns>A result message indicating success or failure</returns>
    public string RemoveRemote(string remoteName, bool isSystemWide = false)
    {
        if (!NativeResolver.IsLibraryAvailable(FlatpakReference.LibName))
        {
            return "Flatpak library is not available.";
        }

        IntPtr installationPtr;
        IntPtr installationsPtr = IntPtr.Zero;

        if (isSystemWide)
        {
            installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr sysError);
            if (sysError != IntPtr.Zero || installationsPtr == IntPtr.Zero)
            {
                FlatpakReference.GErrorFree(sysError);
                if (installationsPtr != IntPtr.Zero)
                {
                    FlatpakReference.GPtrArrayUnref(installationsPtr);
                }

                return "Failed to get system installation.";
            }

            var dataPtr = Marshal.ReadIntPtr(installationsPtr);
            installationPtr = Marshal.ReadIntPtr(dataPtr);

            if (installationPtr == IntPtr.Zero)
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
                return "System installation pointer is invalid.";
            }
        }
        else
        {
            installationPtr = FlatpakReference.InstallationNewUser(IntPtr.Zero, out IntPtr userError);
            if (userError != IntPtr.Zero || installationPtr == IntPtr.Zero)
            {
                FlatpakReference.GErrorFree(userError);
                return "Failed to get user installation.";
            }
        }

        try
        {
            var success = FlatpakReference.InstallationRemoveRemote(
                installationPtr, remoteName, IntPtr.Zero, out IntPtr error);

            if (!success || error != IntPtr.Zero)
            {
                var errorMsg = FlatpakReference.GetErrorMessage(error);
                FlatpakReference.GErrorFree(error);
                return $"Failed to remove remote '{remoteName}': {errorMsg}";
            }

            var scope = isSystemWide ? "system" : "user";
            return $"Successfully removed remote '{remoteName}' from {scope} installation.";
        }
        finally
        {
            if (isSystemWide)
            {
                if (installationsPtr != IntPtr.Zero)
                {
                    FlatpakReference.GPtrArrayUnref(installationsPtr);
                }
            }
            else
            {
                FlatpakReference.GObjectUnref(installationPtr);
            }
        }
    }

    /// <summary>
    /// Retrieve flatpak that require updates
    /// <returns>List of FlatpakPackageDto</returns>
    /// </summary>
    public List<FlatpakPackageDto> GetPackagesWithUpdates()
    {
        var packages = new List<FlatpakPackageDto>();

        var installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr error);

        if (error != IntPtr.Zero || installationsPtr == IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(error);
            FlatpakReference.GPtrArrayUnref(installationsPtr);
            return packages;
        }

        try
        {
            var dataPtr = Marshal.ReadIntPtr(installationsPtr);
            var length = Marshal.ReadInt32(installationsPtr + IntPtr.Size);

            for (var i = 0; i < length; i++)
            {
                var installationPtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                if (installationPtr == IntPtr.Zero) continue;

                var refsPtr = FlatpakReference.InstanceGetUpdates(
                    installationPtr, IntPtr.Zero, out IntPtr refsError);

                if (refsError != IntPtr.Zero || refsPtr == IntPtr.Zero)
                {
                    continue;
                }

                try
                {
                    var refsDataPtr = Marshal.ReadIntPtr(refsPtr);
                    var refsLength = Marshal.ReadInt32(refsPtr + IntPtr.Size);

                    for (var j = 0; j < refsLength; j++)
                    {
                        var refPtr = Marshal.ReadIntPtr(refsDataPtr + j * IntPtr.Size);
                        if (refPtr == IntPtr.Zero) continue;

                        var package = new FlatpackPackage(refPtr);
                        packages.Add(package.ToDto());
                    }
                }
                finally
                {
                    FlatpakReference.GPtrArrayUnref(refsPtr);
                }
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(installationsPtr);
        }

        return packages;
    }

    /// <summary>
    /// Updates the local appstream metadata for all remotes in both system and user installations.
    /// </summary>
    /// <param name="arch">The architecture (e.g., "x86_64"). If null, uses current system architecture.</param>
    /// <returns>Tuple with success boolean and result message</returns>
    public (bool success, string message) UpdateAppstream(string? arch = null)
    {
        if (!NativeResolver.IsLibraryAvailable(FlatpakReference.LibName))
        {
            return (false, "Flatpak library is not available.");
        }

        var targetArch = arch ?? GetCurrentArch();
        var results = new List<string>();
        var hasErrors = false;

        // Update system installation remotes
        var installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr error);
        if (error == IntPtr.Zero && installationsPtr != IntPtr.Zero)
        {
            try
            {
                var dataPtr = Marshal.ReadIntPtr(installationsPtr);
                var length = Marshal.ReadInt32(installationsPtr + IntPtr.Size);

                for (var i = 0; i < length; i++)
                {
                    var installationPtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                    if (installationPtr != IntPtr.Zero)
                    {
                        UpdateAppstreamForInstallation(installationPtr, "system", targetArch, results, ref hasErrors);
                    }
                }
            }
            finally
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
            }
        }

        // Update user installation remotes
        var userInstallationPtr = FlatpakReference.InstallationNewUser(IntPtr.Zero, out IntPtr userError);
        if (userError == IntPtr.Zero && userInstallationPtr != IntPtr.Zero)
        {
            try
            {
                UpdateAppstreamForInstallation(userInstallationPtr, "user", targetArch, results, ref hasErrors);
            }
            finally
            {
                FlatpakReference.GObjectUnref(userInstallationPtr);
            }
        }

        if (results.Count == 0)
        {
            return (false, "No remotes found to update.");
        }

        var message = string.Join("\n", results);
        return (!hasErrors, message);
    }

    /// <summary>
    /// Helper method to update appstream for all remotes in a specific installation.
    /// </summary>
    private void UpdateAppstreamForInstallation(IntPtr installationPtr, string scope, string arch,
        List<string> results, ref bool hasErrors)
    {
        IntPtr remotesPtr = FlatpakReference.InstallationListRemotes(
            installationPtr, IntPtr.Zero, out IntPtr error);

        if (error != IntPtr.Zero || remotesPtr == IntPtr.Zero)
        {
            FlatpakReference.GErrorFree(error);
            return;
        }

        try
        {
            var remotesDataPtr = Marshal.ReadIntPtr(remotesPtr);
            var remotesLength = Marshal.ReadInt32(remotesPtr + IntPtr.Size);

            for (var i = 0; i < remotesLength; i++)
            {
                IntPtr remotePtr = Marshal.ReadIntPtr(remotesDataPtr + i * IntPtr.Size);
                if (remotePtr == IntPtr.Zero) continue;

                var remoteName = PtrToStringSafe(FlatpakReference.RemoteGetName(remotePtr));
                if (string.IsNullOrEmpty(remoteName)) continue;

                var success = FlatpakReference.InstallationUpdateAppstreamSync(
                    installationPtr,
                    remoteName,
                    arch,
                    out bool outChanged,
                    IntPtr.Zero,
                    out IntPtr updateError);

                if (!success || updateError != IntPtr.Zero)
                {
                    var errorMsg = FlatpakReference.GetErrorMessage(updateError);
                    FlatpakReference.GErrorFree(updateError);

                    if (errorMsg.Contains("No such ref 'appstream") || errorMsg.Contains("not found"))
                    {
                        results.Add($"{remoteName} ({scope}): no appstream data available");
                    }
                    else
                    {
                        results.Add($"Failed to update {remoteName} ({scope}): {errorMsg}");
                        hasErrors = true;
                    }
                }
                else
                {
                    var status = outChanged ? "updated" : "already up to date";
                    results.Add($"{remoteName} ({scope}): {status}");
                }
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(remotesPtr);
        }
    }

    /// <summary>
    /// Gets all available apps from the local appstream metadata.
    /// </summary>
    /// <param name="remoteName">The remote name (e.g., "flathub"). I</param>
    /// <param name="arch">The architecture (e.g., "x86_64"). If null, uses current system architecture.</param>
    /// <returns>List of available applications from appstream</returns>
    public List<AppstreamApp> GetAvailableAppsFromAppstream(string remoteName, string? arch = null)
    {
        try
        {
            var targetArch = arch ?? GetCurrentArch();
            var remote = remoteName;

            if (string.IsNullOrEmpty(remote))
            {
                return new List<AppstreamApp>();
            }

            // Try system installation first
            var appstreamPath = $"/var/lib/flatpak/appstream/{remote}/{targetArch}/active/appstream.xml";

            // Try .xml.gz if .xml doesn't exist
            if (!File.Exists(appstreamPath))
            {
                appstreamPath = $"/var/lib/flatpak/appstream/{remote}/{targetArch}/active/appstream.xml.gz";
            }


            if (!File.Exists(appstreamPath))
            {
                var userHome = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                appstreamPath = Path.Combine(userHome, ".local/share/flatpak/appstream", remote, targetArch,
                    "active/appstream.xml");

                if (!File.Exists(appstreamPath))
                {
                    appstreamPath = Path.Combine(userHome, ".local/share/flatpak/appstream", remote, targetArch,
                        "active/appstream.xml.gz");
                }
            }

            if (!File.Exists(appstreamPath))
            {
                return new List<AppstreamApp>();
            }

            var parser = new AppstreamParser();
            return parser.ParseFile(appstreamPath);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"Failed to parse appstream: {e}");
        }

        return new List<AppstreamApp>();
    }

    /// <summary>
    /// Gets all available apps from a remote by querying the remote directly (without appstream).
    /// </summary>
    /// <param name="remoteName">The remote name (e.g., "flathub-beta")</param>
    /// <returns>List of available applications from the remote</returns>
    public List<FlatpakPackageDto> GetAvailableAppsFromRemote(string remoteName)
    {
        var packages = new List<FlatpakPackageDto>();

        if (!NativeResolver.IsLibraryAvailable(FlatpakReference.LibName))
        {
            return packages;
        }

        if (string.IsNullOrEmpty(remoteName))
        {
            return packages;
        }

        // Try system installation first
        var installationsPtr = FlatpakReference.GetSystemInstallations(IntPtr.Zero, out IntPtr error);
        if (error == IntPtr.Zero && installationsPtr != IntPtr.Zero)
        {
            try
            {
                var dataPtr = Marshal.ReadIntPtr(installationsPtr);
                var length = Marshal.ReadInt32(installationsPtr + IntPtr.Size);

                for (var i = 0; i < length; i++)
                {
                    var installationPtr = Marshal.ReadIntPtr(dataPtr + i * IntPtr.Size);
                    if (installationPtr != IntPtr.Zero)
                    {
                        AddPackagesFromRemote(installationPtr, remoteName, packages);
                    }
                }
            }
            finally
            {
                FlatpakReference.GPtrArrayUnref(installationsPtr);
            }
        }


        if (packages.Count == 0)
        {
            var userInstallationPtr = FlatpakReference.InstallationNewUser(IntPtr.Zero, out IntPtr userError);
            if (userError == IntPtr.Zero && userInstallationPtr != IntPtr.Zero)
            {
                try
                {
                    AddPackagesFromRemote(userInstallationPtr, remoteName, packages);
                }
                finally
                {
                    FlatpakReference.GObjectUnref(userInstallationPtr);
                }
            }
            else
            {
                FlatpakReference.GErrorFree(userError);
            }
        }

        return packages;
    }

    /// <summary>
    /// Helper method to add packages from a remote to the list
    /// </summary>
    private void AddPackagesFromRemote(IntPtr installationPtr, string remoteName, List<FlatpakPackageDto> packages)
    {
        var refsPtr = FlatpakReference.InstallationListRemoteRefsSync(
            installationPtr, remoteName, IntPtr.Zero, out IntPtr error);

        if (error != IntPtr.Zero || refsPtr == IntPtr.Zero)
        {
            if (error != IntPtr.Zero)
            {
                var errorMsg = FlatpakReference.GetErrorMessage(error);
                Console.Error.WriteLine($"Failed to list remote refs for '{remoteName}': {errorMsg}");
                FlatpakReference.GErrorFree(error);
            }

            return;
        }

        try
        {
            var refsDataPtr = Marshal.ReadIntPtr(refsPtr);
            var refsLength = Marshal.ReadInt32(refsPtr + IntPtr.Size);

            for (var j = 0; j < refsLength; j++)
            {
                var refPtr = Marshal.ReadIntPtr(refsDataPtr + j * IntPtr.Size);
                if (refPtr == IntPtr.Zero) continue;

                // Check if it's an app (not a runtime)
                var kind = FlatpakReference.RefGetKind(refPtr);
                if (kind != FlatpakReference.FlatpakRefKindApp) continue;

                var package = new FlatpackPackage(refPtr);
                packages.Add(package.ToDto());
            }
        }
        finally
        {
            FlatpakReference.GPtrArrayUnref(refsPtr);
        }
    }

    public FlatpakRemoteRefInfo GetRemoteSize(string remote, string name, string arch, string branch)
    {
        if (!NativeResolver.IsLibraryAvailable(FlatpakReference.LibName))
        {
            return new FlatpakRemoteRefInfo();
        }

        var installation = FlatpakReference.FlatpakInstallationNewSystem(IntPtr.Zero, out var error);

        var remoteRef = FlatpakReference.InstallationFetchRemoteRefsSync(installation, remote, 0, name,
            GetCurrentArch(), branch, IntPtr.Zero, out _);

        if (remoteRef == IntPtr.Zero) return new FlatpakRemoteRefInfo();

        var remoteRefInfo = new FlatpakRemoteRefInfo
        {
            DownloadSize = FlatpakReference.RemoteRefGetDownloadSize(remoteRef),
            InstalledSize = FlatpakReference.RemoteRefGetInstalledSize(remoteRef),
        };


        FlatpakReference.GObjectUnref(remoteRef);
        return remoteRefInfo;
        
    }

    /// <summary>
    /// Gets all available apps from appstream and serializes to JSON (AOT-compatible)
    /// </summary>
    /// <param name="remoteName">The remote name (e.g., "flathub"). If null, uses the first remote.</param>
    /// <param name="arch">The architecture (e.g., "x86_64"). If null, uses current system architecture.</param>
    /// <returns>JSON string of available applications</returns>
    public string GetAvailableAppsFromAppstreamJson(string remoteName, string? arch = null, bool getAll = false)
    {
        var apps = new List<AppstreamApp>();
        if (getAll)
        {
            var remotes = ListRemotesWithDetails();
            foreach (var remote in remotes)
            {
                foreach (var app in GetAvailableAppsFromAppstream(remote.Name, arch))
                {
                    var existing = apps.FirstOrDefault(a => a.Id == app.Id);
                    if (existing != null)
                        existing.Remotes.Add(new FlatpakRemoteDto()
                        {
                            Name = remote.Name,
                            Scope = remote.Scope
                        });
                    else
                    {
                        app.Remotes.Add(new FlatpakRemoteDto()
                        {
                            Name = remote.Name,
                            Scope = remote.Scope
                        });
                        apps.Add(app);
                    }
                }
            }
        }
        else
        {
            apps = GetAvailableAppsFromAppstream(remoteName, arch);
        }

        return JsonSerializer.Serialize(apps, AppstreamJsonContext.Default.ListAppstreamApp);
    }

    /// <summary>
    /// Search Flathub return Api Response
    /// <param name="query">Query Parameter</param>
    /// <param name="page">Page of query</param>
    /// <param name="limit">Limit of each page</param>
    /// <param name="filters">Filters to apply on search</param>
    /// <param name="ct">Cancellation Token</param>
    /// <returns>FlatpakApiResponse</returns>
    /// </summary>
    public async Task<FlatpakApiResponse> SearchFlathubAsync(
        string query,
        int page = 1,
        int limit = 21,
        List<FlatpakHttpRequests.FlathubSearchFilter>? filters = null,
        CancellationToken ct = default)
    {
        return await new FlatpakHttpRequests().SearchAsync(query, page, limit, filters, ct);
    }

    /// <summary>
    /// Search Flathub return json Response
    /// <param name="query">Query Parameter</param>
    /// <param name="page">Page of query</param>
    /// <param name="limit">Limit of each page</param>
    /// <param name="filters">Filters to apply on search</param>
    /// <param name="ct">Cancellation Token</param>
    /// <returns>FlatpakApiResponse</returns>
    /// </summary>
    public async Task<string> SearchFlathubJsonAsync(
        string query,
        int page = 1,
        int limit = 21,
        List<FlatpakHttpRequests.FlathubSearchFilter>? filters = null,
        CancellationToken ct = default)
    {
        return await new FlatpakHttpRequests().SearchJsonAsync(query, page, limit, filters, ct);
    }


    /// <summary>
    /// Gets the current system architecture for flatpak refs.
    /// </summary>
    private static string GetCurrentArch()
    {
        return RuntimeInformation.OSArchitecture switch
        {
            Architecture.X64 => "x86_64",
            Architecture.Arm64 => "aarch64",
            Architecture.X86 => "i386",
            Architecture.Arm => "arm",
            _ => "x86_64"
        };
    }

    /// <summary>
    /// Convert Ptr* to String
    /// </summary>
    private static string PtrToStringSafe(IntPtr ptr)
    {
        return ptr == IntPtr.Zero ? string.Empty : Marshal.PtrToStringUTF8(ptr) ?? string.Empty;
    }

    /// <summary>
    /// Builds a Flatpak ref string based on the package kind.
    /// </summary>
    private static string BuildRefString(FlatpakPackageDto package)
    {
        var kindString = package.Kind == FlatpakReference.FlatpakRefKindApp
            ? "app"
            : "runtime";

        return $"{kindString}/{package.Id}/{package.Arch}/{package.Branch}";
    }

    /// <summary>
    /// Callback for when a new operation is started in a transaction.
    /// </summary>
    private static void OnNewOperation(IntPtr transaction, IntPtr operation, IntPtr progress, IntPtr userData)
    {
        try
        {
            if (progress == IntPtr.Zero)
            {
                return;
            }

            // Set update frequency to get more frequent updates (in milliseconds)
            FlatpakReference.TransactionProgressSetUpdateFrequency(progress, 50);

            // Get initial progress info
            var percentage = FlatpakReference.TransactionProgressGetProgress(progress);
            var isEstimating = FlatpakReference.TransactionProgressGetIsEstimating(progress);
            var statusPtr = FlatpakReference.TransactionProgressGetStatus(progress);
            var status = PtrToStringSafe(statusPtr) ?? "";

            if (isEstimating)
            {
                Console.Error.WriteLine($"[DEBUG_LOG]Progress: Estimating... {status}");
            }
            else
            {
                Console.Error.WriteLine($"[DEBUG_LOG]Progress: {percentage}% - {status}");
            }

            // Connect to the progress changed signal for this specific operation
            var progressCallback = new FlatpakReference.TransactionProgressCallback(OnOperationProgress);
            var progressCallbackPtr = Marshal.GetFunctionPointerForDelegate(progressCallback);
            FlatpakReference.GSignalConnectData(progress, "changed", progressCallbackPtr,
                IntPtr.Zero, IntPtr.Zero, 0);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Error in new operation callback: " + ex.Message);
        }
    }

    /// <summary>
    /// Callback for operation progress updates.
    /// </summary>
    private static void OnOperationProgress(IntPtr progress, IntPtr userData1, IntPtr userData2)
    {
        if (progress == IntPtr.Zero) return;

        var percentage = FlatpakReference.TransactionProgressGetProgress(progress);
        var isEstimating = FlatpakReference.TransactionProgressGetIsEstimating(progress);
        var statusPtr = FlatpakReference.TransactionProgressGetStatus(progress);
        var status = PtrToStringSafe(statusPtr) ?? "";

        if (isEstimating)
        {
            Console.Error.Write($"[Shelly][DEBUG_LOG]Progress: Estimating... {status}\n");
        }
        else
        {
            Console.Error.Write($"[Shelly][DEBUG_LOG]Progress: {percentage}% - {status}\n");
        }
    }

    /// <summary>
    /// Downloads and parses a .flatpakrepo file to extract repository configuration.
    /// </summary>
    private FlatpakrepoConfig? DownloadAndParseFlatpakrepo(string url)
    {
        try
        {
            using var httpClient = new System.Net.Http.HttpClient();
            httpClient.Timeout = TimeSpan.FromSeconds(30);
            var content = httpClient.GetStringAsync(url).GetAwaiter().GetResult();

            var config = new FlatpakrepoConfig();
            
            foreach (var line in content.Split('\n'))
            {
                var trimmed = line.Trim();
                if (string.IsNullOrEmpty(trimmed) || trimmed.StartsWith('[') || trimmed.StartsWith('#'))
                    continue;

                var parts = trimmed.Split('=', 2);
                if (parts.Length != 2)
                    continue;

                var key = parts[0].Trim();
                var value = parts[1].Trim();

                switch (key)
                {
                    case "Url":
                        config.Url = value;
                        break;
                    case "GPGVerify":
                        config.GpgVerify = value.Equals("true", StringComparison.OrdinalIgnoreCase);
                        break;
                }
            }

            return config;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Error downloading/parsing .flatpakrepo: {ex.Message}");
            return null;
        }
    }

    public void Dispose()
    {
        //Currently just here to have it when needed.
    }

    private class FlatpakrepoConfig
    {
        public string? Url { get; set; }
        public bool? GpgVerify { get; set; }
    }
}