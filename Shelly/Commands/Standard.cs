using System.Diagnostics.CodeAnalysis;
using ConsoleAppFramework;
using PackageManager.Alpm;

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
        return globals.UiMode ? SyncUiMode(globals.Verbose, force) : SyncConsoleMode(globals.Verbose, force);
    }

    private int SyncUiMode(bool verbose = false, bool force = false)
    {
        var manager = new AlpmManager(verbose, true, Configuration.GetConfigurationFile());
        Console.WriteLine("Synchronizing package databases...");
        manager.Progress += (sender, args) => { Console.WriteLine($"{args.PackageName}: {args.Percent}%"); };
        manager.Sync(force);
        Console.WriteLine("Package databases synchronization completed");
        return 0;
    }

    private int SyncConsoleMode(bool verbose = false, bool force = false)
    {
        var manager = new AlpmManager(verbose, false, Configuration.GetConfigurationFile());
        Console.WriteLine("Synchronizing package databases...");
        if (force)
        {
            Console.WriteLine("Forcing Synchronization");
        }

        var rowIndex = new Dictionary<string, int>();
        object renderLock = new();
        var baseTop = -1;

        manager.Progress += (sender, args) =>
        {
            lock (renderLock)
            {
                var name = args.PackageName ?? "unknown";
                var pct = args.Percent ?? 0;
                var bar = new string('\u2588', pct / 5) + new string('\u2591', 20 - pct / 5);
                var stage = args.ProgressType;

                var line = $"  {name,-30} {bar} {pct,3}%  {stage}";

                if (!rowIndex.TryGetValue(name, out var row))
                {
                    if (baseTop < 0) baseTop = Console.CursorTop;
                    row = rowIndex.Count;
                    rowIndex[name] = row;
                }

                Console.SetCursorPosition(0, baseTop + row);
                Console.Write("\x1b[2K");
                Console.Write(line);
                Console.Out.Flush();
            }
        };

        manager.Sync(force);
        if (baseTop >= 0)
            Console.SetCursorPosition(0, baseTop + rowIndex.Count);
        Console.WriteLine();
        Console.WriteLine("Package databases synchronization completed");
        return 0;
    }
}