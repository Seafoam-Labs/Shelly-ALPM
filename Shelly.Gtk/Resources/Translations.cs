using System.Runtime.InteropServices;

namespace Shelly.GTK.Resources;

internal static partial class Translations
{
    public const string Domain = "shelly-ui";

    [LibraryImport("libc", StringMarshalling = StringMarshalling.Utf8)]
    private static partial nint bindtextdomain(string domainname, string dirname);

    [LibraryImport("libc", StringMarshalling = StringMarshalling.Utf8)]
    private static partial nint bind_textdomain_codeset(string domainname, string codeset);

    [LibraryImport("libc", StringMarshalling = StringMarshalling.Utf8)]
    // ReSharper disable once InconsistentNaming
    private static partial string setlocale(int category, [MarshalAs(UnmanagedType.LPStr)] string locale);

    // ReSharper disable once InconsistentNaming
    private const int LC_ALL = 6;
    
    [LibraryImport("libc", EntryPoint = "setenv", SetLastError = true, StringMarshalling = StringMarshalling.Utf8)]
    private static partial int setenv(string name, string value, int overwrite);
    
    [LibraryImport("libc", EntryPoint = "unsetenv", SetLastError = true, StringMarshalling = StringMarshalling.Utf8)]
    private static partial int unsetenv(string name);

    internal static void Init(string? culture = null)
    {
        if (string.IsNullOrWhiteSpace(culture))
            unsetenv("LANGUAGE");   
        else
            setenv("LANGUAGE", culture, 1);
        
        setlocale(LC_ALL, "");
        const string localeDir = "/usr/share/locale";
        bindtextdomain(Domain, localeDir);
        bind_textdomain_codeset(Domain, "UTF-8");
    }

    internal static string T(string msgid)
    {
        try
        {
            return GLib.Functions.Dgettext(Domain, msgid);
        }
        catch (DllNotFoundException)
        {
            return msgid;
        }
    }

    internal static string T(string msgid, params object[] args)
    {
        try
        {
            return string.Format(GLib.Functions.Dgettext(Domain, msgid), args);
        }
        catch (DllNotFoundException)
        {
            return string.Format(msgid, args);
        }
    }
}
