namespace Shelly.Gtk.UiModels;

// NOTE: Values must match PackageManager.Alpm.AlpmQuestionType exactly.
// Add new entries here whenever the CLI emits a new [ALPM_QUESTION_*] marker.
public enum QuestionType
{
    InstallIgnorePkg = 1,
    ReplacePkg = 2,
    ConflictPkg = 4,
    CorruptedPkg = 8,
    ImportKey = 16,
    SelectProvider = 32,
    RemovePkgs = 64,
    SelectOptionalDeps = 256
}
