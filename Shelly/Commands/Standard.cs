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
        if (globals.UiMode)
        {
            return SyncUiMode(globals.Verbose, force);
        }
        
        return 1;
    }

    private int SyncUiMode(bool verbose = false, bool force = false)
    {
        var manager = new AlpmManager(Configuration.GetConfigurationFile());
        Console.WriteLine("Synchronizing package databases...");
        manager.Progress += (sender, args) => { Console.WriteLine($"{args.PackageName}: {args.Percent}%"); };
        if (force)
        {
            Console.WriteLine("Forcing Synchronization");
        }

        manager.Sync(force);
        Console.WriteLine("Packages databases synchronization completed");
        return 0;
    }
}