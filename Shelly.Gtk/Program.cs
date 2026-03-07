using Gtk;
using Microsoft.Extensions.DependencyInjection;
using Shelly.Gtk.Services;
using Shelly.Gtk.Windows;
using Shelly.Gtk.Windows.AUR;
using Shelly.Gtk.Windows.Dialog;
using Shelly.Gtk.Windows.Flatpak;
using Shelly.Gtk.Windows.Packages;

namespace Shelly.Gtk;

sealed class Program
{
    public static int Main(string[] args)
    {
        ServiceCollection serviceCollection = new();
        var serviceProvider = CreateDependencyInjection(serviceCollection);

        var application = global::Gtk.Application.New("com.shellyorg.shelly", Gio.ApplicationFlags.DefaultFlags);

        application.OnActivate += (sender, _) =>
        {
            var cssProvider = CssProvider.New();
            cssProvider.LoadFromPath("Assets/style.css");
            StyleContext.AddProviderForDisplay(Gdk.Display.GetDefault()!, cssProvider, 800);

            var mainBuilder = Builder.NewFromFile("UiFiles/MainWindow.ui");
            var window = (ApplicationWindow)mainBuilder.GetObject("MainWindow")!;

            window.SetIconName("shelly");
            window.Application = application;

            var menuBuilder = Builder.NewFromFile("UiFiles/MainMenu.ui");
            var appMenu = (Gio.Menu)menuBuilder.GetObject("AppMenu")!;
            application.Menubar = appMenu;

            var quitAction = Gio.SimpleAction.New("quit", null);
            quitAction.OnActivate += (_, _) => application.Quit();
            application.AddAction(quitAction);

            var preferencesAction = Gio.SimpleAction.New("preferences", null);
            preferencesAction.OnActivate += (_, _) => Console.WriteLine("Preferences clicked");
            application.AddAction(preferencesAction);

            var aboutAction = Gio.SimpleAction.New("about", null);
            aboutAction.OnActivate += (_, _) => Console.WriteLine("About clicked");
            application.AddAction(aboutAction);

            var contentArea = (Box)mainBuilder.GetObject("ContentArea")!;
            var homeButton = (Button)mainBuilder.GetObject("HomeButton")!;
            var settingsButton = (Button)mainBuilder.GetObject("SettingsButton")!;

            IShellyWindow? currentPage = null;

            void NavigateTo<T>() where T : IShellyWindow
            {
                currentPage?.Dispose();

                while (contentArea.GetFirstChild() is { } child)
                {
                    contentArea.Remove(child);
                    child.Unparent();
                }

                var page = serviceProvider.GetRequiredService<T>();
                contentArea.Append(page.CreateWindow());
                currentPage = page;
            }

            homeButton.OnClicked += (_, _) => NavigateTo<HomeWindow>();
            settingsButton.OnClicked += (_, _) => NavigateTo<FlatpakUpdate>();

            AddAction("install-packages", NavigateTo<PackageInstall>);
            AddAction("update-packages", NavigateTo<PackageUpdate>); // Placeholder
            AddAction("manage-packages", NavigateTo<PackageManagement>);

            // AUR Actions
            AddAction("install-aur", NavigateTo<AurInstall>);
            AddAction("update-aur", NavigateTo<AurUpdate>); 
            AddAction("remove-aur", NavigateTo<AurRemove>); 

            // Flatpak Actions
            AddAction("install-flatpak", NavigateTo<FlatpakInstall>);
            AddAction("update-flatpak", NavigateTo<FlatpakUpdate>);
            AddAction("remove-flatpak", NavigateTo<FlatpakRemove>);

            var initialHomeWindow = serviceProvider.GetRequiredService<HomeWindow>();
            contentArea.Append(initialHomeWindow.CreateWindow());
            currentPage = initialHomeWindow;

            //Subscribing to credential required to trigger the password dialog
            var credentialManager = serviceProvider.GetRequiredService<ICredentialManager>();
            credentialManager.CredentialRequested += (s, e) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    var dialog = serviceProvider.GetRequiredService<PasswordDialog>();
                    dialog.ShowPasswordDialog(e.Reason);
                    return false;
                });
            };


            window.Show();

            var lockoutService = serviceProvider.GetRequiredService<ILockoutService>();

            var lockoutOverlay = (Box)mainBuilder.GetObject("LockoutOverlay")!;
            var lockoutDescription = (Label)mainBuilder.GetObject("LockoutDescription")!;
            var lockoutProgressBar = (ProgressBar)mainBuilder.GetObject("LockoutProgressBar")!;

            lockoutService.StatusChanged += (_, lockoutArgs) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    lockoutOverlay.Visible = lockoutArgs.IsLocked;
                    if (!lockoutArgs.IsLocked) return false;
                    lockoutDescription.SetText(lockoutArgs.Description ?? "Processing...");
                    lockoutProgressBar.Fraction = lockoutArgs.Progress / 100.0;
                    if (lockoutArgs.IsIndeterminate)
                    {
                        lockoutProgressBar.Pulse();
                    }
                    return false;
                });
            };

            return;

            void AddAction(string name, Action onActivate)
            {
                var action = Gio.SimpleAction.New(name, null);
                action.OnActivate += (_, _) => { onActivate(); };
                application.AddAction(action);
            }
        };

        return application.Run(args);
    }

    private static ServiceProvider CreateDependencyInjection(ServiceCollection collection)
    {
        collection.AddSingleton<IPrivilegedOperationService, PrivilegedOperationService>();
        collection.AddSingleton<IUnprivilegedOperationService, UnprivilegedOperationService>();
        collection.AddSingleton<ICredentialManager, CredentialManager>();
        collection.AddSingleton<IAlpmEventService, AlpmEventService>();
        collection.AddSingleton<IConfigService, ConfigService>();
        collection.AddSingleton<ILockoutService, LockoutService>();
        collection.AddTransient<HomeWindow>();
        collection.AddTransient<FlatpakRemove>();
        collection.AddTransient<AurInstall>();
        collection.AddTransient<AurUpdate>();
        collection.AddTransient<AurRemove>();
        collection.AddTransient<FlatpakInstall>();
        collection.AddTransient<FlatpakUpdate>();
        collection.AddTransient<PackageManagement>();
        collection.AddTransient<PackageUpdate>();
        collection.AddTransient<PackageInstall>();
        collection.AddTransient<PasswordDialog>();
        return collection.BuildServiceProvider();
    }
}