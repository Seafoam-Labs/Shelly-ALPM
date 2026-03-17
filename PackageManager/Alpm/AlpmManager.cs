using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using PackageManager.Alpm.Questions;
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
    private static readonly HttpClient HttpClient = new();
    private AlpmFetchCallback _fetchCallback;
    private AlpmEventCallback _eventCallback;
    private AlpmQuestionCallback _questionCallback;
    private AlpmProgressCallback? _progressCallback;

    public event EventHandler<AlpmProgressEventArgs>? Progress;
    public event EventHandler<AlpmPackageOperationEventArgs>? PackageOperation;
    public event EventHandler<AlpmQuestionEventArgs>? Question;
    public event EventHandler<AlpmReplacesEventArgs>? Replaces;

    public void IntializeWithSync()
    {
        Initialize(true);
        Sync();
    }

    public void Initialize(bool root = false, bool useTempPath = false, string tempPath = "")
    {
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
        string resolvedArch = _config.Architecture;
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
                    AddArchitecture(_handle, resolvedArch + suffix);
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
                questionText = $"{packageName}. Remove {packageTwo?.Name ?? "unknown"}?";
                conflictOptions = new List<string>();
                if (!string.IsNullOrEmpty(packageOne?.Name)) conflictOptions.Add(packageOne.Name);
                if (!string.IsNullOrEmpty(packageTwo?.Name)) conflictOptions.Add(packageTwo.Name);
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

            handler = new SocketsHttpHandler
            {
                PooledConnectionLifetime = TimeSpan.FromMinutes(2),
                AutomaticDecompression = System.Net.DecompressionMethods.All,
                AllowAutoRedirect = true,
                MaxAutomaticRedirections = 10
            };
            client = new HttpClient(handler);
            client.Timeout = TimeSpan.FromMinutes(30);
            client.DefaultRequestHeaders.UserAgent.ParseAdd("Shelly-ALPM/1.0 (compatible)");
            using var response = client.GetAsync(fullUrl, HttpCompletionOption.ResponseContentRead)
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

            using var response = HttpClient.GetAsync(sigUrl, HttpCompletionOption.ResponseContentRead)
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
        if (_handle == IntPtr.Zero) Initialize();
        var syncDbsPtr = GetSyncDbs(_handle);
        if (syncDbsPtr != IntPtr.Zero)
        {
            // Pass the entire list pointer directly to alpm_db_update
            var result = Update(_handle, syncDbsPtr, force);
            if (result < 0)
            {
                var error = ErrorNumber(_handle);
                Console.Error.WriteLine($"Sync failed: {GetErrorMessage(error)}");
            }

            if (result > 0)
            {
                Console.Error.WriteLine($"Sync database up to date");
            }

            if (result == 0)
            {
                Console.Error.WriteLine($"Updating Sync database");
            }
        }
    }

    public List<AlpmPackageDto> GetInstalledPackages()
    {
        if (_handle == IntPtr.Zero) Initialize();
        var dbPtr = GetLocalDb(_handle);
        var pkgPtr = DbGetPkgCache(dbPtr);
        return AlpmPackage.FromList(pkgPtr).Select(p => p.ToDto()).ToList();
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

        return updates;
    }

    private string GetErrorMessage(AlpmErrno error)
    {
        return Marshal.PtrToStringUTF8(StrError(error)) ?? $"Unknown error ({error})";
    }

    public void InstallPackage(string packageName,
        AlpmTransFlag flags = AlpmTransFlag.NoScriptlet | AlpmTransFlag.NoHooks)
    {
        if (_handle == IntPtr.Zero) Initialize();

        // 1. Find the package in sync databases
        IntPtr pkgPtr = IntPtr.Zero;
        var syncDbsPtr = GetSyncDbs(_handle);
        var currentPtr = syncDbsPtr;
        while (currentPtr != IntPtr.Zero)
        {
            var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
            if (node.Data != IntPtr.Zero)
            {
                pkgPtr = DbGetPkg(node.Data, packageName);
                if (pkgPtr != IntPtr.Zero) break;
            }

            currentPtr = node.Next;
        }

        if (pkgPtr == IntPtr.Zero)
        {
            Console.Error.WriteLine($"[ALPM_ERROR]Package '{packageName}' not found in any sync database.");
            throw new Exception($"Package '{packageName}' not found in any sync database.");
        }

        // If we are doing a DbOnly install, we should also skip dependency checks, 
        // extraction, and signature/checksum validation to avoid requirement for the physical package file.
        if (flags.HasFlag(AlpmTransFlag.DbOnly))
        {
            flags |= AlpmTransFlag.NoDeps | AlpmTransFlag.NoExtract | AlpmTransFlag.NoPkgSig |
                     AlpmTransFlag.NoCheckSpace;
        }

        // 2. Initialize transaction
        if (TransInit(_handle, flags) != 0)
        {
            Console.Error.WriteLine(
                $"[ALPM_ERROR]Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            throw new Exception($"Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
        }

        try
        {
            // 3. Add package to transaction
            if (AddPkg(_handle, pkgPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to add package '{packageName}' to transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception(
                    $"Failed to add package '{packageName}' to transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            // 4. Prepare transaction
            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to prepare transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to prepare transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            // 5. Commit transaction
            if (TransCommit(_handle, out dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to commit transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to commit transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }
        }
        finally
        {
            // 6. Release transaction
            TransRelease(_handle);
        }
    }

    public void InstallPackages(List<string> packageNames,
        AlpmTransFlag flags = AlpmTransFlag.None)
    {
        if (_handle == IntPtr.Zero) Initialize();

        List<IntPtr> pkgPtrs = new List<IntPtr>();

        foreach (var packageName in packageNames)
        {
            // Find the package in sync databases
            IntPtr pkgPtr = IntPtr.Zero;
            var syncDbsPtr = GetSyncDbs(_handle);
            var currentPtr = syncDbsPtr;
            while (currentPtr != IntPtr.Zero)
            {
                var node = Marshal.PtrToStructure<AlpmList>(currentPtr);
                if (node.Data != IntPtr.Zero)
                {
                    pkgPtr = DbGetPkg(node.Data, packageName);
                    if (pkgPtr != IntPtr.Zero) break;
                }

                currentPtr = node.Next;
            }

            if (pkgPtr == IntPtr.Zero)
            {
                Console.Error.WriteLine($"[ALPM_ERROR]Package '{packageName}' not found in any sync database.");
                throw new Exception($"Package '{packageName}' not found in any sync database.");
            }

            pkgPtrs.Add(pkgPtr);
        }

        if (pkgPtrs.Count == 0) return;

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
            Console.Error.WriteLine(
                $"[ALPM_ERROR]Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            throw new Exception($"Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
        }

        try
        {
            foreach (var pkgPtr in pkgPtrs)
            {
                if (AddPkg(_handle, pkgPtr) != 0)
                {
                    // Note: In libalpm, if one fails, we might want to know which one, 
                    // but here we just throw an exception for the first failure.
                    Console.Error.WriteLine(
                        $"[ALPM_ERROR]Failed to add package to transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                    throw new Exception(
                        $"Failed to add a package to transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                }
            }

            // Prepare transaction
            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to prepare transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to prepare transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            // Commit transaction
            if (TransCommit(_handle, out dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to commit transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to commit transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }
        }
        finally
        {
            // Release transaction
            TransRelease(_handle);
        }
    }

    public void RemovePackages(List<string> packageNames,
        AlpmTransFlag flags = AlpmTransFlag.None)
    {
        if (_handle == IntPtr.Zero) Initialize();

        List<IntPtr> pkgPtrs = new List<IntPtr>();
        var localDbPtr = GetLocalDb(_handle);
        foreach (var packageName in packageNames)
        {
            // Find the package in sync databases

            var pkgPtr = DbGetPkg(localDbPtr, packageName);

            if (pkgPtr == IntPtr.Zero)
            {
                Console.Error.WriteLine($"[ALPM_ERROR]Package '{packageName}' not found in local database.");
                throw new Exception($"Package '{packageName}' not found in any sync database.");
            }

            pkgPtrs.Add(pkgPtr);
        }

        if (pkgPtrs.Count == 0) return;

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
            Console.Error.WriteLine(
                $"[ALPM_ERROR]Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            throw new Exception($"Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
        }

        try
        {
            foreach (var pkgPtr in pkgPtrs)
            {
                if (RemovePkg(_handle, pkgPtr) != 0)
                {
                    // Note: In libalpm, if one fails, we might want to know which one, 
                    // but here we just throw an exception for the first failure.
                    Console.Error.WriteLine(
                        $"[ALPM_ERROR]Failed to remove package from transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                    throw new Exception(
                        $"Failed to add a package to transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                }
            }

            // Prepare transaction
            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to prepare transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to prepare transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            // Commit transaction
            if (TransCommit(_handle, out dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to commit transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to commit transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }
        }
        finally
        {
            // Release transaction
            TransRelease(_handle);
        }
    }

    public void RemovePackage(string packageName,
        AlpmTransFlag flags = AlpmTransFlag.None)
    {
        if (_handle == IntPtr.Zero) Initialize();

        // 1. Find the package in the local database
        var localDbPtr = GetLocalDb(_handle);
        var pkgPtr = DbGetPkg(localDbPtr, packageName);

        if (pkgPtr == IntPtr.Zero)
        {
            Console.Error.WriteLine($"[ALPM_ERROR]Package '{packageName}' not found in local database.");
            throw new Exception($"Package '{packageName}' not found in the local database.");
        }

        // 2. Initialize transaction
        // Using 0 for flags for now, similar to InstallPackage
        if (TransInit(_handle, flags) != 0)
        {
            Console.Error.WriteLine(
                $"[ALPM_ERROR]Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            throw new Exception($"Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
        }

        try
        {
            // 3. Add package to removal list
            if (RemovePkg(_handle, pkgPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to add package '{packageName}' to removal list: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception(
                    $"Failed to add package '{packageName}' to removal transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            // 4. Prepare transaction
            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to prepare transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to prepare removal transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            // 5. Commit transaction
            if (TransCommit(_handle, out dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to commit removal transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to commit removal transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }
        }
        finally
        {
            // 6. Release transaction
            TransRelease(_handle);
        }
    }

    public void SyncSystemUpdate(AlpmTransFlag flags = AlpmTransFlag.None)
    {
        if (_handle == IntPtr.Zero) Initialize();
        var syncDbsPtr = GetSyncDbs(_handle);
        Update(_handle, syncDbsPtr, true);
        try
        {
            if (TransInit(_handle, flags) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            if (SyncSysupgrade(_handle, false) != 0) throw new Exception(GetErrorMessage(ErrorNumber(_handle)));
            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to prepare system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception(
                    $"Failed to prepare system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            CheckTransactionReplaces(_handle);

            if (TransCommit(_handle, out dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to commit system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception(
                    $"Failed to commit system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[ALPM_ERROR]Failed to initialize transaction: {ex.Message}");
            throw new Exception($"Failed to initialize transaction: {ex.Message}");
        }
        finally
        {
            _ = TransRelease(_handle);
        }
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

    public void InstallLocalPackage(string path, AlpmTransFlag flags = AlpmTransFlag.None)
    {
        if (_handle == IntPtr.Zero) Initialize();

        // 1. Load package from file
        var result = PkgLoad(_handle, path, true, AlpmSigLevel.PackageOptional | AlpmSigLevel.DatabaseOptional,
            out IntPtr pkgPtr);
        if (result != 0 || pkgPtr == IntPtr.Zero)
        {
            Console.Error.WriteLine(
                $"[ALPM_ERROR]Failed to load package from '{path}': {GetErrorMessage(ErrorNumber(_handle))}");
            throw new Exception($"Failed to load package from '{path}': {GetErrorMessage(ErrorNumber(_handle))}");
        }

        // 2. Initialize transaction
        if (TransInit(_handle, flags) != 0)
        {
            _ = PkgFree(pkgPtr);
            Console.Error.WriteLine(
                $"[ALPM_ERROR]Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            throw new Exception($"Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
        }

        try
        {
            // 3. Add package to transaction
            if (AddPkg(_handle, pkgPtr) != 0)
            {
                _ = PkgFree(pkgPtr);
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to add package to transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to add package to transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            // 4. Prepare transaction
            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to prepare transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to prepare transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            // 5. Commit transaction
            if (TransCommit(_handle, out dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to commit transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to commit transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }
        }
        catch (Exception ex)
        {
            _ = PkgFree(pkgPtr);
            Console.Error.WriteLine($"[ALPM_ERROR]Failed to initialize transaction: {ex.Message}");
            throw new Exception($"Failed to initialize transaction: {ex.Message}");
        }
        finally
        {
            TransRelease(_handle);
            Refresh();
        }
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

    public void InstallDependenciesOnly(string packageName,
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
            Console.WriteLine($"Package '{packageName}' not found");
            return;
        }

        var dependencies = GetDependencyList(GetPkgDepends(pkgPtr));


        if (includeMakeDeps)
        {
            var makeDepends = GetDependencyList(GetPkgMakeDepends(pkgPtr));
            dependencies = dependencies.Concat(makeDepends).ToList();
        }


        var installedPackages = GetInstalledPackages().ToDictionary(x => x.Name, x => x.Version);
        var dependencyToInstall = dependencies.Where(x => !installedPackages.ContainsKey(x)).ToList();

        if (dependencyToInstall.Count == 0) return;

        InstallPackages(dependencyToInstall, flags);
    }

    public void Refresh()
    {
        if (_handle != IntPtr.Zero)
        {
            Release(_handle);
            _handle = IntPtr.Zero;
        }

        Initialize();
    }

    public void UpdatePackages(List<string> packageNames,
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
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            failedPkgPtrs.AddRange(pkgPtrs.Where(pkgPtr => AddPkg(_handle, pkgPtr) != 0));

            // Check if there are any packages to add or remove before preparing/committing
            if (TransGetAdd(_handle) == IntPtr.Zero && TransGetRemove(_handle) == IntPtr.Zero)
            {
                return; // Nothing to do, considered successful
            }

            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to prepare system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception(
                    $"Failed to prepare system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            if (TransCommit(_handle, out dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to commit system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception(
                    $"Failed to commit system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }
        }
        finally
        {
            _ = TransRelease(_handle);
        }
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
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            var pkgPtr = DbGetPkg(GetLocalDb(_handle), packageName);
            if (AddPkg(_handle, pkgPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to add package '{packageName}' to transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to mark system upgrade: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            // Check if there are any packages to add or remove before preparing/committing
            if (TransGetAdd(_handle) == IntPtr.Zero && TransGetRemove(_handle) == IntPtr.Zero)
            {
                return true; // Nothing to do, considered successful
            }

            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to prepare system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception(
                    $"Failed to prepare system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            if (TransCommit(_handle, out dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to commit system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception(
                    $"Failed to commit system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            return true;
        }
        finally
        {
            _ = TransRelease(_handle);
        }
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
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to initialize transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            if (SyncSysupgrade(_handle, false) != 0)
            {
                Console.Error.WriteLine($"[ALPM_ERROR]Failed to sync system: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception($"Failed to mark system upgrade: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            // Check if there are any packages to add or remove before preparing/committing
            if (TransGetAdd(_handle) == IntPtr.Zero && TransGetRemove(_handle) == IntPtr.Zero)
            {
                return true; // Nothing to do, considered successful
            }

            if (TransPrepare(_handle, out var dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to prepare system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception(
                    $"Failed to prepare system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            if (TransCommit(_handle, out dataPtr) != 0)
            {
                Console.Error.WriteLine(
                    $"[ALPM_ERROR]Failed to commit system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
                throw new Exception(
                    $"Failed to commit system upgrade transaction: {GetErrorMessage(ErrorNumber(_handle))}");
            }

            return true;
        }
        finally
        {
            _ = TransRelease(_handle);
        }
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
                    Console.Error.WriteLine("[ALPM] Checking for inter-conflicts...");
                    break;
                case AlpmEventType.InterConflictsDone:
                    Console.Error.WriteLine("[ALPM] Inter-conflict check finished.");
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
                    Console.Error.WriteLine("[ALPM] Running scriptlet...");
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
                    Console.Error.WriteLine("[ALPM] Running hook...");
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
                    Console.Error.WriteLine("[ALPM] .pacnew file created.");
                    break;
                case AlpmEventType.PacsaveCreated:
                    Console.Error.WriteLine("[ALPM] .pacsave file created.");
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
}