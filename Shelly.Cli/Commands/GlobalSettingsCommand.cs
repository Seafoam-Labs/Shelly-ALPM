namespace Shelly.Cli.Commands;

public abstract class GlobalSettingsCommand
{
    /// <summary>
    /// Legacy global no-confirm flag (--no-confirm / -n). When true, all actions skip confirmation.
    /// </summary>
    public bool NoConfirm { get; set; }

    /// <summary>
    /// Per-action no-confirm overrides set via --no-confirm-* flags.
    /// </summary>
    public bool? NoConfirmUpgrade { get; set; }
    public bool? NoConfirmInstall { get; set; }
    public bool? NoConfirmRemove { get; set; }
    public bool? NoConfirmDowngrade { get; set; }
    public bool? NoConfirmAurInstall { get; set; }
    public bool? NoConfirmAurRemove { get; set; }
    public bool? NoConfirmAurUpgrade { get; set; }
    public bool? NoConfirmFlatpakInstall { get; set; }
    public bool? NoConfirmFlatpakRemove { get; set; }
    public bool? NoConfirmFlatpakUpgrade { get; set; }
    public bool? NoConfirmAppImageRemove { get; set; }
    public bool? NoConfirmAppImageUpgrade { get; set; }
    public bool? NoConfirmPurify { get; set; }
    public bool? NoConfirmMark { get; set; }

    public bool UiMode { get; set; }

    public bool JsonOutput { get; set; }

    public bool Verbose { get; set; }

    /// <summary>
    /// Resolves the effective no-confirm value for a given action.
    /// Priority: per-action CLI flag > per-action config > global CLI flag > global config All
    /// </summary>
    protected bool ShouldSkipConfirm(bool actionSpecificConfig)
    {
        // Global CLI flag overrides everything
        if (NoConfirm) return true;
        return actionSpecificConfig;
    }

    /// <summary>
    /// Resolves the default-yes prompt setting from config.
    /// When true, prompts show Y/n (yes by default) instead of y/N.
    /// </summary>
    protected bool DefaultYes => ConfigManager.ReadConfig().NoConfirmSettings.DefaultYesPrompt;

    public abstract ValueTask ExecuteAsync(IShellyConsole console);

    public abstract ValueTask ExecuteUiMode();
}