using GObject;
using Gtk;
using Shelly.Gtk.UiModels.PackageManagerObjects.GObjects;

namespace Shelly.Gtk.DataStores;

public sealed class BindState
{
    public AlpmPackageGObject? Pkg;
    public SignalHandler<CheckButton>? Toggled;
    public EventHandler? External;
}