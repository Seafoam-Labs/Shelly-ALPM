using System.Net;
using System.Text.Json;
using GdkPixbuf;
using GObject;
using Gtk;
using Shelly.Gtk.Enums;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Services;
using Shelly.Gtk.Services.AppImageHub;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AppImageHub;
using Shelly.Utilities;
using static Shelly.GTK.Resources.Translations;
using Functions = GLib.Functions;
using WrapMode = Pango.WrapMode;

namespace Shelly.Gtk.Windows;

public sealed class AppImageBrowse(
    IUnprivilegedOperationService unprivilegedOperationService,
    IGenericQuestionService genericQuestionService,
    ILockoutService lockoutService,
    IAppImageHubService appImageHubService) : IShellyWindow
{
    private readonly HttpClient _httpClient = new(new SocketsHttpHandler
    {
        AutomaticDecompression = DecompressionMethods.All,
        AllowAutoRedirect = true,
        MaxAutomaticRedirections = 10,
        ConnectTimeout = TimeSpan.FromSeconds(30),
    })
    {
        Timeout = TimeSpan.FromMinutes(10),
        DefaultRequestHeaders = { UserAgent = { Http.UserAgent } },
    };

    private readonly CancellationTokenSource _cts = new();
    private CancellationTokenSource _searchDebounce = new();

    // Static: survives tab switches (AppImageBrowse is Transient — recreated each visit)
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, Gdk.Texture?> _iconCache = new();
    private readonly SemaphoreSlim _iconSemaphore = new(4, 4);

    private List<AppImageHubItem> _allItems = [];
    private List<string> _categories = [];
    private string _searchText = string.Empty;
    private string _selectedCategory = string.Empty;
    private AppImageHubItem? _selectedItem;

    // Grid page widgets
    private GridView? _gridView;
    private Gio.ListStore? _listStore;
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
    private SingleSelection? _selectionModel;
    private SignalListItemFactory? _factory;
    private ListBox? _categoryListBox;
    private ScrolledWindow? _gridScroller;
    private Box? _loadingOverlay;
    private Spinner? _loadingSpinner;
    private Box? _errorOverlay;
    private Label? _errorMessageLabel;

    // Detail page widgets
    private Box? _gridPage;
    private ScrolledWindow? _detailPage;
    private ScrolledWindow? _screenshotScroller;
    private Image? _detailIcon;
    private Label? _detailName;
    private Label? _detailDescription;
    private Label? _detailLicense;
    private Label? _detailAuthors;
    private Label? _detailCategories;
    private Button? _detailInstallButton;
    private Box? _detailScreenshotsBox;
    private SignalHandler<Button>? _installHandler;

    public string[] ListensTo => [];

    public void Reload() { }

    private bool _loading;

    public Widget CreateWindow()
    {
        var outerStack = Stack.New();
        outerStack.Hexpand = true;
        outerStack.Vexpand = true;

        // ── Grid page ──────────────────────────────────────────────
        _gridPage = Box.New(Orientation.Horizontal, 0);
        _gridPage.Hexpand = true;
        _gridPage.Vexpand = true;

        // Left category sidebar
        var sidebarScroller = ScrolledWindow.New();
        sidebarScroller.HscrollbarPolicy = PolicyType.Never;
        sidebarScroller.VscrollbarPolicy = PolicyType.Automatic;
        sidebarScroller.WidthRequest = 165;

        _categoryListBox = ListBox.New();
        _categoryListBox.SetSelectionMode(SelectionMode.Single);
        _categoryListBox.AddCssClass("navigation-sidebar");
        _categoryListBox.OnRowSelected += (_, args) =>
        {
            if (args.Row is null) return;
            _selectedCategory = args.Row.GetIndex() == 0
                ? string.Empty
                : _categories[args.Row.GetIndex() - 1];
            ApplyFilter();
            ScrollGridToTop();
        };
        sidebarScroller.SetChild(_categoryListBox);

        _gridPage.Append(sidebarScroller);
        _gridPage.Append(Separator.New(Orientation.Vertical));

        // Right side: toolbar + grid
        var rightBox = Box.New(Orientation.Vertical, 0);
        rightBox.Hexpand = true;
        rightBox.Vexpand = true;

        // Toolbar
        var toolbar = Box.New(Orientation.Horizontal, 8);
        toolbar.MarginStart = 12;
        toolbar.MarginEnd = 12;
        toolbar.MarginTop = 8;
        toolbar.MarginBottom = 8;

        var searchEntry = SearchEntry.New();
        searchEntry.PlaceholderText = T("Search AppImages...");
        searchEntry.Hexpand = true;
        searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchDebounce.Cancel();
            _searchDebounce = new CancellationTokenSource();
            var ct = _searchDebounce.Token;
            Task.Delay(200, ct).ContinueWith(_ =>
            {
                if (ct.IsCancellationRequested) return;
                Functions.IdleAdd(0, () =>
                {
                    _searchText = searchEntry.GetText();
                    ApplyFilter();
                    ScrollGridToTop();
                    return false;
                });
            }, ct);
        };

        var reloadButton = Button.New();
        reloadButton.IconName = "view-refresh-symbolic";
        reloadButton.TooltipText = T("Reload catalog");
        reloadButton.OnClicked += (_, _) =>
        {
            appImageHubService.InvalidateCache();
            _ = LoadCatalogAsync(_cts.Token);
        };

        toolbar.Append(searchEntry);
        toolbar.Append(reloadButton);

        rightBox.Append(toolbar);
        rightBox.Append(Separator.New(Orientation.Horizontal));

        // Loading overlay + grid
        var contentOverlay = Overlay.New();
        contentOverlay.Hexpand = true;
        contentOverlay.Vexpand = true;

        _gridScroller = ScrolledWindow.New();
        _gridScroller.HscrollbarPolicy = PolicyType.Never;
        _gridScroller.VscrollbarPolicy = PolicyType.Automatic;
        _gridScroller.Hexpand = true;
        _gridScroller.Vexpand = true;

        _listStore = Gio.ListStore.New(AppImageHubGObject.GetGType());
        _filter = PackageSearch.CreateSafeFilter(FilterItem);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);

        _gridView = GridView.New(_selectionModel, null);
        _gridView.SetMaxColumns(4);
        _gridView.SetMinColumns(1);
        _gridView.SingleClickActivate = true;

        _factory = SignalListItemFactory.New();
        _factory.OnSetup += OnSetup;
        _factory.OnBind += OnBind;
        _factory.OnUnbind += OnUnbind;
        _gridView.SetFactory(_factory);
        _gridView.OnRealize += (_, _) => { if (!_loading) _ = LoadCatalogAsync(_cts.Token); };

        _gridView.OnActivate += (_, _) =>
        {
            var obj = _selectionModel.GetSelectedItem();
            if (obj is not AppImageHubGObject { Item: { } item }) return;
            ShowDetailPage(item, outerStack);
        };

        _gridScroller.SetChild(_gridView);
        contentOverlay.SetChild(_gridScroller);

        // Loading spinner overlay
        _loadingOverlay = Box.New(Orientation.Vertical, 12);
        _loadingOverlay.SetValign(Align.Center);
        _loadingOverlay.SetHalign(Align.Center);
        _loadingOverlay.SetVisible(false);
        _loadingSpinner = Spinner.New();
        _loadingSpinner.SetSizeRequest(48, 48);
        var loadingLabel = Label.New(T("Loading AppImage catalog..."));
        loadingLabel.AddCssClass("title-3");
        _loadingOverlay.Append(_loadingSpinner);
        _loadingOverlay.Append(loadingLabel);
        contentOverlay.AddOverlay(_loadingOverlay);

        // No results overlay
        var noResultsBox = Box.New(Orientation.Vertical, 12);
        noResultsBox.SetValign(Align.Center);
        noResultsBox.SetHalign(Align.Center);
        noResultsBox.SetVisible(false);
        var noResultsIcon = Image.NewFromIconName("search-none-symbolic");
        noResultsIcon.SetPixelSize(64);
        noResultsIcon.AddCssClass("dim-label");
        var noResultsLabel = Label.New(T("No AppImages found"));
        noResultsLabel.AddCssClass("title-2");
        noResultsLabel.AddCssClass("dim-label");
        noResultsBox.Append(noResultsIcon);
        noResultsBox.Append(noResultsLabel);
        contentOverlay.AddOverlay(noResultsBox);

        // Error overlay
        _errorOverlay = Box.New(Orientation.Vertical, 16);
        _errorOverlay.SetValign(Align.Center);
        _errorOverlay.SetHalign(Align.Center);
        _errorOverlay.SetVisible(false);
        var errorIcon = Image.NewFromIconName("network-error-symbolic");
        errorIcon.SetPixelSize(64);
        errorIcon.AddCssClass("dim-label");
        var errorTitle = Label.New(T("Failed to load AppImage catalog"));
        errorTitle.AddCssClass("title-2");
        _errorMessageLabel = Label.New(string.Empty);
        _errorMessageLabel.AddCssClass("dim-label");
        _errorMessageLabel.SetWrap(true);
        _errorMessageLabel.MaxWidthChars = 50;
        var retryButton = Button.New();
        retryButton.Label = T("Retry");
        retryButton.AddCssClass("pill");
        retryButton.SetHalign(Align.Center);
        retryButton.OnClicked += (_, _) =>
        {
            appImageHubService.InvalidateCache();
            _ = LoadCatalogAsync(_cts.Token);
        };
        _errorOverlay.Append(errorIcon);
        _errorOverlay.Append(errorTitle);
        _errorOverlay.Append(_errorMessageLabel);
        _errorOverlay.Append(retryButton);
        contentOverlay.AddOverlay(_errorOverlay);

        rightBox.Append(contentOverlay);
        _gridPage.Append(rightBox);

        // ── Detail page ────────────────────────────────────────────
        _detailPage = BuildDetailPage(outerStack);

        outerStack.AddNamed(_gridPage, "grid");
        outerStack.AddNamed(_detailPage, "detail");
        outerStack.SetVisibleChildName("grid");

        return outerStack;
    }

    public void Dispose()
    {
        _cts.Cancel();
        _cts.Dispose();
        _searchDebounce.Cancel();
        _searchDebounce.Dispose();
        _httpClient.Dispose();
        _iconSemaphore.Dispose();
        _allItems = []; // don't .Clear() — that mutates AppImageHubService's cached list (same reference)
        // _iconCache is static — don't clear, it persists intentionally across instances
        _listStore?.RemoveAll();
    }

    // ── Catalog loading ────────────────────────────────────────────

    private async Task LoadCatalogAsync(CancellationToken ct)
    {
        _loading = true;
        Functions.IdleAdd(0, () =>
        {
            if (ct.IsCancellationRequested) return false;
            _errorOverlay?.SetVisible(false);
            _loadingOverlay?.SetVisible(true);
            _loadingSpinner?.Start();
            return false;
        });

        try
        {
            _allItems = await appImageHubService.GetCatalogAsync(ct);
            _categories = _allItems
                .SelectMany(i => i.Categories ?? [])
                .Where(c => !string.IsNullOrWhiteSpace(c) && char.IsLetter(c[0]))
                .Select(NormalizeCategory)
                .Distinct()
                .OrderBy(c => c)
                .ToList();

            // Build UI and populate grid in one idle callback — content appears all at once
            Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested) return false;
                BuildCategoryList();
                PopulateGrid(ct);
                _loadingOverlay?.SetVisible(false);
                _loadingSpinner?.Stop();
                return false;
            });
        }
        catch (OperationCanceledException) { }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to load AppImage catalog: {e.Message}");
            var msg = e.Message;
            Functions.IdleAdd(0, () =>
            {
                _loadingOverlay?.SetVisible(false);
                _loadingSpinner?.Stop();
                _errorMessageLabel?.SetText(msg);
                _errorOverlay?.SetVisible(true);
                return false;
            });
        }
        finally
        {
            _loading = false;
        }
    }

    private void BuildCategoryList()
    {
        if (_categoryListBox == null) return;
        _categoryListBox.RemoveAll();

        var allRow = CreateCategoryRow("applications-other", T("All Applications"));
        _categoryListBox.Append(allRow);

        foreach (var cat in _categories)
            _categoryListBox.Append(CreateCategoryRow(CategoryIcon(cat), T(cat)));

        _categoryListBox.SelectRow(allRow);
    }

    private void PopulateGrid(CancellationToken ct)
    {
        if (_listStore == null || ct.IsCancellationRequested) return;

        var objects = new GObject.Object[_allItems.Count];
        for (int i = 0; i < _allItems.Count; i++)
        {
            var obj = AppImageHubGObject.NewWithProperties([]);
            obj.Item = _allItems[i];
            objects[i] = obj;
        }

        // Splice replaces everything in one items-changed signal — avoids 3000 individual signals
        _listStore.Splice(0, _listStore.GetNItems(), objects, (uint)objects.Length);
    }

    // ── GridView factory ───────────────────────────────────────────

    private static void OnSetup(SignalListItemFactory sender, SignalListItemFactory.SetupSignalArgs args)
    {
        var listItem = (ListItem)args.Object;

        var hbox = Box.New(Orientation.Horizontal, 10);
        hbox.MarginStart = 10;
        hbox.MarginEnd = 10;
        hbox.MarginTop = 8;
        hbox.MarginBottom = 8;
        hbox.Hexpand = false;

        var icon = Image.New();
        icon.PixelSize = 48;
        icon.WidthRequest = 48;
        icon.HeightRequest = 48;
        icon.Valign = Align.Center;
        hbox.Append(icon);

        var vbox = Box.New(Orientation.Vertical, 2);
        vbox.Valign = Align.Center;
        vbox.Hexpand = true;

        var nameLabel = Label.New(string.Empty);
        nameLabel.Halign = Align.Start;
        nameLabel.AddCssClass("title-4");
        nameLabel.SetWrap(true);
        nameLabel.SetWrapMode(WrapMode.WordChar);
        nameLabel.MaxWidthChars = 25;

        var descLabel = Label.New(string.Empty);
        descLabel.Halign = Align.Start;
        descLabel.AddCssClass("dim-label");
        descLabel.SetWrap(true);
        descLabel.SetWrapMode(WrapMode.WordChar);
        descLabel.SetEllipsize(Pango.EllipsizeMode.End);
        descLabel.SetLines(2);
        descLabel.MaxWidthChars = 30;

        vbox.Append(nameLabel);
        vbox.Append(descLabel);
        hbox.Append(vbox);

        var frame = Frame.New(null);
        frame.SetChild(hbox);
        frame.WidthRequest = 280;
        frame.Hexpand = false;
        frame.AddCssClass("card");

        listItem.SetChild(frame);
    }

    private void OnBind(SignalListItemFactory sender, SignalListItemFactory.BindSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        if (listItem.GetItem() is not AppImageHubGObject { Item: { } item }) return;

        var frame = (Frame)listItem.GetChild()!;
        var hbox = (Box)frame.GetChild()!;
        var icon = (Image)hbox.GetFirstChild()!;
        var vbox = (Box)icon.GetNextSibling()!;
        var nameLabel = (Label)vbox.GetFirstChild()!;
        var descLabel = (Label)nameLabel.GetNextSibling()!;

        nameLabel.SetText(item.DisplayName);
        descLabel.SetText(item.CleanDescription ?? string.Empty);
        icon.SetFromIconName("application-x-executable");

        var iconUrl = item.IconUrl;
        if (iconUrl == null || iconUrl.EndsWith(".svg", StringComparison.OrdinalIgnoreCase)) return;

        // 1. Memory cache — instant
        if (_iconCache.TryGetValue(iconUrl, out var cached))
        {
            if (cached != null) icon.SetFromPaintable(cached);
            return;
        }

        // 2. Disk cache — sync like Flatpak (local file, fast)
        var diskPath = DiskCachePath(iconUrl);
        if (File.Exists(diskPath))
        {
            icon.SetFromFile(diskPath);
            return;
        }

        // 3. Network fetch — background only when no cache at all
        var ct = _cts.Token;
        _ = Task.Run(() => FetchIconAsync(iconUrl, icon, ct), ct);
    }

    private async Task FetchIconAsync(string iconUrl, Image targetIcon, CancellationToken ct)
    {
        await _iconSemaphore.WaitAsync(ct);
        try
        {
            if (_iconCache.TryGetValue(iconUrl, out var existing))
            {
                if (existing != null)
                    Functions.IdleAdd(0, () => { targetIcon.SetFromPaintable(existing); return false; });
                return;
            }

            var bytes = await _httpClient.GetByteArrayAsync(iconUrl, ct);
            var stream = Gio.MemoryInputStream.NewFromBytes(GLib.Bytes.New(bytes));
            var pixbuf = GdkPixbuf.Pixbuf.NewFromStream(stream, null);
            if (pixbuf == null) { _iconCache[iconUrl] = null; return; }

            var tex = Gdk.Texture.NewForPixbuf(pixbuf);
            _iconCache[iconUrl] = tex;
            Functions.IdleAdd(0, () => { targetIcon.SetFromPaintable(tex); return false; });

            _ = SaveIconToDiskCacheAsync(iconUrl, bytes);
        }
        catch (OperationCanceledException) { }
        catch { _iconCache.TryAdd(iconUrl, null); }
        finally { _iconSemaphore.Release(); }
    }

    private static readonly string _diskCacheDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".cache", "shelly", "appimage-icons");

    private static string DiskCachePath(string cacheKey)
    {
        var hash = Convert.ToHexString(System.Security.Cryptography.MD5.HashData(
            System.Text.Encoding.UTF8.GetBytes(cacheKey)));
        return Path.Combine(_diskCacheDir, hash);
    }

    private static async Task SaveIconToDiskCacheAsync(string cacheKey, byte[] bytes)
    {
        try
        {
            Directory.CreateDirectory(_diskCacheDir);
            await File.WriteAllBytesAsync(DiskCachePath(cacheKey), bytes);
        }
        catch { /* non-critical */ }
    }

private static void OnUnbind(SignalListItemFactory sender, SignalListItemFactory.UnbindSignalArgs args)
    {
        var listItem = (ListItem)args.Object;
        var frame = (Frame)listItem.GetChild()!;
        var hbox = (Box)frame.GetChild()!;
        var icon = (Image)hbox.GetFirstChild()!;
        var vbox = (Box)icon.GetNextSibling()!;
        var nameLabel = (Label)vbox.GetFirstChild()!;
        var descLabel = (Label)nameLabel.GetNextSibling()!;

        nameLabel.SetText(string.Empty);
        descLabel.SetText(string.Empty);
        icon.Clear();
    }

    // ── Filter ────────────────────────────────────────────────────

    private static readonly HashSet<string> _othersCategories = new(StringComparer.OrdinalIgnoreCase)
    {
        "Application", "AdventureGame", "Astronomy", "Chat", "InstantMessaging",
        "Database", "Engineering", "Electronics", "HamRadio", "IDE", "News",
        "ProjectManagement", "Settings", "Sequencer", "StrategyGame", "TextEditor",
        "TerminalEmulator", "Viewer", "WebDev", "WordProcessor", "X-Tool"
    };

    private static string NormalizeCategory(string cat)
    {
        if (cat.Contains("AudioVideo", StringComparison.OrdinalIgnoreCase)) return "Multimedia";
        if (cat.Contains("Video", StringComparison.OrdinalIgnoreCase)) return "Video";
        if (cat.Contains("Audio", StringComparison.OrdinalIgnoreCase) ||
            cat.Contains("Music", StringComparison.OrdinalIgnoreCase)) return "Audio";
        if (cat.Contains("Photo", StringComparison.OrdinalIgnoreCase)) return "Graphics";
        if (cat.Contains("KDE", StringComparison.OrdinalIgnoreCase)) return "Qt";
        if (cat.Contains("GNOME", StringComparison.OrdinalIgnoreCase)) return "GTK";
        if (cat.Equals("WebDevelopment", StringComparison.OrdinalIgnoreCase)) return "Web Development";
        if (_othersCategories.Contains(cat)) return "Others";
        return cat;
    }

    private bool FilterItem(GObject.Object obj)
    {
        if (obj is not AppImageHubGObject { Item: { } item }) return false;

        if (!string.IsNullOrEmpty(_selectedCategory) &&
            (item.Categories == null ||
             !item.Categories.Any(c => NormalizeCategory(c)
                 .Equals(_selectedCategory, StringComparison.OrdinalIgnoreCase))))
            return false;

        return PackageSearch.Matches(item.Name, item.Description ?? string.Empty, _searchText);
    }

    private void ApplyFilter()
    {
        _filter?.Changed(FilterChange.Different);
    }

    private void ScrollGridToTop()
    {
        if (_gridScroller == null) return;
        Functions.IdleAdd(0, () =>
        {
            if (_gridScroller == null) return false;
            var frames = 0;
            _gridScroller.AddTickCallback((_, _) =>
            {
                var vadj = _gridScroller.GetVadjustment();
                vadj?.SetValue(vadj.GetLower());
                return ++frames < 3;
            });
            return false;
        });
    }

    // ── Detail page ───────────────────────────────────────────────

    private ScrolledWindow BuildDetailPage(Stack outerStack)
    {
        var scroller = ScrolledWindow.New();
        scroller.HscrollbarPolicy = PolicyType.Never;
        scroller.VscrollbarPolicy = PolicyType.Automatic;
        scroller.Hexpand = true;
        scroller.Vexpand = true;

        var root = Box.New(Orientation.Vertical, 0);
        root.Halign = Align.Center;
        root.Hexpand = true;

        var content = Box.New(Orientation.Vertical, 24);
        content.MarginStart = 24;
        content.MarginEnd = 24;
        content.MarginTop = 24;
        content.MarginBottom = 24;
        content.WidthRequest = 680;

        // Header row: back + icon + name/desc
        var headerBox = Box.New(Orientation.Horizontal, 18);

        var backButton = Button.New();
        backButton.IconName = "go-previous-symbolic";
        backButton.Valign = Align.Center;
        backButton.AddCssClass("flat");
        backButton.AddCssClass("circular");
        backButton.OnClicked += (_, _) => outerStack.SetVisibleChildName("grid");
        headerBox.Append(backButton);

        _detailIcon = Image.New();
        _detailIcon.PixelSize = 72;
        _detailIcon.Valign = Align.Center;
        headerBox.Append(_detailIcon);

        var namebox = Box.New(Orientation.Vertical, 4);
        namebox.Valign = Align.Center;
        namebox.Hexpand = true;

        _detailName = Label.New(string.Empty);
        _detailName.AddCssClass("title-1");
        _detailName.Xalign = 0;

        _detailDescription = Label.New(string.Empty);
        _detailDescription.AddCssClass("body");
        _detailDescription.AddCssClass("dim-label");
        _detailDescription.Xalign = 0;
        _detailDescription.SetWrap(true);
        _detailDescription.SetWrapMode(WrapMode.WordChar);
        _detailDescription.SetLines(3);
        _detailDescription.MaxWidthChars = 60;

        namebox.Append(_detailName);
        namebox.Append(_detailDescription);
        headerBox.Append(namebox);

        _detailInstallButton = Button.New();
        _detailInstallButton.Label = T("Install");
        _detailInstallButton.AddCssClass("suggested-action");
        _detailInstallButton.AddCssClass("pill");
        _detailInstallButton.Valign = Align.Center;
        headerBox.Append(_detailInstallButton);

        content.Append(headerBox);

        // Screenshots
        _detailScreenshotsBox = Box.New(Orientation.Horizontal, 8);
        _screenshotScroller = ScrolledWindow.New();
        _screenshotScroller.HscrollbarPolicy = PolicyType.Automatic;
        _screenshotScroller.VscrollbarPolicy = PolicyType.Never;
        _screenshotScroller.SetChild(_detailScreenshotsBox);
        _screenshotScroller.HeightRequest = 220;
        _screenshotScroller.SetVisible(false);

        content.Append(_screenshotScroller);

        // Info list (boxed-list style)
        var infoList = ListBox.New();
        infoList.SetSelectionMode(SelectionMode.None);
        infoList.AddCssClass("boxed-list");

        _detailLicense = Label.New(string.Empty);
        _detailLicense.AddCssClass("dim-label");
        _detailLicense.Xalign = 1;
        infoList.Append(BuildInfoRow(T("License"), _detailLicense));

        _detailAuthors = Label.New(string.Empty);
        _detailAuthors.AddCssClass("dim-label");
        _detailAuthors.Xalign = 1;
        infoList.Append(BuildInfoRow(T("Authors"), _detailAuthors));

        _detailCategories = Label.New(string.Empty);
        _detailCategories.AddCssClass("dim-label");
        _detailCategories.Xalign = 1;
        infoList.Append(BuildInfoRow(T("Categories"), _detailCategories));

        content.Append(infoList);

        root.Append(content);
        scroller.SetChild(root);
        return scroller;
    }

    private static ListBoxRow BuildInfoRow(string labelText, Widget valueWidget)
    {
        var row = ListBoxRow.New();
        var box = Box.New(Orientation.Horizontal, 12);
        box.MarginStart = 12;
        box.MarginEnd = 12;
        box.MarginTop = 12;
        box.MarginBottom = 12;

        var label = Label.New(labelText);
        label.Hexpand = true;
        label.Xalign = 0;
        box.Append(label);
        box.Append(valueWidget);
        row.SetChild(box);
        return row;
    }

    private void ShowDetailPage(AppImageHubItem item, Stack outerStack)
    {
        _selectedItem = item;

        _detailName?.SetText(item.DisplayName);
        _detailDescription?.SetText(item.CleanDescription ?? string.Empty);
        _detailLicense?.SetText(item.License ?? T("Unknown"));
        _detailAuthors?.SetText(
            item.Authors is { Count: > 0 }
                ? string.Join(", ", item.Authors.Select(a => a.Name))
                : T("Unknown"));
        _detailCategories?.SetText(
            item.Categories is { Count: > 0 }
                ? string.Join(", ", item.Categories)
                : T("Unknown"));

        _detailIcon?.SetFromIconName("application-x-executable");
        var iconUrl = item.IconUrl;
        if (iconUrl != null && !iconUrl.EndsWith(".svg", StringComparison.OrdinalIgnoreCase))
        {
            if (_iconCache.TryGetValue(iconUrl, out var cached) && cached != null)
                _detailIcon?.SetFromPaintable(cached);
            else if (File.Exists(DiskCachePath(iconUrl)))
                _detailIcon?.SetFromFile(DiskCachePath(iconUrl));
            else if (_detailIcon != null)
            {
                var di = _detailIcon;
                _ = Task.Run(() => FetchIconAsync(iconUrl, di, _cts.Token), _cts.Token);
            }

        }

        // Screenshots
        if (_detailScreenshotsBox != null)
        {
            while (_detailScreenshotsBox.GetFirstChild() is { } child)
                _detailScreenshotsBox.Remove(child);

            var hasScreenshots = item.Screenshots is { Count: > 0 };
            _screenshotScroller?.SetVisible(hasScreenshots);

            const string prefix =
                "https://raw.githubusercontent.com/AppImage/appimage.github.io/master/database/";

            foreach (var screenshotUrl in item.Screenshots ?? [])
            {
                var url = screenshotUrl.StartsWith("http") ? screenshotUrl : prefix + screenshotUrl;
                var picture = Picture.New();
                picture.ContentFit = ContentFit.Cover;
                picture.HeightRequest = 200;
                picture.WidthRequest = 320;
                picture.AddCssClass("card");

                _ = Task.Run(async () =>
                {
                    try
                    {
                        var bytes = await _httpClient.GetByteArrayAsync(url, _cts.Token);
                        Functions.IdleAdd(0, () =>
                        {
                            try
                            {
                                var stream = Gio.MemoryInputStream.NewFromBytes(GLib.Bytes.New(bytes));
                                var pixbuf = GdkPixbuf.Pixbuf.NewFromStream(stream, null);
                                if (pixbuf == null) return false;
                                picture.SetPaintable(Gdk.Texture.NewForPixbuf(pixbuf));
                            }
                            catch { }
                            return false;
                        });
                    }
                    catch { }
                });

                _detailScreenshotsBox.Append(picture);
            }
        }

        // Wire install button — disconnect previous handler first to prevent accumulation
        if (_detailInstallButton != null)
        {
            _detailInstallButton.SetSensitive(true);
            _detailInstallButton.Label = T("Install");

            if (_installHandler != null)
                _detailInstallButton.OnClicked -= _installHandler;

            _installHandler = async (_, _) =>
            {
                if (_selectedItem != null)
                    await InstallAppAsync(_selectedItem);
            };
            _detailInstallButton.OnClicked += _installHandler;
        }

        outerStack.SetVisibleChildName("detail");

        // Scroll detail to top
        if (_detailPage != null)
        {
            var vadj = _detailPage.GetVadjustment();
            vadj?.SetValue(vadj.GetLower());
        }
    }

    // ── Install ───────────────────────────────────────────────────

    private async Task InstallAppAsync(AppImageHubItem item)
    {
        if (_detailInstallButton != null)
            _detailInstallButton.SetSensitive(false);

        string? downloadUrl = null;
        string updateUrl = string.Empty;
        var updateType = AppImageUpdateType.None;

        try
        {
            // Prefer GitHub/Codeberg — compatible API format
            var forgeUrl = item.GitHubUrl ?? item.CodebergUrl ?? item.ForgejoUrl;
            if (forgeUrl != null)
            {
                lockoutService.Show(T("Resolving latest release for {0}...", item.DisplayName));
                (downloadUrl, updateUrl, updateType) =
                    await ResolveForgeDownloadAsync(forgeUrl);
            }

            // Fallback to direct download
            if (downloadUrl == null && item.DirectDownloadUrl != null)
            {
                downloadUrl = item.DirectDownloadUrl;
                updateUrl = item.DirectDownloadUrl;
                updateType = AppImageUpdateType.StaticUrl;
            }

            if (downloadUrl == null)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(
                        T("No downloadable release found for {0}", item.DisplayName)));
                return;
            }

            var tempPath = Path.Combine(Path.GetTempPath(), item.Name + ".AppImage");

            lockoutService.Show(T("Downloading {0}...", item.DisplayName));
            using (var response = await _httpClient.GetAsync(
                       downloadUrl, HttpCompletionOption.ResponseHeadersRead, _cts.Token))
            {
                response.EnsureSuccessStatusCode();
                await using var fs = File.Create(tempPath);
                await response.Content.CopyToAsync(fs, _cts.Token);
            }

            lockoutService.Show(T("Installing {0}...", item.DisplayName));
            var result = await unprivilegedOperationService.AppImageInstallAsync(
                tempPath, updateUrl, updateType);

            try { File.Delete(tempPath); }
            catch { /* ignore */ }

            if (result.Success)
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(
                        T("{0} installed successfully!", item.DisplayName)));

                if (_detailInstallButton != null)
                {
                    _detailInstallButton.Label = T("Installed");
                    _detailInstallButton.SetSensitive(false);
                }
            }
            else
            {
                genericQuestionService.RaiseToastMessage(
                    new ToastMessageEventArgs(
                        T("Failed to install {0}: {1}", item.DisplayName, result.Error)));

                if (_detailInstallButton != null)
                    _detailInstallButton.SetSensitive(true);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Console.WriteLine($"Install failed for {item.Name}: {ex.Message}");
            genericQuestionService.RaiseToastMessage(
                new ToastMessageEventArgs(T("Installation failed: {0}", ex.Message)));

            if (_detailInstallButton != null)
                _detailInstallButton.SetSensitive(true);
        }
        finally
        {
            lockoutService.Hide();
        }
    }

    private async Task<(string? Url, string UpdateUrl, AppImageUpdateType Type)>
        ResolveForgeDownloadAsync(string forgeUrl)
    {
        try
        {
            string apiUrl;
            AppImageUpdateType updateType;

            if (forgeUrl.Contains("github.com"))
            {
                var path = forgeUrl.Split("github.com")[1].TrimEnd('/');
                apiUrl = "https://api.github.com/repos" + path + "/releases/latest";
                updateType = AppImageUpdateType.GitHub;
            }
            else if (forgeUrl.Contains("codeberg.org"))
            {
                var path = forgeUrl.Split("codeberg.org")[1].TrimEnd('/');
                apiUrl = "https://codeberg.org/api/v1/repos" + path + "/releases?limit=1";
                updateType = AppImageUpdateType.Codeberg;
            }
            else
            {
                return (null, string.Empty, AppImageUpdateType.None);
            }

            var response = await _httpClient.GetAsync(apiUrl, _cts.Token);
            if (!response.IsSuccessStatusCode)
                return (null, string.Empty, AppImageUpdateType.None);

            var json = await response.Content.ReadAsStringAsync(_cts.Token);

            GitHubRelease? release;
            if (updateType == AppImageUpdateType.Codeberg)
            {
                var releases = JsonSerializer.Deserialize(json,
                    ShellyGtkJsonContext.Default.ListGitHubRelease);
                release = releases?.FirstOrDefault();
            }
            else
            {
                release = JsonSerializer.Deserialize(json,
                    ShellyGtkJsonContext.Default.GitHubRelease);
            }

            if (release?.Assets is not { Length: > 0 })
                return (null, string.Empty, AppImageUpdateType.None);

            var appImages = release.Assets
                .Where(a => a.Name.EndsWith(".AppImage", StringComparison.OrdinalIgnoreCase)
                            || a.Name.EndsWith(".appimage", StringComparison.OrdinalIgnoreCase))
                .ToList();

            if (appImages.Count == 0)
                return (null, string.Empty, AppImageUpdateType.None);

            var best =
                appImages.FirstOrDefault(a =>
                    a.Name.Contains("x86_64", StringComparison.OrdinalIgnoreCase) ||
                    a.Name.Contains("x86-64", StringComparison.OrdinalIgnoreCase) ||
                    a.Name.Contains("amd64", StringComparison.OrdinalIgnoreCase))
                ?? appImages.FirstOrDefault(a =>
                    !a.Name.Contains("arm", StringComparison.OrdinalIgnoreCase) &&
                    !a.Name.Contains("i386", StringComparison.OrdinalIgnoreCase) &&
                    !a.Name.Contains("i686", StringComparison.OrdinalIgnoreCase))
                ?? appImages[0];

            return (best.BrowserDownloadUrl, forgeUrl, updateType);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Forge resolve failed: {ex.Message}");
            return (null, string.Empty, AppImageUpdateType.None);
        }
    }

    // ── Helpers ───────────────────────────────────────────────────

    private static ListBoxRow CreateCategoryRow(string iconName, string labelText)
    {
        var row = ListBoxRow.New();
        var box = Box.New(Orientation.Horizontal, 8);
        box.MarginStart = 8;
        box.MarginEnd = 8;
        box.MarginTop = 6;
        box.MarginBottom = 6;

        var img = Image.NewFromIconName(iconName);
        img.PixelSize = 16;
        var lbl = Label.New(labelText);
        lbl.Halign = Align.Start;
        lbl.Hexpand = true;

        box.Append(img);
        box.Append(lbl);
        row.SetChild(box);
        return row;
    }

    private static string CategoryIcon(string category) => category switch
    {
        "AudioVideo" or "Audio" or "Video" or "Multimedia" => "applications-multimedia",
        "Development" => "applications-development",
        "Education" => "applications-education",
        "Game" => "applications-games",
        "Graphics" => "applications-graphics",
        "Network" => "applications-internet",
        "Office" => "applications-office",
        "Science" => "applications-science",
        "System" => "applications-system",
        "Utility" => "applications-utilities",
        _ => "applications-other"
    };
}
