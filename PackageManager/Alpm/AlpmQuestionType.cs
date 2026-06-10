namespace PackageManager.Alpm;

public enum AlpmQuestionType
{
    InstallIgnorePkg = 1,
    ReplacePkg = 2,
    ConflictPkg = 4,
    CorruptedPkg = 8,
    ImportKey = 16,
    SelectProvider = 32,
    RemovePkgs = 64,

    //Custom question types
    SelectOptionalDeps = 256,
    UpdateNotice = 512
}