using System;
using System.Collections.Generic;
using System.ComponentModel.Design;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using PackageManager.Alpm.Events;
using PackageManager.Alpm.Events.EventArgs;
using PackageManager.Alpm.Questions;
using PackageManager.Alpm.TransactionErrors;
using PackageManager.Alpm.Utilities;
using PackageManager.Utilities;
using static PackageManager.Alpm.AlpmReference;

#pragma warning disable CS8618 // Non-nullable field must contain a non-null value when exiting constructor. Consider adding the 'required' modifier or declaring as nullable.
#pragma warning disable CS8618 // Non-nullable field must contain a non-null value when exiting constructor. Consider adding the 'required' modifier or declaring as nullable.

namespace PackageManager.Alpm;

[SuppressMessage("ReSharper", "SuggestVarOrType_BuiltInTypes",
    Justification = "This class should be extra clear on the type definitions of the variables.")]
[SuppressMessage("Compiler",
    "CS8618:Non-nullable field must contain a non-null value when exiting constructor. Consider adding the \'required\' modifier or declaring as nullable.")]
public class AlpmManager(string configPath = "/etc/pacman.conf") : IDisposable, IAlpmManager
{
    private string _configPath = configPath;
    private PacmanConf _config;
    private IntPtr _handle = IntPtr.Zero;

    private static SocketsHttpHandler _socketsHttpHandler = new()
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2),
        MaxConnectionsPerServer = 10,
        AutomaticDecompression = DecompressionMethods.All,
        AllowAutoRedirect = true,
        MaxAutomaticRedirections = 10,
        ConnectTimeout = TimeSpan.FromSeconds(30),
        EnableMultipleHttp2Connections = true,
        EnableMultipleHttp3Connections = true,
    };

    private static readonly HttpClient DownloadClient = new(_socketsHttpHandler, disposeHandler: false)
    {
        Timeout = TimeSpan.FromMinutes(5),
        DefaultRequestHeaders =
        {
            { "User-Agent", "Shelly/2.0 (compatible)" }
        },
    };

    private HashSet<string> _preDownloadedFiles = new();

    private AlpmFetchCallback _fetchCallback;
    private AlpmEventCallback _eventCallback;
    private AlpmQuestionCallback _questionCallback;
    private AlpmProgressCallback? _progressCallback;
    private int _parallelDownloads = 10;
    private bool _showHiddenPackages = false;
    private bool _isPackageDownload;

    public event EventHandler<AlpmProgressEventArgs>? Progress;
    public event EventHandler<AlpmPackageOperationEventArgs>? PackageOperation;
    public event EventHandler<AlpmQuestionEventArgs>? Question;
    public event EventHandler<AlpmReplacesEventArgs>? Replaces;
    public event EventHandler<AlpmScriptletEventArgs>? ScriptletInfo;
    public event EventHandler<AlpmHookEventArgs>? HookRun;
    public event EventHandler<AlpmPacnewEventArgs>? PacnewInfo;
    public event EventHandler<AlpmPacsaveEventArgs>? PacsaveInfo;

    public event EventHandler<AlpmErrorEventArgs>? ErrorEvent;

    public void IntializeWithSync()
    {
        Initialize(true);
        Sync(true);
    }

    public void Initialize(bool root = false, int parallelDownloads = 10, bool useTempPath = false,
        string tempPath = "", bool showHiddenPackages = false)
    {
        _parallelDownloads = parallelDownloads;
        _showHiddenPackages = showHiddenPackages;
        if (_handle != IntPtr.Zero)
        {
            Release(_handle);
            _handle = IntPtr.Zero;
        }

        _config = PacmanConfParser.Parse(_configPath);
        //Checks to see if the temp path is being used to run in
        //non-root mode for update checking.
        if (useTempPath)
        {
            // Symlink the real local database into the temp path so ALPM
            // can see installed packages when checking for updates.
            var realLocalDb = Path.Combine(_config.DbPath, "local");
            _config.DbPath = tempPath;
            var tempLocalDb = Path.Combine(tempPath, "local");
            if (Directory.Exists(realLocalDb))
            {
                // Remove existing local dir/symlink in temp path so we can create a fresh symlink
                if (Directory.Exists(tempLocalDb) || File.Exists(tempLocalDb))
                {
                    var info = new DirectoryInfo(tempLocalDb);
                    if (info.LinkTarget != null)
                    {
                        info.Delete();
                    }
                    else
                    {
                        Directory.Delete(tempLocalDb, true);
                    }
                }

                Directory.CreateSymbolicLink(tempLocalDb, realLocalDb);
            }
        }

        var lockFilePath = Path.Combine(_config.DbPath, "db.lck");
        if (File.Exists(lockFilePath))
        {
            try
            {
                File.Delete(lockFilePath);
            }
            catch (IOException)
            {
                //Do nothing accept natural failure
            }
        }

        _handle = AlpmReference.Initialize(_config.RootDirectory, _config.DbPath, out var error);
        if (error != 0)
        {
            Release(_handle);
            _handle = IntPtr.Zero;
            throw new Exception($"Error initializing alpm library: {error}");
        }

        foreach (var ignorePkg in _config.IgnorePkg)
        {
            AddIgnorePkg(_handle, ignorePkg);
        }

        if (!string.IsNullOrEmpty(_config.GpgDir) && root)
        {
            SetGpgDir(_handle, _config.GpgDir);
        }

        if (_config.SigLevel != AlpmSigLevel.None)
        {
            AlpmSigLevel sigLevel = _config.SigLevel;
            AlpmSigLevel localSigLevel = _config.LocalFileSigLevel;

            if (SetDefaultSigLevel(_handle, sigLevel) != 0)
            {
                Console.Error.WriteLine("[ALPM_ERROR] Failed to set default signature level");
            }

            if (SetLocalFileSigLevel(_handle, localSigLevel) != 0)
            {
                Console.Error.WriteLine("[ALPM_ERROR] Failed to set local file signature level");
            }
        }

        AlpmSigLevel remoteSigLevel = _config.RemoteFileSigLevel;

        if (SetRemoteFileSigLevel(_handle, remoteSigLevel) != 0)
        {
            Console.Error.WriteLine("[ALPM_ERROR] Failed to set remote file signature level");
        }

        if (!string.IsNullOrEmpty(_config.CacheDir))
        {
            AddCacheDir(_handle, _config.CacheDir);
        }


        //Resolve 'auto' architecture to the actual system architecture
        string resolvedArch = _config.Architecture.Split(" ").FirstOrDefault() ?? "auto";
        if (resolvedArch.Equals("auto", StringComparison.OrdinalIgnoreCase))
        {
            resolvedArch = RuntimeInformation.ProcessArchitecture switch
            {
                Architecture.X64 => "x86_64",
                Architecture.Arm64 => "aarch64",
                _ => "x86_64" // Fallback to a sensible default or handle other cases
            };
        }

        if (!string.IsNullOrEmpty(resolvedArch))
        {
            Console.Error.WriteLine($"[DEBUG_LOG] Resolved Architecture: {resolvedArch}");
            AddArchitecture(_handle, resolvedArch);
            AddArchitecture(_handle, "any");
        }

        // Set up the download callback
        _fetchCallback = DownloadFile;
        if (SetFetchCallback(_handle, _fetchCallback, IntPtr.Zero) != 0)
        {
            Console.Error.WriteLine("[ALPM_ERROR] Failed to set download callback");
        }

        _eventCallback = HandleEvent;
        if (SetEventCallback(_handle, _eventCallback, IntPtr.Zero) != 0)
        {
            Console.Error.WriteLine("[ALPM_ERROR] Failed to set event callback");
        }

        _questionCallback = HandleQuestion;
        if (SetQuestionCallback(_handle, _questionCallback, IntPtr.Zero) != 0)
        {
            Console.Error.WriteLine("[ALPM_ERROR] Failed to set question callback");
        }

        _progressCallback = HandleProgress;
        if (SetProgressCallback(_handle, _progressCallback, IntPtr.Zero) != 0)
        {
            Console.Error.WriteLine("[ALPM_ERROR] Failed to set progress callback");
        }


        List<string> registeredArchitectures = [];
        foreach (var repo in _config.Repos)
        {
            var effectiveSigLevel = repo.SigLevel is AlpmSigLevel.None or AlpmSigLevel.UseDefault
                ? _config.SigLevel
                : repo.SigLevel;
            Console.Error.WriteLine($"[DEBUG] Registering {repo.Name} with SigLevel: {effectiveSigLevel}");
            IntPtr db = RegisterSyncDb(_handle, repo.Name, effectiveSigLevel);
            if (db == IntPtr.Zero)
            {
                var errno = ErrorNumber(_handle);
                Console.Error.WriteLine($"[ALPM_ERROR] Failed to register {repo.Name}: {errno}");
                continue;
            }


            foreach (var server in repo.Servers)
            {
                var archSuffixMatch = Regex.Match(server, @"\$arch([^/]+)");
                if (archSuffixMatch.Success)
                {
                    string suffix = archSuffixMatch.Groups[1].Value;
                    var archLevel = int.Parse(archSuffixMatch.Groups[1].Value.Split('v')[1]);
                    for (var i = archLevel; i >= 2; i--)
                    {
                        if (registeredArchitectures.Contains(resolvedArch + $"_v{i}")) continue;
                        AddArchitecture(_handle, resolvedArch + $"_v{i}");
                        Console.Error.WriteLine($"[DEBUG_LOG] Registering Architecture: {resolvedArch + $"_v{i}"}");
                        registeredArchitectures.Add(resolvedArch + $"_v{i}");
                    }
                    //AddArchitecture(_handle, resolvedArch + suffix);

                    //Commented out logs because it's too much noise. Uncomment if needed
                    //Console.Error.WriteLine($"[DEBUG_LOG] Found architecture suffix: {suffix}");
                    //Console.Error.WriteLine($"[DEBUG_LOG] Registering Architecture: {resolvedArch + suffix}");
                }

                // Resolve $repo and $arch variables in the server URL
                var resolvedServer = server
                    .Replace("$repo", repo.Name)
                    .Replace("$arch", resolvedArch);
                //Console.Error.WriteLine($"[DEBUG_LOG] Resolved Architecture {resolvedArch}");

                //Console.Error.WriteLine($"[DEBUG_LOG] Registering Server: {resolvedServer}");
                DbAddServer(db, resolvedServer);
            }
        }
    }

    private void HandleQuestion(IntPtr ctx, IntPtr questionPtr)
    {
        var question = Marshal.PtrToStructure<AlpmQuestionAny>(questionPtr);
        var questionType = (AlpmQuestionType)question.Type;

        // Handle SelectProvider specially - it has a different structure
        if (questionType == AlpmQuestionType.SelectProvider)
        {
            HandleSelectProviderQuestion(questionPtr);
            return;
        }

        string? packageName = null;
        string? questionText = null;
        List<string>? conflictOptions = null;

        switch (questionType)
        {
            case AlpmQuestionType.InstallIgnorePkg:
                var ignoreQuestion = Marshal.PtrToStructure<InstallIgnorePackage>(questionPtr);
                if (ignoreQuestion.Pkg != IntPtr.Zero)
                {
                    packageName = Marshal.PtrToStringUTF8(GetPkgName(ignoreQuestion.Pkg));
                }
                else
                {
                    packageName = "unknown";
                }

                questionText = $"Install ignored package: {packageName}?";
                break;
            case AlpmQuestionType.ReplacePkg:
                var replaceQuestion = Marshal.PtrToStructure<ReplacePackage>(questionPtr);
                AlpmPackage? oldPkg = null;
                AlpmPackage? newPkg = null;


                if (replaceQuestion.OldPkg != IntPtr.Zero)
                {
                    oldPkg = new AlpmPackage(replaceQuestion.OldPkg);
                }

                if (replaceQuestion.NewPkg != IntPtr.Zero)
                {
                    newPkg = new AlpmPackage(replaceQuestion.NewPkg);
                }

                questionText =
                    $"Replace {oldPkg?.Name ?? "unknown"} - {oldPkg?.Version ?? "unknown"} with {newPkg?.Name ?? "unknown"} - {newPkg?.Version ?? "unknown"}?";
                break;
            case AlpmQuestionType.ConflictPkg:
                var conflictQuestion = Marshal.PtrToStructure<ConflictPackage>(questionPtr);
                if (conflictQuestion.Conflict == IntPtr.Zero)
                {
                    questionText = "Package conflict detected (details unavailable)";
                    Console.Error.WriteLine("[ALPM_ERROR]Conflict pointer is null");
                    break;
                }


                var conflict = Marshal.PtrToStructure<Conflict>(conflictQuestion.Conflict);

                AlpmPackage? packageOne = null;
                AlpmPackage? packageTwo = null;

                // Validate pointers before creating AlpmPackage objects
                if (conflict.PackageOne != IntPtr.Zero)
                {
                    packageOne = new AlpmPackage(conflict.PackageOne);
                }

                if (conflict.PackageTwo != IntPtr.Zero)
                {
                    packageTwo = new AlpmPackage(conflict.PackageTwo);
                }

                packageName =
                    $"{packageOne?.Name ?? "unknown"} - {packageOne?.Version ?? "unknown"} conflicts with {packageTwo?.Name ?? "unknown"} - {packageTwo?.Version ?? "unknown"}";
                // Determine which package is installed and which is new
                var installedPkg = GetInstalledPackages().Any(x => x.Name == (packageOne?.Name ?? "unknown"))
                    ? packageOne
                    : packageTwo;
                var incomingPkg = (installedPkg == packageOne) ? packageTwo : packageOne;

                packageName =
                    $"{incomingPkg?.Name ?? "unknown"} - {incomingPkg?.Version ?? "unknown"} conflicts with {installedPkg?.Name ?? "unknown"} - {installedPkg?.Version ?? "unknown"}";
                questionText = $"{packageName}. Remove {installedPkg?.Name ?? "unknown"}?";
                conflictOptions = new List<string>();
                if (!string.IsNullOrEmpty(packageOne?.Name))
                {
                    conflictOptions.Add(packageOne.Name);
                }

                if (!string.IsNullOrEmpty(packageTwo?.Name))
                {
                    conflictOptions.Add(packageTwo.Name);
                }

                break;
            case AlpmQuestionType.CorruptedPkg:
                var corruptQuestion = Marshal.PtrToStructure<CorruptedPackage>(questionPtr);
                if (corruptQuestion.Filepath != IntPtr.Zero)
                {
                    packageName = Marshal.PtrToStringUTF8(corruptQuestion.Filepath);
                }

                questionText = $"Corrupted Package {packageName}. Delete?";
                break;
            case AlpmQuestionType.ImportKey:
                questionText = "Import missing GPG Key?";

                break;
            case AlpmQuestionType.RemovePkgs:
                var removeQuestion = Marshal.PtrToStructure<RemovePackages>(questionPtr);
                var packages = AlpmPackage.FromList(removeQuestion.Pkgs);
                var pkgNames = string.Join(", ", packages.Select(p => p.Name));
                questionText = $"The following packages will be removed: {pkgNames}. Proceed?";
                break;
            default:
                questionText = $"Unknown question type: {question.Type}";
                break;
        }

        var args = new AlpmQuestionEventArgs(questionType, questionText, conflictOptions);
        Question?.Invoke(this, args);

        // Block until the GUI user responds
        args.WaitForResponse();

        Console.Error.WriteLine($"[ALPM_RESPONSE] {questionText} (Answering {args.Response})");

        // Write the response back to the answer field.
        question.Answer = args.Response;
        Marshal.StructureToPtr(question, questionPtr, false);
    }

    private void HandleSelectProviderQuestion(IntPtr questionPtr)
    {
        var selectQuestion = Marshal.PtrToStructure<AlpmQuestionSelectProvider>(questionPtr);

        // Extract the dependency name
        string? dependencyName = null;
        if (selectQuestion.Depend != IntPtr.Zero)
        {
            var depStringPtr = DepComputeString(selectQuestion.Depend);
            if (depStringPtr != IntPtr.Zero)
            {
                dependencyName = Marshal.PtrToStringUTF8(depStringPtr);
                // Note: alpm_dep_compute_string returns a malloc'd string that should be freed
                // but we don't have access to free() easily, so we accept a small leak here
            }
        }

        // Extract the list of provider package names
        var providerOptions = new List<string>();
        var currentPtr = selectQuestion.Providers;
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                // node.Data is an alpm_pkg_t*, get its name
                var pkgNamePtr = GetPkgName(node.Data);
                if (pkgNamePtr != IntPtr.Zero)
                {
                    var pkgName = Marshal.PtrToStringUTF8(pkgNamePtr);
                    if (!string.IsNullOrEmpty(pkgName))
                    {
                        providerOptions.Add(pkgName);
                    }
                }
            }

            currentPtr = node.Next;
        }

        // Build the question text
        var questionText = $"Select a provider for '{dependencyName ?? "dependency"}':";

        for (int i = 0; i < providerOptions.Count; i++)
        {
            Console.Error.WriteLine($"  [{i}] {providerOptions[i]}");
        }

        var args = new AlpmQuestionEventArgs(
            AlpmQuestionType.SelectProvider,
            questionText,
            providerOptions,
            dependencyName);

        // Default to first provider (index 0) if no handler responds
        args.Response = 0;

        Question?.Invoke(this, args);

        // Block until the GUI user responds
        args.WaitForResponse();

        // Write the response back to the UseIndex field
        selectQuestion.UseIndex = args.Response;
        Marshal.StructureToPtr(selectQuestion, questionPtr, false);
    }

    private int DownloadFile(IntPtr ctx, IntPtr urlPtr, IntPtr localpathPtr, int force)
    {
        try
        {
            string? url = Marshal.PtrToStringUTF8(urlPtr);
            string? localpathDir = null;

            if (localpathPtr != IntPtr.Zero)
            {
                try
                {
                    localpathDir = Marshal.PtrToStringUTF8(localpathPtr);
                }
                catch (Exception)
                {
                    Console.Error.WriteLine("[DEBUG_LOG] localpathPtr points to invalid memory");
                }
            }

            Console.Error.WriteLine(
                $"[DEBUG_LOG] DownloadFile called with url='{url}', localpath='{localpathDir}', force={force}");

            if (string.IsNullOrEmpty(url)) return -1;

            // Extract filename from URL
            string fileName;
            if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
            {
                fileName = Path.GetFileName(uri.LocalPath);
            }
            else
            {
                fileName = Path.GetFileName(url);
            }

            if (!_isPackageDownload && _preDownloadedFiles.Remove(fileName))
            {
                Console.Error.WriteLine($"[DEBUG_LOG] File {fileName} already downloaded, skipping");
                return 0;
            }

            // Construct full destination path
            string localpath;
            if (!string.IsNullOrEmpty(localpathDir))
            {
                // localpath from fetchcb is a DIRECTORY, combine with filename
                localpath = Path.Combine(localpathDir, fileName);
            }
            else
            {
                // Fallback: determine directory based on file type
                if (url.EndsWith(".db") || url.EndsWith(".db.sig"))
                {
                    localpath = Path.Combine(_config.DbPath, "sync", fileName);
                }
                else
                {
                    localpath = Path.Combine(_config.CacheDir, fileName);
                }
            }

            Console.Error.WriteLine($"[DEBUG_LOG] Full destination path: {localpath}");

            if (string.IsNullOrEmpty(localpath)) return -1;

            var directory = Path.GetDirectoryName(localpath);
            if (directory != null) Directory.CreateDirectory(directory);

            if (_isPackageDownload && File.Exists(localpath) && force == 0)
            {
                return 0;
            }

            // URL should already be absolute from fetchcb
            return PerformDownload(url, localpath);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[DEBUG_LOG] Download failed: {ex.Message}");
            Console.Error.WriteLine($"[DEBUG_LOG] Stack trace: {ex.StackTrace}");
            return -1;
        }
    }


    private int PerformDownload(string fullUrl, string localpath)
    {
        // Use a temporary file for atomic writes - prevents corruption if download is interrupted
        string tempPath = localpath + ".part";
        Console.Error.WriteLine($"[DEBUG_LOG] Using temp file {tempPath}");
        SocketsHttpHandler? handler = null;
        HttpClient? client = null;
        try
        {
            Console.Error.WriteLine($"[Shelly][DEBUG_LOG] Downloading {fullUrl} to {localpath}");
            using var response = DownloadClient.GetAsync(fullUrl, HttpCompletionOption.ResponseContentRead)
                .GetAwaiter()
                .GetResult();


            if (!response.IsSuccessStatusCode)
            {
                Console.Error.WriteLine($"[DEBUG_LOG] Failed to download {fullUrl}: {response.StatusCode}");
                return -1;
            }

            var totalBytes = response.Content.Headers.ContentLength;
            string fileName = Path.GetFileName(localpath);

            // Write to temporary file first
            using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            using (var stream = response.Content.ReadAsStream())
            {
                Console.Error.WriteLine($"[DEBUG_LOG] Reading content stream");
                byte[] buffer = new byte[8192];
                int bytesRead;
                long totalRead = 0;
                int lastPercent = -1;

                while ((bytesRead = stream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    fs.Write(buffer, 0, bytesRead);
                    totalRead += bytesRead;

                    if (totalBytes.HasValue && totalBytes.Value > 0)
                    {
                        int percent = (int)((totalRead * 100) / totalBytes.Value);
                        if (percent != lastPercent)
                        {
                            PercentLoggerHandler("Downloading", fileName, percent, totalRead, totalBytes.Value);
                            lastPercent = percent;
                            Progress?.Invoke(this, new AlpmProgressEventArgs(
                                AlpmProgressType.PackageDownload,
                                fileName,
                                percent,
                                (ulong)totalBytes.Value,
                                (ulong)totalRead
                            ));
                        }
                    }
                }

                // Ensure 100% is sent
                if (lastPercent != 100)
                {
                    PercentLoggerHandler("Downloading", fileName, 100, totalBytes.Value, totalBytes.Value);
                    Progress?.Invoke(this, new AlpmProgressEventArgs(
                        AlpmProgressType.PackageDownload,
                        fileName,
                        100,
                        (ulong)(totalBytes ?? (long)totalRead),
                        (ulong)totalRead
                    ));
                }
            }

            //Compares files to determine if a replacement is needed
            if (!FileComparison.DoFileReplace(localpath, tempPath))
            {
                // Files are identical, clean up temp file
                try
                {
                    File.Delete(tempPath);
                }
                catch
                {
                    Console.Error.WriteLine($"[DEBUG_LOG] Failed to delete temp file: {tempPath}");
                }

                return 0;
            }

            // Atomic rename: move temp file to final destination only after successful download
            try
            {
                File.Move(tempPath, localpath, overwrite: true);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[DEBUG_LOG] Failed to move temp file: {ex.Message}");
                Console.Error.WriteLine($"[DEBUG_LOG] Source: {tempPath}, Exists: {File.Exists(tempPath)}");
                Console.Error.WriteLine($"[DEBUG_LOG] Destination: {localpath}");
                Console.Error.WriteLine(
                    $"[DEBUG_LOG] Dest dir exists: {Directory.Exists(Path.GetDirectoryName(localpath))}");
                return -1;
            }

            // If we just downloaded a .db file, also download the corresponding .db.sig file
            // This ensures database and signature files stay in sync, preventing "signature invalid" errors
            Console.Error.WriteLine($"[DEBUG_LOG] Downloading corresponding signature file: {fullUrl}.sig");
            Console.Error.WriteLine($"[DEBUG_LOG] Destination: {localpath}.sig");
            if (fullUrl.EndsWith(".db") && !fullUrl.EndsWith(".db.sig"))
            {
                var sigUrl = fullUrl + ".sig";
                var sigLocalPath = localpath + ".sig";
                Console.Error.WriteLine($"[DEBUG_LOG] Downloading corresponding signature file: {sigUrl}");
                DownloadSignatureFile(sigUrl, sigLocalPath);
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[DEBUG_LOG] Download failed for {fullUrl}: {ex.Message}");
            // Clean up temp file on failure to prevent leaving partial files
            try
            {
                File.Delete(tempPath);
            }
            catch
            {
                /* Ignore cleanup errors */
            }
        }
        finally
        {
            client?.Dispose();
            handler?.Dispose();
        }

        try
        {
            // We've fallen out of the custom downloader attempt to use curl
            if (!string.IsNullOrEmpty(_config.TransferCommand))
            {
                // Replace placeholders: %o = output file, %u = URL
                var command = _config.TransferCommand
                    .Replace("%o", localpath)
                    .Replace("%u", fullUrl);

                // Execute external command
                var process = Process.Start("/bin/sh", $"-c \"{command}\"");
                process.WaitForExit();
                return process.ExitCode == 0 ? 0 : -1;
            }

            Console.Error.WriteLine($"[DEBUG_LOG] Failed to download {fullUrl}: curl not available");
            return -1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[DEBUG_LOG] Failed to execute custom transfer command: {ex.Message}");
            return -1;
        }
    }

    /// <summary>
    /// Downloads a signature file (.sig) for a database file.
    /// This is called automatically when a .db file is downloaded to ensure
    /// the signature file stays in sync with the database file.
    /// Failures are logged but don't cause the main download to fail.
    /// </summary>
    private void DownloadSignatureFile(string sigUrl, string sigLocalPath)
    {
        string tempPath = sigLocalPath + ".part";
        try
        {
            Console.Error.WriteLine($"[Shelly][DEBUG_LOG] Downloading signature {sigUrl}");

            using var response = DownloadClient.GetAsync(sigUrl, HttpCompletionOption.ResponseContentRead)
                .GetAwaiter()
                .GetResult();

            if (!response.IsSuccessStatusCode)
            {
                // Signature file may not exist on the server (optional), just log and continue
                Console.Error.WriteLine($"[DEBUG_LOG] Signature file not available: {sigUrl} ({response.StatusCode})");
                // Delete any existing stale signature file to prevent mismatch
                try
                {
                    File.Delete(sigLocalPath);
                }
                catch
                {
                    /* ignore */
                }

                return;
            }

            // Write to temporary file first
            using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            using (var stream = response.Content.ReadAsStream())
            {
                stream.CopyTo(fs);
            }

            // Move temp file to final destination
            File.Move(tempPath, sigLocalPath, overwrite: true);
            Console.Error.WriteLine($"[DEBUG_LOG] Signature file downloaded successfully: {sigLocalPath}");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[DEBUG_LOG] Failed to download signature file {sigUrl}: {ex.Message}");
            // Clean up temp file on failure
            try
            {
                File.Delete(tempPath);
            }
            catch
            {
                /* ignore */
            }

            // Delete any existing stale signature file to prevent mismatch
            try
            {
                File.Delete(sigLocalPath);
            }
            catch
            {
                /* ignore */
            }
        }
    }

    public void Sync(bool force = false)
    {
        _isPackageDownload = false;
        if (_handle == IntPtr.Zero) Initialize();
        var syncDbsPtr = GetSyncDbs(_handle);
        if (syncDbsPtr == IntPtr.Zero)
        {
            Console.WriteLine("No sync databases found");
            return;
        }

        var databaseDownloads = new List<(string dbName, string serverUrl)>();
        var currentPtr = syncDbsPtr;
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                var dbNamePtr = DbGetName(node.Data);
                var dbName = Marshal.PtrToStringUTF8(dbNamePtr);
                if (!string.IsNullOrEmpty(dbName))
                {
                    var serverPtrs = DbGetServers(node.Data);
                    if (serverPtrs != IntPtr.Zero)
                    {
                        var serverNode = Marshal.PtrToStructure<AlpmList>(serverPtrs);
                        if (serverNode.Data == IntPtr.Zero)
                        {
                            continue;
                        }

                        var serverUrl = Marshal.PtrToStringUTF8(serverNode.Data);
                        if (!string.IsNullOrEmpty(serverUrl))
                        {
                            databaseDownloads.Add((dbName, serverUrl));
                        }
                    }
                }

                currentPtr = node.Next;
            }
        }

        var syncDirectory = Path.Combine(_config.DbPath, "sync");
        // This should always exist, but just in case
        Directory.CreateDirectory(syncDirectory);

        var downloadTasks = databaseDownloads.Select(db => Task.Run(() =>
        {
            var dbFileName = $"{db.dbName}.db";
            var url = $"{db.serverUrl.TrimEnd('/')}/{dbFileName}";
            var localPath = Path.Combine(syncDirectory, dbFileName);
            Console.Error.WriteLine($"[DEBUG_LOG] Downloading {url} to {localPath}");
            PerformDownload(url, localPath);
        }));

        Task.WhenAll(downloadTasks).Wait();
        _preDownloadedFiles = databaseDownloads.SelectMany(d => new[] { d.dbName + ".db", d.dbName + "db.sig" })
            .ToHashSet();
        var result = Update(_handle, syncDbsPtr, force);
        if (result < 0)
        {
            var error = ErrorNumber(_handle);
            Console.Error.WriteLine($"Sync failed: {GetErrorMessage(error)}");
        }
    }

    public List<AlpmPackageDto> GetInstalledPackages()
    {
        if (_handle == IntPtr.Zero) Initialize();
        var dbPtr = GetLocalDb(_handle);
        var pkgPtr = DbGetPkgCache(dbPtr);
        var packages = AlpmPackage.FromList(pkgPtr).Select(p => p.ToDto()).ToList();

        if (!_showHiddenPackages)
        {
            packages.RemoveAll(x => _config.IgnorePkg.Contains(x.Name));
        }

        return packages;
    }

    public List<AlpmPackageDto> GetForeignPackages()
    {
        if (_handle == IntPtr.Zero) Initialize();

        var localDbPtr = GetLocalDb(_handle);
        var installedPkgs = AlpmPackage.FromList(DbGetPkgCache(localDbPtr));
        var syncDbsPtr = GetSyncDbs(_handle);

        var foreignPackages = new List<AlpmPackageDto>();

        foreach (var pkg in installedPkgs)
        {
            // Check if package exists in any sync database
            bool foundInSync = false;
            var currentPtr = syncDbsPtr;

            while (currentPtr != IntPtr.Zero)
            {
                var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
                if (node.Data != IntPtr.Zero)
                {
                    var syncPkgPtr = DbGetPkg(node.Data, pkg.Name);
                    if (syncPkgPtr != IntPtr.Zero)
                    {
                        foundInSync = true;
                        break;
                    }
                }

                currentPtr = node.Next;
            }

            // If not found in any sync db, it's a foreign package
            if (!foundInSync)
            {
                foreignPackages.Add(pkg.ToDto());
            }
        }

        if (!_showHiddenPackages)
        {
            foreignPackages.RemoveAll(x => _config.IgnorePkg.Contains(x.Name));
        }

        return foreignPackages;
    }

    public List<AlpmPackageDto> GetAvailablePackages()
    {
        if (_handle == IntPtr.Zero) Initialize();
        var packages = new List<AlpmPackageDto>();
        var seen = new HashSet<string>();
        var syncDbsPtr = GetSyncDbs(_handle);

        var currentPtr = syncDbsPtr;
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                //Might need to swap these values
                if (DbGetValid(node.Data) != 0)
                {
                    var dbName = Marshal.PtrToStringUTF8(DbGetName(node.Data)) ?? "unknown";
                    Console.Error.WriteLine($"[ALPM_WARNING] Database '{dbName}' is invalid, skipping");
                    currentPtr = node.Next;
                    continue;
                }

                var dbPkgCachePtr = DbGetPkgCache(node.Data);
                foreach (var pkg in AlpmPackage.FromList(dbPkgCachePtr).Select(p => p.ToDto()))
                {
                    if (seen.Add(pkg.Name))
                    {
                        packages.Add(pkg);
                    }
                }
            }

            currentPtr = node.Next;
        }

        if (!_showHiddenPackages)
        {
            packages.RemoveAll(x => _config.IgnorePkg.Contains(x.Name));
        }

        return packages;
    }

    public List<AlpmPackageUpdateDto> GetPackagesNeedingUpdate()
    {
        if (_handle == IntPtr.Zero) Initialize();
        var updates = new List<AlpmPackageUpdateDto>();
        var syncDbsPtr = GetSyncDbs(_handle);
        var dbPtr = GetLocalDb(_handle);
        var pkgPtr = DbGetPkgCache(dbPtr);
        var installedPackages = AlpmPackage.FromList(pkgPtr);

        foreach (var installedPkg in installedPackages)
        {
            var newVersionPtr = SyncGetNewVersion(installedPkg.PackagePtr, syncDbsPtr);
            if (newVersionPtr != IntPtr.Zero)
            {
                var update = new AlpmPackageUpdate(installedPkg, new AlpmPackage(newVersionPtr));
                updates.Add(update.ToDto());
            }
        }

        if (!_showHiddenPackages)
        {
            updates.RemoveAll(p => _config.IgnorePkg.Contains(p.Name));
        }

        return updates;
    }

    private string GetErrorMessage(AlpmErrno error)
    {
        return Marshal.PtrToStringUTF8(StrError(error)) ?? $"Unknown error ({error})";
    }

    public Task<bool> InstallPackages(List<string> packageNames,
        AlpmTransFlag flags = AlpmTransFlag.None)
    {
        if (_handle == IntPtr.Zero) Initialize();

        List<IntPtr> pkgPtrs = [];
        List<(string, string)> repoPkgs = [];
        List<string> chosenPkgs = [];


        foreach (var name in packageNames)
        {
            if (name.Contains("/"))
            {
                var split = name.Split('/');
                repoPkgs.Add((split[0], split[1]));
            }
            else
            {
                chosenPkgs.Add(name);
            }
        }

        foreach (var (repoName, pkgName) in repoPkgs)
        {
            IntPtr pkgPtr = IntPtr.Zero;
            var syncDbsPtr = GetSyncDbs(_handle);
            var currentPtr = syncDbsPtr;

            while (currentPtr != IntPtr.Zero)
            {
                var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
                if (node.Data != IntPtr.Zero)
                {
                    var dbNamePtr = DbGetName(node.Data);
                    var dbName = Marshal.PtrToStringUTF8(dbNamePtr);
                    Console.Error.WriteLine($"[DEBUG_LOG] Found database: {dbName}");
                    if (dbName != null && dbName.Equals(repoName, StringComparison.OrdinalIgnoreCase))
                    {
                        pkgPtr = DbGetPkg(node.Data, pkgName);
                        break;
                    }
                }

                currentPtr = node.Next;
            }

            if (pkgPtr == IntPtr.Zero)
            {
                ErrorEvent?.Invoke(this,
                    new AlpmErrorEventArgs($"Package '{pkgName}' not found in repository '{repoName}'."));
                return Task.FromResult(false);
            }

            pkgPtrs.Add(pkgPtr);
        }

        foreach (var packageName in chosenPkgs)
        {
            // Find the package in sync databases
            IntPtr pkgPtr = IntPtr.Zero;
            var syncDbsPtr = GetSyncDbs(_handle);
            var currentPtr = syncDbsPtr;
            List<IntPtr> groupPkgs = null;
            while (currentPtr != IntPtr.Zero)
            {
                var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
                if (node.Data != IntPtr.Zero)
                {
                    pkgPtr = DbGetPkg(node.Data, packageName);
                    if (pkgPtr != IntPtr.Zero) break;

                    //Group search next
                    var groupCachePtr = DbGetGroupCache(node.Data);
                    var groupNode = groupCachePtr;
                    while (groupNode != IntPtr.Zero)
                    {
                        var groupNodeData = Marshal.PtrToStructure<AlpmList>(groupNode);
                        if (groupNodeData.Data != IntPtr.Zero)
                        {
                            var group = Marshal.PtrToStructure<AlpmPackageGroup>(groupNodeData.Data);
                            var groupName = Marshal.PtrToStringUTF8(group.Name);
                            try
                            {
                                if (groupName!.Equals(packageName, StringComparison.OrdinalIgnoreCase))
                                {
                                    groupPkgs = new List<IntPtr>();
                                    var pkgNode = group.Packages;
                                    while (pkgNode != IntPtr.Zero)
                                    {
                                        var pkg = Marshal.PtrToStructure<AlpmList>(pkgNode);
                                        if (pkg.Data != IntPtr.Zero)
                                        {
                                            groupPkgs.Add(pkg.Data);
                                        }

                                        pkgNode = pkg.Next;
                                    }

                                    break;
                                }
                            }
                            catch (Exception ex)
                            {
                                Console.Error.WriteLine($"[DEBUG_LOG] Exception: {ex.Message}");
                            }
                        }

                        groupNode = groupNodeData.Next;
                    }

                    if (groupPkgs != null)
                    {
                        break;
                    }
                }

                currentPtr = node.Next;
            }

            // Failed to find direct pkg name or group pkg so looking for a satisfier.
            if (pkgPtr == IntPtr.Zero && groupPkgs == null)
            {
                currentPtr = syncDbsPtr;
                while (currentPtr != IntPtr.Zero)
                {
                    var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
                    if (node.Data != IntPtr.Zero)
                    {
                        var pkgCache = DbGetPkgCache(node.Data);
                        pkgPtr = PkgFindSatisfier(pkgCache, packageName);
                        if (pkgPtr != IntPtr.Zero)
                        {
                            break;
                        }
                    }

                    currentPtr = node.Next;
                }

                if (pkgPtr == IntPtr.Zero)
                {
                    ErrorEvent?.Invoke(this,
                        new AlpmErrorEventArgs($"Package '{packageName}' not found in any sync database."));
                    return Task.FromResult(false);
                }
            }

            if (pkgPtr != IntPtr.Zero)
            {
                pkgPtrs.Add(pkgPtr);
            }

            if (groupPkgs != null)
            {
                pkgPtrs.AddRange(groupPkgs);
            }
        }

        if (pkgPtrs.Count == 0) return Task.FromResult(false);

        // If we are doing a DbOnly install, we should also skip dependency checks, 
        // extraction, and signature/checksum validation to avoid requirement for the physical package file.
        if (flags.HasFlag(AlpmTransFlag.DbOnly))
        {
            flags |= AlpmTransFlag.NoDeps | AlpmTransFlag.NoExtract | AlpmTransFlag.NoPkgSig |
                     AlpmTransFlag.NoCheckSpace;
        }

        List<string> optDependList = [];
        foreach (var pkgPtr in pkgPtrs)
        {
            var pkg = new AlpmPackage(pkgPtr);
            if (pkg != null)
            {
                optDependList.AddRange(pkg.OptDepends);
            }
        }

        List<string> optDepNames = [];
        if (optDependList.Count > 0)
        {
            var args = new AlpmQuestionEventArgs(AlpmQuestionType.SelectOptionalDeps,
                "Select optional dependencies",
                optDependList);
            Question?.Invoke(this, args);
            args.WaitForResponse();
            optDepNames = optDependList
                .Where((dep, index) => (args.Response & (1 << index)) != 0)
                .Select(dep => dep.Split(':', 2)[0].Trim())
                .Where(name => !string.IsNullOrEmpty(name))
                .ToList();
            var result = PackageListBuilder.Build(_handle, optDepNames);
            pkgPtrs.AddRange(result);
        }

        Console.Error.WriteLine($"[DEBUG] TransInit: handle={_handle}, dbPath={_config.DbPath}");
        Console.Error.WriteLine($"[DEBUG] db.lck exists: {File.Exists(Path.Combine(_config.DbPath, "db.lck"))}");

        var lockfilePath = AlpmReference.GetLockFile(_handle); // Need to bind alpm_option_get_lockfile
        Console.Error.WriteLine($"[DEBUG] libalpm lockfile: {Marshal.PtrToStringAnsi(lockfilePath)}");
        Console.Error.WriteLine($"[DEBUG] C# check path: {Path.Combine(_config.DbPath, "db.lck")}");
        Console.Error.WriteLine($"[DEBUG] dbpath dir exists: {Directory.Exists(_config.DbPath)}");
        // Initialize transaction
        if (TransInit(_handle, flags) != 0)
        {
            // var posixErrno = Marshal.ReadInt32(ErrnoLocation());
            // Console.Error.WriteLine($"[DEBUG] POSIX errno: {posixErrno}");
            var err = ErrorNumber(_handle);
            // Console.Error.WriteLine($"[DEBUG] TransInit failed: errno={err} ({(int)err}), message={GetErrorMessage(err)}");
            ErrorEvent?.Invoke(this,
                new AlpmErrorEventArgs(
                    $"Failed to initialize transaction: with Error Number: {err} and message: {GetErrorMessage(err)}"));


            return Task.FromResult(false);
        }

        try
        {
            foreach (var pkgPtr in pkgPtrs)
            {
                if (AddPkg(_handle, pkgPtr) != 0)
                {
                    var err = ErrorNumber(_handle);
                    // If it's just a duplicate target, skip it silently
                    if (err == AlpmErrno.TransDupTarget)
                    {
                        Console.Error.WriteLine($"[ALPM_WARN] Skipping duplicate package in transaction.");
                        continue;
                    }

                    ErrorEvent?.Invoke(this,
                        new AlpmErrorEventArgs($"Failed to add package to transaction: {GetErrorMessage(err)}"));
                    return Task.FromResult(false); // or just return Task.CompletedTask if keeping Task
                }
            }

            // Prepare transaction
            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return Task.FromResult(false);
            }

            // Commit transaction
            if (TransCommit(_handle, out dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return Task.FromResult(false);
            }

            var localDb = AlpmReference.GetLocalDb(_handle);
            foreach (var name in optDepNames)
            {
                Console.Error.WriteLine($"[DEBUG] Installing optional dependency: {name}");
                var localPkg = AlpmReference.DbGetPkg(localDb, name);
                if (localPkg == IntPtr.Zero) continue; // not actually installed (skipped / failed)
                if (PkgSetReason(localPkg, AlpmPkgReason.Depend) != 0)
                {
                    var err = ErrorNumber(_handle);
                    Console.Error.WriteLine(
                        $"[ALPM_WARN] Failed to set reason for {name}: {GetErrorMessage(err)}");
                    // don't abort — install already succeeded
                }
                Console.Error.WriteLine($"[DEBUG] Installed optional dependency: {name}");
            }
        }
        finally
        {
            // Release transaction
            TransRelease(_handle);
        }

        return Task.FromResult(true);
    }

    public Task<bool> RemovePackages(List<string> packageNames,
        AlpmTransFlag flags = AlpmTransFlag.None, bool removeOptionalDeps = false)
    {
        var heldPackagesBeingRemove = packageNames.Intersect(_config.HoldPkg).ToList();
        if (heldPackagesBeingRemove.Count > 0)
        {
            var args = new AlpmQuestionEventArgs(
                AlpmQuestionType.RemovePkgs,
                $"Are you sure you want to remove the following package held pkg: {string.Join(", ", heldPackagesBeingRemove)}",
                null,
                null);

            args.Response = 0;

            Question?.Invoke(this, args);

            // Block until the GUI user responds
            args.WaitForResponse();

            if (args.Response == 0)
            {
                ErrorEvent?.Invoke(this, new AlpmErrorEventArgs("Held Package removal cancelled."));
                return Task.FromResult(false);
            }
        }

        if (_handle == IntPtr.Zero) Initialize();

        List<IntPtr> pkgPtrs = new List<IntPtr>();
        var localDbPtr = GetLocalDb(_handle);
        foreach (var packageName in packageNames)
        {
            IntPtr pkgPtr = IntPtr.Zero;
            List<IntPtr> groupPkgs = null;

            // 1. Try exact package name in local db
            pkgPtr = DbGetPkg(localDbPtr, packageName);

            // 2. If not found, try as a group in local db
            if (pkgPtr == IntPtr.Zero)
            {
                var groupCachePtr = DbGetGroupCache(localDbPtr);
                var groupNode = groupCachePtr;
                while (groupNode != IntPtr.Zero)
                {
                    var groupNodeData = Marshal.PtrToStructure<AlpmList>(groupNode);
                    if (groupNodeData.Data != IntPtr.Zero)
                    {
                        var group = Marshal.PtrToStructure<AlpmPackageGroup>(groupNodeData.Data);
                        var groupName = Marshal.PtrToStringUTF8(group.Name);
                        try
                        {
                            if (groupName!.Equals(packageName, StringComparison.OrdinalIgnoreCase))
                            {
                                groupPkgs = new List<IntPtr>();
                                var pkgNode = group.Packages;
                                while (pkgNode != IntPtr.Zero)
                                {
                                    var pkg = Marshal.PtrToStructure<AlpmList>(pkgNode);
                                    if (pkg.Data != IntPtr.Zero)
                                    {
                                        groupPkgs.Add(pkg.Data);
                                    }

                                    pkgNode = pkg.Next;
                                }

                                break;
                            }
                        }
                        catch (Exception ex)
                        {
                            Console.Error.WriteLine($"[DEBUG_LOG] Exception: {ex.Message}");
                        }
                    }

                    groupNode = groupNodeData.Next;
                }
            }

            // 3. If still not found, try find_satisfier on local db
            if (pkgPtr == IntPtr.Zero && groupPkgs == null)
            {
                var pkgCache = DbGetPkgCache(localDbPtr);
                pkgPtr = PkgFindSatisfier(pkgCache, packageName);
            }

            if (pkgPtr == IntPtr.Zero && groupPkgs == null)
            {
                ErrorEvent?.Invoke(this,
                    new AlpmErrorEventArgs($"Package '{packageName}' not found in local database."));
                return Task.FromResult(false);
            }

            if (pkgPtr != IntPtr.Zero) pkgPtrs.Add(pkgPtr);
            if (groupPkgs != null) pkgPtrs.AddRange(groupPkgs);
        }

        if (pkgPtrs.Count == 0) return Task.FromResult(true);

        var optDepCandidates = new HashSet<string>();
        var toAlsoRemove = new List<IntPtr>();
        if (removeOptionalDeps)
        {
            foreach (var name in from pkgPtr in pkgPtrs
                     select new AlpmPackage(pkgPtr)
                     into pkg
                     from raw in pkg.OptDepends
                     select raw.Split(':', 2)[0].Trim()
                     into name
                     where !string.IsNullOrEmpty(name)
                     select name)
            {
                Console.Error.WriteLine($"[DEBUG] Removing optional dependency: {name}");
                optDepCandidates.Add(name);
            }

            var localDb = GetLocalDb(_handle);
            var removedSet = new HashSet<string>(packageNames, StringComparer.Ordinal);

            foreach (var name in optDepCandidates)
            {
                var lp = DbGetPkg(localDb, name);
                if (lp == IntPtr.Zero) { Console.Error.WriteLine($"[DEBUG] {name}: not installed"); continue; }
                var reason = GetPkgReason(lp);
                if (reason != AlpmPkgReason.Depend) { Console.Error.WriteLine($"[DEBUG] {name}: reason={reason}, skip"); continue; }
                if (PackageChecker.IsStillNeededByOther(lp, removedSet))
                {
                    Console.Error.WriteLine($"[DEBUG] {name}: still required/optional-for another package, skip");
                    continue;
                }
                Console.Error.WriteLine($"[DEBUG] {name}: queued for removal");
                toAlsoRemove.Add(lp);
            }
        }

        // If we are doing a DbOnly install, we should also skip dependency checks, 
        // extraction, and signature/checksum validation to avoid requirement for the physical package file.
        if (flags.HasFlag(AlpmTransFlag.DbOnly))
        {
            flags |= AlpmTransFlag.NoDeps | AlpmTransFlag.NoExtract | AlpmTransFlag.NoPkgSig |
                     AlpmTransFlag.NoCheckSpace;
        }

        // Initialize transaction
        if (TransInit(_handle, flags) != 0)
        {
            var err = ErrorNumber(_handle);
            ErrorEvent?.Invoke(this,
                new AlpmErrorEventArgs($"Failed to initialize transaction: {GetErrorMessage(err)}"));
            return Task.FromResult(false);
        }

        try
        {
            foreach (var pkgPtr in pkgPtrs)
            {
                if (RemovePkg(_handle, pkgPtr) != 0)
                {
                    var err = ErrorNumber(_handle);
                    ErrorEvent?.Invoke(this,
                        new AlpmErrorEventArgs(
                            $"Failed to add package removal to transaction: {GetErrorMessage(err)}"));
                    return Task.FromResult(false); // or just return Task.CompletedTask if keeping Task
                }
            }

            foreach (var pkgPtr in toAlsoRemove)
            {
                if (RemovePkg(_handle, pkgPtr) != 0)
                {
                    {
                        var err = ErrorNumber(_handle);
                        ErrorEvent?.Invoke(this,
                            new AlpmErrorEventArgs(
                                $"Failed to add package removal to transaction: {GetErrorMessage(err)}"));
                        return Task.FromResult(false); // or just return Task.CompletedTask if keeping Task
                    }
                }
            }

            // Prepare transaction
            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return Task.FromResult(false); // or just return Task.CompletedTask if keeping Task
            }

            // Commit transaction
            if (TransCommit(_handle, out dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return Task.FromResult(false);
            }
        }
        finally
        {
            // Release transaction
            TransRelease(_handle);
        }

        return Task.FromResult(true);
    }

    public async Task<bool> SyncSystemUpdate(AlpmTransFlag flags = AlpmTransFlag.None)
    {
        if (_handle == IntPtr.Zero) Initialize();
        var syncDbsPtr = GetSyncDbs(_handle);
        Update(_handle, syncDbsPtr, true);
        try
        {
            _isPackageDownload = true;
            var updates = GetPackagesNeedingUpdate();
            var updateUrl = updates.Select(BuildPackageUrl).ToList();
            var downloadTasks = updateUrl.Select(url => Task.Run(() =>
            {
                var fileName = url.Split('/').Last();
                var localPath = Path.Combine(_config.CacheDir, fileName);
                if (!File.Exists(localPath))
                {
                    Progress?.Invoke(this, new AlpmProgressEventArgs(
                        AlpmProgressType.PackageDownload,
                        fileName,
                        0, 0, 0
                    ));
                    PerformDownload(url, localPath);
                }
                else
                {
                    Progress?.Invoke(this, new AlpmProgressEventArgs(
                        AlpmProgressType.PackageDownload,
                        fileName,
                        100, 0, 0
                    ));
                }
            }));
            await Task.WhenAll(downloadTasks);
            if (TransInit(_handle, flags) != 0)
            {
                var err = ErrorNumber(_handle);
                ErrorEvent?.Invoke(this,
                    new AlpmErrorEventArgs($"Failed to initialize transaction: {GetErrorMessage(err)}"));
                return false;
            }

            if (SyncSysupgrade(_handle, false) != 0)
            {
                ErrorEvent?.Invoke(this, new AlpmErrorEventArgs(GetErrorMessage(ErrorNumber(_handle))));
                return false;
            }

            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return false;
            }

            CheckTransactionReplaces(_handle);

            if (TransCommit(_handle, out dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return false;
            }
        }
        catch (Exception ex)
        {
            ErrorEvent?.Invoke(this, new AlpmErrorEventArgs(ex.Message));
            return false;
        }
        finally
        {
            _ = TransRelease(_handle);
        }

        return true;
    }

    private void CheckTransactionReplaces(IntPtr handle)
    {
        var addList = TransGetAdd(handle);
        if (addList == IntPtr.Zero) return;

        var packages = AlpmPackage.FromList(addList);
        foreach (var pkg in packages)
        {
            var replaces = pkg.Replaces;
            if (replaces.Count > 0)
            {
                Replaces?.Invoke(this, new AlpmReplacesEventArgs(pkg.Name, pkg.Repository, replaces));
            }
        }
    }

    public void RaiseQuestion(AlpmQuestionEventArgs args)
    {
        Question?.Invoke(this, args);
    }

    /// <summary>
    /// Marks an installed package in the local DB with the Depend install reason. Used by
    /// the AUR layer to flag user-selected optional dependencies after they are installed
    /// in a separate transaction. Returns true when the reason was successfully set.
    /// </summary>
    public bool MarkPackageAsDepend(string packageName)
    {
        if (_handle == IntPtr.Zero) Initialize();
        var localDb = AlpmReference.GetLocalDb(_handle);
        if (localDb == IntPtr.Zero) return false;
        var localPkg = AlpmReference.DbGetPkg(localDb, packageName);
        if (localPkg == IntPtr.Zero) return false;
        if (PkgSetReason(localPkg, AlpmPkgReason.Depend) != 0)
        {
            var err = ErrorNumber(_handle);
            Console.Error.WriteLine($"[ALPM_WARN] Failed to set reason for {packageName}: {GetErrorMessage(err)}");
            return false;
        }
        return true;
    }

    public Task<bool> InstallLocalPackage(string path, AlpmTransFlag flags = AlpmTransFlag.None)
    {
        if (_handle == IntPtr.Zero) Initialize();

        // 1. Load package from file
        var result = PkgLoad(_handle, path, true, AlpmSigLevel.PackageOptional | AlpmSigLevel.DatabaseOptional,
            out IntPtr pkgPtr);
        if (result != 0 || pkgPtr == IntPtr.Zero)
        {
            ErrorEvent?.Invoke(this, new AlpmErrorEventArgs(
                $"Failed to load package from '{path}': {GetErrorMessage(ErrorNumber(_handle))}"));
            return Task.FromResult(false);
        }

        // 2. Initialize transaction
        if (TransInit(_handle, flags) != 0)
        {
            _ = PkgFree(pkgPtr);
            var err = ErrorNumber(_handle);
            ErrorEvent?.Invoke(this,
                new AlpmErrorEventArgs($"Failed to initialize transaction: {GetErrorMessage(err)}"));
            return Task.FromResult(false);
        }

        try
        {
            // 3. Add package to transaction
            if (AddPkg(_handle, pkgPtr) != 0)
            {
                _ = PkgFree(pkgPtr);
                var err = ErrorNumber(_handle);
                ErrorEvent?.Invoke(this,
                    new AlpmErrorEventArgs($"Failed to add package to transaction: {GetErrorMessage(err)}"));
                return Task.FromResult(false);
            }

            // 4. Prepare transaction
            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return Task.FromResult(false);
            }

            // 5. Commit transaction
            if (TransCommit(_handle, out dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return Task.FromResult(false);
            }
        }
        catch (Exception ex)
        {
            _ = PkgFree(pkgPtr);
            ErrorEvent?.Invoke(this,
                new AlpmErrorEventArgs($"Encountered an error during local package installation: {ex.Message}"));
            return Task.FromResult(false);
        }
        finally
        {
            TransRelease(_handle);
            Refresh();
        }

        return Task.FromResult(true);
    }

    public string GetPackageNameFromProvides(string provides, AlpmTransFlag flags = AlpmTransFlag.None)
    {
        if (_handle == IntPtr.Zero) Initialize();
        var syncDbsPtr = GetSyncDbs(_handle);
        var currentPtr = syncDbsPtr;
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                //Grab pkg cache
                var pkgCache = DbGetPkgCache(node.Data);
                var pkgPtr = PkgFindSatisfier(pkgCache, provides);
                if (pkgPtr != IntPtr.Zero)
                {
                    return Marshal.PtrToStringUTF8(GetPkgName(pkgPtr))!;
                }
            }

            currentPtr = node.Next;
        }

        return string.Empty;
    }

    public bool IsDependencySatisfiedByInstalled(string dependency)
    {
        if (_handle == IntPtr.Zero) Initialize();
        var localDbPtr = GetLocalDb(_handle);
        var pkgCache = DbGetPkgCache(localDbPtr);
        var pkgPtr = PkgFindSatisfier(pkgCache, dependency);
        return pkgPtr != IntPtr.Zero;
    }

    public bool IsDepdencySatisfiedBySyncDbs(string dependency)
    {
        return FindSatisfierInSyncDbs(dependency) != null;
    }

    public string? FindSatisfierInSyncDbs(string dependency)
    {
        if (_handle == IntPtr.Zero) Initialize();
        var syncDbsPtr = GetSyncDbs(_handle);
        var currentPtr = syncDbsPtr;

        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                var dbPkgCache = DbGetPkgCache(node.Data);
                var pkgPtr = PkgFindSatisfier(dbPkgCache, dependency);
                if (pkgPtr != IntPtr.Zero)
                    return Marshal.PtrToStringUTF8(GetPkgName(pkgPtr));
            }

            currentPtr = node.Next;
        }

        return null;
    }

    public Task<bool> InstallDependenciesOnly(string packageName,
        bool includeMakeDeps = false,
        AlpmTransFlag flags = AlpmTransFlag.None)
    {
        if (_handle == IntPtr.Zero) Initialize();
        var syncDbsPtr = GetSyncDbs(_handle);
        var localDbPtr = GetLocalDb(_handle);
        var currentPtr = syncDbsPtr;
        IntPtr pkgPtr = IntPtr.Zero;
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                pkgPtr = AlpmReference.DbGetPkg(node.Data, packageName);
                if (pkgPtr != IntPtr.Zero) break;
            }

            currentPtr = node.Next;
        }

        if (pkgPtr == IntPtr.Zero)
        {
            ErrorEvent?.Invoke(this,
                new AlpmErrorEventArgs($"Package '{packageName}' not found in any sync database."));
            return Task.FromResult(false);
        }

        var dependencies = GetDependencyList(GetPkgDepends(pkgPtr));


        if (includeMakeDeps)
        {
            var makeDepends = GetDependencyList(GetPkgMakeDepends(pkgPtr));
            dependencies = dependencies.Concat(makeDepends).ToList();
        }


        var installedPackages = GetInstalledPackages().ToDictionary(x => x.Name, x => x.Version);
        var dependencyToInstall = dependencies.Where(x => !installedPackages.ContainsKey(x)).ToList();

        if (dependencyToInstall.Count == 0) return Task.FromResult(true);

        return InstallPackages(dependencyToInstall, flags);
    }

    public void Refresh()
    {
        if (_handle != IntPtr.Zero)
        {
            Release(_handle);
            _handle = IntPtr.Zero;
        }

        Initialize(true);
    }

    public Task<bool> UpdatePackages(List<string> packageNames,
        AlpmTransFlag flags = AlpmTransFlag.None)
    {
        List<IntPtr> pkgPtrs = [];
        List<IntPtr> failedPkgPtrs = [];
        if (_handle == IntPtr.Zero) Initialize();
        var syncDbsPtr = GetSyncDbs(_handle);
        var localDbPtr = GetLocalDb(_handle);
        Update(_handle, syncDbsPtr, true);
        try
        {
            foreach (var packageName in packageNames)
            {
                IntPtr installedPkgPtr = DbGetPkg(localDbPtr, packageName);
                if (installedPkgPtr == IntPtr.Zero)
                {
                    //Don't attempt to update something that doesn't exist.
                    continue;
                }

                // Find the package in sync databases
                IntPtr pkgPtr = IntPtr.Zero;
                pkgPtr = SyncGetNewVersion(installedPkgPtr, syncDbsPtr);
                // var currentPtr = syncDbsPtr;
                // while (currentPtr != IntPtr.Zero)
                // {
                //     var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
                //     if (node.Data != IntPtr.Zero)
                //     {
                //         pkgPtr = DbGetPkg(node.Data, packageName);
                //         if (pkgPtr != IntPtr.Zero) break;
                //     }
                //
                //     currentPtr = node.Next;
                // }

                if (pkgPtr == IntPtr.Zero)
                {
                    continue;
                }

                pkgPtrs.Add(pkgPtr);
            }

            if (TransInit(_handle, flags) != 0)
            {
                ErrorEvent?.Invoke(this,
                    new AlpmErrorEventArgs(
                        $"Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}"));
                return Task.FromResult(false);
            }

            failedPkgPtrs.AddRange(pkgPtrs.Where(pkgPtr => AddPkg(_handle, pkgPtr) != 0));

            // Check if there are any packages to add or remove before preparing/committing
            // Not sure why I'm running this check but this method absolutely shouldn't be used so i'm using the bare
            // minimum of work here.
            if (TransGetAdd(_handle) == IntPtr.Zero && TransGetRemove(_handle) == IntPtr.Zero)
            {
                return Task.FromResult(true);
                // Nothing to do, considered successful
            }

            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return Task.FromResult(false);
            }

            if (TransCommit(_handle, out dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return Task.FromResult(false);
            }
        }
        finally
        {
            _ = TransRelease(_handle);
        }

        return Task.FromResult(true);
    }

    public bool UpdateSinglePackage(string packageName,
        AlpmTransFlag flags = AlpmTransFlag.NoScriptlet | AlpmTransFlag.NoHooks)
    {
        if (_handle == IntPtr.Zero) Initialize();
        var syncDbsPtr = GetSyncDbs(_handle);
        Update(_handle, syncDbsPtr, true);
        try
        {
            if (TransInit(_handle, flags) != 0)
            {
                var err = ErrorNumber(_handle);
                ErrorEvent?.Invoke(this,
                    new AlpmErrorEventArgs($"Failed to initialize transaction: {GetErrorMessage(err)}"));
                return false;
            }

            var pkgPtr = DbGetPkg(GetLocalDb(_handle), packageName);
            if (AddPkg(_handle, pkgPtr) != 0)
            {
                ErrorEvent?.Invoke(this,
                    new AlpmErrorEventArgs(
                        $"Failed to add package '{packageName}' to transaction: {GetErrorMessage(ErrorNumber(_handle))}"));
                return false;
            }

            // Check if there are any packages to add or remove before preparing/committing
            // Not sure why I'm running this check but this method absolutely shouldn't be used so i'm using the bare
            // minimum of work here.
            if (TransGetAdd(_handle) == IntPtr.Zero && TransGetRemove(_handle) == IntPtr.Zero)
            {
                return true; // Nothing to do, considered successful
            }

            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return false;
            }

            if (TransCommit(_handle, out dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return false;
            }
        }
        finally
        {
            _ = TransRelease(_handle);
        }

        return true;
    }

    public bool UpdateAll(AlpmTransFlag flags = AlpmTransFlag.NoScriptlet | AlpmTransFlag.NoHooks)
    {
        if (_handle == IntPtr.Zero) Initialize();
        var syncDbsPtr = GetSyncDbs(_handle);
        Update(_handle, syncDbsPtr, true);
        try
        {
            if (TransInit(_handle, flags) != 0)
            {
                var err = ErrorNumber(_handle);
                ErrorEvent?.Invoke(this,
                    new AlpmErrorEventArgs($"Failed to initialize transaction: {GetErrorMessage(err)}"));
                return false;
            }

            if (SyncSysupgrade(_handle, false) != 0)
            {
                ErrorEvent?.Invoke(this, new AlpmErrorEventArgs(GetErrorMessage(ErrorNumber(_handle))));
                return false;
            }

            // Check if there are any packages to add or remove before preparing/committing
            if (TransGetAdd(_handle) == IntPtr.Zero && TransGetRemove(_handle) == IntPtr.Zero)
            {
                return true; // Nothing to do, considered successful
            }

            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return false;
            }

            if (TransCommit(_handle, out dataPtr) != 0)
            {
                HandleErrorMessage(dataPtr, ErrorNumber(_handle));
                return false;
            }
        }
        finally
        {
            _ = TransRelease(_handle);
        }

        return true;
    }

    public void Dispose()
    {
        if (_handle == IntPtr.Zero) return;
        UnregisterAllSyncDbs(_handle);
        SetFetchCallback(_handle, null, IntPtr.Zero);
        SetEventCallback(_handle, null, IntPtr.Zero);
        SetQuestionCallback(_handle, null, IntPtr.Zero);
        SetProgressCallback(_handle, null, IntPtr.Zero);
        _fetchCallback = null!;
        _eventCallback = null!;
        _questionCallback = null!;
        _progressCallback = null;
        Release(_handle);
        _handle = IntPtr.Zero;
    }

    private void HandleProgress(IntPtr ctx, AlpmProgressType progress, IntPtr pkgNamePtr, int percent, ulong howmany,
        ulong current)
    {
        try
        {
            string? pkgName = pkgNamePtr != IntPtr.Zero ? Marshal.PtrToStringUTF8(pkgNamePtr) : null;
            PercentLoggerHandler(progress.ToString(), pkgName, percent);

            Progress?.Invoke(this, new AlpmProgressEventArgs(
                progress,
                pkgName,
                percent,
                howmany,
                current
            ));
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ALPM_ERROR] Error in progress callback: {ex.Message}");
        }
    }

    private void PercentLoggerHandler(string type, string pkgName, int percent, long bytes = 0, long totalBytes = 0)
    {
        if (bytes > 0 && totalBytes > 0)
        {
            Console.Error.WriteLine(
                $"[DEBUG_LOG] ALPM Progress: {type}, Pkg: {pkgName}, %: {percent}, bytesRead: {bytes}, totalBytes: {totalBytes}");
        }
        else
        {
            Console.Error.WriteLine($"[DEBUG_LOG] ALPM Progress: {type}, Pkg: {pkgName}, %: {percent}");
        }
    }

    private void HandleEvent(IntPtr ctx, IntPtr eventPtr)
    {
        // Early return for null pointer
        if (eventPtr == IntPtr.Zero) return;

        // Additional safety check - if handle is disposed, don't process events
        if (_handle == IntPtr.Zero) return;

        int typeValue;
        try
        {
            // Read the type field directly using ReadInt32
            typeValue = Marshal.ReadInt32(eventPtr);
        }
        catch (AccessViolationException)
        {
            // Memory access violation - pointer is invalid, silently ignore
            return;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ALPM_ERROR] Error reading event type: {ex.Message}");
            return;
        }

        // Validate the type value is within expected range (1-37 for ALPM events)
        if (typeValue < 1 || typeValue > 37)
        {
            // Invalid event type - likely corrupted memory or wrong pointer
            return;
        }

        try
        {
            var type = (AlpmEventType)typeValue;

            switch (type)
            {
                case AlpmEventType.CheckDepsStart:
                    Console.Error.WriteLine("[ALPM] Checking dependencies...");
                    break;
                case AlpmEventType.CheckDepsDone:
                    Console.Error.WriteLine("[ALPM] Dependency check finished.");
                    break;
                case AlpmEventType.FileConflictsStart:
                    Console.Error.WriteLine("[ALPM] Checking for file conflicts...");
                    break;
                case AlpmEventType.FileConflictsDone:
                    Console.Error.WriteLine("[ALPM] File conflict check finished.");
                    break;
                case AlpmEventType.ResolveDepsStart:
                    Console.Error.WriteLine("[ALPM] Resolving dependencies...");
                    break;
                case AlpmEventType.ResolveDepsDone:
                    Console.Error.WriteLine("[ALPM] Dependency resolution finished.");
                    break;
                case AlpmEventType.InterConflictsStart:
                    Console.Error.WriteLine("[ALPM] Checking for conflicting packages...");
                    break;
                case AlpmEventType.InterConflictsDone:
                    Console.Error.WriteLine("[ALPM] Conflict checking finished.");
                    break;
                case AlpmEventType.TransactionStart:
                    Console.Error.WriteLine("[ALPM] Starting transaction...");
                    PackageOperation?.Invoke(this, new AlpmPackageOperationEventArgs(type, null));
                    break;
                case AlpmEventType.TransactionDone:
                    Console.Error.WriteLine("[ALPM] Transaction successfully finished.");
                    PackageOperation?.Invoke(this, new AlpmPackageOperationEventArgs(type, null));
                    break;
                case AlpmEventType.IntegrityStart:
                    Console.Error.WriteLine("[ALPM] Checking package integrity...");
                    break;
                case AlpmEventType.IntegrityDone:
                    Console.Error.WriteLine("[ALPM] Integrity check finished.");
                    break;
                case AlpmEventType.LoadStart:
                    Console.Error.WriteLine("[ALPM] Loading packages...");
                    break;
                case AlpmEventType.LoadDone:
                    Console.Error.WriteLine("[ALPM] Packages loaded.");
                    break;
                case AlpmEventType.DiskspaceStart:
                    Console.Error.WriteLine("[ALPM] Checking available disk space...");
                    break;
                case AlpmEventType.DiskspaceDone:
                    Console.Error.WriteLine("[ALPM] Disk space check finished.");
                    break;

                case AlpmEventType.PackageOperationStart:
                {
                    Console.Error.WriteLine("[ALPM] Starting package operation...");
                    break;
                }

                case AlpmEventType.PackageOperationDone:
                {
                    Console.Error.WriteLine("[ALPM] Package operation finished.");
                    break;
                }

                case AlpmEventType.ScriptletInfo:
                {
                    var scriptletEvent = Marshal.PtrToStructure<AlpmEventScriptletInfo>(eventPtr);
                    string? line = scriptletEvent.Line != IntPtr.Zero
                        ? Marshal.PtrToStringUTF8(scriptletEvent.Line)
                        : null;

                    if (!string.IsNullOrEmpty(line))
                    {
                        Console.Error.WriteLine($"[ALPM_SCRIPTLET]{line}");
                        ScriptletInfo?.Invoke(this, new AlpmScriptletEventArgs(line));
                    }

                    break;
                }

                case AlpmEventType.HookStart:
                    Console.Error.WriteLine("[ALPM] Running hooks...");
                    break;
                case AlpmEventType.HookDone:
                    Console.Error.WriteLine("[ALPM] Hooks finished.");
                    break;

                case AlpmEventType.HookRunStart:
                {
                    var hookEvent = Marshal.PtrToStructure<AlpmEventHookRun>(eventPtr);
                    string? name = hookEvent.Name != IntPtr.Zero
                        ? Marshal.PtrToStringUTF8(hookEvent.Name)
                        : null;
                    string? desc = hookEvent.Desc != IntPtr.Zero
                        ? Marshal.PtrToStringUTF8(hookEvent.Desc)
                        : null;
                    var position = (ulong)hookEvent.Position;
                    var total = (ulong)hookEvent.Total;

                    var hookLine = !string.IsNullOrEmpty(desc)
                        ? $"({position}/{total}) {desc}"
                        : $"({position}/{total}) {name ?? "Running hook..."}";

                    HookRun?.Invoke(this, new AlpmHookEventArgs(hookLine, position, total));
                    break;
                }
                case AlpmEventType.HookRunDone:
                    Console.Error.WriteLine("[ALPM] Hook finished.");
                    break;

                // Database retrieval events (for sync operations)
                case AlpmEventType.DbRetrieveStart:
                    Console.Error.WriteLine("[ALPM] Retrieving database...");
                    break;
                case AlpmEventType.DbRetrieveDone:
                    Console.Error.WriteLine("[ALPM] Database retrieved.");
                    break;
                case AlpmEventType.DbRetrieveFailed:
                    Console.Error.WriteLine("[ALPM] Database retrieval failed.");
                    break;

                // Package retrieval events
                case AlpmEventType.PkgRetrieveStart:
                    Console.Error.WriteLine("[ALPM] Retrieving packages...");
                    break;
                case AlpmEventType.PkgRetrieveDone:
                    Console.Error.WriteLine("[ALPM] Packages retrieved.");
                    break;
                case AlpmEventType.PkgRetrieveFailed:
                    Console.Error.WriteLine("[ALPM] Package retrieval failed.");
                    break;

                case AlpmEventType.DatabaseMissing:
                {
                    Console.Error.WriteLine(
                        "[ALPM] Database missing. Please run 'pacman-key --init' to initialize it.");
                    break;
                }

                case AlpmEventType.OptdepRemoval:
                    Console.Error.WriteLine("[ALPM] Optional dependency being removed.");
                    break;

                case AlpmEventType.KeyringStart:
                    Console.Error.WriteLine("[ALPM] Checking keyring...");
                    break;
                case AlpmEventType.KeyringDone:
                    Console.Error.WriteLine("[ALPM] Keyring check finished.");
                    break;
                case AlpmEventType.KeyDownloadStart:
                    Console.Error.WriteLine("[ALPM] Downloading keys...");
                    break;
                case AlpmEventType.KeyDownloadDone:
                    Console.Error.WriteLine("[ALPM] Key download finished.");
                    break;

                case AlpmEventType.PacnewCreated:
                    var pacnewEvent = Marshal.PtrToStructure<AlpmPacnewCreatedEvent>(eventPtr);

                    string? file = pacnewEvent.File != IntPtr.Zero
                        ? Marshal.PtrToStringUTF8(pacnewEvent.File)
                        : null;

                    string? oldPkgName = null;
                    if (pacnewEvent.OldPkg != IntPtr.Zero)
                    {
                        IntPtr namePtr = AlpmReference.GetPkgName(pacnewEvent.OldPkg);
                        oldPkgName = namePtr != IntPtr.Zero ? Marshal.PtrToStringUTF8(namePtr) : null;
                    }

                    string? newPkgName = null;
                    if (pacnewEvent.NewPkg != IntPtr.Zero)
                    {
                        IntPtr namePtr = AlpmReference.GetPkgName(pacnewEvent.NewPkg);
                        newPkgName = namePtr != IntPtr.Zero ? Marshal.PtrToStringUTF8(namePtr) : null;
                    }

                    bool fromNoupgrade = pacnewEvent.FromNoUpgrade != 0;

                    Console.Error.WriteLine($"[ALPM] .pacnew file created: {file}");
                    PacnewInfo?.Invoke(this, new AlpmPacnewEventArgs(file!));
                    break;
                case AlpmEventType.PacsaveCreated:
                    Console.Error.WriteLine("[ALPM] .pacsave file created.");
                    var pacsaveEvent = Marshal.PtrToStructure<AlpmPacsaveCreatedEvent>(eventPtr);

                    var fileLocation = pacsaveEvent.File != IntPtr.Zero
                        ? Marshal.PtrToStringUTF8(pacsaveEvent.File)
                        : null;

                    string? pkgNameOld = null;
                    if (pacsaveEvent.OldPkg != IntPtr.Zero)
                    {
                        IntPtr namePtr = AlpmReference.GetPkgName(pacsaveEvent.OldPkg);
                        pkgNameOld = namePtr != IntPtr.Zero ? Marshal.PtrToStringUTF8(namePtr) : null;
                    }

                    Console.Error.WriteLine($"[ALPM] .pacsave file created: {fileLocation}");
                    PacsaveInfo?.Invoke(this,
                        new AlpmPacsaveEventArgs(pkgNameOld ?? "No package name", fileLocation ?? "No file location"));
                    break;

                default:
                    // Unknown event type - just ignore it
                    break;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ALPM_ERROR] Error handling event: {ex.Message}");
        }
    }

    /// <summary>
    /// Safely reads a string pointer from an event struct at the given offset.
    /// Returns null if the pointer is invalid or reading fails.
    /// </summary>
    private static string? ReadStringFromEvent(IntPtr eventPtr, int offset)
    {
        try
        {
            IntPtr strPtr = Marshal.ReadIntPtr(eventPtr, offset);
            if (strPtr == IntPtr.Zero) return null;
            return Marshal.PtrToStringUTF8(strPtr);
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Safely reads the package name from a PackageOperation event.
    /// The struct layout is: type (4) + operation (4) + oldpkg ptr + newpkg ptr
    /// </summary>
    private string? ReadPackageNameFromEvent(IntPtr eventPtr)
    {
        try
        {
            const int ptrOffset = 8; // type (4) + operation (4)
            IntPtr oldPkgPtr = Marshal.ReadIntPtr(eventPtr, ptrOffset);
            IntPtr newPkgPtr = Marshal.ReadIntPtr(eventPtr, ptrOffset + IntPtr.Size);

            // For install/upgrade, use NewPkgPtr; for remove, use OldPkgPtr
            IntPtr pkgPtr = newPkgPtr != IntPtr.Zero ? newPkgPtr : oldPkgPtr;
            if (pkgPtr == IntPtr.Zero) return null;

            IntPtr namePtr = GetPkgName(pkgPtr);
            if (namePtr == IntPtr.Zero) return null;

            return Marshal.PtrToStringUTF8(namePtr);
        }
        catch
        {
            return null;
        }
    }

    private static List<string> GetDependencyList(IntPtr listPtr)
    {
        if (listPtr == IntPtr.Zero) return [];

        var dependencies = new List<string>();
        var currentPtr = listPtr;
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                var depString = AlpmReference.DepComputeString(node.Data);
                if (depString != IntPtr.Zero)
                {
                    var str = Marshal.PtrToStringUTF8(depString);
                    if (!string.IsNullOrEmpty(str))
                    {
                        // Strip version constraints (e.g., "gcc>=10" -> "gcc")
                        var pkgName = str.Split(new[] { '>', '<', '=' })[0];
                        dependencies.Add(pkgName);
                    }
                }
            }

            currentPtr = node.Next;
        }

        return dependencies;
    }

    public static List<string> GetRepositories(string configPath = "/etc/pacman.conf")
    {
        var config = PacmanConfParser.Parse(configPath);
        return config.Repos.Select(r => r.Name).ToList();
    }

    private string BuildPackageUrl(AlpmPackageUpdateDto pkg)
    {
        // Find the sync DB that contains this package
        var syncDbsPtr = GetSyncDbs(_handle);
        var currentPtr = syncDbsPtr;

        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                var pkgPtr = DbGetPkg(node.Data, pkg.Name);
                if (pkgPtr != IntPtr.Zero)
                {
                    // Get the filename from the package
                    var fileNamePtr = AlpmReference.GetPkgFileName(pkgPtr);
                    var fileName = Marshal.PtrToStringUTF8(fileNamePtr)
                                   ?? throw new Exception($"Could not get filename for package {pkg.Name}");

                    // Get the first server URL from this database
                    var serversPtr = AlpmReference.DbGetServers(node.Data);
                    if (serversPtr != IntPtr.Zero)
                    {
                        var serverNode = Marshal.PtrToStructure<AlpmList>(serversPtr);
                        if (serverNode.Data != IntPtr.Zero)
                        {
                            var serverUrl = Marshal.PtrToStringUTF8(serverNode.Data)
                                            ?? throw new Exception($"Could not get server URL for package {pkg.Name}");
                            return $"{serverUrl.TrimEnd('/')}/{fileName}";
                        }
                    }
                }
            }

            currentPtr = node.Next;
        }

        throw new Exception($"Package '{pkg.Name}' not found in any sync database");
    }

    public static int VersionCompare(string a, string b)
    {
        return AlpmReference.PkgVerCmp(a, b);
    }

    public List<string> RemoveCorruptedPackages(bool dryRun = false)
    {
        if (_handle == IntPtr.Zero)
        {
            Initialize(true);
        }

        List<string> corruptedPackages = [];
        if (!Directory.Exists(_config.CacheDir))
        {
            return corruptedPackages;
        }

        var packageFiles = Directory.EnumerateFiles(_config.CacheDir, "*.pkg.tar*",
            SearchOption.AllDirectories).Where(x => !x.EndsWith(".sig"));

        foreach (var filePath in packageFiles)
        {
            var result = PkgLoad(_handle, filePath, false, AlpmSigLevel.PackageOptional | AlpmSigLevel.DatabaseOptional,
                out var pkgPtr);
            if (result == -1)
            {
                Console.WriteLine(filePath);
                corruptedPackages.Add(Path.GetFileName(filePath));
                if (!dryRun)
                {
                    File.Delete(filePath);
                }
            }
            else if (pkgPtr != IntPtr.Zero)
            {
                if (PkgFree(pkgPtr) != 0)
                {
                    ErrorEvent?.Invoke(this, new AlpmErrorEventArgs("Failed to free package"));
                    //Potentially need to manually release memory here will keep track of usage during testing.
                    //If I find this later, and it's still here, you can just remove this as it works as expected.
                }
            }
        }

        return corruptedPackages;
    }

    private void HandleErrorMessage(IntPtr dataPtr, AlpmErrno error)
    {
        var errorMsg = GetErrorMessage(error);
        List<string> details = [];

        switch (error)
        {
            case AlpmErrno.UnsatisfiedDeps:
                WalkList(dataPtr, details, ptr =>
                {
                    var miss = Marshal.PtrToStructure<AlpmDependencyMissing>(ptr);
                    return miss.ToString();
                });
                break;
            case AlpmErrno.ConflictingDeps:
                WalkList(dataPtr, details, ptr =>
                {
                    var conflict = Marshal.PtrToStructure<AlpmConflict>(ptr);
                    return conflict.ToString();
                });
                break;
            case AlpmErrno.FileConflicts:
                WalkList(dataPtr, details, ptr =>
                {
                    var fc = Marshal.PtrToStructure<AlpmFileConflict>(ptr);
                    return fc.ToString();
                });
                break;
            case AlpmErrno.PkgInvalidArch:
            case AlpmErrno.DownloadFailed:
            case AlpmErrno.PkgMissingSig:
            case AlpmErrno.PkgOpen:
            case AlpmErrno.PkgInvalid:
            case AlpmErrno.PkgInvalidChecksum:
            case AlpmErrno.PkgInvalidSig:
                WalkList(dataPtr, details, ptr =>
                    Marshal.PtrToStringUTF8(ptr) ?? "unknown");
                break;
            case AlpmErrno.Ok:
                break;
            case AlpmErrno.Memory:
                details.Add("Memory allocation failed");
                break;
            case AlpmErrno.System:
                details.Add("System error");
                break;
            case AlpmErrno.BadPerms:
                details.Add("Inssufficient permissions");
                break;
            case AlpmErrno.NotAFile:
                details.Add("Expected a file, did not receive a file. How did you mess this up?");
                break;
            case AlpmErrno.NotADir:
                details.Add("Expected a directory, did not receive a directory. I'm sorry what?");
                break;
            case AlpmErrno.WrongArgs:
                details.Add("Wrong or NULL arguments");
                break;
            case AlpmErrno.DiskSpace:
                details.Add("Not enough disk space");
                details.Add("Why is your disk so small?");
                break;
            case AlpmErrno.HandleNull:
                details.Add("Lost the handle. Kinda like a plot but more important");
                break;
            case AlpmErrno.HandleNotNull:
                details.Add("Handle is not null. Not sure how you pulled this off.");
                break;
            case AlpmErrno.HandleLock:
                details.Add("You have a db.lck . It's at /var/lib/pacman/db.lck. You should probably delete that.");
                break;
            case AlpmErrno.DbOpen:
                details.Add("Could not open database");
                break;
            case AlpmErrno.DbCreate:
                details.Add("Could not create database");
                break;
            case AlpmErrno.DbNull:
                details.Add("Database is null.");
                break;
            case AlpmErrno.DbNotNull:
                details.Add("Database already registered. Don't do that!");
                break;
            case AlpmErrno.DbNotFound:
                details.Add("Database not found");
                details.Add("It must have gotten lost in the file forest");
                break;
            case AlpmErrno.DbInvalid:
                details.Add("Database is invalid or corrupted");
                details.Add("These aren't supposed to take bribes.");
                break;
            case AlpmErrno.DbInvalidSig:
                details.Add("Database signature is invalid");
                break;
            case AlpmErrno.DbVersion:
                details.Add("Database version is not supported");
                break;
            case AlpmErrno.DbWrite:
                details.Add("Could not write to database");
                break;
            case AlpmErrno.DbRemove:
                details.Add("Could not remove database entry");
                break;
            case AlpmErrno.ServerBadUrl:
                details.Add("Server URL is invalid");
                break;
            case AlpmErrno.ServerNone:
                details.Add("No server URL specified");
                details.Add("The pacman.conf has no entries. I'm sorry what?");
                break;
            case AlpmErrno.TransNotNull:
                details.Add("Transaction already started");
                details.Add("I guess I'll just die.");
                break;
            case AlpmErrno.TransNull:
                details.Add("Transaction not started");
                details.Add("I swear this doesn't normally happen, you just made me so excited.");
                break;
            case AlpmErrno.TransDupTarget:
                details.Add("Duplicate target in transaction");
                details.Add("You can't add your favorite thing twice");
                break;
            case AlpmErrno.TransDupFilename:
                details.Add("Duplicate filename in transaction");
                break;
            case AlpmErrno.TransNotInitialized:
                details.Add("Transaction not initialized");
                break;
            case AlpmErrno.TransNotPrepared:
                details.Add("Transaction not prepared");
                details.Add("Think before you leap");
                break;
            case AlpmErrno.TransAbort:
                details.Add("Transaction aborted");
                details.Add("I decided I'm tired and just kinda gave up.");
                break;
            case AlpmErrno.TransType:
                details.Add("Invalid transaction type");
                details.Add("Choose the right option please.");
                break;
            case AlpmErrno.TransNotLocked:
                details.Add("Transaction not locked");
                break;
            case AlpmErrno.TransHookFailed:
                details.Add("Hook failed");
                details.Add("I just couldn't hook into what was supposed to happen.");
                break;
            case AlpmErrno.PkgNotFound:
                details.Add("Package not found");
                details.Add("Why did you think this existed?");
                break;
            case AlpmErrno.PkgIgnored:
                details.Add("Package is in ignored package.");
                details.Add("Move along nothing to seee here");
                break;
            case AlpmErrno.PkgCantRemove:
                details.Add("Can't remove this package try something else.");
                break;
            case AlpmErrno.PkgInvalidName:
                details.Add("Invalid package name");
                break;
            case AlpmErrno.SigMissing:
                details.Add("Signature missing");
                break;
            case AlpmErrno.SigInvalid:
                details.Add("Invalid signature");
                break;
            case AlpmErrno.Gpgme:
                details.Add("GPGME error");
                break;
            case AlpmErrno.ExternalDownload:
                details.Add("External download failed to fire, give me a minute to pep them up and try again.");
                break;
            case AlpmErrno.SandboxFailed:
                details.Add($"Sandbox failed");
                break;
            default:
                details.Add($"Unknown error: {error}");
                break;
        }


        var fullError = $"{errorMsg}\n{string.Join("\n", details)}";
        ErrorEvent?.Invoke(this, new AlpmErrorEventArgs(fullError));
    }

    private static void WalkList(IntPtr listPtr, List<string> details, Func<IntPtr, string> marshal)
    {
        var current = listPtr;
        while (current != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(current);
            if (node.Data != IntPtr.Zero)
                details.Add(marshal(node.Data));
            current = node.Next;
        }
    }
}