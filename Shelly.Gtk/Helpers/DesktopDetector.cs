namespace Shelly.Gtk.Helpers;

public static class DesktopDetector
{
    public static string DetectDesktop()
    {
        var xdg = (Environment.GetEnvironmentVariable("XDG_CURRENT_DESKTOP") ?? "")
            .ToLowerInvariant();
        var ds  = (Environment.GetEnvironmentVariable("DESKTOP_SESSION") ?? "")
            .ToLowerInvariant();

        if (Has("gnome"))   return "GNOME";
        if (Has("kde") || Has("plasma")) return "KDE";
        return string.IsNullOrEmpty(xdg) ? "KDE" : xdg.ToUpperInvariant();

        bool Has(string needle) =>
            xdg.Contains(needle) || ds.Contains(needle);
    }
}