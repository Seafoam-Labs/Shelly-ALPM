namespace Shelly.Gtk.Helpers;

public static class DesktopDetector
{
    public static string DetectDesktop()
    {
        var xdg = Environment.GetEnvironmentVariable("XDG_CURRENT_DESKTOP");
        if (!string.IsNullOrEmpty(xdg))
        {
            return xdg;
        }
        
        var ds = (Environment.GetEnvironmentVariable("DESKTOP_SESSION") ?? "").ToLowerInvariant();
        return ds switch
        {
            "gnome" => "GNOME",
            _ => "KDE"
        };
    }
}