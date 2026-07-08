namespace Shelly.Utilities;

/// <summary>
/// Granular no-confirm settings per action type.
/// Replaces the single global NoConfirm bool with per-action control.
/// </summary>
public class NoConfirmSettings
{
    // Backward compatibility: if old config has "NoConfirm": true, this maps to All = true
    [System.Text.Json.Serialization.JsonPropertyName("All")]
    public bool All { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("Upgrade")]
    public bool Upgrade { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("Install")]
    public bool Install { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("Remove")]
    public bool Remove { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("Downgrade")]
    public bool Downgrade { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("AurInstall")]
    public bool AurInstall { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("AurRemove")]
    public bool AurRemove { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("AurUpgrade")]
    public bool AurUpgrade { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("FlatpakInstall")]
    public bool FlatpakInstall { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("FlatpakRemove")]
    public bool FlatpakRemove { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("FlatpakUpgrade")]
    public bool FlatpakUpgrade { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("AppImageRemove")]
    public bool AppImageRemove { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("AppImageUpgrade")]
    public bool AppImageUpgrade { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("Purify")]
    public bool Purify { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("Mark")]
    public bool Mark { get; set; }

    [System.Text.Json.Serialization.JsonPropertyName("DefaultYesPrompt")]
    public bool DefaultYesPrompt { get; set; }

    /// <summary>
    /// Resolves the effective value for a given action, checking the specific flag first,
    /// then falling back to the global All setting.
    /// </summary>
    public bool Resolve(bool actionSpecific)
    {
        return All || actionSpecific;
    }
}