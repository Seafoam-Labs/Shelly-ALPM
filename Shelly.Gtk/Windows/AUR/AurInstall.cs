using System.Globalization;
using System.Xml;
using GObject;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Enums;
using static Shelly.Gtk.Helpers.AurColumnViewSorter;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AUR.GObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects;
using Shelly.Gtk.Windows.Dialog;

// ReSharper disable NotAccessedField.Local

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.AUR;

public class AurInstall(
    IPrivilegedOperationService privilegedOperationService,
    ILockoutService lockoutService,
    IPkgBuildService pkgBuildService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    IDirtyService dirtyService) : IShellyWindow, IReloadable
{
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.AurInstalled, DirtyScopes.Config];
    private Box _box = null!;
    private CancellationTokenSource _cts = new();
    private int _loadGeneration;
    private ColumnView _columnView = null!;
    private SingleSelection _selectionModel = null!;
    private Gio.ListStore _listStore = null!;
    private string _searchText = string.Empty;
    private SearchEntry _searchEntry = null!;
    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _votesFactory = null!;
    private SignalListItemFactory _popFactory = null!;
    private SignalListItemFactory _versionFactory = null!;
    private ColumnViewSorter _columnViewSorter = null!;
    private Box _detailBox = null!;
    private AurPackageDto? _currentDetailPkg;
    private Revealer _detailRevealer = null!;
    private Overlay? _mainOverlay = null!;

    private Dictionary<ColumnViewCell, (SignalHandler<CheckButton> OnToggled, EventHandler OnExternalToggle)>
        // ReSharper disable once FieldCanBeMadeReadOnly.Local
        _checkBinding = [];

    private readonly List<AurPackageGObject> _packageGObjectRefs = [];
    private readonly List<AurPackageDto> _aurPackages = [];
    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _votesColumn = null!;
    private ColumnViewColumn _popColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private Button _installButton = null!;
    private CheckButton _chrootCheck = null!;
    private CheckButton _runChecksCheck = null!;

    private Label _searchForPackageLabel = null!;

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/AUR/AurWindow.ui"), -1);
        var rootOverlay = (Overlay)builder.GetObject("main_overlay")!;
        _mainOverlay = rootOverlay;
        _box = (Box)builder.GetObject("AurInstallWindow")!;
        _columnView = (ColumnView)builder.GetObject("package_grid")!;
        _searchEntry = (SearchEntry)builder.GetObject("search_entry")!;

        _mainOverlay = (Overlay)builder.GetObject("main_overlay")!;

        _checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        _checkColumn.Resizable = true;

        _nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        _nameColumn.Resizable = true;

        _votesColumn = (ColumnViewColumn)builder.GetObject("votes_column")!;
        _votesColumn.Resizable = true;

        _popColumn = (ColumnViewColumn)builder.GetObject("popularity_column")!;
        _popColumn.Resizable = true;

        _detailBox = (Box)builder.GetObject("detail_box")!;
        _detailRevealer = (Revealer)builder.GetObject("detail_revealer")!;

        _versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        _versionColumn.Resizable = true;
        _installButton = (Button)builder.GetObject("install_button")!;
        _installButton.SetSensitive(false);
        _chrootCheck = (CheckButton)builder.GetObject("chroot_check")!;
        _runChecksCheck = (CheckButton)builder.GetObject("run_checks_check")!;
        _listStore = Gio.ListStore.New(AurPackageGObject.GetGType());
        _selectionModel = SingleSelection.New(_listStore);
        _selectionModel.CanUnselect = true;
        _selectionModel.Autoselect = false;
        _columnView.SetModel(_selectionModel);
        _searchForPackageLabel = (Label)builder.GetObject("search_overlay")!;
        _searchForPackageLabel.Label_ = "<span size='large'>Search for AUR packages</span>";
        _searchForPackageLabel.Visible = true;

        SetupColumns(_checkColumn, _nameColumn, _votesColumn, _popColumn, _versionColumn);

        // Creating sorter
        _nameColumn.Sorter = CustomSorter.New<AurPackageGObject>((a, b) => 0);
        _versionColumn.Sorter = CustomSorter.New<AurPackageGObject>((a, b) => 0);

        _columnViewSorter = (ColumnViewSorter)_columnView.GetSorter()!;

        _columnViewSorter.OnChanged += (_, _) =>
        {
            var primaryColumn =
                _columnViewSorter.GetPrimarySortColumn();

            if (primaryColumn is null)
                return;

            var sortColumn = GetSortColumn(primaryColumn);

            var order =
                _columnViewSorter.GetPrimarySortOrder();

            if (sortColumn is null)
                return;

            Sort(
                _listStore,
                _aurPackages,
                _packageGObjectRefs,
                sortColumn.Value,
                order
            );
        };

        ColumnViewHelper.AlignColumnHeader(_columnView, 1, Align.Start);
        ColumnViewHelper.AlignColumnHeader(_columnView, 2, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 3, Align.End);
        ColumnViewHelper.AlignColumnHeader(_columnView, 4, Align.End);

        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AurPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
                _installButton.SetSensitive(AnySelected());
            }
        };
        _installButton.OnClicked += (_, _) => { _ = InstallSelectedAsync(); };
        _installButton.CanFocus = true;
        _installButton.ReceivesDefault = true;

        var shortcutController = ShortcutController.New();
        shortcutController.Scope = ShortcutScope.Global;
        shortcutController.PropagationPhase = PropagationPhase.Capture;

        var triggers = new[] { "Return", "KP_Enter", "space" };
        foreach (var triggerStr in triggers)
        {
            var action = CallbackAction.New((_, _) =>
            {
                if (!_installButton.GetSensitive()) return false;
                if (OverlayHelper.HasActiveOverlay(_box)) return false;

                Task.Run(async () => await InstallSelectedAsync());
                return true;
            });
            shortcutController.AddShortcut(Shortcut.New(ShortcutTrigger.ParseString(triggerStr), action));
        }

        _box.AddController(shortcutController);

        _searchEntry.OnActivate += (_, _) =>
        {
            Interlocked.Increment(ref _loadGeneration);
            _ = SearchAsync(_cts.Token, _loadGeneration);
        };
        _sub = DirtySubscription.Attach(dirtyService, this);

        _selectionModel.OnSelectionChanged += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            _detailRevealer.SetTransitionType(RevealerTransitionType.SlideLeft);
            if (item is AurPackageGObject pkgObj)
            {
                ShowPackageDetails(_aurPackages[pkgObj.Index]);
            }
            else
            {
                _detailRevealer.SetRevealChild(false);
                _currentDetailPkg = null;
            }
        };

        return _mainOverlay;
    }

    private PackageSortColumn? GetSortColumn(ColumnViewColumn column)
    {
        if (column == _nameColumn)
            return PackageSortColumn.Name;

        if (column == _versionColumn)
            return PackageSortColumn.Version;

        return null;
    }


    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn,
        ColumnViewColumn votesColumn, ColumnViewColumn popColumn, ColumnViewColumn versionColumn)
    {
        var checkFactory = _checkFactory = SignalListItemFactory.New();
        checkFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var check = CheckButton.New();
            check.MarginStart = 10;
            check.MarginEnd = 10;
            listItem.SetChild(check);
        };

        checkFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;

            checkButton.SetActive(pkgObj.IsSelected);
            checkButton.OnToggled += OnToggled;

            pkgObj.OnSelectionToggled += OnExternalToggle;
            _checkBinding[listItem] = (OnToggled, OnExternalToggle);

            return;

            void OnToggled(CheckButton s, EventArgs e)
            {
                pkgObj.IsSelected = s.GetActive();
                _installButton.SetSensitive(AnySelected());
            }

            void OnExternalToggle(object? s, EventArgs e)
            {
                if (listItem.GetItem() == pkgObj)
                {
                    checkButton.SetActive(pkgObj.IsSelected);
                    _installButton.SetSensitive(AnySelected());
                }
            }
        };

        checkFactory.OnUnbind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject pkgObj ||
                listItem.GetChild() is not CheckButton checkButton) return;
            if (_checkBinding.Remove(listItem, out var handlers))
            {
                pkgObj.OnSelectionToggled -= handlers.OnExternalToggle;
                checkButton.OnToggled -= handlers.OnToggled;
            }
        };

        checkColumn.SetFactory(checkFactory);

        var nameFactory = _nameFactory = SignalListItemFactory.New();
        nameFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        nameFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject { Index: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(_aurPackages[pkg].Name);
            label.Halign = Align.Start;
        };
        nameColumn.SetFactory(nameFactory);

        var votesFactory = _votesFactory = SignalListItemFactory.New();
        votesFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        votesFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject { Index: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(_aurPackages[pkg].NumVotes.ToString(CultureInfo.InvariantCulture));
            label.Halign = Align.End;
        };
        votesColumn.SetFactory(votesFactory);

        var sizeFactory = _popFactory = SignalListItemFactory.New();
        sizeFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        sizeFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject { Index: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(_aurPackages[pkg].Popularity.ToString("F2", CultureInfo.InvariantCulture));
            label.Halign = Align.End;
        };
        popColumn.SetFactory(sizeFactory);

        var versionFactory = _versionFactory = SignalListItemFactory.New();
        versionFactory.OnSetup += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            var label = Label.New(string.Empty);
            listItem.SetChild(label);
        };
        versionFactory.OnBind += (_, args) =>
        {
            if (args.Object is not ColumnViewCell listItem) return;
            if (listItem.GetItem() is not AurPackageGObject { Index: { } pkg } ||
                listItem.GetChild() is not Label label) return;
            label.SetText(_aurPackages[pkg].Version);
            label.Halign = Align.End;
        };
        versionColumn.SetFactory(versionFactory);
    }

    private async Task SearchAsync(CancellationToken ct, int generation = 0)
    {
        _searchText = _searchEntry.GetText();

        if (!string.IsNullOrWhiteSpace(_searchText))
        {
            var result = await privilegedOperationService.SearchAurPackagesAsync(_searchText);
            _searchForPackageLabel.Visible = false;
            ct.ThrowIfCancellationRequested();

            Console.WriteLine($"[DEBUG_LOG] Search result: {result.Count}");

            result = result.OrderByDescending(x => x.NumVotes).ToList();
            GLib.Functions.IdleAdd(0, () =>
            {
                var index = 0;
                if (ct.IsCancellationRequested || _loadGeneration != generation) return false;

                _listStore.RemoveAll();
                _packageGObjectRefs.Clear();
                _aurPackages.Clear();
                foreach (var pkg in result)
                {
                    _aurPackages.Add(pkg);
                    var pkgObj = AurPackageGObject.NewWithProperties([]);
                    pkgObj.Index = index;
                    _packageGObjectRefs.Add(pkgObj);
                    _listStore.Append(pkgObj);
                    index++;
                }

                return false;
            });
        }
    }

    private async Task InstallSelectedAsync()
    {
        var selectedPackages = new List<string>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AurPackageGObject { IsSelected: true } pkgObj)
            {
                selectedPackages.Add(_aurPackages[pkgObj.Index].Name);
            }
        }

        if (selectedPackages.Count != 0)
        {
            OperationResult? result;

            try
            {
                if (!configService.LoadConfig().NoConfirm)
                {
                    var args = new GenericQuestionEventArgs(
                        "Install Packages?", string.Join("\n", selectedPackages)
                    );

                    genericQuestionService.RaiseQuestion(args);
                    if (!await args.ResponseTask)
                    {
                        return;
                    }
                }

                lockoutService.Show($"Installing...");

                var packageBuilds = await privilegedOperationService.GetAurPackageBuild(selectedPackages);

                if (packageBuilds.Count == 0)
                {
                    Console.WriteLine("No packages found.");
                    return;
                }

                foreach (var pkgbuild in packageBuilds)
                {
                    if (pkgbuild.PkgBuild == null) continue;

                    var buildArgs =
                        new PackageBuildEventArgs($"Displaying Package Build {pkgbuild.Name}", pkgbuild.PkgBuild);
                    genericQuestionService.RaisePackageBuild(buildArgs);

                    if (!await buildArgs.ResponseTask)
                    {
                        return;
                    }
                }

                result = await privilegedOperationService.InstallAurPackagesAsync(selectedPackages,
                    _chrootCheck.GetActive(), _runChecksCheck.GetActive());
                if (!result.Success)
                {
                    Console.WriteLine($"Failed to install packages: {result.Error}");
                }
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to install packages: {e.Message}");
                result = new OperationResult
                {
                    Success = false,
                    Error = e.ToString(),
                    ExitCode = -1
                };
            }
            finally
            {
                lockoutService.Hide();
            }

            if (result.Success)
            {
                var args = new ToastMessageEventArgs(
                    $"Installed {selectedPackages.Count} Package(s)"
                );

                genericQuestionService.RaiseToastMessage(args);
                return;
            }

            ShowInstallFailureDialog(selectedPackages, result);
        }
    }

    private void ShowInstallFailureDialog(IReadOnlyCollection<string> selectedPackages, OperationResult result)
    {
        var dialogArgs = AurInstallFailureDialog.Create(
            selectedPackages,
            LogHelpers.BuildFailureSummary(result),
            () => ExportInstallLogAsync(selectedPackages, result));

        genericQuestionService.RaiseDialog(dialogArgs);
    }

    private async Task<bool> ExportInstallLogAsync(IReadOnlyCollection<string> selectedPackages, OperationResult result)
    {
        try
        {
            var dialog = FileDialog.New();
            dialog.SetTitle("Export AUR install log");
            dialog.SetInitialName(LogHelpers.CreateSuggestedLogFileName(selectedPackages, "aur"));

            var filter = FileFilter.New();
            filter.SetName("Log Files (*.log)");
            filter.AddPattern("*.log");

            var filters = Gio.ListStore.New(FileFilter.GetGType());
            filters.Append(filter);
            dialog.SetFilters(filters);

            var file = await dialog.SaveAsync((Window)_box.GetRoot()!);
            if (file is null)
            {
                return false;
            }

            var path = file.GetPath();
            if (string.IsNullOrWhiteSpace(path))
            {
                return false;
            }

            await File.WriteAllTextAsync(path, LogHelpers.BuildInstallLog(selectedPackages, result, "aur"));

            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs("Exported AUR install log"));
            return true;
        }
        catch (Exception e)
        {
            Console.WriteLine($"Failed to export AUR install log: {e.Message}");
            genericQuestionService.RaiseToastMessage(new ToastMessageEventArgs("Failed to export AUR install log"));
            return false;
        }
    }

    private bool AnySelected()
    {
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AurPackageGObject { IsSelected: true })
                return true;
        }

        return false;
    }

    private void ShowPackageDetails(AurPackageDto pkgObj)
    {
        _currentDetailPkg = pkgObj;

        while (_detailBox.GetFirstChild() is { } child)
        {
            _detailBox.Remove(child);
        }

        // pkgbuild preview button
        var pkgBuildButton = Button.New();
        pkgBuildButton.SetName("Package Build");
        pkgBuildButton.SetLabel("Preview PKGBUILD");
        pkgBuildButton.Halign = Align.Fill;
        if (pkgBuildButton.Child is Label label)
        {
            label.Xalign = 0;
        }

        pkgBuildButton.Valign = Align.Start;
        pkgBuildButton.AddCssClass("package-detail-expander");
        pkgBuildButton.TooltipText = "Displays Package Build";
        pkgBuildButton.OnClicked += OnPkgBuildClicked;

        var backButton = Button.New();
        backButton.SetIconName("go-next-symbolic");
        backButton.Halign = Align.Start;
        backButton.AddCssClass("flat");
        backButton.TooltipText = "Close details";
        backButton.OnClicked += (_, _) =>
        {
            _currentDetailPkg = null;
            _selectionModel.UnselectItem(_selectionModel.GetSelected());
            _detailRevealer.SetTransitionType(RevealerTransitionType.SlideLeft);
            _detailRevealer.SetRevealChild(false);
        };
        _detailBox.Append(backButton);

        void AddDetail(string label, string value)
        {
            var row = Box.New(Orientation.Horizontal, 12);
            row.MarginBottom = 4;
            var labelWidget = Label.New(label + ":");
            labelWidget.AddCssClass("dim-label");
            labelWidget.Halign = Align.Start;
            labelWidget.Valign = Align.Start;
            labelWidget.WidthRequest = 80;
            labelWidget.Xalign = 0;

            var valueWidget = Label.New(value);
            valueWidget.Halign = Align.Start;
            valueWidget.Wrap = true;
            valueWidget.WrapMode = Pango.WrapMode.WordChar;
            valueWidget.MaxWidthChars = 30;
            valueWidget.Xalign = 0;
            valueWidget.Selectable = true;

            row.Append(labelWidget);
            row.Append(valueWidget);
            _detailBox.Append(row);
        }
        
        void AddUrl(string labelUrl, string value)
        {
            var row = Box.New(Orientation.Horizontal, 12);
            row.MarginBottom = 4;
            var labelWidget = Label.New(labelUrl);
            labelWidget.AddCssClass("dim-label");
            labelWidget.Halign = Align.Start;
            labelWidget.Valign = Align.Start;
            labelWidget.Xalign = 0;

            var valueWidget = Label.New(null);
            var escaped = GLib.Functions.MarkupEscapeText(value, -1);
            valueWidget.SetMarkup($"<a href=\"{escaped}\">{escaped}</a>");
            valueWidget.Halign = Align.Start;
            valueWidget.Wrap = true;
            valueWidget.WrapMode = Pango.WrapMode.WordChar;
            valueWidget.MaxWidthChars = 30;
            valueWidget.Xalign = 0;

            row.Append(labelWidget);
            row.Append(valueWidget);
            _detailBox.Append(row);
        }

        var headerBox = Box.New(Orientation.Vertical, 4);
        headerBox.MarginBottom = 16;
        headerBox.MarginTop = 8;

        var iconImage = Image.New();
        iconImage.PixelSize = 64;
        iconImage.Halign = Align.Center;
        iconImage.MarginBottom = 8;

        iconImage.SetFromIconName("package-x-generic");

        headerBox.Append(iconImage);

        var nameLabel = Label.New(pkgObj.Name);
        nameLabel.AddCssClass("title-2");
        nameLabel.Halign = Align.Center;
        headerBox.Append(nameLabel);

        var descLabel = Label.New(pkgObj.Description);
        descLabel.AddCssClass("dim-label");
        descLabel.Halign = Align.Center;
        descLabel.Wrap = true;
        descLabel.Justify = Justification.Center;
        descLabel.MaxWidthChars = 40;
        headerBox.Append(descLabel);

        _detailBox.Append(headerBox);

        var separator = Separator.New(Orientation.Horizontal);
        separator.MarginBottom = 16;
        _detailBox.Append(separator);

        AddDetail("Version", pkgObj.Version);
        if (pkgObj.NumVotes > 0)
            AddDetail("Votes", pkgObj.NumVotes.ToString());
        if (pkgObj.Popularity > 0)
            AddDetail("Popularity", pkgObj.Popularity.ToString("F2"));
        if (pkgObj.OutOfDate != null)
            AddDetail("Out of Date", DateTimeOffset.FromUnixTimeSeconds(pkgObj.OutOfDate.Value).ToString("yyyy-MM-dd"));

        AddDetail("Maintainer", pkgObj.Maintainer ?? "Orphaned");
        AddDetail("Last Modified",
            DateTimeOffset.FromUnixTimeSeconds(pkgObj.LastModified).ToString("yyyy-MM-dd HH:mm"));
        AddDetail("First Submitted",
            DateTimeOffset.FromUnixTimeSeconds(pkgObj.FirstSubmitted).ToString("yyyy-MM-dd HH:mm"));
        if (!string.IsNullOrEmpty(pkgObj.Url))
        {
            AddUrl("Url:", pkgObj.Url);
        }
        AddUrl("AUR:", $"https://aur.archlinux.org/packages/{pkgObj.Name}/");
        
        _detailBox.Append(pkgBuildButton);

        if (pkgObj.Depends?.Count > 0)
        {
            AddChipList("Depends", pkgObj.Depends);
        }

        if (pkgObj.MakeDepends?.Count > 0)
        {
            AddChipList("Make Depends", pkgObj.MakeDepends);
        }

        if (pkgObj.CheckDepends?.Count > 0)
        {
            AddChipList("Check Depends", pkgObj.CheckDepends);
        }

        if (pkgObj.OptDepends?.Count > 0)
        {
            AddChipList("Optional Deps", pkgObj.OptDepends, true);
        }

        if (pkgObj.License?.Count > 0)
        {
            AddChipList("License", pkgObj.License);
        }

        if (pkgObj.Keywords?.Count > 0)
        {
            AddChipList("Keywords", pkgObj.Keywords);
        }
        
        if (pkgObj.Provides?.Count > 0)
            AddChipList("Provides", pkgObj.Provides);
        if (pkgObj.Conflicts?.Count > 0)
            AddChipList("Conflicts", pkgObj.Conflicts);
        if (pkgObj.Groups?.Count > 0)
            AddChipList("Groups", pkgObj.Groups);
        if (pkgObj.Replaces?.Count > 0)
            AddChipList("Replaces", pkgObj.Replaces);

        if (configService.LoadConfig().WebViewEnabled)
        {
            if (pkgObj.Depends?.Count > 0)
            {
                var dictionary = new Dictionary<string, List<string>> { { pkgObj.Name, pkgObj.Depends } };

                foreach (var dep in pkgObj.Depends)
                {
                    for (uint i = 0; i < _listStore.GetNItems(); i++)
                    {
                        var obj = _listStore.GetObject(i);
                        if (obj is not AurPackageGObject depObj) continue;
                        if (_aurPackages[depObj.Index].Name.Contains(dep))
                            dictionary.TryAdd(_aurPackages[depObj.Index].Name,
                                _aurPackages[depObj.Index].Depends ?? []);
                    }
                }

                var window = new WebWindow(pkgObj.Name, dictionary);
                _detailBox.Append(window.CreateWindow());
            }
        }

        _detailRevealer.SetRevealChild(true);
        return;

        void AddChipList(string label, IReadOnlyList<string> items, bool isOptional = false)
        {
            var expander = Expander.New($"{label} ({items.Count})");
            expander.AddCssClass("package-detail-expander");
            expander.Hexpand = false;

            var flowBox = FlowBox.New();
            flowBox.SelectionMode = SelectionMode.None;
            flowBox.ColumnSpacing = 6;
            flowBox.RowSpacing = 6;
            flowBox.Halign = Align.Start;
            flowBox.Valign = Align.Start;
            flowBox.MaxChildrenPerLine = isOptional ? 1u : 10u;
            flowBox.MinChildrenPerLine = 1;


            foreach (var item in items)
            {
                var chip = Label.New(item);
                chip.AddCssClass("package-chip");
                chip.Selectable = true;
                chip.Ellipsize = Pango.EllipsizeMode.End;
                chip.MaxWidthChars = 25;

                if (isOptional)
                {
                    chip.Wrap = true;
                    chip.WrapMode = Pango.WrapMode.WordChar;
                    chip.Xalign = 0;
                }

                flowBox.Append(chip);
            }

            expander.SetChild(flowBox);
            _detailBox.Append(expander);
        }
    }

    private async void OnPkgBuildClicked(object? sender, EventArgs e)
    {
        if (_currentDetailPkg == null) return;

        try
        {
            ((Button)sender!).Sensitive = false;

            var package = _currentDetailPkg.Name;

            await pkgBuildService.ShowPreviewAsync(_mainOverlay!, package!, genericQuestionService);
        }
        finally
        {
            ((Button)sender!).Sensitive = true;
        }
    }


    public void Reload()
    {
        var old = Interlocked.Exchange(ref _cts, new CancellationTokenSource());
        old.Cancel();
        old.Dispose();
        Interlocked.Increment(ref _loadGeneration);
        if (!string.IsNullOrEmpty(_searchText))
            _ = SearchAsync(_cts.Token, _loadGeneration);
    }

    public void Dispose()
    {
        _sub?.Dispose();
        _cts.Cancel();
        _cts.Dispose();
        _listStore.RemoveAll();
        foreach (var r in _packageGObjectRefs) r.Dispose();
        _packageGObjectRefs.Clear();
        _checkBinding.Clear();
    }
}