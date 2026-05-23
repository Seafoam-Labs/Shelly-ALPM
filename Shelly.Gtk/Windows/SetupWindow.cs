using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using static Shelly.GTK.Resources.Translations;

namespace Shelly.Gtk.Windows;

public class SetupWindow(
    IConfigService configService,
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unPrivilegedOperationService,
    ILockoutService lockoutService,
    IGenericQuestionService genericQuestionService) : IShellyWindow
{
    private Box _box = null!;
    public event EventHandler? SetupFinished;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/SetupWindow.ui"), -1);
        _box = (Box)builder.GetObject("SetupWindow")!;

        var aurCheck = (CheckButton)builder.GetObject("aur_check")!;
        var flatpakCheck = (CheckButton)builder.GetObject("flatpak_check")!;
        var appimageCheck = (CheckButton)builder.GetObject("appimage_check")!;
        var trayCheck = (CheckButton)builder.GetObject("tray_check")!;
        var trayAutoCheck = (CheckButton)builder.GetObject("tray_autostart_check")!;
        var finishButton = (Button)builder.GetObject("finish_button")!;
        var introImage = (Image)builder.GetObject("intro_image")!;
        var navCheck = (CheckButton)builder.GetObject("nav_check")!;
        var autoStartBox = (ListBoxRow)builder.GetObject("tray_autostart_box")!;

        try
        {
            using var stream = ResourceHelper.GetResourceStream("Assets/chel-intro.png");
            using var ms = new MemoryStream();
            stream.CopyTo(ms);
            var gioStream = Gio.MemoryInputStream.NewFromBytes(GLib.Bytes.New(ms.ToArray()));
            var pixbuf = GdkPixbuf.Pixbuf.NewFromStream(gioStream, null)!;
            var texture = Gdk.Texture.NewForPixbuf(pixbuf);
            introImage.SetFromPaintable(texture);
        }
        catch (Exception ex)
        {
            Console.WriteLine(T($"Error loading intro image: {ex.Message}"));
        }

        var currentConfig = configService.LoadConfig();
        aurCheck.Active = currentConfig.AurEnabled;
        flatpakCheck.Active = currentConfig.FlatPackEnabled;
        appimageCheck.Active = currentConfig.AppImageEnabled;
        trayCheck.Active = currentConfig.TrayEnabled;
        navCheck.Active = !currentConfig.UseOldMenu;
        trayAutoCheck.Active = true;

        trayCheck.OnToggled += (_, _) => { autoStartBox.SetVisible(trayCheck.Active); };

        finishButton.OnClicked += async (_, _) =>
        {
            var config = configService.LoadConfig();
            config.AurEnabled = aurCheck.Active;
            config.FlatPackEnabled = flatpakCheck.Active;
            config.AppImageEnabled = appimageCheck.Active;
            config.TrayEnabled = trayCheck.Active;
            config.UseOldMenu = !navCheck.Active;
            config.NewInstallInitSettings = true;
            config.NewInstall = false;
            config.TrayAutoStart = trayAutoCheck.Active;

            configService.SaveConfig(config);
            SetupFinished?.Invoke(this, EventArgs.Empty);

            if (trayAutoCheck.Active)
            {
                try
                {
                    const string serviceContent = $"""
                                                   [Unit]
                                                   Description=Shelly Notifications tray service
                                                   PartOf=default.target

                                                   [Service]
                                                   Type=simple
                                                   ExecStart=/usr/bin/shelly-notifications
                                                   Restart=on-failure
                                                   RestartSec=5s

                                                   [Install]
                                                   WantedBy=default.target
                                                   """;

                    _ = unPrivilegedOperationService.AddSystemdServiceTray(serviceContent, "shelly-notifications");
                }
                catch (Exception ex)
                {
                    Console.WriteLine(T($"Error adding systemd service: {ex.Message}"));
                }
            }


            if (!flatpakCheck.Active) return;
            try
            {
                var result = await privilegedOperationService.IsPackageInstalledOnMachine("flatpak");

                if (result) return;

                lockoutService.Show(T("Installing flatpak..."));
                var instalResult = await privilegedOperationService.InstallPackagesAsync(["flatpak"]);

                if (instalResult.Success)
                {
                    genericQuestionService.RaiseToastMessage(
                        new ToastMessageEventArgs(T("Reboot required after flatpak installation.")));
                }
                else
                {
                    Console.WriteLine(T($"Failed to install flatpak"));
                    config.FlatPackEnabled = false;
                    configService.SaveConfig(config);
                }
            }
            catch (Exception ex)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Reboot required after flatpak installation.")));
                Console.WriteLine(T($"Error installing flatpak: {ex.Message}"));
                config.FlatPackEnabled = false;
                configService.SaveConfig(config);
            }
            finally
            {
                lockoutService.Hide();
            }
        };

        return _box;
    }

    public void Dispose()
    {
        _box.Unparent();
    }
}