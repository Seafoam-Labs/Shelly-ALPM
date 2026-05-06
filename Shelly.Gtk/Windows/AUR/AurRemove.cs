using GObject;
using Gtk;
using Shelly.Gtk.Helpers;
using Shelly.Gtk.Enums;
using static Shelly.Gtk.Helpers.AurColumnViewSorter;
using Shelly.Gtk.Services;
using Shelly.Gtk.UiModels;
using Shelly.Gtk.UiModels.AUR.GObjects;
using Shelly.Gtk.UiModels.PackageManagerObjects;

// ReSharper disable NotAccessedField.Local

// ReSharper disable CollectionNeverQueried.Local

namespace Shelly.Gtk.Windows.AUR;

public class AurRemove(
    IPrivilegedOperationService privilegedOperationService,
    ILockoutService lockoutService,
    IConfigService configService,
    IGenericQuestionService genericQuestionService,
    IDirtyService dirtyService)
    : IShellyWindow, IReloadable
{
    private DirtySubscription? _sub;
    public string[] ListensTo => [DirtyScopes.AurInstalled];
    private Box _box = null!;
    private CancellationTokenSource _cts = new();
    private int _loadGeneration;
    private ColumnView _columnView = null!;
    private SingleSelection _selectionModel = null!;
    private Gio.ListStore _listStore = null!;
    private string _searchText = string.Empty;
    private FilterListModel _filterListModel = null!;
    private CustomFilter _filter = null!;
    private SignalListItemFactory _checkFactory = null!;
    private SignalListItemFactory _nameFactory = null!;
    private SignalListItemFactory _versionFactory = null!;
    private ColumnViewSorter _columnViewSorter = null!;
    private Box _detailBox = null!;
    private AurPackageDto? _currentDetailPkg;
    private Revealer _detailRevealer = null!;

    private Dictionary<ColumnViewCell, (SignalHandler<CheckButton> OnToggled, EventHandler OnExternalToggle)>
        _checkBinding = [];

    private readonly List<AurPackageGObject> _packageGObjectRefs = [];
    private readonly List<AurPackageDto> _aurPackages = [];
    private ColumnViewColumn _checkColumn = null!;
    private ColumnViewColumn _nameColumn = null!;
    private ColumnViewColumn _versionColumn = null!;
    private Button _removeButton = null!;
    private CheckButton _cascadeDeleteCheck = null!;
    private CheckButton _showHiddenCheck = null!;


    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(ResourceHelper.LoadUiFile("UiFiles/AUR/RemoveAurWindow.ui"), -1);
        _box = (Box)builder.GetObject("RemoveAurWindow")!;
        _columnView = (ColumnView)builder.GetObject("package_grid")!;
        var searchEntry = (SearchEntry)builder.GetObject("search_entry")!;

        _checkColumn = (ColumnViewColumn)builder.GetObject("check_column")!;
        _nameColumn = (ColumnViewColumn)builder.GetObject("name_column")!;
        _versionColumn = (ColumnViewColumn)builder.GetObject("version_column")!;
        _versionColumn.Resizable = true;

        _detailBox = (Box)builder.GetObject("detail_box")!;
        _detailRevealer = (Revealer)builder.GetObject("detail_revealer")!;

        _removeButton = (Button)builder.GetObject("remove_button")!;
        _removeButton.SetSensitive(false);
        _cascadeDeleteCheck = (CheckButton)builder.GetObject("cascade_delete_check")!;
        _showHiddenCheck = (CheckButton)builder.GetObject("show_hidden_check")!;
        _listStore = Gio.ListStore.New(AurPackageGObject.GetGType());
        _filter = PackageSearch.CreateSafeFilter(FilterPackage);
        _filterListModel = FilterListModel.New(_listStore, _filter);
        _selectionModel = SingleSelection.New(_filterListModel);
        _selectionModel.CanUnselect = true;
        _selectionModel.Autoselect = true;
        _columnView.SetModel(_selectionModel);

        SetupColumns(_checkColumn, _nameColumn, _versionColumn);
        
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

        _columnView.OnRealize += (_, _) => { Reload(); };
        _columnView.OnActivate += (_, _) =>
        {
            var item = _selectionModel.GetSelectedItem();
            if (item is AurPackageGObject pkgObj)
            {
                pkgObj.ToggleSelection();
            }
        };
        searchEntry.OnSearchChanged += (_, _) =>
        {
            _searchText = searchEntry.GetText();
            ApplyFilter();
        };
        _removeButton.OnClicked += (_, _) => { _ = RemovePackagesAsync(); };
        _showHiddenCheck.OnToggled += (_, _) => { Reload(); };
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
                _detailRevealer.SetTransitionType(RevealerTransitionType.SlideLeft);
                _detailRevealer.SetRevealChild(false);
                _currentDetailPkg = null;
            }
        };

        return _box;
    }
    
    private PackageSortColumn? GetSortColumn(ColumnViewColumn column)
    {
        if (column == _nameColumn)
            return PackageSortColumn.Name;
        
        if (column == _versionColumn)
            return PackageSortColumn.Version;

        return null;
    }


    private bool FilterPackage(GObject.Object obj)
    {
        if (obj is not AurPackageGObject { Index: { } pkg })
            return false;

        return PackageSearch.MatchesName(_aurPackages[pkg].Name, _searchText);
    }

    private void ApplyFilter()
    {
        _filter.Changed(FilterChange.Different);
    }

    private void SetupColumns(ColumnViewColumn checkColumn, ColumnViewColumn nameColumn, ColumnViewColumn versionColumn)
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
                _removeButton.SetSensitive(AnySelected());
            }

            void OnExternalToggle(object? s, EventArgs e)
            {
                if (listItem.GetItem() == pkgObj)
                {
                    checkButton.SetActive(pkgObj.IsSelected);
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

    private async Task LoadDataAsync(CancellationToken ct = default, int generation = 0)
    {
        try
        {
            var packages = await privilegedOperationService.GetAurInstalledPackagesAsync(_showHiddenCheck.Active);
            ct.ThrowIfCancellationRequested();
            Console.WriteLine($@"[DEBUG_LOG] Loaded {packages.Count} installed packages");

            GLib.Functions.IdleAdd(0, () =>
            {
                if (ct.IsCancellationRequested || _loadGeneration != generation) return false;

                _listStore.RemoveAll();
                _packageGObjectRefs.Clear();
                _aurPackages.Clear();
                _currentDetailPkg = null;
                var index = 0;
                foreach (var pkg in packages)
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
        catch (Exception e)
        {
            Console.WriteLine($@"Failed to load installed packages for removal: {e.Message}");
        }
    }

    private async Task RemovePackagesAsync()
    {
        var selectedPackages = new List<string>();
        for (uint i = 0; i < _listStore.GetNItems(); i++)
        {
            var item = _listStore.GetObject(i);
            if (item is AurPackageGObject { IsSelected: true} pkgObj)
            {
                selectedPackages.Add(_aurPackages[pkgObj.Index].Name);
            }
        }

        if (selectedPackages.Count != 0)
        {
            if (!configService.LoadConfig().NoConfirm)
            {
                var args = new GenericQuestionEventArgs(
                    "Remove Packages?", string.Join("\n", selectedPackages)
                );

                genericQuestionService.RaiseQuestion(args);
                if (!await args.ResponseTask)
                {
                    return;
                }
            }


            try
            {
                lockoutService.Show($"Removing...");
                //do work
                var result =
                    await privilegedOperationService.RemoveAurPackagesAsync(selectedPackages,
                        _cascadeDeleteCheck.Active);
                if (!result.Success)
                {
                    Console.WriteLine($"Failed to remove packages: {result.Error}");
                }
                else
                {
                    var args = new ToastMessageEventArgs(
                        $"Removed {selectedPackages.Count} Package(s)"
                    );
                    genericQuestionService.RaiseToastMessage(args);
                }

                Reload();
            }
            catch (Exception e)
            {
                Console.WriteLine($"Failed to remove packages: {e.Message}");
            }
            finally
            {
                lockoutService.Hide();
            }
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
            AddDetail("Out of Date",
                DateTimeOffset.FromUnixTimeSeconds(pkgObj.OutOfDate.Value).ToString("yyyy-MM-dd"));

        AddDetail("Maintainer", pkgObj.Maintainer ?? "Orphaned");
        AddDetail("Last Modified", DateTimeOffset.FromUnixTimeSeconds(pkgObj.LastModified).ToString("yyyy-MM-dd HH:mm"));
        AddDetail("First Submitted",
            DateTimeOffset.FromUnixTimeSeconds(pkgObj.FirstSubmitted).ToString("yyyy-MM-dd HH:mm"));
        if (!string.IsNullOrEmpty(pkgObj.Url))
        {
            var row = Box.New(Orientation.Horizontal, 12);
            row.MarginBottom = 4;
            var labelWidget = Label.New("URL:");
            labelWidget.AddCssClass("dim-label");
            labelWidget.Halign = Align.Start;
            labelWidget.Valign = Align.Start;
            labelWidget.WidthRequest = 80;
            labelWidget.Xalign = 0;

            var valueWidget = Label.New(null);
            var escaped = GLib.Functions.MarkupEscapeText(pkgObj.Url, -1);
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

    public void Reload()
    {
        var old = Interlocked.Exchange(ref _cts, new CancellationTokenSource());
        old.Cancel();
        old.Dispose();
        Interlocked.Increment(ref _loadGeneration);
        _ = LoadDataAsync(_cts.Token, _loadGeneration);
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