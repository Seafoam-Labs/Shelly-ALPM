namespace Shelly.Gtk.Helpers;

public static class StringMatching
{
    public static int CalculateLevenshteinDistance(string s, string t)
    {
        var d = new int[s.Length + 1, t.Length + 1];
        for (var i = 0; i <= s.Length; i++) d[i, 0] = i;
        for (var j = 0; j <= t.Length; j++) d[0, j] = j;
        for (var i = 1; i <= s.Length; i++)
        for (var j = 1; j <= t.Length; j++)
            d[i, j] = Math.Min(
                Math.Min(d[i - 1, j] + 1, d[i, j - 1] + 1),
                d[i - 1, j - 1] + (s[i - 1] == t[j - 1] ? 0 : 1));
        return d[s.Length, t.Length];
    }

    public static int PartialRatio(string s, string t)
    {
        if (s.Length > t.Length)
            (s, t) = (t, s);

        var bestScore = 0;
        for (var i = 0; i <= t.Length - s.Length; i++)
        {
            var substring = t.Substring(i, s.Length);
            var dist = CalculateLevenshteinDistance(s.ToLower(), substring.ToLower());
            var score = (int)((1.0 - (double)dist / s.Length) * 100);
            if (score > bestScore)
            {
                bestScore = score;
            }
        }

        return bestScore;
    }
}