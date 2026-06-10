using System.ComponentModel;

namespace Shelly.Gtk.Enums;

public enum RecommendCategory
{
    Audio,
    Browsers,
    Communication,
    Games,
    Development,
    Graphics,
    Utilities,
    [Description("Hardware Tools")]
    HardwareTools,
    Internet,
    Mail,
    Multimedia,
    Office,
    Other,
    Video,
    Virtualization,
    [Description("Shelly Team Picks")]
    ShellyTeam
}