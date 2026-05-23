using Shelly.Gtk.UiModels;

namespace Shelly.Gtk.Services;

internal static class AlpmMarkerParser
{
    
    private const char FieldSeparator = '\u001F';

    /// <summary>
    /// Parses the marker payload that follows [ALPM_PROVIDER_OPTION] / [ALPM_OPTDEPS_OPTION].
    /// Extended form: idx␟name[␟description][␟installed][␟selected]
    /// Legacy form:   idx:name (or idx:name:desc:installed:selected) — kept for
    /// backwards compatibility with older CLI builds.
    /// </summary>
    public static ProviderOptionUiModel ParseOptionPayload(string payload, out int idx)
    {
        idx = -1;
        var separator = payload.Contains(FieldSeparator) ? FieldSeparator : ':';
        var parts = payload.Split(separator);
        if (parts.Length < 2 || !int.TryParse(parts[0], out idx))
        {
            idx = -1;
            return new ProviderOptionUiModel(payload, null, false);
        }

        var name        = parts[1];
        var description = parts.Length > 2 && parts[2].Length > 0 ? parts[2] : null;
        var installed   = parts.Length > 3 && parts[3] == "1";
        var selected    = parts.Length > 4 && parts[4] == "1";
        return new ProviderOptionUiModel(name, description, installed, selected);
    }

    public static void PlaceAt(List<ProviderOptionUiModel> list, int idx, ProviderOptionUiModel item)
    {
        while (list.Count <= idx)
            list.Add(new ProviderOptionUiModel(string.Empty, null, false));
        list[idx] = item;
    }
}
