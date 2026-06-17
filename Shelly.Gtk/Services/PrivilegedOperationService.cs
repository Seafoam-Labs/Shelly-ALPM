using System.Diagnostics;
using System.Text;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services.TrayServices;
using Shelly.Gtk.Services.Wire;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects;

namespace Shelly.Gtk.Services;

public class PrivilegedOperationService : IPrivilegedOperationService
{
    private readonly string _cliPath;
    private readonly ICredentialManager _credentialManager;
    private readonly IAlpmEventService _alpmEventService;
    private readonly IConfigService _configService;
    private readonly ILockoutService _lockoutService;
    private readonly ITrayDbus _trayDbus;
    private readonly IPackageUpdateNotifier _packageUpdateNotifier;
    private readonly IDirtyService _dirtyService;
    private readonly IGenericQuestionService _genericQuestionService;

    public PrivilegedOperationService(ICredentialManager credentialManager, IAlpmEventService alpmEventService,
        IConfigService configService, ILockoutService lockoutService, ITrayDbus trayDbus,
        IPackageUpdateNotifier packageUpdateNotifier, IDirtyService dirtyService, IGenericQuestionService genericQuestionService)
    {
        _credentialManager = credentialManager;
        _alpmEventService = alpmEventService;
        _configService = configService;
        _lockoutService = lockoutService;
        _trayDbus = trayDbus;
        _packageUpdateNotifier = packageUpdateNotifier;
        _dirtyService = dirtyService;
        _cliPath = CliPathResolver.FindCliPath();
        _genericQuestionService = genericQuestionService;
    }

    private string[] AppendNoConfirmIfNeeded(params string[] args)
    {
        var config = _configService.LoadConfig();
        if (config.NoConfirm)
        {
            return [.. args, "--no-confirm"];
        }

        return args;
    }

    private Task<OperationResult> ExecutePrivilegedWithNoConfirmCheck(string operationDescription, params string[] args)
    {
        var finalArgs = AppendNoConfirmIfNeeded(args);
        return ExecutePrivilegedCommandAsync(operationDescription, finalArgs);
    }

    public async Task<OperationResult> SyncDatabasesAsync()
    {
        return await ExecutePrivilegedCommandAsync("Synchronize package databases", "sync");
    }

    public async Task<List<AlpmPackageDto>> SearchPackagesAsync(string query)
    {
        var result = await ExecuteCommandAsync("explore", "--available", $"\"{query}\"",
            "--no-confirm", "--json");
        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            JsonPackFrame.TryDecode<List<AlpmPackageDto>>(result.Output, out var framed);
            return framed ?? throw new InvalidOperationException();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse available packages JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<OperationResult> InstallPackagesAsync(IEnumerable<string> packages, bool upgrade = false)
    {
        var packageArgs = string.Join(" ", packages);
        if (upgrade)
        {
            packageArgs += " -u";
        }

        var result = await ExecutePrivilegedWithNoConfirmCheck("Install packages", "install", packageArgs);
        if (result.Success) _dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> InstallLocalPackageAsync(string filePath)
    {
        var result = await ExecutePrivilegedWithNoConfirmCheck("Install local package", "install",
            $"\"{filePath}\"");
        if (result.Success) _dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }


    private async Task<OperationResult> RemovePackageCacheAsync(
        IEnumerable<string> packages)
    {
        var targetArgs = packages
            .SelectMany(x => new[] { "-t", x })
            .ToArray();

        await Console.Error.WriteAsync("Removing package cache...");

        return await ExecutePrivilegedCommandAsync(
            "Removing package from cache",
            [
                "cache-clean",
                "--no-confirm",
                ..targetArgs
            ]);
    }

    public async Task<OperationResult> RemovePackagesAsync(IEnumerable<string> packages, bool isCascade, bool isCleanup,
        bool removeOptionalDeps, bool removePackageFromCache)
    {
        var packageArgs = string.Join(" ", packages);
        if (isCascade)
        {
            packageArgs += " -c";
        }

        if (isCleanup)
        {
            packageArgs += " -r";
        }

        if (removeOptionalDeps)
        {
            packageArgs += " -o";
        }

        var result = await ExecutePrivilegedWithNoConfirmCheck("Remove packages", "remove", packageArgs);
        if (result.Success && removePackageFromCache)
        {
            _ = await RemovePackageCacheAsync(packages);
        }

        if (result.Success) _dirtyService.MarkDirty(DirtyScopes.Native);

        return result;
    }

    public async Task<OperationResult> RemoveLocalPackagesAsync(IEnumerable<string> packages)
    {
        var packageArgs = string.Join(" ", packages.Select(p => $"\"{p}\""));
        var result = await ExecutePrivilegedWithNoConfirmCheck("Remove local packages", "remove", packageArgs);
        if (result.Success) _dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> UpdatePackagesAsync(IEnumerable<string> packages)
    {
        var packageArgs = string.Join(" ", packages);

        var result = await ExecutePrivilegedWithNoConfirmCheck("Update packages", "update", packageArgs);
        SendDbusMessage(result);
        if (result.Success) _dirtyService.MarkDirty(DirtyScopes.Native);
        return result;
    }

    public async Task<OperationResult> UpgradeSystemAsync()
    {
        var result = await ExecutePrivilegedWithNoConfirmCheck("Upgrade system", "upgrade");
        SendDbusMessage(result);
        return result;
    }

    public async Task<OperationResult> UpgradeAllAsync()
    {
        var result = await ExecutePrivilegedWithNoConfirmCheck("Upgrade all", "upgrade-all");
        
        if(!result.Success)
        {
            _ = Task.Run(() => _trayDbus.UpdatesMadeInUiAsync());
        }
        
        SendDbusMessage(result);
        return result;
    }

    public async Task<OperationResult> ForceSyncDatabaseAsync()
    {
        return await ExecutePrivilegedCommandAsync("Force synchronize package databases", "sync", "--force");
    }

    public async Task<OperationResult> RemoveDbLockAsync()
    {
        return await ExecutePrivilegedSystemCommandAsync(
            "Removing database lock",
            "rm",
            "-f",
            "/var/lib/pacman/db.lck"
        );
    }

    public async Task<OperationResult> InstallAurPackagesAsync(IEnumerable<string> packages, bool useChroot = false,
        bool runChecks = false)
    {
        var packageArgs = string.Join(" ", packages);
        if (useChroot)
        {
            packageArgs += " -c";
        }

        if (runChecks)
        {
            packageArgs += " --check";
        }

        var result = await ExecutePrivilegedWithNoConfirmCheck("Install AUR packages", "aur", "install", packageArgs);
        if (result.Success) _dirtyService.MarkDirty(DirtyScopes.Aur);
        return result;
    }

    public async Task<OperationResult> RemoveAurPackagesAsync(IEnumerable<string> packages, bool isCascade = false)
    {
        var packageArgs = string.Join(" ", packages);
        if (isCascade)
        {
            packageArgs += " -c";
        }

        var result = await ExecutePrivilegedWithNoConfirmCheck("Remove AUR packages", "aur", "remove", packageArgs);
        if (result.Success) _dirtyService.MarkDirty(DirtyScopes.Aur);
        return result;
    }

    public async Task<OperationResult> UpdateAurPackagesAsync(IEnumerable<string> packages, bool runChecks = false)
    {
        var packageArgs = string.Join(" ", packages);
        if (runChecks)
        {
            packageArgs += " --check";
        }

        var result = await ExecutePrivilegedWithNoConfirmCheck("Update AUR packages", "aur", "update", packageArgs);
        SendDbusMessage(result);
        if (result.Success) _dirtyService.MarkDirty(DirtyScopes.Aur);
        return result;
    }

    public async Task<List<PackageBuild>> GetAurPackageBuild(IEnumerable<string> packages)
    {
        var packageArgs = string.Join(" ", packages);
        var result =
            await ExecutePrivilegedWithNoConfirmCheck("Get Package Builds", "aur", "search-pkgbuild", packageArgs);

        if (!result.Success) return [];
        JsonPackFrame.TryDecode<List<PackageBuild>>(result.Output, out var framed);
        return framed ?? [];
    }

    public async Task<List<AlpmPackageUpdateDto>> GetPackagesNeedingUpdateAsync()
    {
        var result = await ExecutePrivilegedCommandAsync("Check for Updates", "list-updates", "--json");
        if (!result.Success) return [];
        JsonPackFrame.TryDecode<List<AlpmPackageUpdateDto>>(result.Output, out var framed);
        return framed ?? [];
    }

    public async Task<List<AlpmPackageDto>> GetAvailablePackagesAsync(bool showHidden = false)
    {
        var result = showHidden
            ? await ExecuteCommandAsync("explore", "--available", "--json", "--show-hidden")
            : await ExecuteCommandAsync("explore", "--available", "--json");

        if (!result.Success) return [];
        JsonPackFrame.TryDecode<List<AlpmPackageDto>>(result.Output, out var framed);
        return framed ?? [];
    }

    public async Task<List<AlpmPackageDto>> GetInstalledPackagesAsync(bool showHidden = false)
    {
        var result = showHidden
            ? await ExecuteCommandAsync("explore", "--installed", "--json", "--show-hidden")
            : await ExecuteCommandAsync("explore", "--installed", "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            JsonPackFrame.TryDecode<List<AlpmPackageDto>>(result.Output, out var framed);
            return framed ?? throw new InvalidOperationException();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse installed packages JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<List<LocalPackageDto>> GetLocalInstalledPackagesAsync()
    {
        var result = await ExecuteCommandAsync("explore", "--local", "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            JsonPackFrame.TryDecode<List<LocalPackageDto>>(result.Output, out var framed);
            return framed ?? throw new InvalidOperationException();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse local installed packages JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<List<AurPackageDto>> GetAurInstalledPackagesAsync(bool showHidden = false)
    {
        var result = showHidden
            ? await ExecuteCommandAsync("aur list", "--json", "--show-hidden")
            : await ExecuteCommandAsync("aur list", "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            JsonPackFrame.TryDecode<List<AurPackageDto>>(result.Output, out var framed);

            return framed ?? throw new InvalidOperationException();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse installed packages JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<List<AurUpdateDto>> GetAurUpdatePackagesAsync(bool showHidden = false)
    {
        var result = showHidden
            ? await ExecuteCommandAsync("aur list-updates", "--json", "--show-hidden")
            : await ExecuteCommandAsync("aur list-updates", "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            JsonPackFrame.TryDecode<List<AurUpdateDto>>(result.Output, out var framed);
            return framed ?? throw new InvalidOperationException();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse installed packages JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<List<AurPackageDto>> SearchAurPackagesAsync(string query)
    {
        var result = await ExecuteCommandAsync("aur search", query, "--json");

        if (!result.Success || string.IsNullOrWhiteSpace(result.Output))
        {
            return [];
        }

        try
        {
            JsonPackFrame.TryDecode<List<AurPackageDto>>(result.Output, out var framed);
            return framed ?? throw new InvalidOperationException();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to parse installed packages JSON: {ex.Message}");
            return [];
        }
    }

    public async Task<bool> IsPackageInstalledOnMachine(string packageName)
    {
        var standardPackages = await GetInstalledPackagesAsync();
        return standardPackages.Any(x => x.Name.Contains(packageName));
    }

    public async Task<OperationResult> RunCacheCleanAsync(int keep, bool uninstalledOnly)
    {
        var args = new List<string> { "cache-clean", "-k", keep.ToString() };
        if (uninstalledOnly)
            args.Add("-i");
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
        var result = await ExecutePrivilegedCommandAsync("Install Flatpak Bundle", "flatpak", "install-bundle", path,
            "--system", "true");
        if (result.Success) _dirtyService.MarkDirty(DirtyScopes.Flatpak);
        return result;
    }

    public async Task<List<DowngradeOptionDto>> GetDowngradeOptionsAsync(string packageName)
    {
        var result = await ExecuteCommandAsync("downgrade", packageName, "--list-options");
        if (!result.Success || string.IsNullOrWhiteSpace(result.Output)) return [];
        JsonPackFrame.TryDecode<List<DowngradeOptionDto>>(result.Output, out var framed);
        return framed ?? throw new InvalidOperationException();
    }

    public async Task<OperationResult> DowngradePackageAsync(string packageName, string filename, bool addIgnore)
    {
        var args = new List<string> { "downgrade", packageName, "--target", $"\"{filename}\"", "--no-confirm" };
        if (addIgnore) args.Add("--ignore");
        var result = await ExecutePrivilegedCommandAsync("Downgrade package", args.ToArray());
        if (result.Success) _dirtyService.MarkDirty(DirtyScopes.NativeInstalled);
        return result;
    }

    public async Task<OperationResult>MigrateAppImagesAsync()
    {
        return await ExecutePrivilegedCommandAsync("Migrate AppImages", "appimage", "migrate-manager");
    }

    private void SendDbusMessage(OperationResult result)
    {
        if (result.Success)
        {
            _ = Task.Run(() => _trayDbus.UpdatesMadeInUiAsync());
            _packageUpdateNotifier.NotifyPackagesUpdated();
        }
    }

    private async Task<OperationResult> ExecuteCommandAsync(params string[] args)
    {
        var arguments = string.Join(" ", args);
        var fullCommand = $"{_cliPath} {arguments}";

        Console.WriteLine($"Executing command: {fullCommand} --ui-mode");

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = _cliPath,
                Arguments = string.IsNullOrWhiteSpace(arguments) ? "--ui-mode" : arguments + " --ui-mode",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            }
        };

        try
        {
            process.Start();

            // Read output and error streams synchronously to avoid race conditions
            // Use Task.WhenAll to read both streams concurrently
            var outputTask = process.StandardOutput.ReadToEndAsync();
            var errorTask = process.StandardError.ReadToEndAsync();

            await Task.WhenAll(outputTask, errorTask);
            await process.WaitForExitAsync();

            var output = await outputTask;
            var error = await errorTask;

            // Log stderr for debugging
            if (!string.IsNullOrEmpty(error))
            {
                await Console.Error.WriteLineAsync(error);
            }

            return new OperationResult
            {
                Success = process.ExitCode == 0,
                Output = output,
                Error = error,
                ExitCode = process.ExitCode
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

    private async Task<OperationResult> ExecutePrivilegedCommandAsync(string operationDescription, params string[] args)
    {
        // Request credentials if not already available
        var hasCredentials = await _credentialManager.RequestCredentialsAsync(operationDescription);
        if (!hasCredentials)
        {
            return new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = "Authentication cancelled by user.",
                ExitCode = -1
            };
        }

        var password = _credentialManager.GetPassword();
        if (string.IsNullOrEmpty(password))
        {
            return new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = "No password available.",
                ExitCode = -1
            };
        }

        var arguments = string.Join(" ", args);
        var fullCommand = $"{_cliPath} {arguments}";

        Console.WriteLine($"Executing privileged command: sudo {fullCommand}");
        var isPasswordless = password == CredentialManager.NoPassword;
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "sudo",
                //removing -k from sudo as a test
                Arguments = isPasswordless ? $"-k {fullCommand} --ui-mode" : $"-S -k {fullCommand} --ui-mode",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                CreateNoWindow = true
            }
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
        var awaitingProviderSelection = false;

        // State for optional dependency selection handling
        var optDepsOptions = new List<ProviderOptionUiModel>();
        string? optDepsQuestion = null;
        var awaitingOptDepsSelection = false;

        // State for conflict selection handling
        var conflictOptions = new List<string>();
        string? conflictQuestion = null;
        var awaitingConflictSelection = false;

        // State for restart check results
        var restartNeedsReboot = false;
        var restartFailures = new List<(string Service, string Error)>();

        var eventRouter = new EventRouter(_alpmEventService, _lockoutService);

        process.OutputDataReceived += async (sender, e) =>
        {
            if (e.Data == null) return;
            outputBuilder.AppendLine(e.Data);

            if (JsonPackFrame.TryExtractPayload(e.Data, out var b64))
            {
                if (eventRouter.TryDispatch(b64)) return;
                Interlocked.Increment(ref pendingCallbacks);
                try
                {
                    await QuestionRouter.TryDispatchAsync(b64, SafeWriteAsync, _genericQuestionService);
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"QuestionRouter error: {ex.Message}");
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

        process.ErrorDataReceived += async (sender, e) =>
        {
            if (e.Data != null)
            {
                // Filter out the password prompt from sudo
                if (!e.Data.Contains("[sudo]") && !e.Data.Contains("password for"))
                {
                    Interlocked.Increment(ref pendingCallbacks);
                    try
                    {
                        Console.WriteLine(e.Data);
                        // Handle provider selection protocol
                        if (e.Data.StartsWith("[ALPM_SELECT_PROVIDER]"))
                        {
                            Console.WriteLine("Provider question received");
                            Console.Error.WriteLine($"[Shelly]Select provider for: {e.Data}");
                            awaitingProviderSelection = true;
                            providerOptions.Clear();
                            providerQuestion = e.Data.Substring("[ALPM_SELECT_PROVIDER]".Length);
                            Console.Error.WriteLine($"[Shelly]Select provider for: {providerQuestion}");
                        }
                        else if (e.Data.StartsWith("[ALPM_PROVIDER_OPTION]"))
                        {
                            Console.Error.WriteLine($"[Shelly]Provider option received: {e.Data}");
                            var payload = e.Data.Substring("[ALPM_PROVIDER_OPTION]".Length);
                            var option = AlpmMarkerParser.ParseOptionPayload(payload, out var idx);
                            if (idx >= 0)
                                AlpmMarkerParser.PlaceAt(providerOptions, idx, option);
                            else
                                providerOptions.Add(option);
                        }
                        else if (e.Data.StartsWith("[ALPM_PROVIDER_END]"))
                        {
                            Console.Error.WriteLine($"[Shelly]Provider selection received");
                            var args = new QuestionEventArgs(
                                QuestionType.SelectProvider,
                                providerQuestion ?? "Select provider",
                                new List<ProviderOptionUiModel>(providerOptions),
                                providerQuestion);

                            _alpmEventService.RaiseQuestion(args);

                            await args.WaitForResponseAsync();

                            if (args.Response != -1)
                            {
                                await SafeWriteAsync(args.Response.ToString());
                            }

                            await Console.Error.WriteLineAsync($"[Shelly]Wrote selection {args.Response}");

                            awaitingProviderSelection = false;
                            providerQuestion = null;
                            providerOptions.Clear();
                        }
                        else if (e.Data.StartsWith("[ALPM_SELECT_OPTDEPS]"))
                        {
                            Console.WriteLine("Optional dependency selection received");
                            awaitingOptDepsSelection = true;
                            optDepsOptions.Clear();
                            optDepsQuestion = e.Data.Substring("[ALPM_SELECT_OPTDEPS]".Length);
                            Console.Error.WriteLine($"[Shelly]Select optional deps for: {optDepsQuestion}");
                        }
                        else if (e.Data.StartsWith("[ALPM_OPTDEPS_OPTION]"))
                        {
                            var payload = e.Data.Substring("[ALPM_OPTDEPS_OPTION]".Length);
                            var option = AlpmMarkerParser.ParseOptionPayload(payload, out var idx);
                            if (idx >= 0)
                                AlpmMarkerParser.PlaceAt(optDepsOptions, idx, option);
                            else
                                optDepsOptions.Add(option);
                        }
                        else if (e.Data.StartsWith("[ALPM_OPTDEPS_END]"))
                        {
                            Console.Error.WriteLine("[Shelly]Optional deps selection end");
                            var args = new QuestionEventArgs(
                                QuestionType.SelectOptionalDeps,
                                optDepsQuestion ?? "Select optional dependencies",
                                new List<ProviderOptionUiModel>(optDepsOptions),
                                optDepsQuestion);

                            _alpmEventService.RaiseQuestion(args);
                            await args.WaitForResponseAsync();

                            var indices = args.SelectedIndices ?? [];
                            var json = System.Text.Json.JsonSerializer.Serialize(
                                indices, ShellyGtkJsonContext.Default.Int32Array);
                            await SafeWriteAsync(json);
                            awaitingOptDepsSelection = false;
                            optDepsQuestion = null;
                            optDepsOptions.Clear();
                        }
                        else if (e.Data.StartsWith("[ALPM_QUESTION_CONFLICT]"))
                        {
                            Console.WriteLine("Conflict question found");
                            var questionText = e.Data.Substring("[ALPM_QUESTION_CONFLICT]".Length);
                            Console.Error.WriteLine($"[Shelly]Question received: {questionText}");

                            var args = new QuestionEventArgs(
                                QuestionType.ConflictPkg,
                                questionText);

                            _alpmEventService.RaiseQuestion(args);

                            await args.WaitForResponseAsync();

                            if (args.Response != -1)
                            {
                                await SafeWriteAsync(args.Response == 1 ? "y" : "n");
                            }
                        }
                        else if (e.Data.StartsWith("[ALPM_QUESTION_REMOVEPKG]"))
                        {
                            Console.WriteLine("Found Remove Package Question");
                            var questionText = e.Data.Substring("[ALPM_QUESTION_REMOVEPKG]".Length);
                            Console.Error.WriteLine($"[Shelly]Question received: {questionText}");

                            var args = new QuestionEventArgs(
                                QuestionType.RemovePkgs,
                                questionText);

                            _alpmEventService.RaiseQuestion(args);

                            await args.WaitForResponseAsync();

                            if (args.Response != -1)
                            {
                                await SafeWriteAsync(args.Response == 1 ? "y" : "n");
                            }
                        }
                        else if (e.Data.StartsWith("[ALPM_QUESTION_CORRUPTEDPKG]"))
                        {
                            Console.WriteLine("Corrupted package question found");
                            var questionText = e.Data.Substring("[ALPM_QUESTION_CORRUPTEDPKG]".Length);
                            Console.Error.WriteLine($"[Shelly]Question received: {questionText}");

                            var args = new QuestionEventArgs(
                                QuestionType.CorruptedPkg,
                                questionText);

                            _alpmEventService.RaiseQuestion(args);

                            await args.WaitForResponseAsync();

                            if (args.Response != -1)
                            {
                                await SafeWriteAsync(args.Response == 1 ? "y" : "n");
                            }
                        }
                        else if (e.Data.StartsWith("[ALPM_QUESTION_IMPORTKEY]"))
                        {
                            Console.WriteLine("Inmport key question found");
                            var questionText = e.Data.Substring("[ALPM_QUESTION_IMPORTKEY]".Length);
                            Console.Error.WriteLine($"[Shelly]Question received: {questionText}");

                            var args = new QuestionEventArgs(
                                QuestionType.ImportKey,
                                questionText);

                            _alpmEventService.RaiseQuestion(args);

                            await args.WaitForResponseAsync();

                            if (args.Response != -1)
                            {
                                await SafeWriteAsync(args.Response == 1 ? "y" : "n");
                            }
                        }
                        else if (e.Data.StartsWith("[ALPM_QUESTION_REPLACEPKG]"))
                        {
                            Console.WriteLine("Replace Question Found");
                            var questionText = e.Data.Substring("[ALPM_QUESTION_REPLACEPKG]".Length);
                            Console.Error.WriteLine($"[Shelly]Question received: {questionText}");
                            var args = new QuestionEventArgs(QuestionType.ReplacePkg, questionText);
                            _alpmEventService.RaiseQuestion(args);
                            await args.WaitForResponseAsync();

                            if (args.Response != -1)
                            {
                                await SafeWriteAsync(args.Response == 1 ? "y" : "n");
                            }
                        }
                        else if (e.Data.StartsWith("[ALPM_SCRIPTLET]"))
                        {
                            var line = e.Data.Substring("[ALPM_SCRIPTLET]".Length);
                            if (!string.IsNullOrEmpty(line))
                            {
                                _lockoutService.ParseLog($"[SCRIPTLET] {line}");
                            }
                        }
                        else if (e.Data.StartsWith("[ALPM_HOOK]"))
                        {
                            var line = e.Data.Substring("[ALPM_HOOK]".Length);
                            if (!string.IsNullOrEmpty(line))
                            {
                                _lockoutService.ParseLog($"[HOOK] {line}");
                            }
                        }
                        // Check for generic ALPM question (yes/no)
                        else if (e.Data.StartsWith("[ALPM_QUESTION]"))
                        {
                            Console.WriteLine("Generic question found");
                            var questionText = e.Data.Substring("[ALPM_QUESTION]".Length);
                            Console.Error.WriteLine($"[Shelly]Question received: {questionText}");

                            var args = new QuestionEventArgs(
                                QuestionType.InstallIgnorePkg,
                                questionText);

                            _alpmEventService.RaiseQuestion(args);

                            await args.WaitForResponseAsync();

                            if (args.Response != -1)
                            {
                                await SafeWriteAsync(args.Response == 1 ? "y" : "n");
                            }
                        }
                        else if (e.Data.StartsWith("[Shelly][RESTART_REQUIRED]"))
                        {
                            var payload = e.Data.Substring("[Shelly][RESTART_REQUIRED]".Length);
                            if (payload == "reboot")
                                restartNeedsReboot = true;
                        }
                        else if (e.Data.StartsWith("[Shelly][RESTART_FAILED]"))
                        {
                            var payload = e.Data.Substring("[Shelly][RESTART_FAILED]".Length);
                            if (payload.StartsWith("service:"))
                            {
                                var rest = payload.Substring("service:".Length);
                                var parts = rest.Split('|', 2);
                                var svcName = parts[0];
                                var svcError = parts.Length > 1 ? parts[1] : "Unknown error";
                                restartFailures.Add((svcName, svcError));
                            }
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
                }
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
            {
                await Task.WhenAny(allCallbacksDone.Task, Task.Delay(TimeSpan.FromMinutes(2)));
            }


            await stdinLock.WaitAsync();
            try
            {
                stdinClosed = true;
                stdinWriter?.Close();
            }
            finally
            {
                stdinLock.Release();
            }

            var success = process.ExitCode == 0;

            // Update credential validation status based on result
            if (success)
            {
                _credentialManager.MarkAsValidated();
            }
            else
            {
                // Check if it was an authentication failure
                var errorOutput = errorBuilder.ToString();
                if (errorOutput.Contains("incorrect password") ||
                    errorOutput.Contains("Sorry, try again") ||
                    errorOutput.Contains("Authentication failure") ||
                    process.ExitCode == 1 && errorOutput.Contains("sudo"))
                {
                    _credentialManager.MarkAsInvalid();
                }
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

    private async Task<OperationResult> ExecutePrivilegedSystemCommandAsync(string operationDescription,
        params string[] args)
    {
        var hasCredentials = await _credentialManager.RequestCredentialsAsync(operationDescription);
        if (!hasCredentials)
        {
            return new OperationResult
            {
                Success = false,
                Output = string.Empty,
                Error = "Authentication cancelled by user.",
                ExitCode = -1
            };
        }

        var password = _credentialManager.GetPassword();
        var isPasswordless = password == CredentialManager.NoPassword;

        var arguments = string.Join(" ", args);

        Console.WriteLine($"Executing privileged system command: sudo {arguments}");

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "sudo",
                Arguments = $"-S -k {arguments}",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                CreateNoWindow = true
            }
        };

        try
        {
            process.Start();

            if (!isPasswordless)
            {
                await process.StandardInput.WriteLineAsync(password);
                await process.StandardInput.FlushAsync();
                process.StandardInput.Close();
            }

            var outputTask = process.StandardOutput.ReadToEndAsync();
            var errorTask = process.StandardError.ReadToEndAsync();

            await Task.WhenAll(outputTask, errorTask);
            await process.WaitForExitAsync();

            var output = await outputTask;
            var error = await errorTask;

            if (!string.IsNullOrEmpty(error))
            {
                await Console.Error.WriteLineAsync(error);
            }

            return new OperationResult
            {
                Success = process.ExitCode == 0,
                Output = output,
                Error = error,
                ExitCode = process.ExitCode
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