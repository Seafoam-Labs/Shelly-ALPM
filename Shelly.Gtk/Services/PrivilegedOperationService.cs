using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services.TrayServices;
using Shelly.Gtk.Services.Wire;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Services;

public class PrivilegedOperationService(
    IProcessExecutor processExecutor,
    ICredentialManager credentialManager,
    IAlpmEventService alpmEventService,
    IConfigService configService,
    ILockoutService lockoutService,
    ITrayDbus trayDbus,
    IPackageUpdateNotifier packageUpdateNotifier,
    IDirtyService dirtyService,
    IGenericQuestionService genericQuestionService)
    : IPrivilegedOperationService
{
    private readonly string _cliPath = CliPathResolver.FindCliPath();
    private readonly bool _noConfirm = configService.LoadConfig().NoConfirm;

    public async Task<OperationResult> SyncDatabasesAsync()
    {
        return await ExecutePrivilegedCommandAsync("Synchronize package databases", "sync");
    }

    public async Task<OperationResult> InstallPackagesAsync(IEnumerable<string> packages, bool upgrade = false)
    {
        var args = new List<string> { "install" };
        args.AddRange(packages);
        if (upgrade) args.Add("-u");
        if (_noConfirm) args.Add("--no-confirm");

        var result = await ExecutePrivilegedCommandAsync("Install packages", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> InstallLocalPackageAsync(string filePath)
    {
        var args = new List<string> { "install", $"\"{filePath}\"" };
        if (_noConfirm) args.Add("--no-confirm");

        var result = await ExecutePrivilegedCommandAsync("Install local package", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> RemovePackagesAsync(IEnumerable<string> packages, bool isCascade, bool isCleanup,
        bool removeOptionalDeps, bool removePackageFromCache = false)
    {
        var args = new List<string> { "remove" };
        args.AddRange(packages);
        if (isCascade) args.Add("-c");
        if (isCleanup) args.Add("-r");
        if (removeOptionalDeps) args.Add("-o");
        if (_noConfirm) args.Add("--no-confirm");

        var result = await ExecutePrivilegedCommandAsync("Remove packages", args.ToArray());
        if (result.Success && removePackageFromCache) _ = await RemovePackageCacheAsync(packages);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> RemoveLocalPackagesAsync(IEnumerable<string> packages)
    {
        var args = new List<string> { "remove" };
        args.AddRange(packages.Select(p => $"\"{p}\""));
        if (_noConfirm) args.Add("--no-confirm");

        var result = await ExecutePrivilegedCommandAsync("Remove local packages", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> UpdatePackagesAsync(IEnumerable<string> packages)
    {
        var args = new List<string> { "update" };
        args.AddRange(packages);
        if (_noConfirm) args.Add("--no-confirm");

        var result = await ExecutePrivilegedCommandAsync("Update packages", args.ToArray());
        SendDbusMessage(result);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> UpgradeSystemAsync()
    {
        var args = new List<string> { "upgrade" };
        if (_noConfirm) args.Add("--no-confirm");

        var result = await ExecutePrivilegedCommandAsync("Upgrade system", args.ToArray());
        SendDbusMessage(result);
        return result;
    }

    public async Task<OperationResult> UpgradeAllAsync()
    {
        var args = new List<string> { "upgrade-all" };
        if (_noConfirm) args.Add("--no-confirm");

        var result = await ExecutePrivilegedCommandAsync("Upgrade all", args.ToArray());
        if (!result.Success) _ = Task.Run(trayDbus.UpdatesMadeInUiAsync);
        SendDbusMessage(result);
        return result;
    }

    public async Task<OperationResult> ForceSyncDatabaseAsync()
    {
        return await ExecutePrivilegedCommandAsync("Force synchronize package databases", "sync", "--force");
    }

    public async Task<OperationResult> RemoveDbLockAsync()
    {
        return await processExecutor.RunPrivilegedSystemCommandAsync(
            "Removing database lock", ["rm", "-f", "/var/lib/pacman/db.lck"]);
    }

    public async Task<OperationResult> InstallAurPackagesAsync(IEnumerable<string> packages, bool useChroot = false,
        bool runChecks = false)
    {
        var args = new List<string> { "aur", "install" };
        args.AddRange(packages);
        if (useChroot) args.Add("-c");
        if (runChecks) args.Add("--check");
        if (_noConfirm) args.Add("--no-confirm");

        var result = await ExecutePrivilegedCommandAsync("Install AUR packages", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Aur);
        return result;
    }

    public async Task<OperationResult> RemoveAurPackagesAsync(IEnumerable<string> packages, bool isCascade = false)
    {
        var args = new List<string> { "aur", "remove" };
        args.AddRange(packages);
        if (isCascade) args.Add("-c");
        if (_noConfirm) args.Add("--no-confirm");

        var result = await ExecutePrivilegedCommandAsync("Remove AUR packages", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Aur);
        return result;
    }

    public async Task<OperationResult> UpdateAurPackagesAsync(IEnumerable<string> packages, bool runChecks = false)
    {
        var args = new List<string> { "aur", "update" };
        args.AddRange(packages);
        if (runChecks) args.Add("--check");
        if (_noConfirm) args.Add("--no-confirm");

        var result = await ExecutePrivilegedCommandAsync("Update AUR packages", args.ToArray());
        SendDbusMessage(result);
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Aur);
        return result;
    }

    public async Task<List<AlpmPackageDto>> SearchPackagesAsync(string query)
    {
        return await ExecuteJsonCommandAsync<AlpmPackageDto>("search packages",
            () => processExecutor.RunShellyCliCommandAsync(["query", "--available", $"\"{query}\"", "--no-confirm", "--json"]));
    }

    public async Task<List<PackageBuild>> GetAurPackageBuild(IEnumerable<string> packages)
    {
        var args = new List<string> { "aur", "search-pkgbuild" };
        args.AddRange(packages);
        if (_noConfirm) args.Add("--no-confirm");

        return await ExecuteJsonCommandAsync<PackageBuild>("AUR package builds",
            () => ExecutePrivilegedCommandAsync("Get Package Builds", args.ToArray()));
    }

    public async Task<List<AlpmPackageUpdateDto>> GetPackagesNeedingUpdateAsync()
    {
        return await ExecuteJsonCommandAsync<AlpmPackageUpdateDto>("updates",
            () => ExecutePrivilegedCommandAsync("Check for Updates", "list-updates", "--json"));
    }

    public async Task<List<AlpmPackageDto>> GetAvailablePackagesAsync(bool showHidden = false)
    {
        var args = new List<string> { "query", "--available", "--json" };
        if (showHidden) args.Add("--show-hidden");

        return await ExecuteJsonCommandAsync<AlpmPackageDto>("available packages",
            () => processExecutor.RunShellyCliCommandAsync(args.ToArray()));
    }

    public async Task<List<AlpmPackageDto>> GetInstalledPackagesAsync(bool showHidden = false)
    {
        var args = new List<string> { "query", "--installed", "--json" };
        if (showHidden) args.Add("--show-hidden");

        return await ExecuteJsonCommandAsync<AlpmPackageDto>("installed packages",
            () => processExecutor.RunShellyCliCommandAsync(args.ToArray()));
    }

    public async Task<List<LocalPackageDto>> GetLocalInstalledPackagesAsync()
    {
        return await ExecuteJsonCommandAsync<LocalPackageDto>("local installed packages",
            () => processExecutor.RunShellyCliCommandAsync(["query", "--local", "--json"]));
    }

    public async Task<List<AurPackageDto>> GetAurInstalledPackagesAsync(bool showHidden = false)
    {
        var args = new List<string> { "aur", "list", "--json" };
        if (showHidden) args.Add("--show-hidden");

        return await ExecuteJsonCommandAsync<AurPackageDto>("AUR installed packages",
            () => processExecutor.RunShellyCliCommandAsync(args.ToArray()));
    }

    public async Task<List<AurUpdateDto>> GetAurUpdatePackagesAsync(bool showHidden = false)
    {
        var args = new List<string> { "aur", "list-updates", "--json" };
        if (showHidden) args.Add("--show-hidden");

        return await ExecuteJsonCommandAsync<AurUpdateDto>("AUR updates",
            () => processExecutor.RunShellyCliCommandAsync(args.ToArray()));
    }

    public async Task<List<AurPackageDto>> SearchAurPackagesAsync(string query)
    {
        return await ExecuteJsonCommandAsync<AurPackageDto>("AUR search",
            () => processExecutor.RunShellyCliCommandAsync(["aur", "search", query, "--json"]));
    }

    public async Task<List<DowngradeOptionDto>> GetDowngradeOptionsAsync(string packageName)
    {
        return await ExecuteJsonCommandAsync<DowngradeOptionDto>("downgrade options",
            () => processExecutor.RunShellyCliCommandAsync(["downgrade", packageName, "--list-options"]));
    }

    private static async Task<List<T>> ExecuteJsonCommandAsync<T>(string operationName, Func<Task<OperationResult>> executeCommand)
    {
        var result = await executeCommand();
        if (!result.Success) return [];

        if (JsonPackFrame.TryDecode<List<T>>(result.Output, out var framed) && framed is not null)
            return framed;

        Console.WriteLine($"Failed to decode {operationName}");
        return [];
    }

    public async Task<bool> IsPackageInstalledOnMachine(string packageName)
    {
        var standardPackages = await GetInstalledPackagesAsync();
        return standardPackages.Any(x => x.Name.Contains(packageName));
    }

    public async Task<OperationResult> RunCacheCleanAsync(int keep, bool uninstalledOnly)
    {
        var args = new List<string> { "cache-clean", "-k", keep.ToString() };
        if (uninstalledOnly) args.Add("-i");
        return await ExecutePrivilegedCommandAsync("Clean package cache", args.ToArray());
    }


    public async Task<OperationResult> PurifyCorruptionAsync()
    {
        return await ExecutePrivilegedCommandAsync("Delete corrupted packages", "purify");
    }

    public async Task<OperationResult> FixXdgPermissionsAsync()
    {
        return await ExecutePrivilegedCommandAsync("Fix Shelly folder ownership", "fix-permissions");
    }

    public async Task<OperationResult> FlatpakInstallFromBundle(string path)
    {
        var result = await ExecutePrivilegedCommandAsync("Install Flatpak Bundle",
            "flatpak", "install-bundle", path, "--system", "true");
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<OperationResult> DowngradePackageAsync(string packageName, string filename, bool addIgnore)
    {
        var args = new List<string> { "downgrade", packageName, "--target", $"\"{filename}\"", "--no-confirm" };
        if (addIgnore) args.Add("--ignore");

        var result = await ExecutePrivilegedCommandAsync("Downgrade package", args.ToArray());
        if (result.Success) dirtyService.MarkDirty(DirtyScopes.NativeInstalled);
        return result;
    }

    public async Task<OperationResult> MigrateAppImagesAsync()
    {
        return await ExecutePrivilegedCommandAsync("Migrate AppImages", "appimage", "migrate-manager");
    }

    private async Task<OperationResult> RemovePackageCacheAsync(IEnumerable<string> packages)
    {
        var targetArgs = packages
            .SelectMany(x => new[] { "-t", x })
            .ToArray();

        return await ExecutePrivilegedCommandAsync("Removing package from cache",
            ["cache-clean", "--no-confirm", ..targetArgs]);
    }

    private void SendDbusMessage(OperationResult result)
    {
        if (!result.Success) return;
        _ = Task.Run(trayDbus.UpdatesMadeInUiAsync);
        packageUpdateNotifier.NotifyPackagesUpdated();
    }

    private async Task<OperationResult> ExecutePrivilegedCommandAsync(string operationDescription, params string[] args)
    {
        // Request credentials if not already available
        var hasCredentials = await credentialManager.RequestCredentialsAsync(operationDescription);
        if (!hasCredentials)
            return new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = "Authentication cancelled by user.",
                ExitCode = -1
            };

        var password = credentialManager.GetPassword();
        if (string.IsNullOrEmpty(password))
            return new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = "No password available.",
                ExitCode = -1
            };

        var arguments = string.Join(" ", args);
        var fullCommand = $"{_cliPath} {arguments}";

        Console.WriteLine($"Executing privileged command: sudo {fullCommand}");
        var isPasswordless = password == CredentialManager.NoPassword;
        using var process = new Process();
        process.StartInfo = new ProcessStartInfo
        {
            FileName = "sudo",
            Arguments = isPasswordless ? $"-k {fullCommand} --ui-mode" : $"-S -k {fullCommand} --ui-mode",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            CreateNoWindow = true
        };

        var outputBuilder = new StringBuilder();
        var errorBuilder = new StringBuilder();
        StreamWriter? stdinWriter = null;

        // Semaphore + counter to prevent stdin from closing before async callbacks complete
        var stdinLock = new SemaphoreSlim(1, 1);
        var stdinClosed = false;
        var pendingCallbacks = 0;
        var allCallbacksDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        // Helper to safely write to stdin
        async Task SafeWriteAsync(string value)
        {
            await stdinLock.WaitAsync();
            try
            {
                if (!stdinClosed && stdinWriter != null)
                {
                    await stdinWriter.WriteLineAsync(value);
                    await stdinWriter.FlushAsync();
                }
            }
            catch (ObjectDisposedException)
            {
                // ignored
            }
            finally
            {
                stdinLock.Release();
            }
        }

        // State for provider selection handling
        var providerOptions = new List<ProviderOptionUiModel>();
        string? providerQuestion = null;

        // State for optional dependency selection handling
        var optDepsOptions = new List<ProviderOptionUiModel>();
        string? optDepsQuestion = null;

        // State for restart check results
        var restartNeedsReboot = false;
        var restartFailures = new List<(string Service, string Error)>();

        var eventRouter = new EventRouter(alpmEventService, lockoutService);

        process.OutputDataReceived += async (_, e) =>
        {
            if (e.Data == null) return;
            outputBuilder.AppendLine(e.Data);

            if (JsonPackFrame.TryExtractPayload(e.Data, out var b64))
            {
                if (eventRouter.TryDispatch(b64)) return;
                Interlocked.Increment(ref pendingCallbacks);
                try
                {
                    await QuestionRouter.TryDispatchAsync(b64, SafeWriteAsync, genericQuestionService);
                }
                catch (Exception ex)
                {
                    await Console.Error.WriteLineAsync($"QuestionRouter error: {ex.Message}");
                }
                finally
                {
                    if (Interlocked.Decrement(ref pendingCallbacks) == 0)
                        allCallbacksDone.TrySetResult();
                }

                return;
            }

            Console.WriteLine(e.Data);
        };

        process.ErrorDataReceived += async (_, e) =>
        {
            if (e.Data == null) return;

            // Filter out the password prompt from sudo
            if (e.Data.Contains("[sudo]") || e.Data.Contains("password for")) return;

            Interlocked.Increment(ref pendingCallbacks);
            try
            {
                Console.WriteLine(e.Data);
                // Handle provider selection protocol
                if (e.Data.StartsWith("[ALPM_SELECT_PROVIDER]"))
                {
                    Console.WriteLine("Provider question received");
                    await Console.Error.WriteLineAsync($"[Shelly]Select provider for: {e.Data}");
                    providerOptions.Clear();
                    providerQuestion = e.Data["[ALPM_SELECT_PROVIDER]".Length..];
                    await Console.Error.WriteLineAsync($"[Shelly]Select provider for: {providerQuestion}");
                }
                else if (e.Data.StartsWith("[ALPM_PROVIDER_OPTION]"))
                {
                    await Console.Error.WriteLineAsync($"[Shelly]Provider option received: {e.Data}");
                    var payload = e.Data["[ALPM_PROVIDER_OPTION]".Length..];
                    var option = AlpmMarkerParser.ParseOptionPayload(payload, out var idx);
                    if (idx >= 0)
                        AlpmMarkerParser.PlaceAt(providerOptions, idx, option);
                    else
                        providerOptions.Add(option);
                }
                else if (e.Data.StartsWith("[ALPM_PROVIDER_END]"))
                {
                    await Console.Error.WriteLineAsync("[Shelly]Provider selection received");
                    var providerArgs = new QuestionEventArgs(
                        QuestionType.SelectProvider,
                        providerQuestion ?? "Select provider",
                        [..providerOptions],
                        providerQuestion);

                    alpmEventService.RaiseQuestion(providerArgs);

                    await providerArgs.WaitForResponseAsync();

                    if (providerArgs.Response != -1) await SafeWriteAsync(providerArgs.Response.ToString());

                    await Console.Error.WriteLineAsync($"[Shelly]Wrote selection {providerArgs.Response}");

                    providerQuestion = null;
                    providerOptions.Clear();
                }
                else if (e.Data.StartsWith("[ALPM_SELECT_OPTDEPS]"))
                {
                    Console.WriteLine("Optional dependency selection received");
                    optDepsOptions.Clear();
                    optDepsQuestion = e.Data["[ALPM_SELECT_OPTDEPS]".Length..];
                    await Console.Error.WriteLineAsync($"[Shelly]Select optional deps for: {optDepsQuestion}");
                }
                else if (e.Data.StartsWith("[ALPM_OPTDEPS_OPTION]"))
                {
                    var payload = e.Data["[ALPM_OPTDEPS_OPTION]".Length..];
                    var option = AlpmMarkerParser.ParseOptionPayload(payload, out var idx);
                    if (idx >= 0)
                        AlpmMarkerParser.PlaceAt(optDepsOptions, idx, option);
                    else
                        optDepsOptions.Add(option);
                }
                else if (e.Data.StartsWith("[ALPM_OPTDEPS_END]"))
                {
                    await Console.Error.WriteLineAsync("[Shelly]Optional deps selection end");
                    var optionalArgs = new QuestionEventArgs(
                        QuestionType.SelectOptionalDeps,
                        optDepsQuestion ?? "Select optional dependencies",
                        [..optDepsOptions],
                        optDepsQuestion);

                    alpmEventService.RaiseQuestion(optionalArgs);
                    await optionalArgs.WaitForResponseAsync();

                    var indices = optionalArgs.SelectedIndices ?? [];
                    var json = JsonSerializer.Serialize(indices, ShellyGtkJsonContext.Default.Int32Array);
                    await SafeWriteAsync(json);
                    optDepsQuestion = null;
                    optDepsOptions.Clear();
                }
                else if (e.Data.StartsWith("[ALPM_QUESTION_CONFLICT]"))
                {
                    Console.WriteLine("Conflict question found");
                    var questionText = e.Data["[ALPM_QUESTION_CONFLICT]".Length..];
                    await Console.Error.WriteLineAsync($"[Shelly]Question received: {questionText}");

                    var conflictArgs = new QuestionEventArgs(
                        QuestionType.ConflictPkg,
                        questionText);

                    alpmEventService.RaiseQuestion(conflictArgs);

                    await conflictArgs.WaitForResponseAsync();

                    if (conflictArgs.Response != -1) await SafeWriteAsync(conflictArgs.Response == 1 ? "y" : "n");
                }
                else if (e.Data.StartsWith("[ALPM_QUESTION_REMOVEPKG]"))
                {
                    Console.WriteLine("Found Remove Package Question");
                    var questionText = e.Data["[ALPM_QUESTION_REMOVEPKG]".Length..];
                    await Console.Error.WriteLineAsync($"[Shelly]Question received: {questionText}");

                    var removeArgs = new QuestionEventArgs(QuestionType.RemovePkgs, questionText);

                    alpmEventService.RaiseQuestion(removeArgs);

                    await removeArgs.WaitForResponseAsync();

                    if (removeArgs.Response != -1) await SafeWriteAsync(removeArgs.Response == 1 ? "y" : "n");
                }
                else if (e.Data.StartsWith("[ALPM_QUESTION_CORRUPTEDPKG]"))
                {
                    Console.WriteLine("Corrupted package question found");
                    var questionText = e.Data["[ALPM_QUESTION_CORRUPTEDPKG]".Length..];
                    await Console.Error.WriteLineAsync($"[Shelly]Question received: {questionText}");

                    var corruptedArgs = new QuestionEventArgs(QuestionType.CorruptedPkg, questionText);

                    alpmEventService.RaiseQuestion(corruptedArgs);

                    await corruptedArgs.WaitForResponseAsync();

                    if (corruptedArgs.Response != -1) await SafeWriteAsync(corruptedArgs.Response == 1 ? "y" : "n");
                }
                else if (e.Data.StartsWith("[ALPM_QUESTION_IMPORTKEY]"))
                {
                    Console.WriteLine("Import key question found");
                    var questionText = e.Data["[ALPM_QUESTION_IMPORTKEY]".Length..];
                    await Console.Error.WriteLineAsync($"[Shelly]Question received: {questionText}");

                    var importArgs = new QuestionEventArgs(QuestionType.ImportKey, questionText);

                    alpmEventService.RaiseQuestion(importArgs);

                    await importArgs.WaitForResponseAsync();

                    if (importArgs.Response != -1) await SafeWriteAsync(importArgs.Response == 1 ? "y" : "n");
                }
                else if (e.Data.StartsWith("[ALPM_QUESTION_REPLACEPKG]"))
                {
                    Console.WriteLine("Replace Question Found");
                    var questionText = e.Data["[ALPM_QUESTION_REPLACEPKG]".Length..];
                    await Console.Error.WriteLineAsync($"[Shelly]Question received: {questionText}");

                    var replaceArgs = new QuestionEventArgs(QuestionType.ReplacePkg, questionText);

                    alpmEventService.RaiseQuestion(replaceArgs);

                    await replaceArgs.WaitForResponseAsync();

                    if (replaceArgs.Response != -1) await SafeWriteAsync(replaceArgs.Response == 1 ? "y" : "n");
                }
                else if (e.Data.StartsWith("[ALPM_SCRIPTLET]"))
                {
                    var line = e.Data["[ALPM_SCRIPTLET]".Length..];
                    if (!string.IsNullOrEmpty(line)) lockoutService.ParseLog($"[SCRIPTLET] {line}");
                }
                else if (e.Data.StartsWith("[ALPM_HOOK]"))
                {
                    var line = e.Data["[ALPM_HOOK]".Length..];
                    if (!string.IsNullOrEmpty(line)) lockoutService.ParseLog($"[HOOK] {line}");
                }
                else if (e.Data.StartsWith("[ALPM_QUESTION]"))
                {
                    Console.WriteLine("Generic question found");
                    var questionText = e.Data["[ALPM_QUESTION]".Length..];
                    await Console.Error.WriteLineAsync($"[Shelly]Question received: {questionText}");

                    var genericArgs = new QuestionEventArgs(QuestionType.InstallIgnorePkg, questionText);

                    alpmEventService.RaiseQuestion(genericArgs);

                    await genericArgs.WaitForResponseAsync();

                    if (genericArgs.Response != -1) await SafeWriteAsync(genericArgs.Response == 1 ? "y" : "n");
                }
                else if (e.Data.StartsWith("[Shelly][RESTART_REQUIRED]"))
                {
                    var payload = e.Data["[Shelly][RESTART_REQUIRED]".Length..];
                    if (payload == "reboot")
                        restartNeedsReboot = true;
                }
                else if (e.Data.StartsWith("[Shelly][RESTART_FAILED]"))
                {
                    var payload = e.Data["[Shelly][RESTART_FAILED]".Length..];
                    if (!payload.StartsWith("service:")) return;

                    var rest = payload["service:".Length..];
                    var parts = rest.Split('|', 2);
                    var svcName = parts[0];
                    var svcError = parts.Length > 1 ? parts[1] : "Unknown error";
                    restartFailures.Add((svcName, svcError));
                }
                else if (e.Data.StartsWith("[Shelly][DEBUG]"))
                {
                    // Debug messages - skip, don't forward to lockout dialog
                }
                else
                {
                    errorBuilder.AppendLine(e.Data);
                    await Console.Error.WriteLineAsync(e.Data);
                }
            }
            catch (Exception ex)
            {
                await Console.Error.WriteLineAsync($"Error processing stderr: {ex.Message}");
                errorBuilder.AppendLine(e.Data);
            }
            finally
            {
                if (Interlocked.Decrement(ref pendingCallbacks) == 0)
                    allCallbacksDone.TrySetResult();
            }
        };

        try
        {
            process.Start();
            stdinWriter = process.StandardInput;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            // Write password to stdin followed by newline
            if (!isPasswordless)
            {
                await stdinWriter.WriteLineAsync(password);
                await stdinWriter.FlushAsync();
            }

            await process.WaitForExitAsync();

            // Wait for any in-flight async callbacks to finish writing
            if (Volatile.Read(ref pendingCallbacks) > 0)
                await Task.WhenAny(allCallbacksDone.Task, Task.Delay(TimeSpan.FromMinutes(2)));

            await stdinLock.WaitAsync();
            try
            {
                stdinClosed = true;
                stdinWriter.Close();
            }
            finally
            {
                stdinLock.Release();
            }

            var success = process.ExitCode == 0;

            // Update credential validation status based on result
            if (success)
            {
                credentialManager.MarkAsValidated();
            }
            else
            {
                // Check if it was an authentication failure
                var errorOutput = errorBuilder.ToString();
                if (errorOutput.Contains("incorrect password") ||
                    errorOutput.Contains("Sorry, try again") ||
                    errorOutput.Contains("Authentication failure") ||
                    (process.ExitCode == 1 && errorOutput.Contains("sudo")))
                    credentialManager.MarkAsInvalid();
            }

            return new OperationResult
            {
                Success = success,
                Output = outputBuilder.ToString(),
                Error = errorBuilder.ToString(),
                ExitCode = process.ExitCode,
                NeedsReboot = restartNeedsReboot,
                FailedServiceRestarts = restartFailures
            };
        }
        catch (Exception ex)
        {
            return new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = ex.Message,
                ExitCode = -1
            };
        }
    }
}