using GObject;
using Gtk;
using Shelly.GTK.Resources;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.FlatHub;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

// ReSharper disable NotAccessedField.Local

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.Flatpak;

public class FlatpakInstall(
    IUnprivilegedOperationService unprivilegedOperationService,
    IPrivilegedOperationService privilegedOperationService,
    ILockoutService lockoutService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    IFlatHubApiService flatHubApiService,
    FlatpakUpdate flatpakUpdate,
    FlatpakManage flatpakManage,
    IDirtyService dirtyService) : IShellyWindow, IReloadable
{
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.FlatpakInstalled, DirtyScopes.Config];
    private GridView? _gridView;
    private ScrolledWindow? _scroller;
    private readonly CancellationTokenSource _cts = new();
    private Gio.ListStore? _listStore;
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
    private SingleSelection? _selectionModel;
    private SignalHandler<Button>? _versionHistoryHandler;
    private SignalHandler<Button>? _addonHistoryHandler;
    private SignalHandler<Button>? _permissionHistoryHandler;
    private ListBox? _categoryListBox;
    private List<AppstreamApp> _allPackages = [];
    private HashSet<string> _trendingApps = [];
    private HashSet<string> _popularApps = [];
    private HashSet<string> _recentlyUpdatedApps = [];
    private HashSet<string> _recentlyAddedApps = [];
    private string _searchText = string.Empty;
    private FlatpakCategories _selectedCategory = FlatpakCategories.AllApplications;
    private SignalListItemFactory? _factory;
    private Box? _overlay;
    private Box? _loadingOverlay;
    private Spinner? _loadingSpinner;
    private Button _overlayCloseButton = null!;
    private Button _overlayInstallButton = null!;
    private Button _versionHistoryButton = null!;
    private Button _permissionsButton = null!;
    private Label _overlayAuthorLabel = null!;
    private Label _overlayNameLabel = null!;
    private Label _overlayVersionLabel = null!;
    private Label _overlaySizeLabel = null!;
    private Label _overlayLicenseLabel = null!;
    private Label _overlayUrlLabel = null!;
    private Label _overlaySummaryLabel = null!;
    private Label _overlayDescriptionLabel = null!;
    private Image _overlayIconImage = null!;
    private Box? _overlayScreenshotsBox;
    private Box? _overlayBoxRoot;
    private StringList _remotesStringList = null!;
    private string? _selectedRemote = "Any";
    private DropDown _remoteDropDown = null!;
    private AppstreamApp _selectedPackage = null!;
    private ListView _listRemotes = null!;

    private Box _remoteRefOverlay = null!;
    private Box _addRemoteOverlay = null!;
    private Button _remoteRefBackButton = null!;
    private Button _addRemoteButton = null!;
    private Button _addRemoteBackButton = null!;
    private Button _addRemoteConfirmButton = null!;
    private Entry _addRemoteNameEntry = null!;
    private Entry _addRemoteUrlEntry = null!;
    private DropDown _addRemoteScopeDropDown = null!;
    private Button _deleteRemoteButton = null!;
    private Gio.ListStore? _remoteListStore;
    private SingleSelection? _remoteSelectionModel;
    private SignalListItemFactory? _remoteFactory;

    private Button _installFromFlatpakRef = null!;
    private DropDown _installFromFlatpakRefDropDown = null!;
    private string _selectedRefScope = "system";

    private Button _overlayShowPluginButton = null!;

    private CancellationTokenSource _searchDebounce = new();

    private readonly HttpClient _httpClient = new();

    private Stack? _mainContentStack;
    private Box? _installSidebarControls;
    private string _activePage = "install";

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/Flatpak/FlatpakInstallWindow.ui"), -1);
        var box = (Box)builder.GetObject("FlatpakInstallWindow")!;

        _gridView = (GridView)builder.GetObject("list_flatpaks")!;
        _scroller = _gridView.GetParent() as ScrolledWindow;
        _gridView.SetMaxColumns(4);
        _gridView.SetMinColumns(1);

        var reloadButton = (Button)builder.GetObject("reload_button")!;
        var searchEntry = (SearchEntry)builder.GetObject("search_entry")!;
        _categoryListBox = (ListBox)builder.GetObject("category_list")!;
        _overlay = (Box)builder.GetObject("overlay_panel")!;
        _loadingOverlay = (Box)builder.GetObject("loading_overlay")!;
        _loadingSpinner = (Spinner)builder.GetObject("loading_spinner")!;
        _remoteRefOverlay = (Box)builder.GetObject("overlay_remote_ref")!;
        _addRemoteOverlay = (Box)builder.GetObject("overlay_add_remote")!;
        _overlayScreenshotsBox = (Box)builder.GetObject("overlay_screenshots_box")!;
        _overlayAuthorLabel = (Label)builder.GetObject("overlay_author_label")!;
        _overlayNameLabel = (Label)builder.GetObject("overlay_name_label")!;
        _overlayVersionLabel = (Label)builder.GetObject("overlay_version_label")!;
        _overlaySizeLabel = (Label)builder.GetObject("overlay_size_label")!;
        _overlayLicenseLabel = (Label)builder.GetObject("overlay_license_label")!;
        _overlayUrlLabel = (Label)builder.GetObject("overlay_urls_label")!;
        _overlaySummaryLabel = (Label)builder.GetObject("overlay_summary_label")!;
        _overlayDescriptionLabel = (Label)builder.GetObject("overlay_description_label")!;
        _remoteDropDown = (DropDown)builder.GetObject("overlay_remote_selection")!;
        _remoteDropDown.OnNotify += (_, args) =>
        {
            if (args.Pspec.GetName() != "selected-item") return;
            var selectedItem = (StringObject)_remoteDropDown.GetSelectedItem()!;
            _selectedRemote = selectedItem.String;
        };

        _overlayCloseButton = (Button)builder.GetObject("overlay_back_button")!;
        _overlayInstallButton = (Button)builder.GetObject("overlay_install_button")!;
        _versionHistoryButton = (Button)builder.GetObject("version_history_button")!;
        _permissionsButton = (Button)builder.GetObject("overlay_permissions_button")!;
        _remoteRefBackButton = (Button)builder.GetObject("overlay_remote_back_button")!;
        _addRemoteButton = (Button)builder.GetObject("overlay_add_remote_button")!;
        _addRemoteBackButton = (Button)builder.GetObject("overlay_add_remote_back_button")!;
        _addRemoteConfirmButton = (Button)builder.GetObject("overlay_add_remote_confirm_button")!;
        _addRemoteNameEntry = (Entry)builder.GetObject("overlay_add_remote_name_entry")!;
        _addRemoteUrlEntry = (Entry)builder.GetObject("overlay_add_remote_url_entry")!;
        _addRemoteScopeDropDown = (DropDown)builder.GetObject("overlay_add_remote_scope_dropdown")!;
        _deleteRemoteButton = (Button)builder.GetObject("overlay_delete_remote_button")!;
        _overlayShowPluginButton = (Button)builder.GetObject("overlay_show_plugin_button")!;

        _installFromFlatpakRef = (Button)builder.GetObject("install_from_flatpak_ref_button")!;
        _installFromFlatpakRefDropDown = (DropDown)builder.GetObject("install_from_flatpak_ref_dropdown")!;

        _mainContentStack = (Stack)builder.GetObject("main_content_stack")!;
        _installSidebarControls = (Box)builder.GetObject("install_sidebar_controls")!;

        var updatePageBox = (Box)builder.GetObject("update_page_box")!;
        var removePageBox = (Box)builder.GetObject("remove_page_box")!;
        updatePageBox.Append(flatpakUpdate.CreateWindow());
        removePageBox.Append(flatpakManage.CreateWindow());

        var sectionNavList = (ListBox)builder.GetObject("section_nav_list")!;
        var navInstallRow = (ListBoxRow)builder.GetObject("nav_install_row")!;
        sectionNavList.SelectRow(navInstallRow);
        sectionNavList.OnRowSelected += (_, args) =>
        {
            if (args.Row is null) return;
            searchEntry.SetText(string.Empty);
            switch (args.Row.GetIndex())
            {
                case 0:
                    _activePage = "install";
                    _mainContentStack.SetVisibleChild((Widget)builder.GetObject("list_overlay")!);
                    break;
                case 1:
                    _activePage = "update";
                    _mainContentStack.SetVisibleChild(updatePageBox);
                    break;
                case 2:
                    _activePage = "remove";
                    _mainContentStack.SetVisibleChild(removePageBox);
                    break;
                case 3:
                    Task.Run(BuildAndShowRemoteRef);
                    break;
            }
        };

        _remoteListStore = Gio.ListStore.New(FlatpakRemoteGObject.GetGType());
        _remoteSelectionModel = SingleSelection.New(_remoteListStore);
        _listRemotes = (ListView)builder.GetObject("list_remotes")!;
        _listRemotes.SetModel(_remoteSelectionModel);

        _overlayInstallButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };
        _overlayInstallButton.CanFocus = true;
        _overlayInstallButton.ReceivesDefault = true;

        var shortcutController = ShortcutController.New();
        shortcutController.Scope = ShortcutScope.Global;
        shortcutController.PropagationPhase = PropagationPhase.Capture;

        var triggers = new[] { "Return", "KP_Enter", "space", "<Control>f" };
        foreach (var triggerStr in triggers)
        {
            
            var action = CallbackAction.New((_, _) =>
            {
                if (triggerStr == "<Control>f")
                {
                    searchEntry.GrabFocus();
                    return true;
                }
                if (!_overlay.GetVisible() || !_overlayInstallButton.GetSensitive()) return false;
                if (OverlayHelper.HasActiveOverlay(box)) return false;

                Task.Run(async () => await InstallSelectedAsync());
                return true;
            });
            shortcutController.AddShortcut(Shortcut.New(ShortcutTrigger.ParseString(triggerStr), action));
        }

        var backTriggers = new[] { "Escape", "<Alt>Left" };
        foreach (var triggerStr in backTriggers)
        {
            var action = CallbackAction.New((_, _) =>
            {
                var visibleChild = _mainContentStack?.GetVisibleChild();
                if (visibleChild == _addRemoteOverlay)
                {
                    _mainContentStack!.SetVisibleChild(_remoteRefOverlay);
                    return true;
                }

                if (visibleChild == _remoteRefOverlay)
                {
                    _mainContentStack!.SetVisibleChild((Widget)builder.GetObject("list_overlay")!);
                    return true;
                }

                if (_overlay.GetVisible())
                {
                    _overlay.SetVisible(false);
                    return true;
                }

                return false;
            });
            shortcutController.AddShortcut(Shortcut.New(ShortcutTrigger.ParseString(triggerStr), action));
        }

        box.AddController(shortcutController);
        
        _remoteRefBackButton.OnClicked += (_, _) => { _mainContentStack?.SetVisibleChild((Widget)builder.GetObject("list_overlay")!); };
        _installFromFlatpakRef.OnClicked += (_, _) => { _ = InstallFromFlatpakRef(); };

        _listStore = Gio.ListStore.New(FlatpakGObject.GetGType());
        _filter = PackageSearch.CreateSafeFilter(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _gridView.SetModel(_selectionModel);
        _gridView.SingleClickActivate = true;
        _factory = SignalListItemFactory.New();
        _factory.OnSetup += OnSetup;
        _factory.OnBind += OnBind;
        _factory.OnUnbind += OnUnbind;
        _gridView.SetFactory(_factory);

        _installFromFlatpakRefDropDown.OnNotify += (_, args) =>
        {
            if (args.Pspec.GetName() != "selected") return;
            var selectedIndex = _installFromFlatpakRefDropDown.GetSelected();
            _selectedRefScope = selectedIndex == 0 ? "system" : "user";
        };

        _addRemoteButton.OnClicked += (_, _) =>
        {
            _addRemoteNameEntry.SetText(string.Empty);
            _addRemoteUrlEntry.SetText(string.Empty);
            _mainContentStack?.SetVisibleChild(_addRemoteOverlay);
        };

        _addRemoteBackButton.OnClicked += (_, _) =>
        {
            _mainContentStack?.SetVisibleChild(_remoteRefOverlay);
        };

        _addRemoteConfirmButton.OnClicked += (_, _) =>
        {
            var name = _addRemoteNameEntry.GetText();
            var url = _addRemoteUrlEntry.GetText();
            var scope = _addRemoteScopeDropDown.GetSelected() == 0 ? "user" : "system";

            if (string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(url))
            {
                genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(Translations.T("Name and URL are required")));
                return;
            }

            if (!url.EndsWith(".flatpakrepo"))
            {
                genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(Translations.T("URL must end with .flatpakrepo")));
                return;
            }

            var result = unprivilegedOperationService.FlatpakAddRemote(name, scope, url).Result;

            if (!result.Success)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(Translations.T("Failed to add remote: {0}", result.Error)));
                return;
            }

            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs(Translations.T("Added Remote: {0}", name)));
            _ = RefreshRemotesList();
            _ = LoadDataAsync();
            _mainContentStack?.SetVisibleChild(_remoteRefOverlay);
        };

        _deleteRemoteButton.OnClicked += (_, _) =>
        {
            var selectedModel = _remoteSelectionModel?.GetSelectedItem();
            if (selectedModel is not FlatpakRemoteGObject remote) return;
            var result = unprivilegedOperationService
                .FlatpakRemoveRemote(remote.Remote!.Name, remote.Remote.Scope)
                .Result;

            if (!result.Success) return;
            var args = new ToastMessageEventArgs(
                Translations.T("Removed Remote")
            );
            genericQuestionService.RaiseToastMessage(args);
            _ = RefreshRemotesList();
        };

        var categories = Enum.GetNames<FlatpakCategories>();
        foreach (var category in categories)
        {
            var gtkBox = Box.New(Orientation.Horizontal, 8);

            var image = Image.New();
            image.PixelSize = 16;

            var label = Label.New(category);

            switch (category)
            {
                case "AllApplications":
                    label.SetText(Translations.T("All Applications"));
                    image.IconName = "applications-other";
                    gtkBox.Append(image);
                    break;
                case "Recommended":
                    label.SetText(Translations.T("Recommended"));
                    image.IconName = "emblem-favorite";
                    gtkBox.Append(image);
                    break;
                case "MostWanted":
                    label.SetText(Translations.T("Most Wanted"));
                    image.IconName = "starred";
                    gtkBox.Append(image);
                    break;
                case "RecentlyAdded":
                    label.SetText(Translations.T("Recently Added"));
                    image.IconName = "document-new";
                    gtkBox.Append(image);
                    break;
                case "RecentlyUpdated":
                    label.SetText(Translations.T("Recently Updated"));
                    image.IconName = "software-update-available";
                    gtkBox.Append(image);
                    break;
                case "AudioVideo":
                    label.SetText(Translations.T("Audio & Video"));
                    image.IconName = "applications-multimedia";
                    gtkBox.Append(image);
                    break;
                case "Development":
                    label.SetText(Translations.T("Development"));
                    image.IconName = "applications-development";
                    gtkBox.Append(image);
                    break;
                case "Education":
                    label.SetText(Translations.T("Education"));
                    image.IconName = "applications-education";
                    gtkBox.Append(image);
                    break;
                case "Game":
                    label.SetText(Translations.T("Game"));
                    image.IconName = "applications-games";
                    gtkBox.Append(image);
                    break;
                case "Graphics":
                    label.SetText(Translations.T("Graphics"));
                    image.IconName = "applications-graphics";
                    gtkBox.Append(image);
                    break;
                case "Network":
                    label.SetText(Translations.T("Network"));
                    image.IconName = "applications-internet";
                    gtkBox.Append(image);
                    break;
                case "Office":
                    label.SetText(Translations.T("Office"));
                    image.IconName = "applications-office";
                    gtkBox.Append(image);
                    break;
                case "Science":
                    label.SetText(Translations.T("Science"));
                    image.IconName = "applications-science";
                    gtkBox.Append(image);
                    break;
                case "System":
                    label.SetText(Translations.T("System"));
                    image.IconName = "applications-system";
                    gtkBox.Append(image);
                    break;
                case "Utility":
                    label.SetText(Translations.T("Utility"));
                    image.IconName = "applications-utilities";
                    gtkBox.Append(image);
                    break;
            }

            label.Halign = Align.Start;
            gtkBox.Append(label);
            _categoryListBox.Append(gtkBox);
        }

        _gridView.OnRealize += (_, _) => { _ = LoadDataAsync(_cts.Token); };

        reloadButton.OnClicked += (_, _) => { _ = LoadDataAsync(_cts.Token); };
        searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchDebounce.Cancel();
            _searchDebounce = new CancellationTokenSource();
            var ct = _searchDebounce.Token;

            Task.Delay(200, ct).ContinueWith(_ =>
            {
                if (ct.IsCancellationRequested) return;
                GLib.Functions.IdleAdd(0, () =>
                {
                    var text = searchEntry.GetText();
                    if (_activePage == "update")
                    {
                        flatpakUpdate.SetSearch(text);
                    }
                    else if (_activePage == "remove")
                    {
                        flatpakManage.SetSearch(text);
                    }
                    else
                    {
                        _searchText = text;
                        ApplyFilter();
                        _selectionModel.SetSelected(uint.MaxValue);
                        ScrollToTop();
                    }

                    return false;
                });
            }, ct);
        };

        void NavigateToInstallPage(int index)
        {
            _selectedCategory = (FlatpakCategories)index;
            _overlay.SetVisible(false);
            _activePage = "install";
            _mainContentStack.SetVisibleChild((Widget)builder.GetObject("list_overlay")!);
            sectionNavList.SelectRow(navInstallRow);

            ApplyFilter();
        }

        _categoryListBox.OnRowSelected += (_, args) =>
        {
            if (args.Row is null) return;
            NavigateToInstallPage(args.Row.GetIndex());
        };

        _categoryListBox.OnRowActivated += (_, args) => { NavigateToInstallPage(args.Row.GetIndex()); };

        _gridView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();

            if (item is not FlatpakGObject pkgObj) return;

            var obj = pkgObj.Package;

            if (obj == null) return;

            _overlayCloseButton.OnClicked += (_, _) => { _overlay.SetVisible(false); };

            _overlayIconImage = (Image)builder.GetObject("overlay_icon")!;


            _overlayAuthorLabel.SetText(obj.DeveloperName);
            _overlayNameLabel.SetText(obj.Name);
            _overlayVersionLabel.SetText(Translations.T("Version: {0}", obj.Releases.First().Version));

            _overlayLicenseLabel.SetText(Translations.T("License: {0}", obj.ProjectLicense));
            _overlaySummaryLabel.SetText(obj.Summary);
            _overlayDescriptionLabel.SetText(obj.Description);

            var result = unprivilegedOperationService
                .GetFlatpakAppDataAsync(obj.Remotes.FirstOrDefault()?.Name ?? String.Empty, obj.Id, "stable").Result;

            var installed = unprivilegedOperationService.ListFlatpakPackages().Result;

            if (installed.Any(p => p.Id == obj.Id))
            {
                _overlayInstallButton.SetSensitive(false);
                _overlayInstallButton.Label = Translations.T("Installed");
            }
            else
            {
                _overlayInstallButton.SetSensitive(true);
                _overlayInstallButton.Label = Translations.T("Install");
            }

            _overlaySizeLabel.SetText(Translations.T("Size: {0}", SizeHelpers.FormatSize((long)result.InstalledSize)));

            SetUrlLinks(obj.Urls);

            var remotes = obj.Remotes.FirstOrDefault() ?? new FlatpakRemoteDto();
            if (remotes.Scope == "user")
            {
                var userHome = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                _overlayIconImage.SetFromFile(
                    Path.Combine(userHome, $".local/share/flatpak/appstream", obj.Remotes.FirstOrDefault()!.Name,
                        "x86_64/active/icons/64x64", $"{obj.Id}.png"));
            }
            else
            {
                _overlayIconImage.SetFromFile(
                    $"/var/lib/flatpak/appstream/{obj.Remotes.FirstOrDefault()!.Name}/x86_64/active/icons/64x64/{obj.Id}.png");
            }


            List<string> images = [];

            images.AddRange(obj.Screenshots
                .Select(screenshot => screenshot.Images.FirstOrDefault()?.Url)
                .Where(url => !string.IsNullOrEmpty(url))!);

            PopulateScreenshots(images);

            if (_versionHistoryHandler is not null)
                _versionHistoryButton.OnClicked -= _versionHistoryHandler;
            
            _versionHistoryHandler = (_, _) =>
            {
                _overlayBoxRoot?.Dispose();
                ShowVersionHistory(obj.Releases);
            };
            
            _versionHistoryButton.OnClicked += _versionHistoryHandler;
            
            if (_permissionHistoryHandler is not null)
                _permissionsButton.OnClicked -= _permissionHistoryHandler;
            
            _permissionHistoryHandler = (_, _) =>
            {
                _overlayBoxRoot?.Dispose();
                ShowPermissions(result.Permissions);
            };
            
            _permissionsButton.OnClicked += _permissionHistoryHandler;

            if (obj.Addons.Count > 0)
            {
                _overlayShowPluginButton.SetVisible(true);

                if (_addonHistoryHandler is not null)
                    _overlayShowPluginButton.OnClicked -= _addonHistoryHandler;

                _addonHistoryHandler = (_, _) =>
                {
                    _overlayBoxRoot?.Dispose();
                    ShowAddons(obj.Addons);
                };

                _overlayShowPluginButton.OnClicked += _addonHistoryHandler;
            }
            else
            {
                _overlayShowPluginButton.SetVisible(false);
            }

            var remoteStrings = obj.Remotes.Select(r => r.Name + " : " + r.Scope).ToArray();
            _remotesStringList = StringList.New(remoteStrings);
            _remoteDropDown.SetModel(_remotesStringList);
            if (remoteStrings.Length > 0)
                _selectedRemote = remoteStrings[0];

            _selectedPackage = obj;

            _overlay.SetVisible(true);
        };

        _sub = DirtySubscription.Attach(dirtyService, this);
        return box;
    }

    public void Reload() => _ = LoadDataAsync(_cts.Token);

    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is not FlatpakGObject { Package: { } pkg }) return false;

        var id = pkg.Id;
        switch (_selectedCategory)
        {
            case FlatpakCategories.AllApplications:
                break;
            case FlatpakCategories.Recommended:
                if (!_trendingApps.Contains(id)) return false;
                break;
            case FlatpakCategories.MostWanted:
                if (!_popularApps.Contains(id)) return false;
                break;
            case FlatpakCategories.RecentlyAdded:
                if (!_recentlyAddedApps.Contains(id)) return false;
                break;
            case FlatpakCategories.RecentlyUpdated:
                if (!_recentlyUpdatedApps.Contains(id)) return false;
                break;
            case FlatpakCategories.AudioVideo:
            case FlatpakCategories.Development:
            case FlatpakCategories.Education:
            case FlatpakCategories.Game:
            case FlatpakCategories.Graphics:
            case FlatpakCategories.Network:
            case FlatpakCategories.Office:
            case FlatpakCategories.Science:
            case FlatpakCategories.System:
            case FlatpakCategories.Utility:
            default:
            {
                var categoryName = _selectedCategory.ToString();
                var categories = pkg.Categories;
                var result = categories.Contains(categoryName, StringComparer.OrdinalIgnoreCase);
                if (!result) return false;
                break;
            }
        }

        return PackageSearch.Matches(pkg.Name, pkg.Description, _searchText);
    }

    private void SetUrlLinks(Dictionary<string, string>? urls)
    {
        if (urls == null || urls.Count == 0)
        {
            _overlayUrlLabel.SetText(Translations.T("No links available"));
            return;
        }

        var markup = string.Join("  ·  ", urls.Select(kvp =>
            $"<a href=\"{kvp.Value}\">{CapitalizeFirst(kvp.Key)}</a>"
        ));

        _overlayUrlLabel.SetMarkup(markup);
        _overlayUrlLabel.UseMarkup = true;
    }

    private static string CapitalizeFirst(string s) =>
        string.IsNullOrEmpty(s) ? s : char.ToUpper(s[0]) + s[1..];

    private void PopulateScreenshots(List<string> imageUrls)
    {
        while (_overlayScreenshotsBox!.GetFirstChild() is { } child)
            _overlayScreenshotsBox.Remove(child);

        foreach (var url in imageUrls)
        {
            var picture = Picture.New();
            picture.ContentFit = ContentFit.Cover;
            picture.HeightRequest = 584;
            picture.WidthRequest = 900;
            picture.AddCssClass("card");

            _ = Task.Run(async () =>
            {
                try
                {
                    var bytes = await _httpClient.GetByteArrayAsync(url);
                    GLib.Functions.IdleAdd(0, () =>
                    {
                        var stream = Gio.MemoryInputStream.NewFromBytes(GLib.Bytes.New(bytes));
                        var pixbuf = GdkPixbuf.Pixbuf.NewFromStream(stream, null)!;
                        var texture = Gdk.Texture.NewForPixbuf(pixbuf);

                        var isPortrait = pixbuf.Height > pixbuf.Width;
                        picture.HeightRequest = 584;
                        if (isPortrait)
                        {
                            picture.WidthRequest = (int)(584.0 * pixbuf.Width / pixbuf.Height);
                        }
                        else
                        {
                            picture.WidthRequest = 900;
                        }

                        picture.SetPaintable(texture);
                        return false;
                    });
                }
                catch
                {
                    // if we get an error keep going
                }
            });

            _overlayScreenshotsBox.Append(picture);
        }
    }

    private static void OnSetup(SignalListItemFactory sender, SignalListItemFactory.SetupSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        var hbox = Box.New(Orientation.Horizontal, 10);
        hbox.MarginStart = 10;
        hbox.MarginEnd = 10;
        hbox.MarginTop = 5;
        hbox.MarginBottom = 5;
        hbox.Hexpand = false;
        hbox.Vexpand = false;
        hbox.Halign = Align.Start;

        var icon = Image.New();
        icon.PixelSize = 64;
        icon.WidthRequest = 64;
        icon.HeightRequest = 64;
        icon.Valign = Align.Center;
        hbox.Append(icon);

        var vbox = Box.New(Orientation.Vertical, 2);
        var nameBox = Box.New(Orientation.Horizontal, 4);
        nameBox.Halign = Align.Start;
        var nameLabel = Label.New(string.Empty);
        nameLabel.Halign = Align.Start;
        nameLabel.SetWrap(true);
        nameLabel.SetWrapMode(Pango.WrapMode.WordChar);
        nameLabel.MaxWidthChars = 30;
        nameBox.Append(nameLabel);

        var verifiedIcon = Image.NewFromIconName("security-high-symbolic");
        verifiedIcon.PixelSize = 14;
        verifiedIcon.Valign = Align.Center;
        verifiedIcon.TooltipText = "Verified";
        nameBox.Append(verifiedIcon);

        var idLabel = Label.New(string.Empty);
        idLabel.SetText(string.Empty);
        idLabel.Halign = Align.Start;
        idLabel.Hexpand = true;
        idLabel.AddCssClass("dim-label");
        idLabel.SetWrap(false);
        idLabel.SetEllipsize(Pango.EllipsizeMode.End);
        idLabel.MaxWidthChars = 35;
        idLabel.WidthChars = -1;

        vbox.Append(nameBox);
        vbox.Append(idLabel);
        vbox.Valign = Align.Center;
        hbox.Append(vbox);

        var frame = Frame.New(null);
        frame.SetChild(hbox);
        frame.WidthRequest = 300;
        frame.Hexpand = false;
        frame.Halign = Align.Fill;
        frame.AddCssClass("card");

        listItem.SetChild(frame);
    }


    private void OnBind(SignalListItemFactory sender, SignalListItemFactory.BindSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        if (listItem.GetItem() is not FlatpakGObject obj) return;

        var app = obj.Package;

        if (app == null) return;

        var frame = (Frame)listItem.GetChild()!;
        var hbox = (Box)frame.GetChild()!;
        var icon = (Image)hbox.GetFirstChild()!;
        var vbox = (Box)icon.GetNextSibling()!;
        var nameBox = (Box)vbox.GetFirstChild()!;
        var nameLabel = (Label)nameBox.GetFirstChild()!;
        var verifiedIcon = (Image)nameLabel.GetNextSibling()!;
        var idLabel = (Label)nameBox.GetNextSibling()!;

        nameLabel.SetText(app.Name);
        idLabel.SetText(app.Summary);
        verifiedIcon.SetVisible(app.IsVerified);

        var remotes = app.Remotes.FirstOrDefault() ?? new FlatpakRemoteDto();

        string path;
        if (remotes.Scope == "user")
        {
            var userHome = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            path =
                Path.Combine(userHome, $".local/share/flatpak/appstream", app.Remotes.FirstOrDefault()?.Name ?? "",
                    "x86_64/active/icons/64x64", $"{app.Id}.png");
        }
        else
        {
            path =
                $"/var/lib/flatpak/appstream/{app.Remotes.FirstOrDefault()?.Name}/x86_64/active/icons/64x64/{app.Id}.png";
        }

        if (File.Exists(path))
            icon.SetFromFile(path);
        else
            icon.SetFromIconName("application-x-executable");
    }

    private async Task BuildAndStartFlatHubTasksAsync()
    {
        var trendingTask = flatHubApiService.GetCollectionTrendingAsync();
        var popularTask = flatHubApiService.GetCollectionPopularAsync();
        var recentlyUpdatedTask = flatHubApiService.GetCollectionRecentlyUpdatedAsync();
        var recentlyAddedTask = flatHubApiService.GetCollectionRecentlyAddedAsync();

        await Task.WhenAll(trendingTask, popularTask, recentlyUpdatedTask, recentlyAddedTask);

        _trendingApps = (await trendingTask).ToHashSet();
        _popularApps = (await popularTask).ToHashSet();
        _recentlyUpdatedApps = (await recentlyUpdatedTask).ToHashSet();
        _recentlyAddedApps = (await recentlyAddedTask).ToHashSet();
    }

    private async Task LoadDataAsync(CancellationToken ct = default)
    {
        try
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested) return false;
                _loadingOverlay?.SetVisible(true);
                _loadingSpinner?.Start();
                return false;
            });

            var flathubTask = BuildAndStartFlatHubTasksAsync();

            await RefreshRemotesList(); //Refresh before getting for icons 

            var syncTask = unprivilegedOperationService.FlatpakSyncRemoteAppstream();
            await Task.WhenAny(syncTask, Task.Delay(TimeSpan.FromSeconds(5), ct));

            ct.ThrowIfCancellationRequested();
            _allPackages = await unprivilegedOperationService.ListAppstreamFlatpak(ct);
            ct.ThrowIfCancellationRequested();

            await flathubTask;

            GLib.Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested) return false;
                _listStore!.RemoveAll();
                ApplyFilter();
                return false;
            });

            const int batchSize = 100;
            for (var i = 0; i < _allPackages.Count; i += batchSize)
            {
                var currentBatch = _allPackages.Skip(i).Take(batchSize).ToList();
                GLib.Functions.IdleAdd(0, () =>
                {
                    if (ct.IsCancellationRequested) return false;
                    foreach (var pkg in currentBatch)
                    {
                        var o = FlatpakGObject.NewWithProperties([]);
                        o.Package = pkg;
                        _listStore!.Append(o);
                    }

                    return false;
                });
                await Task.Delay(10, ct);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load installed packages: {e.Message}");
        }
        finally
        {
            GLib.Functions.IdleAdd(0, () =>
            {
                // We always try to hide it, but only if not disposed
                _loadingOverlay?.SetVisible(false);
                _loadingSpinner?.Stop();
                return false;
            });
        }
    }

    private static void OnUnbind(SignalListItemFactory sender, SignalListItemFactory.UnbindSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        var frame = (Frame)listItem.GetChild()!;
        var hbox = (Box)frame.GetChild()!;
        var icon = (Image)hbox.GetFirstChild()!;
        var vbox = (Box)icon.GetNextSibling()!;
        var nameBox = (Box)vbox.GetFirstChild()!;
        var nameLabel = (Label)nameBox.GetFirstChild()!;
        var verifiedIcon = (Image)nameLabel.GetNextSibling()!;
        var idLabel = (Label)nameBox.GetNextSibling()!;

        nameLabel.SetText(string.Empty);
        idLabel.SetText(string.Empty);
        verifiedIcon.SetVisible(false);
        icon.Clear();
    }


    private void ScrollToTop()
    {
        if (_scroller is null) return;
        GLib.Functions.IdleAdd(0, () =>
        {
            if (_scroller is null) return false;
            var frames = 0;
            _scroller.AddTickCallback((_, _) =>
            {
                if (_scroller is null) return false;
                var vadj = _scroller.GetVadjustment();
                if (vadj is not null) vadj.SetValue(vadj.GetLower());
                var hadj = _scroller.GetHadjustment();
                if (hadj is not null) hadj.SetValue(hadj.GetLower());
                return ++frames < 3;
            });
            return false;
        });
    }

    private void ApplyFilter()
    {
        var newText = _searchText;

        if (newText.Length > _searchText.Length)
            _filter.Changed(FilterChange.MoreStrict);
        else if (newText.Length < _searchText.Length)
            _filter.Changed(FilterChange.LessStrict);
        else
            _filter.Changed(FilterChange.Different);
    }

    private async Task InstallFromFlatpakRef()
    {
        try
        {
            var dialog = FileDialog.New();
            dialog.SetTitle(Translations.T("Install Flatpak Ref"));

            var filter = FileFilter.New();
            filter.SetName(Translations.T("Local Flatpak files (\"*.FlatpakRef\", \"*.flatpak)\""));
            filter.AddSuffix("FlatpakRef");
            filter.AddSuffix("flatpak");

            var filters = Gio.ListStore.New(FileFilter.GetGType());
            filters.Append(filter);
            dialog.SetFilters(filters);

            var file = await dialog.OpenAsync((Window)_overlay!.GetRoot()!);

            if (file is not null)
            {
                lockoutService.Show(Translations.T("Installing selected local flatpak file..."));
                if (file.GetPath()!.EndsWith(".FlatpakRef", StringComparison.OrdinalIgnoreCase))
                {
                    var result =
                        await unprivilegedOperationService.FlatpakInsallFromRef(file.GetPath()!, _selectedRefScope);
                    if (!result.Success)
                    {
                        var args = new ToastMessageEventArgs(
                            Translations.T("Installing Flatpak failed")
                        );
                        genericQuestionService.RaiseToastMessage(args);
                        Console.WriteLine($"Failed to install local package: {result.Error}");
                    }
                    else
                    {
                        _overlayInstallButton.SetSensitive(false);

                        var args = new ToastMessageEventArgs(
                            Translations.T("Installed Flatpak")
                        );
                        genericQuestionService.RaiseToastMessage(args);
                    }
                }
                else
                {
                    var remotes = await unprivilegedOperationService.FlatpakListRemotes();
                    var hasSystem = remotes.Any(r => r is { Scope: "system" });


                    //This hoopla is because bundles require resolving their respective deps from the remotes config'd so we must use a flathub that is configured for the right level's.
                    //ex: user level only user trys to install at system level, we must install at user level because that is what their flathub is configured for.
                    if (hasSystem && _selectedRefScope == "system")
                    {
                        var privResult =
                            await privilegedOperationService.FlatpakInstallFromBundle(file.GetPath()!);

                        if (!privResult.Success)
                        {
                            var args = new ToastMessageEventArgs(
                                Translations.T("Installing Flatpak failed")
                            );
                            genericQuestionService.RaiseToastMessage(args);
                            Console.WriteLine($"Failed to install local bundle: {privResult.Error}");
                        }
                        else
                        {
                            var args = new ToastMessageEventArgs(
                                Translations.T("Installed Flatpak")
                            );
                            genericQuestionService.RaiseToastMessage(args);
                        }
                    }
                    else
                    {
                        var unprivResult =
                            await unprivilegedOperationService.FlatpakInstallFromBundle(file.GetPath()!);

                        if (!unprivResult.Success)
                        {
                            var args = new ToastMessageEventArgs(
                                Translations.T("Installing Flatpak failed")
                            );
                            genericQuestionService.RaiseToastMessage(args);
                            Console.WriteLine($"Failed to install local bundle: {unprivResult.Error}");
                        }
                        else
                        {
                            var args = new ToastMessageEventArgs(
                                Translations.T("Installed Flatpak")
                            );
                            genericQuestionService.RaiseToastMessage(args);
                        }
                    }
                }
            }
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private async Task InstallSelectedAsync()
    {
        if (!configService.LoadConfig().NoConfirm)
        {
            var args = new GenericQuestionEventArgs(
                Translations.T("Install Package?"), _selectedPackage.Id
            );

            genericQuestionService.RaiseQuestion(args);
            if (!await args.ResponseTask)
            {
                return;
            }
        }

        try
        {
            UnprivilegedOperationResult result;
            lockoutService.Show(Translations.T("Installing {0}...", _selectedPackage.Id));
            if (_selectedRemote.Contains("user"))
            {
                result = await unprivilegedOperationService.InstallFlatpakPackage(_selectedPackage.Id,
                    true, _selectedRemote.Split(":")[0].Trim(),
                    _selectedRemote.Contains("beta", StringComparison.InvariantCulture) ? "beta" : "stable");
            }
            else
            {
                result = await unprivilegedOperationService.InstallFlatpakPackage(_selectedPackage.Id,
                    false, _selectedRemote.Split(":")[0].Trim(),
                    _selectedRemote.Contains("beta", StringComparison.InvariantCulture) ? "beta" : "stable");
            }


            if (result.Success)
            {
                _overlayInstallButton.SetSensitive(false);

                var args = new ToastMessageEventArgs(
                    $"Installed Flatpak"
                );
                genericQuestionService.RaiseToastMessage(args);
            }
            else
            {
                var args = new ToastMessageEventArgs(
                    $"Installing Flatpak failed"
                );
                genericQuestionService.RaiseToastMessage(args);
                Console.WriteLine($"Failed to install package {_selectedPackage.Id}: {result.Error}");
            }
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private async Task InstallFromIdAsync(string id)
    {
        if (!configService.LoadConfig().NoConfirm)
        {
            var args = new GenericQuestionEventArgs(
                Translations.T("Install Package?"), id
            );

            genericQuestionService.RaiseQuestion(args);
            if (!await args.ResponseTask)
            {
                return;
            }
        }

        try
        {
            UnprivilegedOperationResult result;
            lockoutService.Show(Translations.T("Installing {0}...", id));
            if (_selectedRemote.Contains("user"))
            {
                result = await unprivilegedOperationService.InstallFlatpakPackage(id,
                    true, _selectedRemote.Split(":")[0].Trim(),
                    _selectedRemote.Contains("beta", StringComparison.InvariantCulture) ? "beta" : "stable", true);
            }
            else
            {
                result = await unprivilegedOperationService.InstallFlatpakPackage(id,
                    false, _selectedRemote.Split(":")[0].Trim(),
                    _selectedRemote.Contains("beta", StringComparison.InvariantCulture) ? "beta" : "stable", true);
            }


            if (result.Success)
            {
                var args = new ToastMessageEventArgs(
                    Translations.T("Installed Flatpak addon")
                );
                genericQuestionService.RaiseToastMessage(args);
            }
            else
            {
                var args = new ToastMessageEventArgs(
                    Translations.T("Installing Flatpak failed")
                );
                genericQuestionService.RaiseToastMessage(args);
                Console.WriteLine($"Failed to install addon {id}: {result.Error}");
            }
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private void ShowVersionHistory(List<AppstreamRelease> releases)
    {
        _overlayBoxRoot = Box.New(Orientation.Vertical, 12);
        _overlayBoxRoot.SetSizeRequest(500, -1);

        var title = Label.New(Translations.T("Version History"));
        title.AddCssClass("title-2");
        title.SetHalign(Align.Start);
        _overlayBoxRoot.Append(title);

        var scroll = ScrolledWindow.New();
        scroll.HscrollbarPolicy = PolicyType.Never;
        scroll.VscrollbarPolicy = PolicyType.Automatic;
        scroll.SetOverlayScrolling(false);
        scroll.SetSizeRequest(-1, 400);

        var list = Box.New(Orientation.Vertical, 8);

        foreach (var release in releases)
            list.Append(BuildReleaseCard(release.Version,
                DateTimeOffset.FromUnixTimeSeconds(release.Timestamp).ToString("yyyy-MM-dd"), release.Description));

        scroll.SetChild(list);
        _overlayBoxRoot.Append(scroll);

        genericQuestionService.RaiseDialog(new GenericDialogEventArgs(_overlayBoxRoot));
    }

    private void ShowAddons(List<AppstreamApp> addons)
    {
        _overlayBoxRoot = Box.New(Orientation.Vertical, 12);
        _overlayBoxRoot.SetSizeRequest(500, -1);

        var title = Label.New(Translations.T("Available Addons"));
        title.AddCssClass("title-2");
        title.SetHalign(Align.Start);
        _overlayBoxRoot.Append(title);

        var scroll = ScrolledWindow.New();
        scroll.HscrollbarPolicy = PolicyType.Never;
        scroll.VscrollbarPolicy = PolicyType.Automatic;
        scroll.SetOverlayScrolling(false);
        scroll.SetSizeRequest(-1, 400);

        var list = Box.New(Orientation.Vertical, 8);

        foreach (var addon in addons)
            list.Append(BuildAddonCard(addon.Name, addon.Summary, addon.Id));

        scroll.SetChild(list);
        _overlayBoxRoot.Append(scroll);

        genericQuestionService.RaiseDialog(new GenericDialogEventArgs(_overlayBoxRoot));
    }
    
    private void ShowPermissions(List<string> permissions)
    {
        _overlayBoxRoot = Box.New(Orientation.Vertical, 12);
        _overlayBoxRoot.SetSizeRequest(500, -1);

        var title = Label.New(Translations.T("App Permissions"));
        title.AddCssClass("title-2");
        title.SetHalign(Align.Start);
        _overlayBoxRoot.Append(title);

        var scroll = ScrolledWindow.New();
        scroll.HscrollbarPolicy = PolicyType.Never;
        scroll.VscrollbarPolicy = PolicyType.Automatic;
        scroll.SetOverlayScrolling(false);
        scroll.SetSizeRequest(-1, 400);
        scroll.SetMarginStart(8);
        scroll.SetMarginEnd(8);

        var list = Box.New(Orientation.Vertical, 16);

        var grouped = permissions
            .Select(p =>
            {
                var eqIdx = p.IndexOf('=');
                var colonIdx = p.IndexOf(':');
                if (eqIdx < 0 || colonIdx < 0 || colonIdx <= eqIdx)
                    return (Group: string.Empty, Key: p, Value: string.Empty);
                return (
                    Group: p[..eqIdx],
                    Key: p[(eqIdx + 1)..colonIdx],
                    Value: p[(colonIdx + 1)..]
                );
            })
            .GroupBy(x => x.Group)
            .OrderBy(g => g.Key);

        var listBox = ListBox.New();
        listBox.AddCssClass("boxed-list");
        listBox.SelectionMode = SelectionMode.None;

        foreach (var group in grouped)
        {
            foreach (var perm in group)
                listBox.Append(BuildPermissionRow(perm.Key, perm.Value));
        }

        list.Append(listBox);

        scroll.SetChild(list);
        _overlayBoxRoot.Append(scroll);

        genericQuestionService.RaiseDialog(new GenericDialogEventArgs(_overlayBoxRoot));
    }

    protected virtual Widget BuildPermissionRow(string key, string value)
    {
        var row = ListBoxRow.New();

        var inner = Box.New(Orientation.Horizontal, 12);
        inner.SetMarginTop(10);
        inner.SetMarginBottom(10);
        inner.SetMarginStart(12);
        inner.SetMarginEnd(12);

        var icon = Image.NewFromIconName(GetPermissionIcon(key));
        icon.SetValign(Align.Center);
        icon.AddCssClass("dim-label");

        var textBox = Box.New(Orientation.Vertical, 2);
        textBox.Hexpand = true;
        textBox.SetValign(Align.Center);

        var keyLabel = Label.New(key);
        keyLabel.AddCssClass("body");
        keyLabel.SetHalign(Align.Start);
        textBox.Append(keyLabel);

        if (!string.IsNullOrWhiteSpace(value))
        {
            var valueLabel = Label.New(value);
            valueLabel.AddCssClass("dim-label");
            valueLabel.AddCssClass("caption");
            valueLabel.SetHalign(Align.Start);
            valueLabel.SetWrap(true);
            valueLabel.SetXalign(0);
            textBox.Append(valueLabel);
        }

        inner.Append(icon);
        inner.Append(textBox);
        row.SetChild(inner);

        return row;
    }

    private static string GetPermissionIcon(string key) => key.ToLowerInvariant() switch
    {
        "network" or "networks" => "network-wireless-symbolic",
        "filesystems" or "filesystem" => "folder-symbolic",
        "ipc" => "system-run-symbolic",
        "sockets" => "preferences-system-network-symbolic",
        "devices" => "computer-symbolic",
        "features" => "applications-system-symbolic",
        "dbus" or "sessionbus" or "systembus" => "preferences-desktop-symbolic",
        "shared" => "emblem-shared-symbolic",
        _ => "dialog-information-symbolic"
    };

    protected virtual Widget BuildReleaseCard(string version, string date, string description)
    {
        var card = Box.New(Orientation.Vertical, 4);
        card.AddCssClass("card");
        card.SetMarginBottom(4);
        card.SetMarginStart(2);
        card.SetMarginEnd(2);

        var row = Box.New(Orientation.Horizontal, 8);
        row.SetMarginTop(8);
        row.SetMarginBottom(8);
        row.SetMarginStart(8);
        row.SetMarginEnd(8);

        var versionLabel = Label.New(Translations.T("Version {0}", version));
        versionLabel.AddCssClass("heading");
        versionLabel.SetHalign(Align.Start);
        versionLabel.Hexpand = true;

        var dateLabel = Label.New(date);
        dateLabel.AddCssClass("dim-label");
        dateLabel.SetHalign(Align.End);
        dateLabel.SetValign(Align.Center);

        row.Append(versionLabel);
        row.Append(dateLabel);
        card.Append(row);

        if (!string.IsNullOrWhiteSpace(description))
        {
            foreach (var line in description.Split('\n'))
            {
                var desc = Label.New(line);
                desc.SetText(line);
                desc.SetWrap(true);
                desc.SetXalign(0);
                desc.SetMarginBottom(4);
                desc.SetMarginStart(8);
                desc.SetMarginEnd(8);
                desc.SetHalign(Align.Fill);
                card.Append(desc);
            }
        }
        else
        {
            var noDetails = Label.New(Translations.T("No details available"));
            noDetails.AddCssClass("dim-label");
            noDetails.SetXalign(0);
            noDetails.SetMarginBottom(4);
            noDetails.SetMarginStart(8);
            noDetails.SetMarginEnd(8);
            card.Append(noDetails);
        }

        return card;
    }

    protected virtual Widget BuildAddonCard(string name, string summary, string id)
    {
        var card = Box.New(Orientation.Vertical, 4);
        card.AddCssClass("card");
        card.SetMarginBottom(4);
        card.SetMarginStart(2);
        card.SetMarginEnd(2);

        var row = Box.New(Orientation.Horizontal, 8);
        row.SetMarginTop(8);
        row.SetMarginBottom(8);
        row.SetMarginStart(8);
        row.SetMarginEnd(8);

        var textBox = Box.New(Orientation.Vertical, 4);
        textBox.Hexpand = true;

        var nameLabel = Label.New(name);
        nameLabel.AddCssClass("heading");
        nameLabel.SetHalign(Align.Start);

        textBox.Append(nameLabel);

        if (!string.IsNullOrWhiteSpace(summary))
        {
            var summaryLabel = Label.New(summary);
            summaryLabel.SetWrap(true);
            summaryLabel.SetXalign(0);
            summaryLabel.SetHalign(Align.Fill);
            textBox.Append(summaryLabel);
        }

        var button = Button.New();
        button.SetIconName("folder-download-symbolic");
        button.SetValign(Align.Center);
        button.SetHalign(Align.End);
        button.OnClicked += async (_, _) => { await InstallFromIdAsync(id); };

        row.Append(textBox);
        row.Append(button);
        card.Append(row);

        return card;
    }

    private static void OnSetupRemote(SignalListItemFactory sender, SignalListItemFactory.SetupSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        var box = Box.New(Orientation.Horizontal, 12);
        box.MarginStart = 12;
        box.MarginEnd = 12;
        box.MarginTop = 6;
        box.MarginBottom = 6;

        var nameLabel = Label.New(string.Empty);
        nameLabel.Halign = Align.Start;
        nameLabel.Xalign = 0;
        nameLabel.Hexpand = true;
        nameLabel.AddCssClass("bold");

        var scopeLabel = Label.New(string.Empty);
        scopeLabel.Halign = Align.Start;
        scopeLabel.Xalign = 0;
        scopeLabel.AddCssClass("dim-label");

        var urlLabel = Label.New(string.Empty);
        urlLabel.Halign = Align.Start;
        urlLabel.Xalign = 0;
        urlLabel.AddCssClass("dim-label");

        box.Append(nameLabel);
        box.Append(scopeLabel);
        box.Append(urlLabel);

        listItem.SetChild(box);
    }

    private static void OnBindRemote(SignalListItemFactory sender, SignalListItemFactory.BindSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        if (listItem.GetItem() is not FlatpakRemoteGObject remoteGObject) return;
        if (remoteGObject.Remote == null) return;

        var box = (Box)listItem.GetChild()!;
        var nameLabel = (Label)box.GetFirstChild()!;
        var scopeLabel = (Label)nameLabel.GetNextSibling()!;
        var urlLabel = (Label)scopeLabel.GetNextSibling()!;

        nameLabel.SetText(remoteGObject.Remote.Name);
        scopeLabel.SetText($"({remoteGObject.Remote.Scope})");
        urlLabel.SetText(remoteGObject.Remote.Url);
    }

    private async Task RefreshRemotesList()
    {
        if (_remoteListStore == null) return;

        var remotes = await unprivilegedOperationService.FlatpakListRemotes();

        GLib.Functions.IdleAdd(0, () =>
        {
            if (_cts.Token.IsCancellationRequested) return false;
            _remoteListStore.RemoveAll();
            foreach (var obj in remotes.Select(remote =>
                     {
                         var o = FlatpakRemoteGObject.NewWithProperties([]);
                         o.Remote = remote;
                         return o;
                     }))
            {
                _remoteListStore.Append(obj);
            }

            return false;
        });
    }

    private Task BuildAndShowRemoteRef()
    {
        if (_remoteFactory == null)
        {
            _remoteFactory = SignalListItemFactory.New();
            _remoteFactory.OnSetup += OnSetupRemote;
            _remoteFactory.OnBind += OnBindRemote;
            _listRemotes.SetFactory(_remoteFactory);
        }

        RefreshRemotesList().Wait();

        GLib.Functions.IdleAdd(0, () =>
        {
            _mainContentStack?.SetVisibleChild(_remoteRefOverlay);
            return false;
        });
        return Task.CompletedTask;
    }


    public void Dispose()
    {
        _sub?.Dispose();
        _cts.Cancel();
        _cts.Dispose();
        _searchDebounce.Cancel();
        _searchDebounce.Dispose();
        _httpClient.Dispose();
        _addRemoteOverlay.Dispose();
        _overlay?.Dispose();
        _allPackages.Clear();
        _listStore?.RemoveAll();
        _remoteListStore?.RemoveAll();
        _selectedPackage = null!;
    }
}