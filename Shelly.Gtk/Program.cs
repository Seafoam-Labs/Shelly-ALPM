using System.Reflection;
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
using Settings = Shelly.Gtk.Windows.Settings;


namespace Shelly.Gtk;

sealed class Program
{
    public static int Main(string[] args)
    {
        ServiceCollection serviceCollection = new();
        var serviceProvider = ServiceBuilder.CreateDependencyInjection(serviceCollection);
        
        var application = Application.New(ShellyConstants.Service, Gio.ApplicationFlags.DefaultFlags);
        
        
        application.OnActivate += (sender, _) =>
        {
            if(serviceProvider!.GetService<IConfigService>()!.LoadConfig().TrayEnabled)
                TrayStartService.Start();
            
            var existingWindow = application.GetActiveWindow();
            if (existingWindow != null) {
                existingWindow.Present();
                return;
            }
            
            var cssProvider = CssProvider.New();
            cssProvider.LoadFromString(ResourceHelper.LoadAsset("Assets/style.css"));
            StyleContext.AddProviderForDisplay(Gdk.Display.GetDefault()!, cssProvider, 800);

            var iconTheme = IconTheme.GetForDisplay(Gdk.Display.GetDefault()!);
            iconTheme.AddSearchPath("Assets/svg");
            
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

            // Set icons with fallbacks for AUR and Flatpak buttons
            var aurChild = aurMenuButton.GetChild();
            if (aurChild != null)
            {
                var aurBox = (Box)aurChild;
                var aurImage = (Image)aurBox.GetFirstChild()!;
                //If your theme icon is missing at to the list of strings here without the file extension and it will pick it up
                aurImage.IconName = ImageHelper.GetIconWithFallback("arch-symbolic", "distributor-logo-arch", "distributor-logo-archlinux");
            }
            var flatpakChild = flatpakMenuButton.GetChild();
            if (flatpakChild != null)
            {
                var flatpakBox = (Box)flatpakChild;
                var flatpakImage = (Image)flatpakBox.GetFirstChild()!;
                //If your theme icon is missing at to the list of strings here without the file extension and it will pick it up
                flatpakImage.IconName = ImageHelper.GetIconWithFallback("flatpak-symbolic", "flatpak", "flatpak-logo", "folder-flatpak-symbolic", "application-vnd.flatpak");
            }

            var configService = serviceProvider.GetRequiredService<IConfigService>();
            var initialConfig = configService.LoadConfig();

            aurMenuButton.Visible = initialConfig.AurEnabled;
            flatpakMenuButton.Visible = initialConfig.FlatPackEnabled;
           
            //Setting window height
            window.DefaultHeight = double.ConvertToInteger<int>(initialConfig.WindowHeight);
            window.DefaultWidth = double.ConvertToInteger<int>(initialConfig.WindowWidth);
            uint resizeTimerId = 0;

            window.OnNotify += (_, args) =>
            {
                if (args.Pspec.GetName() is not ("default-width" or "default-height")) return;
                if (resizeTimerId != 0)
                    GLib.Functions.SourceRemove(resizeTimerId);

                resizeTimerId = GLib.Functions.TimeoutAdd(0, 500, () =>
                {
                    var config = configService.LoadConfig();
                    config.WindowWidth = window.DefaultWidth;
                    config.WindowHeight = window.DefaultHeight;
                    configService.SaveConfig(config);
                    resizeTimerId = 0;
                    return false;
                });
            };

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

            genericQuestionService.PackageBuildRequested += (s, e) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    PackageBuildDialog.ShowPackageBuildDialog(mainOverlay, e);
                    return false;
                });
            };
            
            genericQuestionService.ToastMessageRequested += (s, e) =>
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    ToastMessageDialog.ShowToastMessage(mainOverlay, e);
                    return false;
                });
            };


            window.Show();

            if (Assembly.GetExecutingAssembly().GetName().Version != configService.LoadConfig().CurrentVersion)
            {
                if (!configService.LoadConfig().NewInstall)
                {
                    var notes = new GitHubUpdateService(credentialManager).PullReleaseNotesAsync();
                    ReleaseNotesDialog.ShowReleaseNotesDialog(mainOverlay, notes.Result);
                    
                    var config = configService.LoadConfig();
                    config.CurrentVersion = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0,0,0);
                    configService.SaveConfig(config);
                }
                else
                {
                    var config = configService.LoadConfig();
                    config.NewInstall = false;
                    config.CurrentVersion = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0,0,0);
                    configService.SaveConfig(config);
                }
            }

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
                if (page is Settings settings)
                {
                    settings.NavigationToHomeRequested += NavigateTo<HomeWindow>;
                }
                
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