using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.TrayServices;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.Windows.Dialog;

namespace Shelly.Gtk.Windows;

public class Settings(
    IConfigService configService,
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    ILockoutService lockoutService,
    IGenericQuestionService genericQuestionService) : IShellyWindow
{
    private Box _box = null!;
    private ShellyConfig _config = null!;

    public event Action? NavigationToHomeRequested;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/SettingWindow.ui"), -1);
        _box = (Box)builder.GetObject("SettingWindow")!;

        _config = configService.LoadConfig();

        SetupAurSwitch("aur_switch", _config.AurEnabled, (v) => _config.AurEnabled = v, builder);
        SetupFlatpakSwitch("flatpak_switch", _config.FlatPackEnabled, (v) => _config.FlatPackEnabled = v, builder);
        SetupTraySwitch("tray_switch", _config.TrayEnabled, (v) => _config.TrayEnabled = v, builder);
        SetupSwitch("no_confirm_switch", _config.NoConfirm, (v) => _config.NoConfirm = v, builder);

        var traySpin = (SpinButton)builder.GetObject("tray_interval_spin")!;
        traySpin.Value = _config.TrayCheckIntervalHours;
        traySpin.OnValueChanged += (s, e) =>
        {
            _config.TrayCheckIntervalHours = (int)traySpin.Value;
            SaveConfig();
        };

        var syncButton = (Button)builder.GetObject("sync_button")!;
        syncButton.OnClicked += (s, e) => { _ = ForceSyncAsync(); };

        var saveButton = (Button)builder.GetObject("save_button")!;
        saveButton.OnClicked += (s, e) => { NavigationToHomeRequested?.Invoke(); };

        var removeLockButton = (Button)builder.GetObject("rm_db_lock_button")!;
        removeLockButton.OnClicked += (s, e) => { _ = RemoveDbLockAsync(); };

        var versionLabel = (Label)builder.GetObject("version_label")!;
        versionLabel.SetLabel(
            $"v{System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "Unknown"}");

        return _box;
    }

    private void SetupSwitch(string id, bool initialValue, Action<bool> updateAction, Builder builder)
    {
        var sw = (Switch)builder.GetObject(id)!;
        sw.Active = initialValue;
        sw.OnStateSet += (s, e) =>
        {
            updateAction(e.State);
            SaveConfig();
            return false;
        };
    }

    private void SetupAurSwitch(string id, bool initialValue, Action<bool> updateAction, Builder builder)
    {
        var sw = (Switch)builder.GetObject(id)!;
        sw.Active = initialValue;
        sw.OnStateSet += (s, e) =>
        {
            if (e.State && !_config.AurWarningConfirmed)
            {
                _ = HandleAurConfirmationAsync(sw, updateAction);
                return true;
            }

            updateAction(e.State);
            SaveConfig();
            return false;
        };
    }

    private void SetupTraySwitch(string id, bool initialValue, Action<bool> updateAction, Builder builder)
    {
        var sw = (Switch)builder.GetObject(id)!;
        sw.Active = initialValue;
        sw.OnStateSet += (s, e) =>
        {
            if (e.State)
            {
                TrayStartService.Start();
            }
            else
            {
                TrayStartService.End();
            }
            
            return false;
        };
    }

    private void SetupFlatpakSwitch(string id, bool initialValue, Action<bool> updateAction, Builder builder)
    {
        var sw = (Switch)builder.GetObject(id)!;
        sw.Active = initialValue;
        sw.OnStateSet += (s, e) =>
        {
            if (!e.State)
            {
                updateAction(false);
                SaveConfig();
                return false;
            }
            
            _ = HandleFlatpakMissingAsync(sw, updateAction);
            return true;
        };
    }


    private async Task HandleAurConfirmationAsync(Switch sw, Action<bool> updateAction)
    {
        var args = new GenericQuestionEventArgs(
            "Enable AUR?",
            "The Arch User Repository (AUR) is a community-driven repository. " +
            "Packages are user-produced and may contain risks. Do you want to enable it?"
        );

        genericQuestionService.RaiseQuestion(args);
        var confirmed = await args.ResponseTask;

        GLib.Functions.IdleAdd(0, () =>
        {
            if (confirmed)
            {
                _config.AurWarningConfirmed = true;
                updateAction(true);
                SaveConfig();
                sw.Active = true;
                sw.State = true;
            }
            else
            {
                sw.Active = false;
                sw.State = false;
            }
            return false;
        });
    }

    private async Task HandleFlatpakMissingAsync(Switch sw, Action<bool> updateAction)
    {
        var result = await privilegedOperationService.IsPackageInstalledOnMachine("flatpak");

        if (!result)
        {
            var args = new GenericQuestionEventArgs(
                "Missing Flatpak",
                "Would you like to install this this now?"
            );

            genericQuestionService.RaiseQuestion(args);
            var confirmed = await args.ResponseTask;

            if (confirmed)
            {
                try
                {
                    lockoutService.Show("Installing flatpak...");
                    await privilegedOperationService.InstallPackagesAsync(["flatpak"]);
                    GLib.Functions.IdleAdd(0, () =>
                    {
                        updateAction(true);
                        SaveConfig();
                        sw.Active = true;
                        sw.State = true;
                        return false;
                    });
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Error installing flatpak: {ex.Message}");
                    GLib.Functions.IdleAdd(0, () =>
                    {
                        sw.Active = false;
                        sw.State = false;
                        return false;
                    });
                }
                finally
                {
                    lockoutService.Hide();
                }
            }
            else
            {
                GLib.Functions.IdleAdd(0, () =>
                {
                    sw.Active = false;
                    sw.State = false;
                    return false;
                });
            }
        }
        else
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                updateAction(true);
                SaveConfig();
                sw.Active = true;
                sw.State = true;
                return false;
            });
        }
    }

    private void SaveConfig()
    {
        configService.SaveConfig(_config);
    }

    private async Task ForceSyncAsync()
    {
        try
        {
            lockoutService.Show("Synchronizing databases...");
            await privilegedOperationService.SyncDatabasesAsync();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error syncing databases: {ex.Message}");
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private async Task RemoveDbLockAsync()
    {
        var result = await privilegedOperationService.RemoveDbLockAsync();

        if (result.Success)
        {
            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs("Database lock removed"));
        }
        else
        {
            Console.Error.WriteLine($"Failed to remove database lock: {result.Error}");
        }
    }
    
    public void Dispose()
    {
    }
}