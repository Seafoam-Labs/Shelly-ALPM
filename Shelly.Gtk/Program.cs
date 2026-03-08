using Gtk;
using Microsoft.Extensions.DependencyInjection;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.TrayServices;
using Shelly.Gtk.Windows;
using Shelly.Gtk.Windows.AUR;
using Shelly.Gtk.Windows.Dialog;
using Shelly.Gtk.Windows.Flatpak;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Windows.Packages;
using Shelly.Gtk.UiModels;
using Settings = Shelly.Gtk.Windows.Settings;

namespace Shelly.Gtk;

sealed class Program
{
    public static int Main(string[] args)
    {
        ServiceCollection serviceCollection = new();
        var serviceProvider = ServiceBuilder.CreateDependencyInjection(serviceCollection);

        var application = Application.New("com.shellyorg.shelly", Gio.ApplicationFlags.DefaultFlags);

        application.OnActivate += (sender, _) =>
        {
            //Tray service will need to be update to point at GTK Install
            //or tray service will need to know if avalonia or GTK started it.
            //TrayStartService.Start();
            
            var cssProvider = CssProvider.New();
            cssProvider.LoadFromString(ResourceHelper.LoadAsset("Assets/style.css"));
            StyleContext.AddProviderForDisplay(Gdk.Display.GetDefault()!, cssProvider, 800);

            var mainBuilder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/MainWindow.ui"), -1);
            var window = (ApplicationWindow)mainBuilder.GetObject("MainWindow")!;

            window.SetIconName("shelly");
            window.Application = application;

            var menuBuilder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/MainMenu.ui"), -1);
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
            var mainSearchEntry = (SearchEntry)mainBuilder.GetObject("MainSearchEntry")!;
            var aurMenuButton = (MenuButton)mainBuilder.GetObject("AurMenuButton")!;
            var flatpakMenuButton = (MenuButton)mainBuilder.GetObject("FlatpakMenuButton")!;

            var configService = serviceProvider.GetRequiredService<IConfigService>();
            var initialConfig = configService.LoadConfig();

            aurMenuButton.Visible = initialConfig.AurEnabled;
            flatpakMenuButton.Visible = initialConfig.FlatPackEnabled;

            configService.ConfigSaved += (_, updatedConfig) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    aurMenuButton.Visible = updatedConfig.AurEnabled;
                    flatpakMenuButton.Visible = updatedConfig.FlatPackEnabled;
                    return false;
                });
            };

            IShellyWindow? currentPage = null;

            homeButton.OnClicked += (_, _) => NavigateTo<HomeWindow>();
            settingsButton.OnClicked += (_, _) => NavigateTo<Settings>();

            mainSearchEntry.OnActivate += (_, _) =>
            {
                var query = mainSearchEntry.GetText();
                if (string.IsNullOrWhiteSpace(query)) return;
                
                NavigateWithQuery<MetaSearch>(query);
                mainSearchEntry.SetText(string.Empty);
            };

            AddAction("install-packages", NavigateTo<PackageInstall>);
            AddAction("update-packages", NavigateTo<PackageUpdate>); // Placeholder
            AddAction("manage-packages", NavigateTo<PackageManagement>);

            AddAction("install-aur", NavigateTo<AurInstall>);
            AddAction("update-aur", NavigateTo<AurUpdate>); 
            AddAction("remove-aur", NavigateTo<AurRemove>); 
            
            AddAction("install-flatpak", NavigateTo<FlatpakInstall>);
            AddAction("update-flatpak", NavigateTo<FlatpakUpdate>);
            AddAction("remove-flatpak", NavigateTo<FlatpakRemove>);

            var initialHomeWindow = serviceProvider.GetRequiredService<HomeWindow>();
            contentArea.Append(initialHomeWindow.CreateWindow());
            currentPage = initialHomeWindow;

            var mainOverlay = (Overlay)mainBuilder.GetObject("MainOverlay")!;
            var lockoutOverlay = (Box)mainBuilder.GetObject("LockoutOverlay")!;
            var lockoutDescription = (Label)mainBuilder.GetObject("LockoutDescription")!;
            var lockoutProgressBar = (ProgressBar)mainBuilder.GetObject("LockoutProgressBar")!;

            //Subscribing to credential required to trigger the password dialog
            var credentialManager = serviceProvider.GetRequiredService<ICredentialManager>();
            credentialManager.CredentialRequested += (s, e) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    var dialog = serviceProvider.GetRequiredService<PasswordDialog>();
                    dialog.ShowPasswordDialog(mainOverlay, e.Reason);
                    return false;
                });
            };
            
            var alpmEventService = serviceProvider.GetRequiredService<IAlpmEventService>();
            alpmEventService.Question += (s, e) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    var dialog = serviceProvider.GetRequiredService<AlpmEventDialog>();
                    AlpmEventDialog.ShowAlpmEventDialog(mainOverlay, e);
                    return false;
                });
            };

            var genericQuestionService = serviceProvider.GetRequiredService<IGenericQuestionService>();
            genericQuestionService.Question += (s, e) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    GenericQuestionDialog.ShowGenericQuestionDialog(mainOverlay, e);
                    return false;
                });
            };


            window.Show();

            var lockoutService = serviceProvider.GetRequiredService<ILockoutService>();

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

            void NavigateTo<T>() where T : IShellyWindow
            {
                NavigateWithQuery<T>(null);
            }

            void NavigateWithQuery<T>(string? query) where T : IShellyWindow
            {
                currentPage?.Dispose();

                while (contentArea.GetFirstChild() is { } child)
                {
                    contentArea.Remove(child);
                    child.Unparent();
                }

                var page = serviceProvider.GetRequiredService<T>();
                if (page is MetaSearch metaSearch && query != null)
                {
                    contentArea.Append(metaSearch.CreateWindow(query));
                }
                else
                {
                    contentArea.Append(page.CreateWindow());
                }
                currentPage = page;
            }

            void AddAction(string name, Action onActivate)
            {
                var action = Gio.SimpleAction.New(name, null);
                action.OnActivate += (_, _) => { onActivate(); };
                application.AddAction(action);
            }
        };

        return application.Run(args);
    }
}