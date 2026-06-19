using Shelly.Cli.Commands;
using Shelly.Cli.Interactions;
using Shelly.Utilities;
using Shelly.Utilities.Enums;

namespace Shelly.Cli.Outputs;

/// <summary>
/// Multi-sticky animated bottom-bar region, ported from the legacy Spectre implementation
/// to Shelly's <see cref="IShellyConsole"/> + Pastel.
/// </summary>
public sealed class BottomBarRegion : IDisposable
{
    public readonly record struct LineKey(string Source, string Package, string Action);

    public sealed class BarState
    {
        public string Name = "";
        public double Current;
        public double HowMany;
        public int Pct;
        public string ActionType = "";
    }

    private sealed class StickySlot
    {
        public LineKey Key;
        public string Text = "";
        public DateTime LastUpdate;
    }

    private readonly object _ioLock = new();
    private readonly Dictionary<string, BarState> _bars = new(StringComparer.Ordinal);
    private readonly List<string> _order = [];
    private readonly List<StickySlot> _stickies = [];
    private readonly HashSet<(string Name, string Action)> _finalizedBars = [];
    private readonly List<string> _deferred = [];
    private int _barRowsDrawn;
    private int _stickyDrawnCount;
    private int _frame;
    private bool _suspended;

    private readonly IShellyConsole _console;
    private readonly ProgressBarStyleKind _style;
    private readonly int _barWidth;
    private readonly int _maxStickies;
    private readonly bool _animate;
    private readonly bool _asciiOnly;

    private readonly CancellationTokenSource _frameCts = new();
    private readonly Task? _ticker;

    public BottomBarRegion(IShellyConsole console, ProgressBarStyleKind style, int barWidth, int maxStickies, int fps)
    {
        _console = console;
        _style = style;
        _barWidth = barWidth;
        _maxStickies = Math.Max(1, maxStickies);

        var supportsAnsi = AnsiUtilities.SupportsAnsi;
        _animate = !console.IsOutputRedirected && supportsAnsi;

        var noColor = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("NO_COLOR"));
        _asciiOnly = !supportsAnsi || noColor || console.IsOutputRedirected;

        if (_animate && ProgressBarRenderer.NeedsFrameTicker(_style))
        {
            var delay = Math.Max(50, 1000 / Math.Max(1, fps));
            _ticker = Task.Run(async () =>
            {
                try
                {
                    while (!_frameCts.IsCancellationRequested)
                    {
                        await Task.Delay(delay, _frameCts.Token);
                        lock (_ioLock)
                        {
                            if (_suspended) continue;
                            _frame++;
                            if (_bars.Count > 0)
                            {
                                ClearBars();
                                DrawBars();
                            }
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                }
            }, _frameCts.Token);
        }
    }

    public static BottomBarRegion CreateFromConfig(ShellyConfig cfg, IShellyConsole console)
    {
        var style = ProgressBarRenderer.ParseStyle(cfg.ProgressBarStyle);
        return new BottomBarRegion(console, style, cfg.ProgressBarWidth, cfg.SinglePaneMaxStickies, cfg.ProgressBarFps);
    }

    public void WriteLine(string text)
    {
        lock (_ioLock)
        {
            ClearBars();
            EmitLine(text);
            DrawBars();
        }
    }

    private void EmitLine(string text)
    {
        if (_suspended)
        {
            _deferred.Add(text);
            return;
        }

        _console.Output.WriteLine(_asciiOnly ? AnsiText.StripAnsi(text) : text);
    }

    public void WritePlain(string text)
    {
        lock (_ioLock)
        {
            ClearBars();
            EmitLine(text);
            DrawBars();
        }
    }

    public void WriteEvent(LineKey key, string text)
    {
        lock (_ioLock)
        {
            var slot = _stickies.FirstOrDefault(s => s.Key.Equals(key));
            if (slot is null)
            {
                if (_animate) ClearBars();
                EnsureCapacityForNewSticky();
                slot = new StickySlot { Key = key, Text = text, LastUpdate = DateTime.UtcNow };
                _stickies.Add(slot);
                if (_animate) DrawBars();
                return;
            }

            slot.Text = text;
            slot.LastUpdate = DateTime.UtcNow;
            if (_animate)
            {
                ClearBars();
                DrawBars();
            }
        }
    }

    public void UpdateBar(string name, double current, double howMany, int pct, string actionType)
    {
        lock (_ioLock)
        {
            if (!_animate)
            {
                // Plain / redirected mode: suppress intermediates and emit at most
                // one finalized line per (name, action).
                if (pct < 100) return;
                var finKey = (name, actionType);
                if (!_finalizedBars.Add(finKey)) return;

                var rPlain = new BarState
                {
                    Name = name,
                    Current = current,
                    HowMany = howMany,
                    Pct = pct,
                    ActionType = actionType
                };
                EmitLine(RenderBarLine(rPlain));
                return;
            }

            // Animated: dedupe unchanged events for the same key.
            if (_bars.TryGetValue(name, out var existing)
                && existing.Pct == pct
                && existing.Current.Equals(current)
                && existing.ActionType == actionType)
                return;

            // If we've already finalized this (name, action) at 100%, drop it.
            var finKeyAnim = (name, actionType);
            if (pct >= 100 && _finalizedBars.Contains(finKeyAnim))
                return;

            if (!_bars.TryGetValue(name, out var r))
            {
                r = new BarState { Name = name };
                _bars[name] = r;
                _order.Add(name);
            }

            r.Current = current;
            r.HowMany = howMany;
            r.Pct = pct;
            r.ActionType = actionType;

            ClearBars();
            if (pct >= 100)
            {
                EmitLine(RenderBarLine(r));
                _bars.Remove(name);
                _order.Remove(name);
                _finalizedBars.Add(finKeyAnim);
            }

            DrawBars();
        }
    }

    public void PromoteBar(string name)
    {
        lock (_ioLock)
        {
            if (!_bars.TryGetValue(name, out var r)) return;
            if (_animate) ClearBars();
            EmitLine(RenderBarLine(r));
            _finalizedBars.Add((name, r.ActionType));
            _bars.Remove(name);
            _order.Remove(name);
            if (_animate) DrawBars();
        }
    }

    public void FinalizeSticky(LineKey key)
    {
        lock (_ioLock)
        {
            var idx = _stickies.FindIndex(s => s.Key.Equals(key));
            if (idx < 0) return;
            var slot = _stickies[idx];
            _stickies.RemoveAt(idx);
            if (_animate)
            {
                ClearBars();
                EmitLine(slot.Text);
                DrawBars();
            }
            else
            {
                EmitLine(slot.Text);
            }
        }
    }

    public void FinalizeStickiesWhere(Func<LineKey, bool> predicate)
    {
        lock (_ioLock)
        {
            var matched = _stickies.Where(s => predicate(s.Key)).ToList();
            if (matched.Count == 0) return;
            if (_animate) ClearBars();
            foreach (var s in matched)
            {
                _stickies.Remove(s);
                EmitLine(s.Text);
            }

            if (_animate) DrawBars();
        }
    }

    public void FinalizeAllStickies()
    {
        lock (_ioLock)
        {
            if (_stickies.Count == 0) return;
            if (_animate) ClearBars();
            foreach (var s in _stickies)
            {
                EmitLine(s.Text);
            }

            _stickies.Clear();
            if (_animate) DrawBars();
        }
    }

    public void SuspendForPrompt()
    {
        lock (_ioLock)
        {
            FinalizeAllStickies();
            ClearBars();
            _suspended = true;
            _console.Output.Flush();
        }
    }

    public void Resume()
    {
        lock (_ioLock)
        {
            _suspended = false;
            if (_deferred.Count > 0)
            {
                foreach (var line in _deferred)
                    EmitLine(line);
                _deferred.Clear();
            }

            DrawBars();
        }
    }

    public T RunInteractive<T>(Func<T> prompt)
    {
        SuspendForPrompt();
        try
        {
            return prompt();
        }
        finally
        {
            Resume();
        }
    }

    public void RunInteractive(Action prompt)
    {
        SuspendForPrompt();
        try
        {
            prompt();
        }
        finally
        {
            Resume();
        }
    }

    public void Dispose()
    {
        try
        {
            _frameCts.Cancel();
        }
        catch
        {
        }

        if (_ticker != null)
        {
            try
            {
                _ticker.GetAwaiter().GetResult();
            }
            catch
            {
            }
        }

        lock (_ioLock)
        {
            FinalizeAllStickies();
            ClearBars();
            _bars.Clear();
            _order.Clear();
        }

        _frameCts.Dispose();
    }

    private void DrawBars()
    {
        if (!_animate || _suspended) return;
        DrawStickies();
        foreach (var key in _order)
        {
            var line = RenderBarLine(_bars[key]);
            _console.Output.WriteLine(_asciiOnly ? AnsiText.StripAnsi(line) : line);
            _barRowsDrawn++;
        }

        _console.Output.Flush();
    }

    private void ClearBars()
    {
        if (!_animate || _suspended) return;
        if (_barRowsDrawn > 0)
        {
            for (var i = 0; i < _barRowsDrawn; i++)
            {
                _console.Output.Write("\x1b[1A\x1b[2K");
            }

            _console.Output.Write("\r");
            _barRowsDrawn = 0;
        }

        ClearStickies();
    }

    private void DrawStickies()
    {
        if (!_animate || _stickies.Count == 0 || _stickyDrawnCount > 0) return;
        foreach (var s in _stickies)
        {
            var t = TruncateStickyText(s.Text);
            _console.Output.WriteLine(_asciiOnly ? AnsiText.StripAnsi(t) : t);
        }

        _stickyDrawnCount = _stickies.Count;
    }

    private void ClearStickies()
    {
        if (!_animate || _stickyDrawnCount == 0) return;
        for (var i = 0; i < _stickyDrawnCount; i++)
        {
            _console.Output.Write("\x1b[1A\x1b[2K");
        }

        _console.Output.Write("\r");
        _stickyDrawnCount = 0;
    }

    private void EnsureCapacityForNewSticky()
    {
        while (_stickies.Count >= _maxStickies)
        {
            var victimIdx = 0;
            var victimTime = _stickies[0].LastUpdate;
            for (var i = 1; i < _stickies.Count; i++)
            {
                if (_stickies[i].LastUpdate < victimTime)
                {
                    victimTime = _stickies[i].LastUpdate;
                    victimIdx = i;
                }
            }

            var victim = _stickies[victimIdx];
            _stickies.RemoveAt(victimIdx);
            EmitLine(victim.Text);
        }
    }

    private string RenderBarLine(BarState r)
    {
        var bar = _asciiOnly
            ? ProgressBarRenderer.RenderAscii(r.Pct, _frame, _style, _barWidth)
            : ProgressBarRenderer.Render(r.Pct, _frame, _style, _barWidth);
        var line = $"({r.Current:0}/{r.HowMany:0}) {r.ActionType} {r.Name} {bar} {r.Pct,3}%";

        var max = Math.Max(20, SafeWindowWidth() - 1);
        if (AnsiText.VisibleLength(line) > max)
            line = AnsiText.TruncateVisible(line, max);

        return line;
    }

    private static string TruncateStickyText(string text)
    {
        var max = Math.Max(20, SafeWindowWidth() - 1);
        return AnsiText.VisibleLength(text) <= max
            ? text
            : AnsiText.TruncateVisible(text, max);
    }

    private static int SafeWindowWidth()
    {
        try { return Console.WindowWidth > 0 ? Console.WindowWidth : 80; }
        catch { return 80; }
    }
}
