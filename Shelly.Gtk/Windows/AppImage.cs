using Gdk;
using Gio;
using Gtk;
using Pango;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AppImage;
using static Shelly.GTK.Resources.Translations;
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
    private Box _listPage = null!;
    private ScrolledWindow _appImageListWindow = null!;
    private SearchEntry _searchEntry = null!;
    private AppImageDto? _selectedApp;
    private DirtySubscription? _sub;
    private DropDown _updateTypeDropDown = null!;
    private Entry _updateUrlEntry = null!;

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
        _installPathEntry = (Entry)builder.GetObject("InstallPathEntry")!;
        _detailTitleLabel = (Label)builder.GetObject("DetailTitleLabel")!;
        _detailVersionLabel = (Label)builder.GetObject("DetailVersionLabel")!;
        _detailDescriptionLabel = (Label)builder.GetObject("DetailDescriptionLabel")!;
        _detailSizeLabel = (Label)builder.GetObject("DetailSizeLabel")!;
        _detailIcon = (Image)builder.GetObject("DetailIcon")!;

        _appImageListWindow = (ScrolledWindow)builder.GetObject("AppImageListWindow")!;
        _dropZone = (Box)builder.GetObject("DropZone")!;

        var syncButton = (Button)builder.GetObject("SyncButton")!;
        var syncAllButton = (Button)builder.GetObject("SyncAllButton")!;

        var backButton = (Button)builder.GetObject("BackToListButton")!;
        var saveButton = (Button)builder.GetObject("SaveConfigButton")!;
        var removeButton = (Button)builder.GetObject("RemoveAppImageButton")!;
        var installButton = (Button)builder.GetObject("InstallAppImageButton")!;
        var upgradeAllButton = (Button)builder.GetObject("UpgradeAllButton")!;

        var mainBox = Box.NewWithProperties([]);
        mainBox.Append(_listPage);
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
        backButton.OnClicked += (_, _) => ShowListPage();
        saveButton.OnClicked += (_, _) => SaveConfig();
        removeButton.OnClicked += (_, _) => RemoveAppImage();
        installButton.OnClicked += (_, _) => InstallAppImage();
        upgradeAllButton.OnClicked += (_, _) => UpgradeAll();
        syncButton.OnClicked += (_, _) => SyncAppImage();
        syncAllButton.OnClicked += (_, _) => SyncAllAppImages();

        _ = LoadDataAsync();
        _sub = DirtySubscription.Attach(dirtyService, this);

        return mainBox;
    }

    public void Dispose()
    {
        _sub?.Dispose();
        _appListBox.RemoveAll();
        _fileDropTarget.Unref();
    }

    private async Task LoadDataAsync()
    {
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
            var result = await privilegedOperationService.AppImageUpgradeAsync();

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
        _updateUrlEntry.SetText(app.UpdateURl);
        _installPathEntry.SetText($"/opt/shelly/{app.Name}");

        _listPage.SetVisible(false);
        _detailPage.SetVisible(true);
    }

    private async void SaveConfig()
    {
        try
        {
            if (_selectedApp == null) return;

            var updateType = (AppImageUpdateType)_updateTypeDropDown.Selected;
            var updateUrl = _updateUrlEntry.GetText();

            var result =
                await privilegedOperationService.AppImageConfigureUpdatesAsync(updateUrl, _selectedApp.Name,
                    updateType);

            if (result.Success)
            {
                _selectedApp.UpdateType = updateType;
                _selectedApp.UpdateURl = updateUrl;
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
                await privilegedOperationService.AppImageSyncApp(_selectedApp.Name);

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
                await privilegedOperationService.AppImageSyncAll();

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

            lockoutService.Show(string.Format(T("Removing {0}..."), _selectedApp.Name));

            var result = await privilegedOperationService.AppImageRemoveAsync(_selectedApp.Name);

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

    private async Task InstallAppImageFromPathAsync(string filePath)
    {
        try
        {
            lockoutService.Show(T("Installing AppImage..."));

            var result = await privilegedOperationService.AppImageInstallAsync(filePath);

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