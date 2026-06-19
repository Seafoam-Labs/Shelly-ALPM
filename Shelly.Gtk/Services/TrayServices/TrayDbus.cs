using Tmds.DBus.Protocol;

namespace Shelly.Gtk.Services.TrayServices;

public sealed class TrayDBus : ITrayDbus, IDisposable
{
    private readonly DBusConnection _connection = new(DBusAddress.Session!);

    public void Dispose()
    {
        _connection.Dispose();
    }

    public async Task RefreshSettingsAsync()
    {
        await _connection.ConnectAsync();
        await CallTrayAsync("RefreshSettings");
    }

    public async Task UpdatesMadeInUiAsync()
    {
        await _connection.ConnectAsync();
        await CallTrayAsync("UpdatesMadeInUi");
    }

    private Task CallTrayAsync(string method)
    {
        var writer = _connection.GetMessageWriter();

        writer.WriteMethodCallHeader(
            ShellyConstants.TrayService,
            ShellyConstants.TrayPath,
            ShellyConstants.TrayInterface,
            method);

        return _connection.CallMethodAsync(writer.CreateMessage());
    }
}