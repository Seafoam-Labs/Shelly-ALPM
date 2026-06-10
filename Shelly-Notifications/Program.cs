using System.Diagnostics;
using Shelly_Notifications.DbusHandlers;
using Shelly_Notifications.Resources;
using Shelly_Notifications.Models;
using Shelly_Notifications.Services;
using Tmds.DBus.Protocol;
using Tmds.DBus.SourceGenerator;

try
{
    Translations.Init();
    CancellationTokenSource? delayCts = null;
    var forceCheck = false;
    var configReader = new ConfigReader();

    //review later source generated code generated with obsolete 
    //may need to take the source generated code and drop source generation
    using var connection = new Connection(DBusAddress.Session!);
    await connection.ConnectAsync();

    const string shellyNotificationsService = "org.shelly.Notifications";
    await connection.RequestNameAsync(shellyNotificationsService);

    var trayHandler = new StatusNotifierItemHandler(connection, configReader);
    connection.AddMethodHandler(trayHandler);

    var menuHandler = new DBusMenuHandler(connection);
    menuHandler.OnUpdateStatusChanged += async (pending) =>
    {
        await trayHandler.SetUpdatesPending(pending);
    };
    menuHandler.OnExitRequested += () =>
    {
        Console.WriteLine("Exit requested via tray menu.");
        try
        {
            var appName = "shelly-ui";
            var processes = Process.GetProcessesByName(appName);
            foreach (var process in processes)
            {
                try
                {
                    process.Kill();
                    process.WaitForExit(TimeSpan.FromSeconds(2));
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Failed to kill {appName} (PID: {process.Id}): {ex.Message}");
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error while trying to kill app: {ex.Message}");
        }

        Environment.Exit(0);
    };
    connection.AddMethodHandler(menuHandler);

    connection.AddMethodHandler(new ShellyUiReceiver(() =>
    {
        try
        {
            configReader.Refresh();
            forceCheck = true;
            try
            {
                delayCts?.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }

            return Task.CompletedTask;
        }
        catch (Exception exception)
        {
            return Task.FromException(exception);
        }
    }, () =>
    {
        forceCheck = true;
        try
        {
            delayCts?.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }
    }));

    var cts = new CancellationTokenSource();
    var token = cts.Token;

    _ = Task.Run(async () =>
    {
        var updates = new UpdateService(menuHandler);
        var update = await updates.CheckForUpdates();
        await trayHandler.SetUpdatesPending(update > 0);
        if (update > 0)
        {
            _ = new NotificationHandler().SendNotif(connection, Translations.T("Updates available: {0}", update));
        }

        var time = DateTime.Now;
        while (!token.IsCancellationRequested)
        {
            try
            {
                if (forceCheck || time.AddSeconds(30) < DateTime.Now)
                {
                    forceCheck = false;
                    update = await updates.CheckForUpdates();
                    await trayHandler.SetUpdatesPending(update > 0);
                    if (update > 0)
                    {
                        _ = new NotificationHandler().SendNotif(connection, Translations.T("Updates available: {0}", update));
                    }

                    time = DateTime.Now;
                }
            }
            catch (Exception)
            {
                // Swallow exceptions so the loop continues
            }
            finally
            {
                GC.Collect();
            }

            try
            {
                TimeSpan checkInterval;
                if (configReader.LoadConfig().UseWeeklySchedule)
                {
                    checkInterval = NextNotification.GetNextNotificationTime(configReader.LoadConfig().DaysOfWeek,
                        configReader.LoadConfig().Time,
                        TimeSpan.FromHours(configReader.LoadConfig().TrayCheckIntervalHours));
                }
                else
                {
                    checkInterval = TimeSpan.FromHours(configReader.LoadConfig().TrayCheckIntervalHours);
                }

                delayCts = CancellationTokenSource.CreateLinkedTokenSource(token);
                await Task.Delay(checkInterval, delayCts.Token);
            }
            catch (OperationCanceledException)
            {
                if (token.IsCancellationRequested) break;
                // If only _delayCts was cancelled, loop will continue and reload config
            }
        }
    }, token);

    var trayServiceName = $"org.freedesktop.StatusNotifierItem-{Process.GetCurrentProcess().Id}-1";
    await connection.RequestNameAsync(trayServiceName);

    // 3 Try Registering the Tray Icon
    await TryRegisterTrayIconAsync(connection, trayServiceName);

    Console.WriteLine(Translations.T("Shelly Notifications started. Press Ctrl+C to exit."));
    await Task.Delay(-1);
}
catch (Exception ex)
{
    Console.WriteLine($"[Error] Shelly Notifications failed to start: {ex.Message}");
}

async Task TryRegisterTrayIconAsync(Connection connection, string serviceName)
{
    var watchers = new[]
    {
        ("org.freedesktop.StatusNotifierWatcher", "/StatusNotifierWatcher"),
        ("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher")
    };

    var registered = false;
    foreach (var (service, path) in watchers)
    {
        try
        {
            if (service.Contains("freedesktop"))
            {
                var watcherProxy = new OrgFreedesktopStatusNotifierWatcherProxy(connection, service, path);
                await watcherProxy.RegisterStatusNotifierItemAsync(serviceName);
            }
            else
            {
                var watcherProxy = new OrgKdeStatusNotifierWatcherProxy(connection, service, path);
                await watcherProxy.RegisterStatusNotifierItemAsync(serviceName);
            }

            Console.WriteLine($"Tray icon registered via {service}");
            registered = true;
            break;
        }
        catch (DBusErrorReplyException ex) when (ex.ErrorName is "org.freedesktop.DBus.Error.ServiceUnknown"
                                                     or "org.freedesktop.DBus.Error.NameHasNoOwner")
        {
            // Try the next one
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Attempt to register via {service} failed: {ex.Message}");
        }
    }

    if (!registered)
    {
        Console.WriteLine(Translations.T("Warning: No StatusNotifierWatcher found. The tray icon will not be visible."));
        Console.WriteLine(Translations.T("Tip: If you are using GNOME, ensure you have an 'AppIndicator' extension installed."));
    }
}