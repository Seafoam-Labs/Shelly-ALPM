using Shelly.Utilities;

namespace Shelly.Gtk.Services;

public interface IConfigService
{
    void SaveConfig(ShellyConfig config);
    ShellyConfig LoadConfig();
    event EventHandler<ShellyConfig>? ConfigSaved;
}