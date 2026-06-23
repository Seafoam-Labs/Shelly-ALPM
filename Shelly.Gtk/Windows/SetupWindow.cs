using GdkPixbuf;
using Gio;
using GLib;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Utilities.Enums;
using static Shelly.GTK.Resources.Translations;
using Functions = GLib.Functions;
using Task = System.Threading.Tasks.Task;

namespace Shelly.Gtk.Windows;

public sealed class SetupWindow(
    IConfigService configService,
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    ILockoutService lockoutService,
    IGenericQuestionService genericQuestionService) : IShellyWindow
{
    private Box _box = null!;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/SetupWindow.ui"), -1);
        _box = (Box)builder.GetObject("SetupWindow")!;

        var aurCheck = (CheckButton)builder.GetObject("aur_check")!;
        var flatpakCheck = (CheckButton)builder.GetObject("flatpak_check")!;
        var appimageCheck = (CheckButton)builder.GetObject("appimage_check")!;
        var trayCheck = (CheckButton)builder.GetObject("tray_check")!;
        var trayAutoCheck = (CheckButton)builder.GetObject("tray_autostart_check")!;
        var navCheck = (CheckButton)builder.GetObject("nav_check")!;
        var autoStartBox = (ListBoxRow)builder.GetObject("tray_autostart_box")!;
        var finishButton = (Button)builder.GetObject("finish_button")!;

        try
        {
            var introImage = (Image)builder.GetObject("intro_image")!;
            using var stream = ResourceHelper.GetResourceStream("Assets/chel-intro.png");
            using var ms = new MemoryStream();
            stream.CopyTo(ms);
            var gioStream = MemoryInputStream.NewFromBytes(Bytes.New(ms.ToArray()));
            var pixbuf = Pixbuf.NewFromStream(gioStream, null)!;
            introImage.SetFromPixbuf(pixbuf);
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
        autoStartBox.Visible = trayCheck.Active;
        navCheck.Active = !currentConfig.UseOldMenu;
        trayAutoCheck.Active = currentConfig.TrayAutoStart;

        aurCheck.OnToggled += async (_, _) =>
            await HandleAurConfirmationAsync(aurCheck, config => aurCheck.Active = config);

        trayCheck.OnToggled += (_, _) => autoStartBox.SetVisible(trayCheck.Active);

        finishButton.OnClicked += async (_, _) =>
        {
            var config = configService.LoadConfig();
            config.AurEnabled = aurCheck.Active;
            config.AurWarningConfirmed = aurCheck.Active;
            config.FlatPackEnabled = flatpakCheck.Active;
            config.AppImageEnabled = appimageCheck.Active;
            config.TrayEnabled = trayCheck.Active;
            config.UseOldMenu = !navCheck.Active;
            config.TrayAutoStart = trayAutoCheck.Active;
            config.NewInstallInitSettings = true;
            config.NewInstall = false;
            config.PackageInstallView = ViewType.Grid;
            config.PackageUpdateView = ViewType.Grid;
            config.PackageManageView = ViewType.Grid;

            try
            {
                SetupFinished?.Invoke(this, EventArgs.Empty);

                if (trayAutoCheck.Active)
                    try
                    {
                        await unprivilegedOperationService.AddSystemdServiceTray(Settings.TrayServiceContent,
                            "shelly-notifications");
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine(T($"Error adding systemd service: {ex.Message}"));
                        config.TrayAutoStart = false;
                    }

                if (!flatpakCheck.Active) return;
                try
                {
                    var result = await unprivilegedOperationService.IsPackageInstalledOnMachine("flatpak");
                    if (result) return;

                    lockoutService.Show(T("Installing flatpak..."));

                    var installResult = await privilegedOperationService.InstallPackagesAsync(["flatpak"]);
                    if (installResult.Success)
                    {
                        genericQuestionService.RaiseToastMessage(
                            new ToastMessageEventArgs(T("Reboot required after flatpak installation.")));
                    }
                    else
                    {
                        Console.WriteLine(T("Failed to install flatpak"));
                        config.FlatPackEnabled = false;
                    }
                }
                catch (Exception ex)
                {
                    genericQuestionService.RaiseToastMessage(
                        new ToastMessageEventArgs(T("Reboot required after flatpak installation.")));
                    Console.WriteLine(T($"Error installing flatpak: {ex.Message}"));
                    config.FlatPackEnabled = false;
                }
                finally
                {
                    lockoutService.Hide();
                }
            }
            finally
            {
                configService.SaveConfig(config);
            }
        };

        return _box;
    }

    public void Dispose()
    {
        _box.Unparent();
    }

    private async Task HandleAurConfirmationAsync(CheckButton check, Action<bool> updateAction)
    {
        if (!check.Active) return;

        var args = new GenericQuestionEventArgs(
            T("Enable AUR?"),
            T("The Arch User Repository (AUR) is a community-driven repository. " +
              "Packages are user-produced and may contain risks. Do you want to enable it?")
        );

        genericQuestionService.RaiseQuestion(args);
        var confirmed = await args.ResponseTask;

        Functions.IdleAdd(0, () =>
        {
            if (confirmed)
            {
                updateAction(true);
                check.Active = true;
            }
            else
            {
                check.Active = false;
            }

            return false;
        });
    }

    public event EventHandler? SetupFinished;
}