using System.Text;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.GTK.Resources;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.TrayServices;
using Shelly.Gtk.UiModels;
using System.Text.Json;
using Gdk;
using Shelly.Gtk.Windows.Dialog;
using Shelly.Utilities;
using Shelly.Utilities.Enums;
using DateTime = System.DateTime;
using Functions = GLib.Functions;
using TimeSpan = System.TimeSpan;

namespace Shelly.Gtk.Windows;

public sealed class Settings(
    IConfigService configService,
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    ILockoutService lockoutService,
    IGenericQuestionService genericQuestionService,
    IDirtyService dirtyService) : IShellyWindow, IReloadable
{
    public const string TrayServiceContent =
        """
        [Unit]
        Description=Shelly Notifications tray service
        After=graphical-session.target

        [Service]
        Type=simple
        ExecStart=/usr/bin/shelly-notifications
        Restart=on-failure
        RestartSec=5s

        [Install]
        WantedBy=graphical-session.target
        """;

    private Box _box = null!;
    private ShellyConfig _config = null!;
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.Config];
    private Overlay? _parentOverlay;
    private static readonly (string? Culture, string Label)[] LanguageOptions =
    [
        (null, "Follow system language"),
        ("bg_BG", "Bulgarian"),
        ("ca", "Català"),
        ("de_DE", "Deutsch"),
        ("es", "Español"),
        ("fr_FR", "Français"),
        ("hu_HU", "Magyar"),
        ("ja_JP", "日本語"),
        ("pl", "Polski"),
        ("pt_BR", "Português (Brasil)"),
        ("pt_PT", "Português (Portugal)"),
        ("ru_RU", "Русский"),
        ("tr_TR", "Türkçe"),
        ("zh_CN", "中文（简体）")
    ];
    private static List<ReleaseNotesDialog.ReleaseItem>? _cachedReleaseList;
    private static string? _cachedLatestVersion;
    private static DateTime _lastVersionCheck = DateTime.MinValue;
    private static readonly TimeSpan VersionCheckInterval = TimeSpan.FromMinutes(5);

    private static readonly HttpClient HttpClient = new()
    {
        DefaultRequestHeaders = { UserAgent = { Http.UserAgent } }
    };

    public event Action? NavigationToPackages;
    public event Action<ShellyConfig>? ConfigChanged;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/SettingWindow.ui"), -1);
        _box = (Box)builder.GetObject("SettingWindow")!;

        _config = configService.LoadConfig();
        _parentOverlay = (Overlay)builder.GetObject("SettingsOverlay")!;

        SetupAurSwitch("aur_switch", _config.AurEnabled, (v) => _config.AurEnabled = v, builder);
        SetupFlatpakSwitch("flatpak_switch", _config.FlatPackEnabled, (v) => _config.FlatPackEnabled = v, builder);
        SetupTraySwitch("tray_switch", _config.TrayEnabled, (v) => _config.TrayEnabled = v, builder);
        SetupWeeklyScheduleSwitch("daily_schedule", _config.UseWeeklySchedule, (v) => _config.UseWeeklySchedule = v,
            builder);
        SetupSwitch("no_confirm_switch", _config.NoConfirm, (v) => _config.NoConfirm = v, builder);
        SetupSwitch("remove_cache_switch", _config.RemoveCache, (v) => _config.RemoveCache = v, builder);
        SetupSwitch("webview_switch", _config.WebViewEnabled, (v) => _config.WebViewEnabled = v, builder);
        SetupSwitch("shelly_icons_switch", _config.ShellyIconsEnabled, (v) => _config.ShellyIconsEnabled = v, builder);
        SetupSwitch("recommended_switch", _config.RecommendedEnabled, (v) => _config.RecommendedEnabled = v, builder);
        SetupSwitch("appimage_switch", _config.AppImageEnabled, (v) => _config.AppImageEnabled = v, builder);
        SetupSwitch("symbolic_tray_switch", _config.UseSymbolicTray, (v) => _config.UseSymbolicTray = v, builder);
        SetupSwitch("shelly_search_switch", _config.ShellySearchEnabled, (v) => _config.ShellySearchEnabled = v,
            builder);
        SetupSwitch("package_downgrade_switch", _config.PackageDowngradeEnabled, (v) => _config.PackageDowngradeEnabled = v,
            builder);
        SetupSwitch("use_old_menu_switch", !_config.UseOldMenu, (v) => _config.UseOldMenu = !v, builder);
        SetupTrayAutoStart("tray_auto_switch", _config.TrayAutoStart, (v) => _config.TrayAutoStart = v, builder);

        var parallelDownloadsSpin = (SpinButton)builder.GetObject("parallel_downloads_spin")!;
        parallelDownloadsSpin.Value = _config.ParallelDownloadCount;
        parallelDownloadsSpin.OnValueChanged += (_, _) =>
        {
            _config.ParallelDownloadCount = (int)parallelDownloadsSpin.Value;
            SaveConfig();
        };

        var traySpin = (SpinButton)builder.GetObject("tray_interval_spin")!;
        traySpin.Value = _config.TrayCheckIntervalHours;
        traySpin.OnValueChanged += (_, _) =>
        {
            _config.TrayCheckIntervalHours = (int)traySpin.Value;
            SaveConfig();
        };

        SetupDayCheckbox("day_sun_check", DayOfWeek.Sunday, builder);
        SetupDayCheckbox("day_mon_check", DayOfWeek.Monday, builder);
        SetupDayCheckbox("day_tue_check", DayOfWeek.Tuesday, builder);
        SetupDayCheckbox("day_wed_check", DayOfWeek.Wednesday, builder);
        SetupDayCheckbox("day_thu_check", DayOfWeek.Thursday, builder);
        SetupDayCheckbox("day_fri_check", DayOfWeek.Friday, builder);
        SetupDayCheckbox("day_sat_check", DayOfWeek.Saturday, builder);

        var hourSpin = (SpinButton)builder.GetObject("update_hour_spin")!;
        var minuteSpin = (SpinButton)builder.GetObject("update_minute_spin")!;

        if (_config.Time.HasValue)
        {
            hourSpin.Value = _config.Time.Value.Hour;
            minuteSpin.Value = _config.Time.Value.Minute;
        }

        hourSpin.OnValueChanged += (_, _) =>
        {
            _config.Time = new TimeOnly((int)hourSpin.Value, (int)minuteSpin.Value);
            SaveConfig();
        };

        minuteSpin.OnValueChanged += (_, _) =>
        {
            _config.Time = new TimeOnly((int)hourSpin.Value, (int)minuteSpin.Value);
            SaveConfig();
        };

        var syncButton = (Button)builder.GetObject("sync_button")!;
        syncButton.OnClicked += (_, _) => { _ = ForceSyncAsync(); };

        var saveButton = (Button)builder.GetObject("save_button")!;
        saveButton.OnClicked += (_, _) => { OnSaveClicked(); };

        var removeLockButton = (Button)builder.GetObject("rm_db_lock_button")!;
        removeLockButton.OnClicked += (_, _) => { _ = RemoveDbLockAsync(); };

        _sub = DirtySubscription.Attach(dirtyService, this);

        var viewChangelogButton = (Button)builder.GetObject("changelog_button")!;
        viewChangelogButton.OnClicked += async (_, _) => { await ShowAppChangelogAsync(); };

        var purifyCorruptionButton = (Button)builder.GetObject("purify_button")!;
        purifyCorruptionButton.TooltipText = Translations.T("Remove corrupted packages");
        purifyCorruptionButton.OnClicked += async (_, _) => { await PurifyCorruption(); };

        var fixPermissionsButton = (Button)builder.GetObject("fix_permissions_button")!;
        fixPermissionsButton.OnClicked += async (_, _) => { await FixXdgPermissionsAsync(); };

        var viewPacfilesButton = (Button)builder.GetObject("view_pacfiles_button")!;
        viewPacfilesButton.OnClicked += async (_, _) => { await ViewPacfilesAsync(); };

        var versionLabel = (Label)builder.GetObject("version_label")!;
        versionLabel.SetLabel(
            $"v{System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version?.ToString(4) ?? "Unknown"}");

        var languageDropDown = (DropDown)builder.GetObject("language_drop")!;
        PopulateLanguageDropDown(languageDropDown);

        var defaultPageDropDown = (DropDown)builder.GetObject("default_page_drop")!;
        PopulateDefaultPageDropDown(defaultPageDropDown);

        var trayIconButton = (Button)builder.GetObject("tray_icon_button")!;
        if (!string.IsNullOrEmpty(_config.TrayIconPath))
        {
            trayIconButton.Label = Path.GetFileName(_config.TrayIconPath);
        }

        var appImageInstallPathButton = (Button)builder.GetObject("appimage_install_path_button")!;
        if (!string.IsNullOrEmpty(_config.AppImageInstallPath))
        {
            appImageInstallPathButton.Label = _config.AppImageInstallPath;
        }

        appImageInstallPathButton.OnClicked += async (_, _) =>
        {
            var folderChooser = FileDialog.New();
            folderChooser.Title = Translations.T("Select AppImage Install Directory");
            try
            {
                var folder = await folderChooser.SelectFolderAsync(null);
                if (folder != null)
                {
                    var path = folder.GetPath();
                    if (!string.IsNullOrEmpty(path))
                    {
                        _config.AppImageInstallPath = path;
                        appImageInstallPathButton.Label = path;
                        SaveConfig();
                    }
                }
            }
            catch
            {
                // Cancelled
            }
        };

        trayIconButton.OnClicked += async (_, _) =>
        {
            var results = await SetupFileSelector(trayIconButton);
            if (string.IsNullOrEmpty(results)) return;
            _config.TrayIconPath = results;
            SaveConfig();
        };

        var trayIconClearButton = (Button)builder.GetObject("tray_icon_clear_button")!;
        trayIconClearButton.OnClicked += (_, _) =>
        {
            _config.TrayIconPath = null;
            trayIconButton.Label = Translations.T("Select File");
            SaveConfig();
        };

        var trayUpdatesIconButton = (Button)builder.GetObject("tray_updates_icon_button")!;
        if (!string.IsNullOrEmpty(_config.TrayUpdatesIconPath))
        {
            trayUpdatesIconButton.Label = Path.GetFileName(_config.TrayUpdatesIconPath);
        }

        trayUpdatesIconButton.OnClicked += async (_, _) =>
        {
            var results = await SetupFileSelector(trayUpdatesIconButton);
            if (string.IsNullOrEmpty(results)) return;
            _config.TrayUpdatesIconPath = results;
            SaveConfig();
        };

        var trayUpdatesIconClearButton = (Button)builder.GetObject("tray_updates_icon_clear_button")!;
        trayUpdatesIconClearButton.OnClicked += (_, _) =>
        {
            _config.TrayUpdatesIconPath = null;
            trayUpdatesIconButton.Label = Translations.T("Select File");
            SaveConfig();
        };

        defaultPageDropDown.OnNotify += (_, args) =>
        {
            if (args.Pspec.GetName() != "selected") return;
            if (_isPopulatingDropDown) return;
            if (_availablePages.Count == 0) return;
            var selectedIndex = defaultPageDropDown.Selected;
            if (selectedIndex >= _availablePages.Count) return;
            var selectedPage = _availablePages[(int)selectedIndex];
            if (selectedPage == _config.DefaultPageDropDown) return;
            _config.DefaultPageDropDown = selectedPage;
            SaveConfig();
        };

        languageDropDown.OnNotify += (_, args) =>
        {
            if (args.Pspec.GetName() != "selected") return;
            if (_isPopulatingLanguageDropDown) return;
            if (languageDropDown.Selected >= (uint)LanguageOptions.Length) return;

            var selectedOption = LanguageOptions[(int)languageDropDown.Selected];
            var normalizedCulture = string.IsNullOrWhiteSpace(selectedOption.Culture) ? null : selectedOption.Culture;
            if (string.Equals(_config.Culture, normalizedCulture, StringComparison.OrdinalIgnoreCase)) return;

            _config.Culture = normalizedCulture;
            SaveConfig();
            genericQuestionService.RaiseToastMessage(
                new ToastMessageEventArgs(Translations.T("Restart Shelly to apply the selected language.")));
        };

        var aurSwitch = (Switch)builder.GetObject("aur_switch")!;
        var flatpakSwitch = (Switch)builder.GetObject("flatpak_switch")!;
        var appImageSwitch = (Switch)builder.GetObject("appimage_switch")!;
        var shellySearchSwitch = (Switch)builder.GetObject("shelly_search_switch")!;
        var recommendedSwitch = (Switch)builder.GetObject("recommended_switch")!;

        aurSwitch.OnNotify += (_, a) => { if (a.Pspec.GetName() == "active") PopulateDefaultPageDropDown(defaultPageDropDown); };
        flatpakSwitch.OnNotify += (_, a) => { if (a.Pspec.GetName() == "active") PopulateDefaultPageDropDown(defaultPageDropDown); };
        appImageSwitch.OnNotify += (_, a) => { if (a.Pspec.GetName() == "active") PopulateDefaultPageDropDown(defaultPageDropDown); };
        shellySearchSwitch.OnNotify += (_, a) => { if (a.Pspec.GetName() == "active") PopulateDefaultPageDropDown(defaultPageDropDown); };
        recommendedSwitch.OnNotify += (_, a) => { if (a.Pspec.GetName() == "active") PopulateDefaultPageDropDown(defaultPageDropDown); };

        return _box;
    }

    private List<ShellyTabs> _availablePages = [];
    private bool _isPopulatingDropDown;
    private bool _isPopulatingLanguageDropDown;

    private void PopulateLanguageDropDown(DropDown dropDown)
    {
        _isPopulatingLanguageDropDown = true;
        try
        {
            var labels = LanguageOptions
                .Select(option => option.Culture is null ? Translations.T(option.Label) : option.Label)
                .ToArray();
            var stringList = StringList.New(labels);
            dropDown.SetModel(stringList);

            var currentIndex = 0;
            if (!string.IsNullOrWhiteSpace(_config.Culture))
            {
                var matchedIndex = Array.FindIndex(
                    LanguageOptions,
                    option => string.Equals(option.Culture, _config.Culture, StringComparison.OrdinalIgnoreCase));
                if (matchedIndex >= 0)
                {
                    currentIndex = matchedIndex;
                }
            }

            dropDown.Selected = (uint)currentIndex;
        }
        finally
        {
            _isPopulatingLanguageDropDown = false;
        }
    }

    private void PopulateDefaultPageDropDown(DropDown dropDown)
    {
        _isPopulatingDropDown = true;
        try
        {
            var pages = new List<string>();
            _availablePages = [];

            pages.Add(Translations.T("Packages"));
            _availablePages.Add(ShellyTabs.Packages);

            if (_config.RecommendedEnabled)
            {
                pages.Add(Translations.T("Recommend"));
                _availablePages.Add(ShellyTabs.Recommend);
            }

            if (_config.AurEnabled)
            {
                pages.Add(Translations.T("AUR"));
                _availablePages.Add(ShellyTabs.Aur);
            }

            if (_config.FlatPackEnabled)
            {
                pages.Add(Translations.T("Flatpak"));
                _availablePages.Add(ShellyTabs.Flatpak);
            }

            if (_config.AppImageEnabled)
            {
                pages.Add(Translations.T("AppImage"));
                _availablePages.Add(ShellyTabs.AppImage);
            }

            if (_config.ShellySearchEnabled)
            {
                pages.Add(Translations.T("Shelly Search"));
                _availablePages.Add(ShellyTabs.ShellySearch);
            }

            var stringList = StringList.New(pages.ToArray());
            dropDown.SetModel(stringList);

            var currentIndex = _availablePages.IndexOf(_config.DefaultPageDropDown);
            if (currentIndex != -1)
            {
                dropDown.Selected = (uint)currentIndex;
            }
            else
            {
                dropDown.Selected = 0; // Fallback to Packages
                _config.DefaultPageDropDown = ShellyTabs.Packages;
            }
        }
        finally
        {
            _isPopulatingDropDown = false;
        }
    }

    private void OnSaveClicked()
    {
        SaveConfig();
        NavigationToPackages?.Invoke();
    }

    private static async Task<string?> SetupFileSelector(Button button)
    {
        var dialog = FileDialog.New();
        dialog.Title = Translations.T("Select Icon File");

        var initialFolder = Gio.FileHelper.NewForPath("/usr/share/icons/hicolor/");
        dialog.InitialFolder = initialFolder;

        var filter = FileFilter.New();
        filter.Name = Translations.T("Image Files");
        filter.AddPattern("*.png");
        filter.AddPattern("*.svg");
        filter.AddPattern("*.ico");

        var listModel = Gio.ListStore.New(FileFilter.GetGType());
        listModel.Append(filter);
        dialog.Filters = listModel;

        try
        {
            var file = await dialog.OpenAsync(null);
            if (file == null) return null;

            var path = file.GetPath();

            if (string.IsNullOrEmpty(path)) return null;

            button.Label = Path.GetFileName(path);
            return path;
        }
        catch (Exception)
        {
            // Cancelled
        }

        return null;
    }

    private void SetupSwitch(string id, bool initialValue, Action<bool> updateAction, Builder builder)
    {
        var sw = (Switch)builder.GetObject(id)!;
        sw.Active = initialValue;
        sw.OnStateSet += (_, e) =>
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
    
    private void SetupTrayAutoStart(string id, bool initialValue, Action<bool> updateAction, Builder builder)
    {
        var sw = (Switch)builder.GetObject(id)!;
        sw.Active = initialValue;
        sw.OnStateSet += (_, e) =>
        {
            if (e.State)
            {
                unprivilegedOperationService.AddSystemdServiceTray(TrayServiceContent, "shelly-notifications");
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(Translations.T("Systemd startup service added.")));
            }
            else
            {
                unprivilegedOperationService.RemoveSystemdServiceTray("shelly-notifications");
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(Translations.T("Systemd startup service removed.")));
            }

            updateAction(e.State);
            SaveConfig();
            return false;
        };
    }

    private void SetupTraySwitch(string id, bool initialValue, Action<bool> updateAction, Builder builder)
    {
        var sw = (Switch)builder.GetObject(id)!;
        var autoStartBox = (Box)builder.GetObject("tray_auto_switch_box")!;
        var autoStartSwitch = (Switch)builder.GetObject("tray_auto_switch")!;
        var trayIntervalBox = (Box)builder.GetObject("tray_interval_box")!;
        var symbolicTrayBox = (Box)builder.GetObject("symbolic_tray_box")!;
        var weeklyScheduleSwitchBox = (Box)builder.GetObject("weekly_schedule_switch_box")!;
        var weeklyScheduleBox = (Box)builder.GetObject("weekly_schedule_box")!;
        var weeklyScheduleSwitch = (Switch)builder.GetObject("daily_schedule")!;

        sw.Active = initialValue;

        // Set initial visibility
        weeklyScheduleSwitchBox.Visible = initialValue;
        symbolicTrayBox.Visible = initialValue;
        autoStartBox.Visible = initialValue;

        // tray interval is visible only if tray enabled AND weekly schedule disabled
        trayIntervalBox.Visible = initialValue && !weeklyScheduleSwitch.Active;
        weeklyScheduleBox.Visible = initialValue && weeklyScheduleSwitch.Active;

        sw.OnStateSet += (_, e) =>
        {
            if (e.State) TrayStartService.Start();
            else TrayStartService.End();

            weeklyScheduleSwitchBox.Visible = e.State;
            symbolicTrayBox.Visible = e.State;

            autoStartBox.Visible = e.State;
            if (!e.State) autoStartSwitch.Active = false;

            trayIntervalBox.Visible = e.State && !weeklyScheduleSwitch.Active;
            weeklyScheduleBox.Visible = e.State && weeklyScheduleSwitch.Active;

            updateAction(e.State);
            SaveConfig();

            return false;
        };
    }

    private void SetupWeeklyScheduleSwitch(string id, bool initialValue, Action<bool> updateAction, Builder builder)
    {
        var sw = (Switch)builder.GetObject(id)!;
        var trayIntervalBox = (Box)builder.GetObject("tray_interval_box")!;
        var weeklyScheduleBox = (Box)builder.GetObject("weekly_schedule_box")!;
        var traySwitch = (Switch)builder.GetObject("tray_switch")!;

        sw.Active = initialValue;

        if (traySwitch.Active)
        {
            trayIntervalBox.Visible = !initialValue;
            weeklyScheduleBox.Visible = initialValue;
        }

        sw.OnStateSet += (_, e) =>
        {
            if (traySwitch.Active)
            {
                trayIntervalBox.Visible = !e.State;
                weeklyScheduleBox.Visible = e.State;
            }

            updateAction(e.State);
            SaveConfig();

            return false;
        };
    }

    private void SetupDayCheckbox(string id, DayOfWeek day, Builder builder)
    {
        var checkbox = (CheckButton)builder.GetObject(id)!;
        checkbox.Active = _config.DaysOfWeek.Contains(day);

        checkbox.OnToggled += (_, _) =>
        {
            if (checkbox.Active)
            {
                if (!_config.DaysOfWeek.Contains(day))
                {
                    _config.DaysOfWeek.Add(day);
                }
            }
            else
            {
                _config.DaysOfWeek.Remove(day);
            }

            SaveConfig();
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
            Translations.T("Enable AUR?"),
            Translations.T("The Arch User Repository (AUR) is a community-driven repository. " +
            "Packages are user-produced and may contain risks. Do you want to enable it?")
        );

        genericQuestionService.RaiseQuestion(args);
        var confirmed = await args.ResponseTask;

        Functions.IdleAdd(0, () =>
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
        var result = await unprivilegedOperationService.IsPackageInstalledOnMachine("flatpak");

        if (!result)
        {
            var args = new GenericQuestionEventArgs(
                Translations.T("Missing Flatpak"),
                Translations.T("Would you like to install this this now?")
            );

            genericQuestionService.RaiseQuestion(args);
            var confirmed = await args.ResponseTask;

            if (confirmed)
            {
                try
                {
                    lockoutService.Show(Translations.T("Installing flatpak..."));
                    await privilegedOperationService.InstallPackagesAsync(["flatpak"]);
                    Functions.IdleAdd(0, () =>
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
                    Functions.IdleAdd(0, () =>
                    {
                        sw.Active = false;
                        sw.State = false;
                        return false;
                    });
                }
                finally
                {
                    lockoutService.Hide();
                    genericQuestionService.RaiseToastMessage(
                        new ToastMessageEventArgs(Translations.T("Reboot required to complete installation.")));
                }
            }
            else
            {
                Functions.IdleAdd(0, () =>
                {
                    sw.Active = false;
                    sw.State = false;
                    return false;
                });
            }
        }
        else
        {
            Functions.IdleAdd(0, () =>
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
        ConfigChanged?.Invoke(_config);
    }

    private async Task ForceSyncAsync()
    {
        try
        {
            lockoutService.Show(Translations.T("Synchronizing databases..."));
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
            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(Translations.T("Database lock removed")));
        }
        else
        {
            await Console.Error.WriteLineAsync($"Failed to remove database lock: {result.Error}");
        }
    }

    private async Task FixXdgPermissionsAsync()
    {
        try
        {
            var result = await privilegedOperationService.FixXdgPermissionsAsync();

            if (result.Success)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(Translations.T("Shelly folder ownership restored")));
            }
            else
            {
                await Console.Error.WriteLineAsync($"Failed to fix Shelly folder ownership: {result.Error}");
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(Translations.T("Failed to fix folder permissions")));
            }
        }
        catch (Exception ex)
        {
            await Console.Error.WriteLineAsync($"Error fixing Shelly folder permissions: {ex.Message}");
            genericQuestionService.RaiseToastMessage(
                new ToastMessageEventArgs(Translations.T("Error fixing folder permissions")));
        }
    }

    private async Task PurifyCorruption()
    {
        var result = await privilegedOperationService.PurifyCorruptionAsync();
        if (result.Success)
        {
            var purifyBox = Box.NewWithProperties([]);
            purifyBox.SetOrientation(Orientation.Vertical);
            purifyBox.SetSpacing(12);
            purifyBox.SetSizeRequest(500, -1);
            var title = Label.NewWithProperties([]);
            title.SetText(Translations.T("Purified Corruption"));
            title.AddCssClass("title-2");
            title.SetHalign(Align.Center);
            purifyBox.Append(title);
            var scroll = ScrolledWindow.NewWithProperties([]);
            scroll.HscrollbarPolicy = PolicyType.Never;
            scroll.VscrollbarPolicy = PolicyType.Automatic;
            scroll.SetOverlayScrolling(false);
            scroll.SetSizeRequest(-1, 400);
            var list = Box.NewWithProperties([]);
            list.SetOrientation(Orientation.Vertical);
            list.SetSpacing(8);
            var output = result.Output != "\n" ? result.Output.Split(",").ToList() : [Translations.T("No corrupted packages found")];
            foreach (var pkg in output)
            {
                var text = Label.NewWithProperties([]);
                text.SetText(pkg);
                text.AddCssClass("text");
                list.Append(text);
            }

            scroll.SetChild(list);
            purifyBox.Append(scroll);
            genericQuestionService.RaiseDialog(new GenericDialogEventArgs(purifyBox));
        }
    }

    private async Task ViewPacfilesAsync()
    {
        var pacfiles = await unprivilegedOperationService.GetPacFiles();
        if (pacfiles.Count == 0)
        {
            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(Translations.T("No pacfiles found")));
            return;
        }

        Functions.IdleAdd(0, () =>
        {
            var pacfileBox = Box.NewWithProperties([]);
            pacfileBox.SetOrientation(Orientation.Vertical);
            pacfileBox.SetSpacing(12);
            pacfileBox.SetSizeRequest(620, -1);

            var title = Label.NewWithProperties([]);
            title.SetText(Translations.T("Pacfiles Found"));
            title.AddCssClass("title-2");
            title.SetHalign(Align.Center);
            pacfileBox.Append(title);

            var scroll = ScrolledWindow.NewWithProperties([]);
            scroll.HscrollbarPolicy = PolicyType.Never;
            scroll.VscrollbarPolicy = PolicyType.Automatic;
            scroll.SetOverlayScrolling(false);
            scroll.SetSizeRequest(-1, 400);

            var list = Box.NewWithProperties([]);
            list.SetOrientation(Orientation.Vertical);
            list.SetSpacing(8);

            foreach (var pacfile in pacfiles)
            {
                var itemBox = Box.NewWithProperties([]);
                itemBox.SetOrientation(Orientation.Vertical);
                itemBox.SetSpacing(4);
                itemBox.SetMarginBottom(16);

                var headerBox = Box.NewWithProperties([]);
                headerBox.SetOrientation(Orientation.Horizontal);
                headerBox.SetSpacing(8);

                var nameLabel = Label.NewWithProperties([]);
                nameLabel.SetMarkup($"<b>{pacfile.Name}</b>");
                nameLabel.SetHalign(Align.Start);
                nameLabel.SetHexpand(true);
                headerBox.Append(nameLabel);

                var copyButton = Button.NewFromIconName("edit-copy-symbolic");
                copyButton.SetTooltipText(Translations.T("Copy content"));
                copyButton.AddCssClass("flat");
                copyButton.OnClicked += (_, _) =>
                {
                    var clipboard = Display.GetDefault()!.GetClipboard();
                    clipboard.SetText(pacfile.Text);
                    genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(Translations.T("Copied to clipboard")));
                };
                headerBox.Append(copyButton);

                itemBox.Append(headerBox);

                var textView = TextView.New();
                textView.Editable = false;
                textView.CursorVisible = false;
                textView.WrapMode = WrapMode.None;
                textView.Monospace = true;

                textView.GetBuffer().SetText(pacfile.Text, pacfile.Text.Length);

                var textScroll = ScrolledWindow.New();
                textScroll.SetSizeRequest(-1, 200);
                textScroll.SetPolicy(PolicyType.Automatic, PolicyType.Automatic);
                textScroll.SetChild(textView);
                textScroll.AddCssClass("rounded-card");
                textScroll.SetLimitEvents(true);

                itemBox.Append(textScroll);
                list.Append(itemBox);
            }

            scroll.SetChild(list);
            pacfileBox.Append(scroll);
            genericQuestionService.RaiseDialog(new GenericDialogEventArgs(pacfileBox));
            return false;
        });
    }

    private async Task ShowAppChangelogAsync()
    {
        if (_parentOverlay is null)
        {
            Console.WriteLine("Parent overlay is null");
            genericQuestionService.RaiseToastMessage(
                new ToastMessageEventArgs(Translations.T("Overlay not available")));
            return;
        }

        try
        {
            if (_cachedReleaseList is not null &&
                DateTime.UtcNow - _lastVersionCheck < VersionCheckInterval)
            {
                Console.WriteLine("Cached releases used (skipping version check)");
                ReleaseNotesDialog.ShowReleaseHistoryDialog(_parentOverlay, _cachedReleaseList);
                return;
            }

            HttpClient.DefaultRequestHeaders.UserAgent.Add(Http.UserAgent);

            var url = "https://api.github.com/repos/Seafoam-Labs/Shelly-ALPM/releases";
            var latestJson = await HttpClient.GetStringAsync($"{url}/latest");
            _lastVersionCheck = DateTime.UtcNow;
            using var latestDoc = JsonDocument.Parse(latestJson);
            var latestTag = latestDoc.RootElement
                .TryGetProperty("tag_name", out var tagProp)
                ? tagProp.GetString()
                : null;

            if (_cachedReleaseList is not null && latestTag == _cachedLatestVersion)
            {
                Console.WriteLine("Cached Releases used");
                ReleaseNotesDialog.ShowReleaseHistoryDialog(_parentOverlay, _cachedReleaseList);
                return;
            }

            var json = await HttpClient.GetStringAsync(url);
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;

            if (root.ValueKind != JsonValueKind.Array || root.GetArrayLength() == 0)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(Translations.T("No changelog entries found")));
                return;
            }

            var releases = new List<ReleaseNotesDialog.ReleaseItem>();

            foreach (var release in root.EnumerateArray())
            {
                var version = release.TryGetProperty("tag_name", out var tagNameProp)
                    ? tagNameProp.GetString() ?? Translations.T("Unknown")
                    : Translations.T("Unknown");

                var markdown = release.TryGetProperty("body", out var bodyProp)
                    ? bodyProp.GetString() ?? Translations.T("No details for this release")
                    : Translations.T("No details for this release");

                var publishedAtRaw = release.TryGetProperty("published_at", out var publishedAtProp)
                    ? publishedAtProp.GetString()
                    : null;

                var date = DateTimeOffset.TryParse(publishedAtRaw, out var published)
                    ? published.ToString("yyyy-MM-dd")
                    : Translations.T("Unknown date");

                releases.Add(new ReleaseNotesDialog.ReleaseItem
                {
                    Version = version,
                    Date = date,
                    Markdown = string.IsNullOrWhiteSpace(markdown)
                        ? Translations.T("No details for this release")
                        : markdown
                });
            }

            if (releases.Count == 0)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(Translations.T("No changelog entries found")));
                return;
            }

            _cachedReleaseList = releases;
            _cachedLatestVersion = latestTag;

            ReleaseNotesDialog.ShowReleaseHistoryDialog(_parentOverlay, releases);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error loading changelog: {ex.Message}");
            genericQuestionService.RaiseToastMessage(
                new ToastMessageEventArgs(Translations.T("Failed to load changelog")));
        }
    }

    public void Reload()
    {
        // Refresh internal config snapshot. Visible switches retain their current
        // state to avoid re-entrant SaveConfig loops; navigating away/back rebuilds the page.
        // TODO: Find a way to sync setting switches after setup?
        _config = configService.LoadConfig();
    }

    public void Dispose()
    {
        _sub?.Dispose();
    }
}
