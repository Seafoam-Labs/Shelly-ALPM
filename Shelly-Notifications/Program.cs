using System.Diagnostics;
using Shelly_Notifications.DbusHandlers;
using Shelly_Notifications.Models;
using Shelly_Notifications.Services;
using Tmds.DBus.Protocol;
using Tmds.DBus.SourceGenerator;

try
{
    CancellationTokenSource? delayCts = null;
    var configReader = new ConfigReader();

    //review later source generated code generated with obsolete 
    //may need to take the source generated code and drop source generation
    using var connection = new Connection(DBusAddress.Session!);
    await connection.ConnectAsync();

    const string shellyNotificationsService = "org.shelly.Notifications";
    await connection.RequestNameAsync(shellyNotificationsService);

    connection.AddMethodHandler(new ShellyUiReceiver(() =>
    {
        configReader.Refresh();
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


    var trayHandler = new StatusNotifierItemHandler();
    connection.AddMethodHandler(trayHandler);

    var menuHandler = new DBusMenuHandler(connection);
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

    _ = Task.Run(async () =>
    {
        var updates = new UpdateService(menuHandler);
        var update = await updates.CheckForUpdates();
        _ = new NotificationHandler().SendNotif(connection, $"Updates available: {update}");
        var time = DateTime.Now;
        while (!token.IsCancellationRequested)
        {
           
            try
            {
                if (time.AddSeconds(30) < DateTime.Now)
                {
                    update = await updates.CheckForUpdates();
                    _ = new NotificationHandler().SendNotif(connection, $"Updates available: {update}");
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
                var checkInterval = TimeSpan.FromHours(configReader.LoadConfig().TrayCheckIntervalHours);
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

    Console.WriteLine("Shelly Notifications started. Press Ctrl+C to exit.");
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
        Console.WriteLine("Warning: No StatusNotifierWatcher found. The tray icon will not be visible.");
        Console.WriteLine("Tip: If you are using GNOME, ensure you have an 'AppIndicator' extension installed.");
    }
}