using Gtk;

namespace Shelly.Gtk.Windows;

public interface IShellyWindow : IDisposable
{
    Widget CreateWindow();
}