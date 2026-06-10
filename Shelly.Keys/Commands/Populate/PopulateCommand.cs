using Shelly.Keys.Gpg;
using Shelly.Keys.Gpgme;
using Shelly.Keys.Gpgme.Interop;
using Spectre.Console;
using Spectre.Console.Cli;

namespace Shelly.Keys.Commands.Populate;

public class PopulateCommand : AsyncCommand<Settings>
{
    public override async Task<int> ExecuteAsync(CommandContext context, Settings settings)
    {
        RootElevator.EnsureRootExectuion();
        if (!Directory.Exists(settings.KeyringsDir))
        {
            AnsiConsole.MarkupLine(
                $"[bold red]Keyrings directory does not exist: {Markup.Escape(settings.KeyringsDir)}[/]");
            return 1;
        }

        string masterFingerprint;
        try
        {
            masterFingerprint = await GpgHelpers.GetMasterFingerprintAsync(settings.Directory);
        }
        catch (InvalidOperationException)
        {
            AnsiConsole.MarkupLine("[bold red]Keyring does not contain a master key. Run `shelly keys init` first[/]");
            return 1;
        }

        var keyrings = ResolveKeyrings(settings);
        if (keyrings.Count == 0)
        {
            AnsiConsole.MarkupLine("[bold red]No keyrings found to populate.[/]");
            return 1;
        }

        using var ctx = new GpgmeContext();
        ctx.SetEngineInfo(
            GpgmeNative.gpgme_protocol_t.GPGME_PROTOCOL_OpenPGP,
            fileName: null,
            homeDir: settings.Directory);
        int considered = 0, imported = 0, unchanged = 0;
        AnsiConsole.MarkupLine("[bold]==> Appending keys from keyrings...[/]");
        foreach (var name in keyrings)
        {
            var path = Path.Combine(settings.KeyringsDir, $"{name}.gpg");
            using var data = GpgmeData.FromMemory(await File.ReadAllBytesAsync(path));
            var result = ctx.ImportKey(data);
            considered += result.Considered;
            imported += result.Imported;
            unchanged += result.Unchanged;
            AnsiConsole.MarkupLine($"[grey]Imported {result.Imported} keys from {Markup.Escape(name)}[/]");
        }

        AnsiConsole.MarkupLine(
            $"[bold green]Imported {imported} keys, {unchanged} unchanged, {considered} considered[/]");
        var failures = 0;
        AnsiConsole.MarkupLine("[bold]==> Locally signing trusted keys...[/]");
        foreach (var keyring in keyrings)
        {
            var trusted = Path.Combine(settings.KeyringsDir, $"{keyring}-trusted");
            foreach (var fingerprint in ReadFingerprints(trusted))
            {
                var code = await GpgHelpers.RunGpgAsync(settings.Directory,"-u", masterFingerprint, "--yes", "--quick-lsign-key", fingerprint);
                if (code != 0)
                {
                    failures++;
                    AnsiConsole.MarkupLine(
                        $"[bold red]Failed to trust key {Markup.Escape(fingerprint)} in {Markup.Escape(keyring)}[/]");
                }
            }
        }
        AnsiConsole.MarkupLine("[bold]==> Importing owner trust values...[/]");

        foreach (var keyring in keyrings)
        {
            var trusted = Path.Combine(settings.KeyringsDir, $"{keyring}-trusted");
            if (File.Exists(trusted))
            {
                failures += await GpgHelpers.RunGpgAsync(settings.Directory, "--import-ownertrust", trusted) == 0
                    ? 0
                    : 1;
            }
        }

        AnsiConsole.MarkupLine("[bold]==> Disabling revoked keys...[/]");
        foreach (var key in keyrings)
        {
            var revoked = Path.Combine(settings.KeyringsDir, $"{key}-revoked");
            foreach (var fingerprint in ReadFingerprints(revoked))
            {
                await GpgHelpers.RunGpgStdinAsync(settings.Directory, "disable\nquit\n", "--command-fd", "0",
                    "--edit-key", fingerprint);
            }
        }

        AnsiConsole.MarkupLine("[bold]==> Updating trust database...[/]");
        var trustResponse = await GpgHelpers.RunGpgAsync(settings.Directory, "--check-trustdb");
        if (trustResponse != 0)
        {
            AnsiConsole.MarkupLine("[bold red]Failed to verify trustdb[/]");
            return trustResponse;
        }

        return failures == 0 ? 0 : 1;
    }

    private static List<string> ResolveKeyrings(Settings settings)
    {
        if (settings.Keyrings.Length == 0)
        {
            return new DirectoryInfo(settings.KeyringsDir)
                .EnumerateFiles("*.gpg")
                .Select(f => Path.GetFileNameWithoutExtension(f.Name))
                .ToList();
        }

        List<string> keyrings = [];
        foreach (var name in settings.Keyrings)
        {
            var path = Path.Combine(settings.KeyringsDir, $"{name}.gpg");
            if (File.Exists(path))
            {
                keyrings.Add(name);
            }
            else
            {
                AnsiConsole.MarkupLine($"[bold red]Keyring not found: {Markup.Escape(name)}[/]");
            }
        }

        return keyrings;
    }

    private static IEnumerable<string> ReadFingerprints(string keyringPath)
    {
        if (!File.Exists(keyringPath)) yield break;
        foreach (var raw in File.ReadLines(keyringPath))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#'))
            {
                continue;
            }

            //Fingerprint structure is <fingerprint>:<trustlevel>:<keyid> 
            //Trimming to just fingerprint
            var fingerprint = line.Split(':', 2)[0].Trim();
            if (fingerprint.Length > 0)
            {
                yield return fingerprint;
            }
        }
    }
}