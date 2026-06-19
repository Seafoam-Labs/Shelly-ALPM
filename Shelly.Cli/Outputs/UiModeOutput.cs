using PackageManager.Alpm;
using PackageManager.Aur;
using PackageManager.Flatpak;
using PackageManager.Flatpak.Events;
using Shelly.Utilities.Eventing;

namespace Shelly.Cli.Outputs;

internal static class UiModeOutput
{
    public static async Task<bool> Run(AurPackageManager manager, Func<AurPackageManager, Task> operation)
    {
        var hadError = false;
        Attach(manager, () => hadError = true);
        try
        {
            await operation(manager);
        }
        catch (Exception ex)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, ex.Message));
            return false;
        }

        return !hadError;
    }

    public static async Task<bool> Run(IAlpmManager manager, Func<IAlpmManager, Task> operation)
    {
        var hadError = false;
        Attach(manager, () => hadError = true);
        try
        {
            await operation(manager);
        }
        catch (Exception ex)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, ex.Message));
            return false;
        }

        return !hadError;
    }


    private static void Attach(AurPackageManager manager, Action onError)
    {
        manager.ErrorEvent += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, e.Error));
            onError();
        };
        manager.HookRun += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmHookEvent(EventLevel.Information, e.Description));
        };
        manager.ScriptletInfo += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmScriptletEvent(EventLevel.Information, e.Line));
        };
        manager.Replaces += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmReplaceEvent(e.Repository, e.PackageName, e.Replaces));
        };
        manager.Progress += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmPackageProgressEvent(
                e.PackageName ?? "Unknown Package",
                e.Current ?? 0,
                e.HowMany ?? 0,
                e.ProgressType.ToProgressType(),
                e.Percent ?? 0,
                e.Message));
        };
        manager.InformationalEvent += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                (AlpmEvents)(int)e.EventType,
                e.Message,
                e.PackageName,
                e.CurrentIndex,
                e.TotalCount));
        };
    }

    private static void Attach(IAlpmManager manager, Action onError)
    {
        manager.ErrorEvent += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, e.Error));
            onError();
        };
        manager.HookRun += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmHookEvent(EventLevel.Information, e.Description));
        };
        manager.ScriptletInfo += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmScriptletEvent(EventLevel.Information, e.Line));
        };
        manager.Replaces += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmReplaceEvent(e.Repository, e.PackageName, e.Replaces));
        };
        manager.Progress += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmPackageProgressEvent(
                e.PackageName ?? "Unknown Package",
                e.Current ?? 0,
                e.HowMany ?? 0,
                e.ProgressType.ToProgressType(),
                e.Percent ?? 0,
                e.Message));
        };
        manager.InformationalEvent += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmInformationalEvent(
                (AlpmEvents)(int)e.EventType,
                e.Message,
                e.PackageName,
                e.CurrentIndex,
                e.TotalCount));
        };
    }

    private static void Attach(FlatpakManager manager, Action onError)
    {
        manager.FlatpakProgressEvent += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new FlatpakProgressEvent(
                e.Status,
                e.Percentage));
        };
        manager.FlatpakEvent += (_, e) =>
        {
            JsonPackFrame.WriteToStdout<Event>(new FlatpakStatusEvent(
                (FlatpakEvents)(int)e.EventType,
                e.Message));
        };
    }

    public static async Task<bool> Run(FlatpakManager manager, Func<FlatpakManager, Task> operation)
    {
        var hadError = false;
        Attach(manager, () => hadError = true);
        try
        {
            await operation(manager);
        }
        catch (Exception ex)
        {
            JsonPackFrame.WriteToStdout<Event>(new AlpmErrorEvent(EventLevel.Error, ex.Message));
            return false;
        }

        return !hadError;
    }
}