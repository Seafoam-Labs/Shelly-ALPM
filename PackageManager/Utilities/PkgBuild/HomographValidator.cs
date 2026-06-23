using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace PackageManager.Utilities.PkgBuild;

/// <summary>
/// Inspects attacker-controlled strings parsed out of a PKGBUILD (the package
/// name, source URLs and dependency names) for characters that visually
/// resemble ASCII but are not, i.e. <see href="https://en.wikipedia.org/wiki/IDN_homograph_attack">
/// IDN homograph attacks</see>.
///
/// Legitimate pacman / AUR package names are pure printable ASCII, so this
/// validator takes a deliberately conservative stance: anything that is not
/// plain ASCII is examined and, if it contains zero-width / bidi / control
/// characters, mixes Unicode scripts, or maps onto an ASCII look-alike
/// "skeleton" (per the spirit of Unicode UTS #39), it is flagged. Findings
/// reuse the existing <see cref="ValidationResult"/> plumbing so they surface
/// through the same PKGBUILD review path as <see cref="PostInstallValidator"/>.
/// </summary>
public class HomographValidator
{
    public ValidationResult Validate(PkgbuildInfo info)
    {
        var result = new ValidationResult();

        ScanName(info.PkgName, "pkgname", result);

        foreach (var dep in info.Depends)
            ScanName(dep, "depends", result);
        foreach (var dep in info.MakeDepends)
            ScanName(dep, "makedepends", result);

        ScanUrl(info.Url, "url", result);
        foreach (var src in info.Source)
            ScanUrl(src, "source", result);

        return result;
    }

    /// <summary>
    /// Validates an arbitrary attacker-controlled string (e.g. an AUR metadata
    /// field such as Name / Maintainer / Url) outside of a PKGBUILD context.
    /// </summary>
    public ValidationResult ValidateField(string? value, string field)
    {
        var result = new ValidationResult();
        ScanName(value, field, result);
        return result;
    }

    private static void ScanName(string? value, string hook, ValidationResult result)
        => Scan(value, hook, result);

    private static void ScanUrl(string? value, string hook, ValidationResult result)
        => Scan(value, hook, result);

    private static void Scan(string? value, string hook, ValidationResult result)
    {
        if (string.IsNullOrWhiteSpace(value))
            return;

        // ASCII fast-path: every char is printable 7-bit ASCII -> nothing to do.
        if (IsPlainAscii(value))
            return;

        // 1. Zero-width / bidi / other invisible or control characters.
        var hidden = FindHiddenCharacter(value);
        if (hidden is not null)
        {
            result.Findings.Add(new ValidationFinding
            {
                Tool = "<homograph>",
                Hook = hook,
                Severity = ValidationSeverity.Critical,
                MatchedLine = Describe(value),
                Message = $"'{Describe(value)}' in {hook} contains a hidden/invisible character "
                          + $"({hidden}) — this can be used to spoof a trusted name (homograph attack)."
            });
            return;
        }

        // 2. Mixed-script detection: a single token mixing Latin with another
        //    script is the classic homograph signal.
        var scripts = CollectScripts(value);
        if (scripts.Count > 1 && scripts.Contains(ScriptClass.Latin))
        {
            scripts.Remove(ScriptClass.Latin);
            result.Findings.Add(new ValidationFinding
            {
                Tool = "<homograph>",
                Hook = hook,
                Severity = ValidationSeverity.Critical,
                MatchedLine = Describe(value),
                Message = $"'{Describe(value)}' in {hook} mixes Latin with another script "
                          + $"({string.Join(", ", scripts)}) — possible homograph spoofing "
                          + $"(skeleton '{Skeleton(value)}')."
            });
            return;
        }

        // 3. Compatibility / fullwidth forms collapse under NFKC.
        var nfkc = value.Normalize(NormalizationForm.FormKC);
        if (!string.Equals(nfkc, value, System.StringComparison.Ordinal) && IsPlainAscii(nfkc))
        {
            result.Findings.Add(new ValidationFinding
            {
                Tool = "<homograph>",
                Hook = hook,
                Severity = ValidationSeverity.Critical,
                MatchedLine = Describe(value),
                Message = $"'{Describe(value)}' in {hook} uses compatibility/fullwidth characters "
                          + $"that resemble ASCII ('{nfkc}') — possible homograph spoofing."
            });
            return;
        }

        // 4. Confusable skeleton: non-Latin characters that map onto ASCII
        //    look-alikes (e.g. Cyrillic 'а' -> 'a').
        var skeleton = Skeleton(value);
        if (!string.Equals(skeleton, value, System.StringComparison.Ordinal) && IsPlainAscii(skeleton))
        {
            result.Findings.Add(new ValidationFinding
            {
                Tool = "<homograph>",
                Hook = hook,
                Severity = ValidationSeverity.Critical,
                MatchedLine = Describe(value),
                Message = $"'{Describe(value)}' in {hook} contains non-ASCII characters that resemble "
                          + $"ASCII (skeleton '{skeleton}') — possible homograph spoofing."
            });
        }
    }

    private static bool IsPlainAscii(string value)
    {
        foreach (var c in value)
        {
            if (c > 0x7F || char.IsControl(c))
                return false;
        }
        return true;
    }

    private static string? FindHiddenCharacter(string value)
    {
        foreach (var rune in value.EnumerateRunes())
        {
            var v = rune.Value;
            var isHidden =
                v == 0x200B || v == 0x200C || v == 0x200D || v == 0xFEFF || // zero-width / BOM
                (v >= 0x202A && v <= 0x202E) ||                             // bidi embeddings/overrides
                (v >= 0x2066 && v <= 0x2069) ||                            // bidi isolates
                (v != '\t' && v != '\n' && v != '\r' && Rune.GetUnicodeCategory(rune) == UnicodeCategory.Control);

            if (isHidden)
                return $"U+{v:X4}";
        }
        return null;
    }

    private enum ScriptClass
    {
        Latin,
        Cyrillic,
        Greek,
        Armenian,
        Other
    }

    private static HashSet<ScriptClass> CollectScripts(string value)
    {
        var scripts = new HashSet<ScriptClass>();
        foreach (var rune in value.EnumerateRunes())
        {
            var cls = Classify(rune);
            if (cls is not null)
                scripts.Add(cls.Value);
        }
        return scripts;
    }

    private static ScriptClass? Classify(Rune rune)
    {
        var v = rune.Value;

        // Only letters define a script; digits, separators and punctuation are
        // script-neutral and would cause false positives if counted.
        if (!Rune.IsLetter(rune))
            return null;

        if ((v >= 'A' && v <= 'Z') || (v >= 'a' && v <= 'z') ||
            (v >= 0x00C0 && v <= 0x024F)) // Latin-1 Supplement / Extended-A/B letters
            return ScriptClass.Latin;
        if (v >= 0x0370 && v <= 0x03FF) // Greek
            return ScriptClass.Greek;
        if (v >= 0x0400 && v <= 0x04FF) // Cyrillic
            return ScriptClass.Cyrillic;
        if (v >= 0x0530 && v <= 0x058F) // Armenian
            return ScriptClass.Armenian;
        return ScriptClass.Other;
    }

    /// <summary>
    /// Maps a string to a simplified ASCII "skeleton" using a small table of
    /// common confusable characters (a focused subset of Unicode UTS #39
    /// confusables.txt covering the most frequently abused look-alikes).
    /// </summary>
    private static string Skeleton(string value)
    {
        var sb = new StringBuilder(value.Length);
        foreach (var rune in value.Normalize(NormalizationForm.FormKC).EnumerateRunes())
        {
            sb.Append(Confusables.TryGetValue(rune.Value, out var ascii)
                ? ascii
                : rune.ToString());
        }
        return sb.ToString();
    }

    private static readonly Dictionary<int, string> Confusables = new()
    {
        // Cyrillic look-alikes
        { 0x0430, "a" }, { 0x0435, "e" }, { 0x043E, "o" }, { 0x0440, "p" },
        { 0x0441, "c" }, { 0x0445, "x" }, { 0x0443, "y" }, { 0x0456, "i" },
        { 0x0458, "j" }, { 0x0455, "s" }, { 0x04BB, "h" }, { 0x0501, "d" },
        { 0x0410, "A" }, { 0x0412, "B" }, { 0x0415, "E" }, { 0x041A, "K" },
        { 0x041C, "M" }, { 0x041D, "H" }, { 0x041E, "O" }, { 0x0420, "P" },
        { 0x0421, "C" }, { 0x0422, "T" }, { 0x0425, "X" },
        // Greek look-alikes
        { 0x03BF, "o" }, { 0x03B1, "a" }, { 0x03B5, "e" }, { 0x03C1, "p" },
        { 0x03BD, "v" }, { 0x03B9, "i" }, { 0x03BA, "k" }, { 0x039F, "O" },
        { 0x0391, "A" }, { 0x0392, "B" }, { 0x0395, "E" }, { 0x0397, "H" },
        { 0x0399, "I" }, { 0x039A, "K" }, { 0x039C, "M" }, { 0x039D, "N" },
        { 0x03A1, "P" }, { 0x03A4, "T" }, { 0x03A7, "X" },
    };

    /// <summary>
    /// Produces a human-readable rendering of a string in which any non-ASCII
    /// or control character is shown as its codepoint, so a spoofed name cannot
    /// itself spoof the diagnostic message.
    /// </summary>
    private static string Describe(string value)
    {
        var sb = new StringBuilder(value.Length);
        foreach (var rune in value.EnumerateRunes())
        {
            var v = rune.Value;
            if (v <= 0x7F && !char.IsControl((char)v))
                sb.Append((char)v);
            else
                sb.Append($"[U+{v:X4}]");
        }
        return sb.ToString();
    }
}
