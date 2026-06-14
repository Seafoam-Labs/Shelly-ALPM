using Gdk;
using Gio;
using Gtk;
using Pango;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AppImage;
using Shelly.Gtk.Windows.Dialog;
using Shelly.Utilities;
using static Shelly.GTK.Resources.Translations;
using File = System.IO.File;
using Functions = GLib.Functions;
using ListStore = Gio.ListStore;
using Task = System.Threading.Tasks.Task;

namespace Shelly.Gtk.Windows;

public sealed class AppImage(
    IPrivilegedOperationService privilegedOperationService,
    IUnprivilegedOperationService unprivilegedOperationService,
    IGenericQuestionService genericQuestionService,
    ILockoutService lockoutService,
    IDirtyService dirtyService) : IShellyWindow, IReloadable
{
    private List<AppImageDto> _appImages = [];
    private ListBox _appListBox = null!;

    private Label _detailDescriptionLabel = null!;
    private Image _detailIcon = null!;
    private ScrolledWindow _detailPage = null!;
    private Label _detailSizeLabel = null!;
    private Label _detailTitleLabel = null!;
    private Label _detailVersionLabel = null!;
    private Box _dropZone = null!;
    private DropTarget _fileDropTarget = null!;
    private Entry _installPathEntry = null!;
    private Entry _launchFlagsEntry = null!;
    private CheckButton _allowPrereleaseCheckButton = null!;
    private Box _listPage = null!;
    private ScrolledWindow _appImageListWindow = null!;
    private SearchEntry _searchEntry = null!;
    private AppImageDto? _selectedApp;
    private DirtySubscription? _sub;
    private DropDown _updateTypeDropDown = null!;
    private Entry _updateUrlEntry = null!;
    private Label _updateUrlErrorLabel = null!;
    private Box _migrationOverlay = null!;
    private Button _startMigrationButton = null!;
    private Button _syncButton = null!;
    private Button _syncAllButton = null!;
    private Button _backButton = null!;
    private Button _saveButton = null!;
    private Button _removeButton = null!;
    private Button _installButton = null!;
    private Button _upgradeAllButton = null!;

    public string[] ListensTo => [DirtyScopes.AppImage, DirtyScopes.Config];

    public void Reload()
    {
        _ = LoadDataAsync();
    }

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/AppImage.ui"), -1);
        builder.TranslationDomain = Domain;
        _listPage = (Box)builder.GetObject("AppImagePage")!;
        _detailPage = (ScrolledWindow)builder.GetObject("AppImageDetailView")!;
        _appListBox = (ListBox)builder.GetObject("AppImageListBox")!;
        _searchEntry = (SearchEntry)builder.GetObject("AppImageSearchEntry")!;
        _updateTypeDropDown = (DropDown)builder.GetObject("UpdateTypeDropDown")!;
        _updateUrlEntry = (Entry)builder.GetObject("UpdateUrlEntry")!;
        _updateUrlErrorLabel = (Label)builder.GetObject("UpdateUrlErrorLabel")!;
        _allowPrereleaseCheckButton = (CheckButton)builder.GetObject("AllowPrereleaseCheckButton")!;
        _migrationOverlay = (Box)builder.GetObject("MigrationOverlay")!;
        _startMigrationButton = (Button)builder.GetObject("StartMigrationButton")!;
        _installPathEntry = (Entry)builder.GetObject("InstallPathEntry")!;
        _launchFlagsEntry = (Entry)builder.GetObject("LaunchFlagsEntry")!;
        _detailTitleLabel = (Label)builder.GetObject("DetailTitleLabel")!;
        _detailVersionLabel = (Label)builder.GetObject("DetailVersionLabel")!;
        _detailDescriptionLabel = (Label)builder.GetObject("DetailDescriptionLabel")!;
        _detailSizeLabel = (Label)builder.GetObject("DetailSizeLabel")!;
        _detailIcon = (Image)builder.GetObject("DetailIcon")!;

        _appImageListWindow = (ScrolledWindow)builder.GetObject("AppImageListWindow")!;
        _dropZone = (Box)builder.GetObject("DropZone")!;

        _syncButton = (Button)builder.GetObject("SyncButton")!;
        _syncAllButton = (Button)builder.GetObject("SyncAllButton")!;

        _backButton = (Button)builder.GetObject("BackToListButton")!;
        _saveButton = (Button)builder.GetObject("SaveConfigButton")!;
        _removeButton = (Button)builder.GetObject("RemoveAppImageButton")!;
        _installButton = (Button)builder.GetObject("InstallAppImageButton")!;
        _upgradeAllButton = (Button)builder.GetObject("UpgradeAllButton")!;

        var overlay = (Overlay)builder.GetObject("AppImageOverlay")!;
        var mainBox = (Box)builder.GetObject("AppImagePageMain")!;

        _detailPage.SetVisible(false);
        mainBox.Append(_detailPage);

        SetupFileDrop();

        var model = StringList.New([
            T("None"),
            T("StaticUrl"),
            T("GitHub"),
            T("GitLab"),
            T("Codeberg"),
            T("Forgejo")
        ]);
        _updateTypeDropDown.Model = model;

        _searchEntry.OnSearchChanged += (_, _) => FilterList();
        _appListBox.OnRowActivated += (_, args) =>
        {
            var index = 0;
            var current = _appListBox.GetFirstChild();
            while (current != null && current != args.Row)
            {
                current = current.GetNextSibling();
                index++;
            }

            if (index < _appImages.Count)
                ShowDetailPage(_appImages[index]);
        };
        _backButton.OnClicked += (_, _) => ShowListPage();
        _saveButton.OnClicked += (_, _) => SaveConfig();
        _removeButton.OnClicked += (_, _) => RemoveAppImage();
        _installButton.OnClicked += (_, _) => InstallAppImage();
        _upgradeAllButton.OnClicked += (_, _) => UpgradeAll();
        _syncButton.OnClicked += (_, _) => SyncAppImage();
        _syncAllButton.OnClicked += (_, _) => SyncAllAppImages();
        _startMigrationButton.OnClicked += (_, _) => StartMigration();

        _ = LoadDataAsync();
        _sub = DirtySubscription.Attach(dirtyService, this);

        return overlay;
    }

    public void Dispose()
    {
        _sub?.Dispose();
        _appListBox.RemoveAll();
        _fileDropTarget.Unref();
    }

    private async Task LoadDataAsync()
    {
        const string legacyInstallDir = "/opt/shelly";
        var legacyLocalDbDir = XdgPaths.ShellyCache("appimage-local-meta-store", "appimage-metadata.db");

        var needsMigration =  File.Exists(legacyLocalDbDir);

        if (needsMigration)
        {
            Functions.IdleAdd(0, () =>
            {
                _appListBox.SetVisible(false);
                _migrationOverlay.SetVisible(true);
                SetButtonsSensitive(false);
                return false;
            });
        }
        else
        {
            Functions.IdleAdd(0, () =>
            {
                _migrationOverlay.SetVisible(false);
                SetButtonsSensitive(true);
                return false;
            });
        }

        var appImages = await unprivilegedOperationService.GetInstallAppImagesAsync();

        Functions.IdleAdd(0, () =>
        {
            _appImages = appImages;
            _appListBox.RemoveAll();

            foreach (var row in _appImages.Select(CreateAppRow)) _appListBox.Append(row);

            _dropZone.SetVisible(_appImages.Count == 0);

            return false;
        });
    }

    private void SetButtonsSensitive(bool sensitive)
    {
        _syncButton.Sensitive = sensitive;
        _syncAllButton.Sensitive = sensitive;
        _backButton.Sensitive = sensitive;
        _saveButton.Sensitive = sensitive;
        _removeButton.Sensitive = sensitive;
        _installButton.Sensitive = sensitive;
        _upgradeAllButton.Sensitive = sensitive;
    }

    private bool ValidateUpdateConfig()
    {
        var updateType = (AppImageUpdateType)_updateTypeDropDown.Selected;
        var updateUrl = _updateUrlEntry.GetText();

        var isValid = true;

        if (updateType is AppImageUpdateType.GitHub or AppImageUpdateType.GitLab or AppImageUpdateType.Codeberg
            or AppImageUpdateType.Forgejo)
        {
            if (string.IsNullOrWhiteSpace(updateUrl) || updateUrl.Count(c => c == '/') != 1 ||
                updateUrl.StartsWith('/') || updateUrl.EndsWith('/'))
            {
                isValid = false;
                _updateUrlErrorLabel.SetText(T("Invalid format. Use owner/repo (e.g. seafoam-labs/shelly-alpm)"));
                _updateUrlErrorLabel.SetVisible(true);
                _updateUrlEntry.AddCssClass("error");
            }
            else
            {
                _updateUrlErrorLabel.SetVisible(false);
                _updateUrlEntry.RemoveCssClass("error");
            }
        }
        else if (updateType == AppImageUpdateType.StaticUrl)
        {
            if (string.IsNullOrWhiteSpace(updateUrl) || !updateUrl.StartsWith("http"))
            {
                isValid = false;
                _updateUrlErrorLabel.SetText(T("Invalid URL. Must start with http:// or https://"));
                _updateUrlErrorLabel.SetVisible(true);
                _updateUrlEntry.AddCssClass("error");
            }
            else
            {
                _updateUrlErrorLabel.SetVisible(false);
                _updateUrlEntry.RemoveCssClass("error");
            }
        }
        else
        {
            _updateUrlErrorLabel.SetVisible(false);
            _updateUrlEntry.RemoveCssClass("error");
        }

        return isValid;
    }

    private static Widget CreateAppRow(AppImageDto app)
    {
        var row = ListBoxRow.New();
        row.Activatable = true;
        var hbox = Box.New(Orientation.Horizontal, 12);
        hbox.MarginStart = 12;
        hbox.MarginEnd = 12;
        hbox.MarginTop = 8;
        hbox.MarginBottom = 8;

        var icon = Image.New();
        icon.PixelSize = 32;

        var iconFilePath = ResolveIconFilePath(app.IconName);
        if (iconFilePath != null)
            try
            {
                var texture = Texture.NewFromFilename(iconFilePath);
                icon.SetFromPaintable(texture);
            }
            catch
            {
                icon.SetFromIconName(string.IsNullOrEmpty(app.IconName)
                    ? "application-x-executable-symbolic"
                    : app.IconName);
            }
        else
            icon.SetFromIconName(
                string.IsNullOrEmpty(app.IconName) ? "application-x-executable-symbolic" : app.IconName);

        hbox.Append(icon);

        var vbox = Box.New(Orientation.Vertical, 2);
        vbox.Hexpand = true;

        var nameLabel = Label.New(app.DesktopName);
        nameLabel.AddCssClass("title-4");
        nameLabel.Xalign = 0;
        vbox.Append(nameLabel);

        var versionLabel = Label.New(app.Version);
        versionLabel.AddCssClass("caption");
        versionLabel.AddCssClass("dim-label");
        versionLabel.Xalign = 0;
        vbox.Append(versionLabel);

        if (!string.IsNullOrEmpty(app.Description))
        {
            var descriptionLabel = Label.New(app.Description);
            descriptionLabel.AddCssClass("caption");
            descriptionLabel.AddCssClass("dim-label");
            descriptionLabel.Xalign = 0;
            descriptionLabel.Ellipsize = EllipsizeMode.End;
            descriptionLabel.MaxWidthChars = 50;
            vbox.Append(descriptionLabel);
        }

        hbox.Append(vbox);

        row.SetChild(hbox);
        return row;
    }

    private static string? ResolveIconFilePath(string? iconName)
    {
        if (string.IsNullOrEmpty(iconName)) return null;

        string[] searchDirs =
        [
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".local/share/icons/hicolor/256x256/apps"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".local/share/icons/hicolor/scalable/apps"),
            "/usr/share/icons/hicolor/256x256/apps",
            "/usr/share/icons/hicolor/scalable/apps"
        ];

        foreach (var dir in searchDirs)
        {
            if (!Directory.Exists(dir)) continue;
            var matches = Directory.GetFiles(dir, $"{iconName}.*");
            if (matches.Length > 0) return matches[0];
        }

        return null;
    }

    private void FilterList()
    {
        var query = _searchEntry.GetText().ToLower();
        var index = 0;
        for (var row = _appListBox.GetFirstChild(); row != null; row = row.GetNextSibling())
        {
            if (row is not ListBoxRow listBoxRow) continue;
            var app = _appImages[index++];
            listBoxRow.SetVisible(app.DesktopName.ToLower().Contains(query));
        }
    }

    private async void InstallAppImage()
    {
        var fileChooser = FileDialog.New();
        fileChooser.Title = T("Select AppImage to Install");

        var filter = FileFilter.New();
        filter.Name = T("AppImage Files");
        filter.AddPattern("*.AppImage");
        filter.AddPattern("*.appimage");

        var listModel = ListStore.New(FileFilter.GetGType());
        listModel.Append(filter);
        fileChooser.Filters = listModel;

        try
        {
            var file = await fileChooser.OpenAsync(null);
            if (file == null) return;
            var filePath = file.GetPath();
            if (string.IsNullOrEmpty(filePath)) return;

            await InstallAppImageFromPathAsync(filePath);
        }
        catch (Exception)
        {
            // User cancelled or error
        }
    }

    private async void UpgradeAll()
    {
        try
        {
            var resultUnpriv = await unprivilegedOperationService.GetUpdatesAppImagesAsync();

            if (resultUnpriv.Count == 0)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("No AppImages need to be upgraded")));
                return;
            }

            lockoutService.Show(T("Running updates..."));

            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(T("Updating AppImages...")));
            var result = await unprivilegedOperationService.AppImageUpgradeAsync();

            if (result.Success)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("All AppImages updated successfully!")));
                await LoadDataAsync();
            }
            else
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Failed to update AppImages: {0}", result.Error)));
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to update AppImages: {ex.Message}");
        }
        finally
        {
            lockoutService.Hide();
        }
    }
    

    private void ShowListPage()
    {
        _listPage.SetVisible(true);
        _detailPage.SetVisible(false);
    }

    private void ShowDetailPage(AppImageDto app)
    {
        _selectedApp = app;
        _detailTitleLabel.SetText(app.DesktopName);
        _detailVersionLabel.SetText(string.Format(T("Version {0}"), app.Version));
        _detailDescriptionLabel.SetText(app.Description);
        _detailSizeLabel.SetText(SizeHelpers.FormatSize(app.SizeOnDisk));
        var detailIconFilePath = ResolveIconFilePath(app.IconName);
        if (detailIconFilePath != null)
            try
            {
                var texture = Texture.NewFromFilename(detailIconFilePath);
                _detailIcon.SetFromPaintable(texture);
            }
            catch
            {
                _detailIcon.IconName = string.IsNullOrEmpty(app.IconName)
                    ? "application-x-executable-symbolic"
                    : app.IconName;
            }
        else
            _detailIcon.IconName =
                string.IsNullOrEmpty(app.IconName) ? "application-x-executable-symbolic" : app.IconName;

        _updateTypeDropDown.Selected = (uint)app.UpdateType;
        var updateInfo = "";
        if (!string.IsNullOrEmpty(app.UpdateURl))
        {
            updateInfo = app.UpdateURl;
        }

        if (!string.IsNullOrEmpty(app.RepoOwner) && !string.IsNullOrEmpty(app.RepoName))
        {
            updateInfo = app.RepoOwner + "/" + app.RepoName;
        }

        _updateUrlEntry.SetText(updateInfo);
        _updateUrlErrorLabel.SetVisible(false);
        _updateUrlEntry.RemoveCssClass("error");
        _allowPrereleaseCheckButton.Active = app.AllowPrerelease;
        _installPathEntry.SetText(app.Path ?? "");
        _launchFlagsEntry.SetText(app.CommandLineArgs ?? "");

        _listPage.SetVisible(false);
        _detailPage.SetVisible(true);
    }

    private async void SaveConfig()
    {
        try
        {
            if (_selectedApp == null) return;
            if (!ValidateUpdateConfig()) return;

            var updateType = (AppImageUpdateType)_updateTypeDropDown.Selected;
            var updateUrl = _updateUrlEntry.GetText();
            var allowPrerelease = _allowPrereleaseCheckButton.Active;

            var result =
                await unprivilegedOperationService.AppImageConfigureUpdatesAsync(updateUrl, _selectedApp.Name,
                    updateType, allowPrerelease);

            if (result.Success)
            {
                _selectedApp.UpdateType = updateType;
                _selectedApp.UpdateURl = updateUrl;
                _selectedApp.AllowPrerelease = allowPrerelease;
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Configuration saved for {0}", _selectedApp.Name)));
                ShowListPage();
                await LoadDataAsync();
            }
            else
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Failed to save configuration: {0}", result.Error)));
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to save AppImage configuration: {ex.Message}");
        }
    }

    private async void SyncAppImage()
    {
        try
        {
            if (_selectedApp == null) return;

            lockoutService.Show(string.Format(T("Syncing {0}..."), _selectedApp.Name));

            var result =
                await unprivilegedOperationService.AppImageSyncApp(_selectedApp.Name);

            if (result.Success)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Synced {0}", _selectedApp.Name)));
                await LoadDataAsync();
            }
            else
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Failed to sync: {0}", result.Error)));
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to save AppImage configuration: {ex.Message}");
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private async void SyncAllAppImages()
    {
        try
        {
            lockoutService.Show(T("Syncing all AppImages ..."));

            var result =
                await unprivilegedOperationService.AppImageSyncAll();

            if (result.Success)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Synced")));
                await LoadDataAsync();
            }
            else
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Failed to sync: {0}", result.Error)));
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to save AppImage configuration: {ex.Message}");
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private async void RemoveAppImage()
    {
        try
        {
            if (_selectedApp == null) return;

            var args = RemoveConfigDialogue.BuildRemoveDialog();

            genericQuestionService.RaiseDialog(args);

            var message = await args.ResponseTask;
            bool removeConfig;
            switch (message)
            {
                case ConfigRemoveEnum.Cancel:
                    return;
                case ConfigRemoveEnum.KeepConfig:
                    removeConfig = false;
                    break;
                case ConfigRemoveEnum.RemoveConfig:
                    removeConfig = true;
                    break;
                default:
                    throw new ArgumentOutOfRangeException();
            }

            lockoutService.Show(string.Format(T("Removing {0}..."), _selectedApp.Name));

            var result = await unprivilegedOperationService.AppImageRemoveAsync(_selectedApp.Name, removeConfig);

            if (result.Success)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("{0} removed successfully!", _selectedApp.Name)));
                await LoadDataAsync();
                ShowListPage();
            }
            else
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Failed to remove {0}: {1}", _selectedApp.Name, result.Error)));
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Failed to remove AppImage: {ex.Message}");
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private void SetupFileDrop()
    {
        _fileDropTarget = DropTarget.New(FileHelper.GetGType(), DragAction.Copy);

        _fileDropTarget.OnDrop += OnFileDrop;
        _fileDropTarget.OnEnter += (_, _) =>
        {
            _dropZone.AddCssClass("drag-hover");
            return DragAction.Copy;
        };
        _fileDropTarget.OnLeave += (_, _) => { _dropZone.RemoveCssClass("drag-hover"); };

        _appImageListWindow.AddController(_fileDropTarget);
    }

    private bool OnFileDrop(DropTarget dropTarget, DropTarget.DropSignalArgs args)
    {
        var handle = FileHelper.NewFromPointer(args.Value.PeekPointer(), false);
        var filePath = handle.GetPath();

        if (string.IsNullOrEmpty(filePath))
            return false;

        if (!filePath.EndsWith(".appimage", StringComparison.OrdinalIgnoreCase))
        {
            genericQuestionService.RaiseToastMessage(
                new ToastMessageEventArgs(T("Only AppImage files are supported")));
            return false;
        }

        _ = InstallAppImageFromPathAsync(filePath);

        return true;
    }

    private async void StartMigration()
    {
        try
        {
            lockoutService.Show(T("Migrating AppImages to V2..."));
            var result = await privilegedOperationService.MigrateAppImagesAsync();

            if (result.Success)
            {
                genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(T("Migration successful!")));
                Functions.IdleAdd(0, () =>
                {
                    _migrationOverlay.SetVisible(false);
                    _appListBox.SetVisible(true);
                    SetButtonsSensitive(true);
                    return false;
                });
                await LoadDataAsync();
            }
            else
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Migration failed: {0}", result.Error)));
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Migration failed: {ex.Message}");
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private async Task InstallAppImageFromPathAsync(string filePath)
    {
        try
        {
            lockoutService.Show(T("Installing AppImage..."));

            var result = await unprivilegedOperationService.AppImageInstallAsync(filePath);

            if (result.Success)
            {
                var basename = Path.GetFileName(filePath);
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("{0} installed successfully!", basename)));
                await LoadDataAsync();
            }
            else
            {
                var basename = Path.GetFileName(filePath);
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(T("Failed to install {0}: {1}", basename, result.Error)));
            }
        }
        catch (Exception)
        {
            // Handle silently
        }
        finally
        {
            lockoutService.Hide();
        }
    }
}