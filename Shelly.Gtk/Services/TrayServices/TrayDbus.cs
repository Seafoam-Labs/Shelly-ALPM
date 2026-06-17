using Tmds.DBus.Protocol;

namespace Shelly.Gtk.Services.TrayServices;

public sealed class TrayDBus : ITrayDbus, IDisposable
{
    private readonly DBusConnection _sessionConnection = new(DBusAddress.Session!);

    public void Dispose()
    {
        _sessionConnection.Dispose();
    }

    public async Task RefreshSettingsAsync()
    {
        await _sessionConnection.ConnectAsync();
        await CallTrayAsync("RefreshSettings");
    }

    public async Task UpdatesMadeInUiAsync()
    {
        await _sessionConnection.ConnectAsync();
        await CallTrayAsync("UpdatesMadeInUi");
    }

    private Task CallTrayAsync(string method)
    {
        var writer = _sessionConnection.GetMessageWriter();

        writer.WriteMethodCallHeader(
            ShellyConstants.TrayService,
            ShellyConstants.TrayPath,
            ShellyConstants.TrayInterface,
            method);

        return _sessionConnection.CallMethodAsync(writer.CreateMessage());
    }
}