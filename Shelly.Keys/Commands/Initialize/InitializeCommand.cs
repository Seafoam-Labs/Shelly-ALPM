using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using Shelly.Keys.Gpg;
using Shelly.Keys.Gpgme;
using Shelly.Keys.Gpgme.Interop;
using Spectre.Console;
using Spectre.Console.Cli;
using static System.IO.UnixFileMode;

namespace Shelly.Keys.Commands.Initialize;

[SuppressMessage("Interoperability", "CA1416:Validate platform compatibility")]
public class InitializeCommand : AsyncCommand<Settings>
{
    private const string GpgConf = """
                                   no-greeting
                                   no-permission-warning
                                   keyserver-options timeout=10
                                   keyserver-options import-clean
                                   keyserver-options no-self-sigs-only
                                   """;

    private const uint GpgmeCreateNopasswd = 128;
    private const uint GpgmeCreateNoexpire = 256;
    private const UnixFileMode DirPrivate = UserRead | UserWrite | UserExecute; // 0700
    private const UnixFileMode FileSecret = UserRead | UserWrite; // 0600
    private const UnixFileMode FilePublic = UserRead | UserWrite | GroupRead | OtherRead; // 0644

    private const UnixFileMode FilePermissions = UserRead | UserWrite | GroupRead | OtherRead;

    private static readonly List<string> urlStart = ["hkp", "hkps", "hkpms", "ldap", "finger", "kdns"];

    public override async Task<int> ExecuteAsync(CommandContext context, Settings settings)
    {
        RootElevator.EnsureRootExectuion();

        AnsiConsole.MarkupLine("[bold green]Initializing keyring[/]");
        AnsiConsole.MarkupLine("[bold green]This may take a while[/]");
        AnsiConsole.MarkupLine("[bold green]Please be patient[/]");


        AnsiConsole.MarkupLine("[bold green]Setting up and Verifying gpg configuration[/]");

        await CheckAndFixDirectories(settings.Directory, settings.Keyserver);


        AnsiConsole.MarkupLine("[bold green]GPG configuration set up[/]");
        AnsiConsole.MarkupLine("[bold green]Starting Gpgme keyring setup[/]");


        using var ctx = new GpgmeContext();
        if (ctx.Handle.IsInvalid)
        {
            throw new InvalidOperationException("gpgme_new returned an invalid handle");
        }

        ctx.SetEngineInfo(
            GpgmeNative.gpgme_protocol_t.GPGME_PROTOCOL_OpenPGP,
            fileName: null,
            homeDir: settings.Directory);
        AnsiConsole.MarkupLine("[bold green]Gpgme engine set up![/]");
        var engineErr = GpgmeImports.gpgme_engine_check_version(GpgmeNative.gpgme_protocol_t.GPGME_PROTOCOL_OpenPGP);
        GpgmeHelpers.ThrowIfErrorString(engineErr);


        await MaterializeKeyringAsync(settings.Directory);
        ValidateFilePermissions(settings.Directory);

        AnsiConsole.MarkupLine("[bold green]Gpgme keyring setup complete[/]");

        AnsiConsole.MarkupLine("[bold green]Generating local signing key[/]");

        string fpr;

        if (!GpgmeContext.HasSecretKey(ctx))
        {
            var err = GpgmeImports.gpgme_op_createkey(ctx.Handle, "Pacman Keyring Master Key <pacman@localhost>",
                "rsa4096",
                IntPtr.Zero,
                0,
                IntPtr.Zero,
                GpgmeCreateNopasswd | GpgmeCreateNoexpire);
            GpgmeHelpers.ThrowIfErrorString(err);
            var resultPtr = GpgmeImports.gpgme_op_genkey_result(ctx.Handle);
            var result = Marshal.PtrToStructure<GpgmeNative.GpgmeGenkeyResult>(resultPtr);
            fpr = Marshal.PtrToStringUTF8(result.fpr)
                  ?? throw new InvalidOperationException("genkey result has no fingerprint");
        }
        else
        {
            AnsiConsole.MarkupLine("[bold green]Skipping keyring already has a master key[/]");
            fpr = await GpgHelpers.GetMasterFingerprintAsync(settings.Directory);
        }


        var psi = new ProcessStartInfo("gpg")
        {
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            RedirectStandardInput = true,
        };

        //Run import-ownertrust to update trustdb
        var psiImport = new ProcessStartInfo("gpg")
        {
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            RedirectStandardInput = true,
        };
        psiImport.ArgumentList.Add("--homedir");
        psiImport.ArgumentList.Add(settings.Directory);
        psiImport.ArgumentList.Add("--no-permission-warning");
        psiImport.ArgumentList.Add("--batch");
        psiImport.ArgumentList.Add("--import-ownertrust");
        psiImport.Environment["LC_ALL"] = "C";
        psiImport.Environment["GNUPGHOME"] = settings.Directory;
        using var importProcess = Process.Start(psiImport);
        var importOutputError = importProcess!.StandardError.ReadToEndAsync();
        var importOutput = importProcess.StandardOutput.ReadToEndAsync();
        await importProcess.StandardInput.WriteLineAsync($"{fpr}:6:");
        importProcess.StandardInput.Close();
        await importProcess.WaitForExitAsync();
        if (importProcess.ExitCode != 0)
        {
            AnsiConsole.MarkupLine($"[bold red]import-ownertrust failed: {importProcess.ExitCode}[/]");
            return importProcess.ExitCode;
        }

        var importOutputString = await importOutput;
        var importOutputErrorString = await importOutputError;
        AnsiConsole.MarkupLine($"[bold green]{Markup.Escape(importOutputString.Trim())}[/]");
        AnsiConsole.MarkupLine($"[bold green]{Markup.Escape(importOutputErrorString.Trim())}[/]");
        psi.Environment["LC_ALL"] = "C";
        psi.Environment["GNUPGHOME"] = settings.Directory;
        psi.ArgumentList.Add("--homedir");
        psi.ArgumentList.Add(settings.Directory);
        psi.ArgumentList.Add("--no-permission-warning");
        psi.ArgumentList.Add("--batch");
        psi.ArgumentList.Add("--check-trustdb");


        using var p = Process.Start(psi);
        var outputError = p!.StandardError.ReadToEndAsync();
        var output = p.StandardOutput.ReadToEndAsync();
        await p.WaitForExitAsync();
        var stdout = await output;
        var stderr = await outputError;
        AnsiConsole.MarkupLine($"[bold green]{Markup.Escape(stdout.Trim())}[/]");
        AnsiConsole.MarkupLine($"[bold green]{Markup.Escape(stderr.Trim())}[/]");
        var exitCode = p.ExitCode;
        if (exitCode != 0)
        {
            AnsiConsole.MarkupLine(
                $"[bold red] Failed to execute gpg trust db update with exitcode {exitCode} [/]");
            return exitCode;
        }

        AnsiConsole.MarkupLine("[bold green]Trust db updated[/]");
        return 0;
    }

    private static async Task MaterializeKeyringAsync(string directory)
    {
        var psi = new ProcessStartInfo("gpg")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.Environment["LC_ALL"] = "C";
        psi.Environment["GNUPGHOME"] = directory;
        psi.ArgumentList.Add("--homedir");
        psi.ArgumentList.Add(directory);
        psi.ArgumentList.Add("--no-permission-warning");
        psi.ArgumentList.Add("--batch");
        psi.ArgumentList.Add("--list-keys");

        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        await stdout;
        await stderr;
        if (p.ExitCode != 0 && p.ExitCode != 2)
        {
            throw new InvalidOperationException(
                $"gpg --list-keys failed with exit code {p.ExitCode}: {await stderr}");
        }
    }

    private void ValidateFilePermissions(string directory)
    {
        EnsureMode(new DirectoryInfo(directory), DirPrivate);


        var priv = new DirectoryInfo(Path.Combine(directory, "private-keys-v1.d"));
        if (!priv.Exists) priv.Create();
        EnsureMode(priv, DirPrivate);
        foreach (var f in priv.EnumerateFiles())
            EnsureMode(f, FileSecret);


        var revocs = new DirectoryInfo(Path.Combine(directory, "openpgp-revocs.d"));
        if (revocs.Exists) EnsureMode(revocs, DirPrivate);


        foreach (var pattern in new[] { "*.gpg", "*.kbx" })
        foreach (var f in new DirectoryInfo(directory).EnumerateFiles(pattern))
            EnsureMode(f, FilePublic);


        var secring = new FileInfo(Path.Combine(directory, "secring.gpg"));
        if (secring.Exists) EnsureMode(secring, FileSecret);
    }


    private static void EnsureMode(FileSystemInfo info, UnixFileMode mode)
    {
        if (info.UnixFileMode == mode) return;
        info.UnixFileMode = mode;
        info.Refresh();
    }

    private async Task CheckAndFixDirectories(string directory, string? keyServer = null)
    {
        EnsureDirectoryPermissions(directory);
        await EnsureGpgConfiguration(directory, keyServer);
        await EnsureSecretRing(directory);
    }

    private static void EnsureDirectoryPermissions(string directory)
    {
        //Creation with mode 0700
        var info = Directory.CreateDirectory(directory, FilePermissions | UserExecute);

        //Validate directory perms
        if (info.UnixFileMode == (FilePermissions | UserExecute))
        {
            return;
        }

        info.UnixFileMode = FilePermissions | UserExecute;
        info.Refresh();
    }

    private static async Task EnsureSecretRing(string directory)
    {
        var secRing = new FileInfo(Path.Combine(directory, "secring.gpg"));
        if (!secRing.Exists)
        {
            await secRing.Create().DisposeAsync();
            secRing.Refresh();
        }

        if (secRing.UnixFileMode != (UserRead | UserWrite))
        {
            secRing.UnixFileMode = (UserRead | UserWrite);
            secRing.Refresh();
        }

        await SetupGpgAgent(directory);
    }

    private static async Task EnsureGpgConfiguration(string directory, string? keyServer = null)
    {
        //Create gpg.conf
        var gpgConfiguration = new FileInfo(Path.Combine(directory, "gpg.conf"));
        if (!gpgConfiguration.Exists)
        {
            await gpgConfiguration.Create().DisposeAsync();
        }

        if (gpgConfiguration.UnixFileMode != FilePermissions)
        {
            gpgConfiguration.UnixFileMode = FilePermissions;
            gpgConfiguration.Refresh();
        }

        if (gpgConfiguration.Length == 0)
        {
            await File.WriteAllTextAsync(gpgConfiguration.FullName, GpgConf);
            File.SetUnixFileMode(gpgConfiguration.FullName, FilePermissions);
        }
        else
        {
            var fileText = await File.ReadAllLinesAsync(gpgConfiguration.FullName);
            bool hasServerTimeout = false,
                hasImportClean = false,
                hasSelfSigsOnly = false,
                hasNoGreeting = false,
                hasNoPermissionWarning = false;
            foreach (var line in fileText)
            {
                switch (line.Trim())
                {
                    case "keyserver-options timeout=10":
                        hasServerTimeout = true;
                        break;
                    case "keyserver-options import-clean":
                        hasImportClean = true;
                        break;
                    case "keyserver-options no-self-sigs-only":
                        hasSelfSigsOnly = true;
                        break;
                    case "no-greeting":
                        hasNoGreeting = true;
                        break;
                    case "no-permission-warning":
                        hasNoPermissionWarning = true;
                        break;
                }
            }

            var writeText = new List<string>();
            if (!hasServerTimeout)
            {
                writeText.Add("keyserver-options timeout=10");
            }

            if (!hasImportClean)
            {
                writeText.Add("keyserver-options import-clean");
            }

            if (!hasSelfSigsOnly)
            {
                writeText.Add("keyserver-options no-self-sigs-only");
            }

            if (!hasNoGreeting)
            {
                writeText.Add("no-greeting");
            }

            if (!hasNoPermissionWarning)
            {
                writeText.Add("no-permission-warning");
            }

            await File.AppendAllLinesAsync(gpgConfiguration.FullName, writeText);
        }

        if (keyServer != null && ValidateUrl(keyServer))
        {
            await File.AppendAllLinesAsync(gpgConfiguration.FullName,
                [$"keyserver {keyServer}"]);
        }
    }

    private static async Task SetupGpgAgent(string directory)
    {
        var gpgAgentConf = new FileInfo(Path.Combine(directory, "gpg-agent.conf"));
        if (!gpgAgentConf.Exists)
        {
            var fileStream = gpgAgentConf.CreateText();
            await fileStream.WriteLineAsync("disable-scdaemon");
            fileStream.Close();
            File.SetUnixFileMode(gpgAgentConf.FullName, UserRead | UserWrite);
        }
        else
        {
            if (gpgAgentConf.UnixFileMode != (UserRead | UserWrite))
            {
                File.SetUnixFileMode(gpgAgentConf.FullName, UserRead | UserWrite);
                gpgAgentConf.Refresh();
            }

            var fileText = await File.ReadAllLinesAsync(gpgAgentConf.FullName);
            var hasScdaemon = fileText.Any(line => line.Contains("disable-scdaemon"));
            if (!hasScdaemon)
            {
                await File.AppendAllLinesAsync(gpgAgentConf.FullName, ["disable-scdaemon"]);
            }
        }
    }

    private static bool ValidateUrl(string keyServer)
    {
        var split = keyServer.Split(':');
        try
        {
            return urlStart.Contains(split[0]);
        }
        catch (Exception e)
        {
            AnsiConsole.MarkupLine($"[bold red]Error validating keyserver url: {e.Message}[/]");
            AnsiConsole.MarkupLine("[bold red]Please check your keyserver url[/]");
            AnsiConsole.MarkupLine("[bold red]Example: hkp://keyserver.ubuntu.com[/]");
            AnsiConsole.MarkupLine("[bold red]Continuing without keyserver modification.[/]");
            return false;
        }
    }
}