using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

[assembly: InternalsVisibleTo("PackageManager.Tests")]

namespace PackageManager.Alpm
{
    internal static partial class AlpmReference
    {
        public const string LibName = "alpm";

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void AlpmEventCallback(IntPtr ctx, IntPtr eventPtr);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void AlpmQuestionCallback(IntPtr ctx, IntPtr questionPtr);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate void AlpmProgressCallback(IntPtr ctx, AlpmProgressType progress,
            IntPtr pkg, int percent, ulong howmany, ulong current);

        [LibraryImport(LibName, EntryPoint = "alpm_option_set_eventcb")]
        public static partial int SetEventCallback(IntPtr handle, AlpmEventCallback cb, IntPtr ctx);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        public delegate int AlpmFetchCallback(IntPtr ctx, IntPtr url, IntPtr localpath, int force);

        [LibraryImport(LibName, EntryPoint = "alpm_option_set_fetchcb")]
        public static partial int SetFetchCallback(IntPtr handle, AlpmFetchCallback cb, IntPtr ctx);

        [LibraryImport(LibName, EntryPoint = "alpm_option_set_questioncb")]
        public static partial int SetQuestionCallback(IntPtr handle, AlpmQuestionCallback cb, IntPtr ctx);

        [LibraryImport(LibName, EntryPoint = "alpm_option_set_progresscb")]
        public static partial int SetProgressCallback(IntPtr handle, AlpmProgressCallback cb, IntPtr ctx);

        [LibraryImport("libalpm.so", EntryPoint = "alpm_option_get_lockfile")]
        [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
        public static partial IntPtr GetLockFile(IntPtr handle);
        //
        // [LibraryImport("libc", EntryPoint = "__errno_location")]
        // public static partial IntPtr ErrnoLocation();

        /// <summary>
        /// Initializes the alpm library.
        /// </summary>
        /// <param name="root">The root directory for operations.</param>
        /// <param name="dbpath">The path to the package database.</param>
        /// <param name="error">The error code if initialization fails.</param>
        /// <returns>A handle to the alpm library, or IntPtr.Zero on failure.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_initialize", StringMarshalling = StringMarshalling.Utf8)]
        public static partial IntPtr Initialize(string root, string dbpath, out AlpmErrno error);

        /// <summary>
        /// Releases the alpm handle.
        /// </summary>
        /// <param name="handle">The alpm handle to release.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_release")]
        public static partial int Release(IntPtr handle);

        /// <summary>
        /// Returns the last error code for a given handle.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>The last error code.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_errno")]
        public static partial AlpmErrno ErrorNumber(IntPtr handle);

        /// <summary>
        /// Returns the capabilities of the library.
        /// </summary>
        /// <returns>A bitmask of library capabilities.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_capabilities")]
        public static partial int Capabilities();

        /// <summary>
        /// Unlocks the database if it is locked.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_unlock")]
        public static partial int Unlock(IntPtr handle);

        #region Options

        /// <summary>
        /// Gets the list of cache directories.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of cache directories.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_cachedirs")]
        public static partial IntPtr GetCacheDirs(IntPtr handle);

        /// <summary>
        /// Sets the list of cache directories.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="cachedirs">A pointer to a list of cache directories.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_cachedirs")]
        public static partial int SetCacheDirs(IntPtr handle, IntPtr cachedirs);

        /// <summary>
        /// Adds a cache directory to the list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="cachedir">The cache directory to add.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_add_cachedir", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int AddCacheDir(IntPtr handle, string cachedir);

        /// <summary>
        /// Removes a cache directory from the list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="cachedir">The cache directory to remove.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_remove_cachedir", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int RemoveCacheDir(IntPtr handle, string cachedir);

        /// <summary>
        /// Gets the list of hook directories.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of hook directories.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_hookdirs")]
        public static partial IntPtr GetHookDirs(IntPtr handle);

        /// <summary>
        /// Sets the list of hook directories.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="hookdirs">A pointer to a list of hook directories.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_hookdirs")]
        public static partial int SetHookDirs(IntPtr handle, IntPtr hookdirs);

        /// <summary>
        /// Adds a hook directory to the list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="hookdir">The hook directory to add.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_add_hookdir", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int AddHookDir(IntPtr handle, string hookdir);

        /// <summary>
        /// Removes a hook directory from the list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="hookdir">The hook directory to remove.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_remove_hookdir", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int RemoveHookDir(IntPtr handle, string hookdir);

        /// <summary>
        /// Gets the list of files to overwrite during installation.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of file globs.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_overwrite_files")]
        public static partial IntPtr GetOverwriteFiles(IntPtr handle);

        /// <summary>
        /// Sets the list of files to overwrite during installation.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="globs">A pointer to a list of file globs.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_overwrite_files")]
        public static partial int SetOverwriteFiles(IntPtr handle, IntPtr globs);

        /// <summary>
        /// Adds a file glob to the overwrite list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="glob">The file glob to add.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_add_overwrite_file",
            StringMarshalling = StringMarshalling.Utf8)]
        public static partial int AddOverwriteFile(IntPtr handle, string glob);

        /// <summary>
        /// Removes a file glob from the overwrite list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="glob">The file glob to remove.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_remove_overwrite_file",
            StringMarshalling = StringMarshalling.Utf8)]
        public static partial int RemoveOverwriteFile(IntPtr handle, string glob);

        /// <summary>
        /// Sets the log file path.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="logfile">The log file path.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_logfile", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int SetLogFile(IntPtr handle, string logfile);

        /// <summary>
        /// Sets the GPG directory path.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="gpgdir">The GPG directory path.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_gpgdir", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int SetGpgDir(IntPtr handle, string gpgdir);

        /// <summary>
        /// Gets whether to use syslog for logging.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>1 if syslog is used, 0 otherwise.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_usesyslog")]
        public static partial int GetUseSyslog(IntPtr handle);

        /// <summary>
        /// Sets whether to use syslog for logging.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="usesyslog">1 to use syslog, 0 otherwise.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_usesyslog")]
        public static partial int SetUseSyslog(IntPtr handle, int usesyslog);

        /// <summary>
        /// Gets the list of packages that should not be upgraded.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of package names.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_noupgrades")]
        public static partial IntPtr GetNoUpgrades(IntPtr handle);

        /// <summary>
        /// Adds a package to the no-upgrade list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="path">The package name or path.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_add_noupgrade", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int AddNoUpgrade(IntPtr handle, string path);

        /// <summary>
        /// Sets the list of packages that should not be upgraded.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="noupgrade">A pointer to a list of package names.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_noupgrades")]
        public static partial int SetNoUpgrades(IntPtr handle, IntPtr noupgrade);

        /// <summary>
        /// Removes a package from the no-upgrade list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="path">The package name or path.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_remove_noupgrade",
            StringMarshalling = StringMarshalling.Utf8)]
        public static partial int RemoveNoUpgrade(IntPtr handle, string path);

        /// <summary>
        /// Gets the list of files that should not be extracted.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of file paths.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_noextracts")]
        public static partial IntPtr GetNoExtracts(IntPtr handle);

        /// <summary>
        /// Adds a file to the no-extract list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="path">The file path.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_add_noextract", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int AddNoExtract(IntPtr handle, string path);

        /// <summary>
        /// Sets the list of files that should not be extracted.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="noextract">A pointer to a list of file paths.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_noextracts")]
        public static partial int SetNoExtracts(IntPtr handle, IntPtr noextract);

        /// <summary>
        /// Removes a file from the no-extract list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="path">The file path.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_remove_noextract",
            StringMarshalling = StringMarshalling.Utf8)]
        public static partial int RemoveNoExtract(IntPtr handle, string path);

        /// <summary>
        /// Gets the list of ignored packages.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of package names.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_ignorepkgs")]
        public static partial IntPtr GetIgnorePkgs(IntPtr handle);

        /// <summary>
        /// Adds a package to the ignore list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="pkg">The package name.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_add_ignorepkg", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int AddIgnorePkg(IntPtr handle, string pkg);

        /// <summary>
        /// Sets the list of ignored packages.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="ignorepkgs">A pointer to a list of package names.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_ignorepkgs")]
        public static partial int SetIgnorePkgs(IntPtr handle, IntPtr ignorepkgs);

        /// <summary>
        /// Removes a package from the ignore list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="pkg">The package name.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_remove_ignorepkg",
            StringMarshalling = StringMarshalling.Utf8)]
        public static partial int RemoveIgnorePkg(IntPtr handle, string pkg);

        /// <summary>
        /// Gets the list of ignored groups.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of group names.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_ignoregroups")]
        public static partial IntPtr GetIgnoreGroups(IntPtr handle);

        /// <summary>
        /// Adds a group to the ignore list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="grp">The group name.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_add_ignoregroup", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int AddIgnoreGroup(IntPtr handle, string grp);

        /// <summary>
        /// Sets the list of ignored groups.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="ignoregrps">A pointer to a list of group names.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_ignoregroups")]
        public static partial int SetIgnoreGroups(IntPtr handle, IntPtr ignoregrps);

        /// <summary>
        /// Removes a group from the ignore list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="grp">The group name.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_remove_ignoregroup",
            StringMarshalling = StringMarshalling.Utf8)]
        public static partial int RemoveIgnoreGroup(IntPtr handle, string grp);

        /// <summary>
        /// Gets the list of allowed architectures.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of architecture names.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_architectures")]
        public static partial IntPtr GetArchitectures(IntPtr handle);

        /// <summary>
        /// Adds an architecture to the allowed list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="arch">The architecture name.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_add_architecture",
            StringMarshalling = StringMarshalling.Utf8)]
        public static partial int AddArchitecture(IntPtr handle, string arch);

        /// <summary>
        /// Sets the list of allowed architectures.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="arches">A pointer to a list of architecture names.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_architectures")]
        public static partial int SetArchitectures(IntPtr handle, IntPtr arches);

        /// <summary>
        /// Removes an architecture from the allowed list.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="arch">The architecture name.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_remove_architecture",
            StringMarshalling = StringMarshalling.Utf8)]
        public static partial int RemoveArchitecture(IntPtr handle, string arch);

        /// <summary>
        /// Gets whether to check for free disk space before transactions.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>1 if space is checked, 0 otherwise.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_checkspace")]
        public static partial int GetCheckSpace(IntPtr handle);

        /// <summary>
        /// Sets whether to check for free disk space before transactions.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="checkspace">1 to check space, 0 otherwise.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_checkspace")]
        public static partial int SetCheckSpace(IntPtr handle, int checkspace);

        /// <summary>
        /// Sets the package database extension.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="dbext">The database extension.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_dbext", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int SetDbExt(IntPtr handle, string dbext);

        /// <summary>
        /// Gets the default signature verification level.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>The signature level.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_default_siglevel")]
        public static partial AlpmSigLevel GetDefaultSigLevel(IntPtr handle);

        /// <summary>
        /// Sets the default signature verification level.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="level">The signature level.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_default_siglevel")]
        public static partial int SetDefaultSigLevel(IntPtr handle, AlpmSigLevel level);

        /// <summary>
        /// Gets the signature verification level for local files.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>The signature level.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_local_file_siglevel")]
        public static partial AlpmSigLevel GetLocalFileSigLevel(IntPtr handle);

        /// <summary>
        /// Sets the signature verification level for local files.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="level">The signature level.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_local_file_siglevel")]
        public static partial int SetLocalFileSigLevel(IntPtr handle, AlpmSigLevel level);

        /// <summary>
        /// Gets the signature verification level for remote files.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>The signature level.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_remote_file_siglevel")]
        public static partial AlpmSigLevel GetRemoteFileSigLevel(IntPtr handle);

        /// <summary>
        /// Sets the signature verification level for remote files.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="level">The signature level.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_remote_file_siglevel")]
        public static partial int SetRemoteFileSigLevel(IntPtr handle, AlpmSigLevel level);

        /// <summary>
        /// Gets the number of parallel downloads.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>The number of parallel downloads.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_get_parallel_downloads")]
        public static partial int GetParallelDownloads(IntPtr handle);

        /// <summary>
        /// Sets the number of parallel downloads.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="num_streams">The number of parallel downloads.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_option_set_parallel_downloads")]
        public static partial int SetParallelDownloads(IntPtr handle, uint num_streams);

        #endregion

        #region Databases

        /// <summary>
        /// Gets the local database.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to the local database.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_get_localdb")]
        public static partial IntPtr GetLocalDb(IntPtr handle);

        /// <summary>
        /// Gets the list of registered sync databases.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of sync databases.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_get_syncdbs")]
        public static partial IntPtr GetSyncDbs(IntPtr handle);

        /// <summary>
        /// Registers a sync database.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="treename">The name of the database.</param>
        /// <param name="level">The signature verification level.</param>
        /// <returns>A pointer to the registered database, or IntPtr.Zero on failure.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_register_syncdb", StringMarshalling = StringMarshalling.Utf8)]
        public static partial IntPtr RegisterSyncDb(IntPtr handle, string treename, AlpmSigLevel level);

        /// <summary>
        /// Unregisters all sync databases.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_unregister_all_syncdbs")]
        public static partial int UnregisterAllSyncDbs(IntPtr handle);

        /// <summary>
        /// Unregisters a specific database.
        /// </summary>
        /// <param name="db">The database to unregister.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_unregister")]
        public static partial int DbUnregister(IntPtr db);

        /// <summary>
        /// Gets the name of a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <returns>The name of the database.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_get_name")]
        public static partial IntPtr DbGetName(IntPtr db);

        /// <summary>
        /// Gets the signature verification level of a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <returns>The signature level.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_get_siglevel")]
        public static partial AlpmSigLevel DbGetSigLevel(IntPtr db);

        /// <summary>
        /// Gets whether a database is valid.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <returns>1 if valid, 0 otherwise.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_get_valid")]
        public static partial int DbGetValid(IntPtr db);

        /// <summary>
        /// Gets the list of servers for a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <returns>A pointer to a list of server URLs.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_get_servers")]
        public static partial IntPtr DbGetServers(IntPtr db);

        /// <summary>
        /// Sets the list of servers for a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <param name="servers">A pointer to a list of server URLs.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_set_servers")]
        public static partial int DbSetServers(IntPtr db, IntPtr servers);

        /// <summary>
        /// Adds a server to a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <param name="url">The server URL.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_add_server", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int DbAddServer(IntPtr db, string url);

        /// <summary>
        /// Removes a server from a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <param name="url">The server URL.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_remove_server", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int DbRemoveServer(IntPtr db, string url);

        /// <summary>
        /// Updates a list of databases.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="databases">A pointer to a list of databases to update.</param>
        /// <param name="force">Whether to force the update.</param>
        /// <returns>0 on success, 1 if up-to-date, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_update")]
        public static partial int Update(IntPtr handle, IntPtr databases, [MarshalAs(UnmanagedType.Bool)] bool force);

        /// <summary>
        /// Gets a package from a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <param name="name">The name of the package.</param>
        /// <returns>A pointer to the package, or IntPtr.Zero if not found.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_get_pkg", StringMarshalling = StringMarshalling.Utf8)]
        public static partial IntPtr DbGetPkg(IntPtr db, string name);

        /// <summary>
        /// Gets the package cache for a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <returns>A pointer to the package cache.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_get_pkgcache")]
        public static partial IntPtr DbGetPkgCache(IntPtr db);

        /// <summary>
        /// Gets the group cache for a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <returns>A pointer to the group cache.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_get_groupcache")]
        public static partial IntPtr DbGetGroupCache(IntPtr db);

        /// <summary>
        /// Searches for packages in a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <param name="needles">A pointer to a list of search terms.</param>
        /// <param name="results">A pointer to the list of results.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_search")]
        public static partial int DbSearch(IntPtr db, IntPtr needles, out IntPtr results);

        /// <summary>
        /// Sets the usage of a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <param name="usage">The database usage.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_set_usage")]
        public static partial int DbSetUsage(IntPtr db, AlpmDbUsage usage);

        /// <summary>
        /// Gets the usage of a database.
        /// </summary>
        /// <param name="db">The database handle.</param>
        /// <param name="usage">The database usage.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_db_get_usage")]
        public static partial int DbGetUsage(IntPtr db, out AlpmDbUsage usage);

        #endregion

        #region Packages

        /// <summary>
        /// Loads a package from a file.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="filename">The package file path.</param>
        /// <param name="full">Whether to load the full package or just the header.</param>
        /// <param name="level">The signature verification level.</param>
        /// <param name="pkg">The loaded package pointer.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_load", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int PkgLoad(IntPtr handle, string filename, [MarshalAs(UnmanagedType.Bool)] bool full,
            AlpmSigLevel level, out IntPtr pkg);

        /// <summary>
        /// Finds a newer version of a package in sync databases.
        /// </summary>
        /// <param name="pkg">The package to check.</param>
        /// <param name="dbs_sync">The list of sync databases to search.</param>
        /// <returns>A pointer to the new version of the package, or IntPtr.Zero if no newer version is found.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_sync_get_new_version")]
        public static partial IntPtr SyncGetNewVersion(IntPtr pkg, IntPtr dbs_sync);

        /// <summary>
        /// Finds a package that satisfies a dependency string.
        /// </summary>
        /// <param name="pkgList"></param>
        /// <param name="depstring"></param>
        /// <returns>The first package that satisfies the dependency</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_find_satisfier", StringMarshalling = StringMarshalling.Utf8)]
        public static partial IntPtr PkgFindSatisfier(IntPtr pkgList, string depstring);

        /// <summary>
        /// Finds a package in a list.
        /// </summary>
        /// <param name="haystack">The list of packages.</param>
        /// <param name="needle">The package name to find.</param>
        /// <returns>A pointer to the found package, or IntPtr.Zero.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_find", StringMarshalling = StringMarshalling.Utf8)]
        public static partial IntPtr PkgFind(IntPtr haystack, string needle);

        /// <summary>
        /// Frees a package handle.
        /// </summary>
        /// <param name="pkg">The package to free.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_free")]
        public static partial int PkgFree(IntPtr pkg);

        /// <summary>
        /// Checks the MD5 sum of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_checkmd5sum")]
        public static partial int PkgCheckMd5Sum(IntPtr pkg);

        /// <summary>
        /// Compares two version strings.
        /// </summary>
        /// <param name="a">The first version string.</param>
        /// <param name="b">The second version string.</param>
        /// <returns>A value less than, equal to, or greater than 0.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_vercmp", StringMarshalling = StringMarshalling.Utf8)]
        public static partial int PkgVerCmp(string a, string b);

        /// <summary>
        /// Computes the list of packages that require this package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of package names.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_compute_requiredby")]
        public static partial IntPtr PkgComputeRequiredBy(IntPtr pkg);

        /// <summary>
        /// Computes the list of packages that this package is an optional dependency for.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of package names.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_compute_optionalfor")]
        public static partial IntPtr PkgComputeOptionalFor(IntPtr pkg);

        /// <summary>
        /// Gets whether a package should be ignored.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="pkg">The package handle.</param>
        /// <returns>1 if it should be ignored, 0 otherwise.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_should_ignore")]
        public static partial int PkgShouldIgnore(IntPtr handle, IntPtr pkg);

        /// <summary>
        /// Gets the name of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The package name.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_name")]
        public static partial IntPtr GetPkgName(IntPtr pkg);

        /// <summary>
        /// Gets the filename of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The package filename.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_filename")]
        public static partial IntPtr GetPkgFileName(IntPtr pkg);

        /// <summary>
        /// Gets the version of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The package version.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_version")]
        public static partial IntPtr GetPkgVersion(IntPtr pkg);

        /// <summary>
        /// Gets the description of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The package description.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_desc")]
        public static partial IntPtr GetPkgDesc(IntPtr pkg);

        /// <summary>
        /// Gets the URL of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The package URL.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_url")]
        public static partial IntPtr GetPkgUrl(IntPtr pkg);

        /// <summary>
        /// Gets the build date of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The build date as a timestamp.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_builddate")]
        public static partial long GetPkgBuildDate(IntPtr pkg);

        /// <summary>
        /// Gets the installation date of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The installation date as a timestamp.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_installdate")]
        public static partial long GetPkgInstallDate(IntPtr pkg);

        /// <summary>
        /// Gets the packager of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The packager's name/email.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_packager")]
        public static partial IntPtr GetPkgPackager(IntPtr pkg);

        /// <summary>
        /// Gets the MD5 sum of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The MD5 sum string.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_md5sum")]
        public static partial IntPtr GetPkgMd5Sum(IntPtr pkg);

        /// <summary>
        /// Gets the SHA256 sum of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The SHA256 sum string.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_sha256sum")]
        public static partial IntPtr GetPkgSha256Sum(IntPtr pkg);

        /// <summary>
        /// Gets the architecture of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The architecture string.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_arch")]
        public static partial IntPtr GetPkgArch(IntPtr pkg);

        /// <summary>
        /// Gets the size of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The package size in bytes.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_size")]
        public static partial long GetPkgSize(IntPtr pkg);

        /// <summary>
        /// Gets the installed size of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The installed size in bytes.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_isize")]
        public static partial long GetPkgISize(IntPtr pkg);

        /// <summary>
        /// Gets the install reason of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The install reason.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_reason")]
        public static partial AlpmPkgReason GetPkgReason(IntPtr pkg);

        /// <summary>
        /// Gets the licenses of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of license strings.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_licenses")]
        public static partial IntPtr GetPkgLicenses(IntPtr pkg);

        /// <summary>
        /// Gets the groups of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of group strings.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_groups")]
        public static partial IntPtr GetPkgGroups(IntPtr pkg);

        /// <summary>
        /// Gets the dependencies of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of dependency strings.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_depends")]
        public static partial IntPtr GetPkgDepends(IntPtr pkg);

        /// <summary>
        /// Gets the optional dependencies of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of optional dependency strings.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_optdepends")]
        public static partial IntPtr GetPkgOptDepends(IntPtr pkg);

        /// <summary>
        /// Gets the check dependencies of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of check dependency strings.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_checkdepends")]
        public static partial IntPtr GetPkgCheckDepends(IntPtr pkg);

        /// <summary>
        /// Gets the make dependencies of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of make dependency strings.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_makedepends")]
        public static partial IntPtr GetPkgMakeDepends(IntPtr pkg);

        /// <summary>
        /// Gets the conflicts of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of conflict strings.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_conflicts")]
        public static partial IntPtr GetPkgConflicts(IntPtr pkg);

        /// <summary>
        /// Gets the provides of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of provide strings.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_provides")]
        public static partial IntPtr GetPkgProvides(IntPtr pkg);

        /// <summary>
        /// Gets the replaces of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of replace strings.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_replaces")]
        public static partial IntPtr GetPkgReplaces(IntPtr pkg);

        /// <summary>
        /// Gets the files of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to the file list structure.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_files")]
        public static partial IntPtr GetPkgFiles(IntPtr pkg);

        /// <summary>
        /// Gets the backup files of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to a list of backup file strings.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_backup")]
        public static partial IntPtr GetPkgBackup(IntPtr pkg);

        /// <summary>
        /// Gets the database a package belongs to.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to the database handle.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_db")]
        public static partial IntPtr GetPkgDb(IntPtr pkg);

        /// <summary>
        /// Gets the validation method of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The validation method bitmask.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_get_validation")]
        public static partial AlpmPkgValidation GetPkgValidation(IntPtr pkg);

        /// <summary>
        /// Gets whether a package has a scriptlet.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>1 if it has a scriptlet, 0 otherwise.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_has_scriptlet")]
        public static partial int PkgHasScriptlet(IntPtr pkg);

        /// <summary>
        /// Gets the download size of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>The download size in bytes.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_download_size")]
        public static partial long PkgDownloadSize(IntPtr pkg);

        /// <summary>
        /// Sets the install reason of a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <param name="reason">The install reason.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_set_reason")]
        public static partial int PkgSetReason(IntPtr pkg, AlpmPkgReason reason);

        #endregion

        #region Transactions

        /// <summary>
        /// Gets the flags of the current transaction.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>The transaction flags.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_trans_get_flags")]
        public static partial AlpmTransFlag TransGetFlags(IntPtr handle);

        /// <summary>
        /// Gets the list of packages to be added in the current transaction.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of packages.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_trans_get_add")]
        public static partial IntPtr TransGetAdd(IntPtr handle);

        /// <summary>
        /// Gets the list of packages to be removed in the current transaction.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>A pointer to a list of packages.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_trans_get_remove")]
        public static partial IntPtr TransGetRemove(IntPtr handle);

        /// <summary>
        /// Initializes a new transaction.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="flags">The transaction flags.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_trans_init")]
        public static partial int TransInit(IntPtr handle, AlpmTransFlag flags);

        /// <summary>
        /// Prepares the transaction.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="data">A pointer to return error data if preparation fails.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_trans_prepare")]
        public static partial int TransPrepare(IntPtr handle, out IntPtr data);

        /// <summary>
        /// Commits the transaction.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="data">A pointer to return error data if commit fails.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_trans_commit")]
        public static partial int TransCommit(IntPtr handle, out IntPtr data);

        /// <summary>
        /// Interrupts the current transaction.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_trans_interrupt")]
        public static partial int TransInterrupt(IntPtr handle);

        /// <summary>
        /// Releases the current transaction.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_trans_release")]
        public static partial int TransRelease(IntPtr handle);

        /// <summary>
        /// Performs a system upgrade.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="enable_downgrade">Whether to enable downgrades.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_sync_sysupgrade")]
        public static partial int SyncSysupgrade(IntPtr handle, [MarshalAs(UnmanagedType.Bool)] bool enable_downgrade);

        /// <summary>
        /// Adds a package to the transaction.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="pkg">The package to add.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_add_pkg")]
        public static partial int AddPkg(IntPtr handle, IntPtr pkg);

        /// <summary>
        /// Removes a package from the transaction.
        /// </summary>
        /// <param name="handle">The alpm handle.</param>
        /// <param name="pkg">The package to remove.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_remove_pkg")]
        public static partial int RemovePkg(IntPtr handle, IntPtr pkg);

        #endregion

        #region Utilities

        /// <summary>
        /// Computes the MD5 sum of a file.
        /// </summary>
        /// <param name="filename">The file path.</param>
        /// <returns>The MD5 sum string pointer.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_compute_md5sum", StringMarshalling = StringMarshalling.Utf8)]
        public static partial IntPtr ComputeMd5Sum(string filename);

        /// <summary>
        /// Computes the SHA256 sum of a file.
        /// </summary>
        /// <param name="filename">The file path.</param>
        /// <returns>The SHA256 sum string pointer.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_compute_sha256sum", StringMarshalling = StringMarshalling.Utf8)]
        public static partial IntPtr ComputeSha256Sum(string filename);

        /// <summary>
        /// Gets the error string for a given error number.
        /// </summary>
        /// <param name="err">The error number.</param>
        /// <returns>The error string.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_strerror")]
        public static partial IntPtr StrError(AlpmErrno err);

        /// <summary>
        /// Computes a string representation of a dependency.
        /// </summary>
        /// <param name="dep">The dependency pointer.</param>
        /// <returns>A pointer to the computed string (must be freed by caller).</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_dep_compute_string")]
        public static partial IntPtr DepComputeString(IntPtr dep);

        #endregion

        #region MTree

        /// <summary>
        /// Opens the mtree file for a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>A pointer to the archive (struct archive*), or IntPtr.Zero on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_mtree_open")]
        public static partial IntPtr PkgMtreeOpen(IntPtr pkg);

        /// <summary>
        /// Reads the next entry from the package's mtree.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <param name="entry">Pointer to the archive_entry (struct archive_entry**).</param>
        /// <returns>ARCHIVE_OK (0) on success, ARCHIVE_EOF (1) at end, or negative on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_mtree_next")]
        public static partial int PkgMtreeNext(IntPtr pkg, out IntPtr entry);

        /// <summary>
        /// Closes the mtree file for a package.
        /// </summary>
        /// <param name="pkg">The package handle.</param>
        /// <returns>0 on success, -1 on error.</returns>
        [LibraryImport(LibName, EntryPoint = "alpm_pkg_mtree_close")]
        public static partial int PkgMtreeClose(IntPtr pkg);

        #endregion

        // This static constructor sets up the resolver
        static AlpmReference()
        {
            NativeResolver.Initialize();
        }
    }
}
