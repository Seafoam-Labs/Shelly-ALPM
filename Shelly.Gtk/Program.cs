using Gtk;
using Microsoft.Extensions.DependencyInjection;
using Shelly.Gtk.Services;
using Shelly.Gtk.Windows;
using Shelly.Gtk.Windows.Flatpak;

namespace Shelly.Gtk;

sealed class Program
{
    public static int Main(string[] args)
    {
        ServiceCollection serviceCollection = new();
        var serviceProvider = CreateDependencyInjection(serviceCollection);

        var application = global::Gtk.Application.New("com.shellyorg.shelly", Gio.ApplicationFlags.DefaultFlags);

        application.OnActivate += (sender, args) =>
        {
            var mainBuilder = Builder.NewFromFile("UiFiles/MainWindow.ui");
            var window = (ApplicationWindow)mainBuilder.GetObject("MainWindow")!;

            window.SetIconName("shelly");
            window.Application = application;

            var menuBuilder = Builder.NewFromFile("UiFiles/MainMenu.ui");
            var appMenu = (Gio.Menu)menuBuilder.GetObject("AppMenu")!;
            application.Menubar = appMenu;

            var quitAction = Gio.SimpleAction.New("quit", null);
            quitAction.OnActivate += (sender, args) => application.Quit();
            application.AddAction(quitAction);

            var preferencesAction = Gio.SimpleAction.New("preferences", null);
            preferencesAction.OnActivate += (sender, args) => Console.WriteLine("Preferences clicked");
            application.AddAction(preferencesAction);

            var aboutAction = Gio.SimpleAction.New("about", null);
            aboutAction.OnActivate += (sender, args) => Console.WriteLine("About clicked");
            application.AddAction(aboutAction);

            var contentArea = (Box)mainBuilder.GetObject("ContentArea")!;
            var homeButton = (Button)mainBuilder.GetObject("HomeButton")!;
            var settingsButton = (Button)mainBuilder.GetObject("SettingsButton")!;

            void NavigateTo<T>() where T : IShellyWindow
            {
                while (contentArea.GetFirstChild() is { } child)
                    contentArea.Remove(child);

                var window = serviceProvider.GetRequiredService<T>();
                contentArea.Append(window.CreateWindow());
            }

            homeButton.OnClicked += (_, _) => NavigateTo<HomeWindow>();
            settingsButton.OnClicked += (_, _) => NavigateTo<FlatpakUpdate>(); 

            AddAction("install-packages", NavigateTo<HomeWindow>); 
            AddAction("update-packages", NavigateTo<HomeWindow>); // Placeholder
            AddAction("manage-packages", NavigateTo<HomeWindow>); // Placeholder

            // AUR Actions
            AddAction("install-aur", NavigateTo<HomeWindow>); // Placeholder
            AddAction("update-aur", NavigateTo<HomeWindow>); // Placeholder
            AddAction("remove-aur", NavigateTo<HomeWindow>); // Placeholder

            // Flatpak Actions
            AddAction("install-flatpak", NavigateTo<FlatpakInstall>);
            AddAction("update-flatpak", NavigateTo<FlatpakUpdate>);
            AddAction("remove-flatpak", NavigateTo<FlatpakRemove>);

            var initialHomeWindow = serviceProvider.GetRequiredService<HomeWindow>();
            contentArea.Append(initialHomeWindow.CreateWindow());

            window.Show();
            return;

            void AddAction(string name, Action onActivate)
            {
                var action = Gio.SimpleAction.New(name, null);
                action.OnActivate += (_, _) =>
                {
                    onActivate();
                };
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
        collection.AddTransient<HomeWindow>();
        collection.AddTransient<FlatpakRemove>();
        collection.AddTransient<FlatpakInstall>();
        collection.AddTransient<FlatpakUpdate>();
        return collection.BuildServiceProvider();
    }
}