using Cairo;
using Gtk;
using Shelly.Gtk.Helpers;

namespace Shelly.Gtk.Windows;

public class WebWindow(string rootPackage, Dictionary<string, List<string>> dependencyMap) : IShellyWindow
{
    private Box _box = null!;
    private DrawingArea _canvas = null!;

    private double _zoom = 1.0;
    
    private double _panX, _panY;
    private double _panStartX, _panStartY;
    private int _canvasW, _canvasH;

    private Dictionary<string, (double x, double y)> _positions = new();

    public Widget CreateWindow()
    {
        var builder = Builder.NewFromString(
            ResourceHelper.LoadUiFile("UiFiles/WebWindow.ui"), -1);

        _box = (Box)builder.GetObject("WebWindow")!;
        _canvas = (DrawingArea)builder.GetObject("graph_canvas")!;
        _canvas.SetDrawFunc(Draw);

        var scroll = EventControllerScroll.New(EventControllerScrollFlags.Vertical);
        scroll.OnScroll += OnScroll;
        _canvas.AddController(scroll);

        var drag = GestureDrag.New();
        drag.Button = 3;
        drag.OnDragBegin += OnPanBegin;
        drag.OnDragUpdate += OnPanUpdate;
        _canvas.AddController(drag);

        var click = GestureClick.New();
        click.Button = 1;
        click.OnPressed += OnClick;
        _canvas.AddController(click);

        return _box;
    }

    private bool OnScroll(EventControllerScroll sender,
        EventControllerScroll.ScrollSignalArgs args)
    {
        _zoom = Math.Clamp(_zoom * (args.Dy > 0 ? 0.9 : 1.1), 0.2, 5.0);
        _canvas.QueueDraw();
        return true;
    }

    private void OnPanBegin(GestureDrag sender, GestureDrag.DragBeginSignalArgs args)
    {
        _panStartX = _panX;
        _panStartY = _panY;
    }

    private void OnPanUpdate(GestureDrag sender, GestureDrag.DragUpdateSignalArgs args)
    {
        _panX = _panStartX + args.OffsetX;
        _panY = _panStartY + args.OffsetY;
        _canvas.QueueDraw();
    }

    private void OnClick(GestureClick sender, GestureClick.PressedSignalArgs args)
    {
        var gx = (args.X - _canvasW / 2.0 - _panX) / _zoom;
        var gy = (args.Y - _canvasH / 2.0 - _panY) / _zoom;

        const double half = 60 / 2.0;
        foreach (var (name, pos) in _positions)
        {
            if (!(gx >= pos.x - half) || !(gx <= pos.x + half) ||
                !(gy >= pos.y - half) || !(gy <= pos.y + half)) continue;
            OnNodeClicked(name);
            return;
        }
    }

    private static void OnNodeClicked(string packageName)
    {
        Console.WriteLine($"Clicked: {packageName}");
    }

    private void Draw(DrawingArea area, Context cr, int w, int h)
    {
        _canvasW = w;
        _canvasH = h;
        const double nodeSize = 60;
        const double ringStep = 140;
        
        var levels = new Dictionary<string, int> { [rootPackage] = 0 };
        var queue = new Queue<string>();
        queue.Enqueue(rootPackage);

        //omg walk a tree that CS degree i got is finally useful
        //my algo prog would be so proud of me right now
        while (queue.Count > 0)
        {
            var current = queue.Dequeue();
            if (!dependencyMap.TryGetValue(current, out var deps)) continue;

            foreach (var dep in deps.Where(dep => !levels.ContainsKey(dep)))
            {
                levels[dep] = levels[current] + 1;
                queue.Enqueue(dep);
            }
        }
        
        _positions = new Dictionary<string, (double x, double y)>
        {
            [rootPackage] = (0, 0)
        };

        var byLevel = levels
            .GroupBy(kv => kv.Value)
            .OrderBy(g => g.Key)
            .ToDictionary(g => g.Key, g => g.Select(kv => kv.Key).ToList());

        foreach (var (level, nodesAtLevel) in byLevel)
        {
            if (level == 0) continue;
            var r = level * ringStep;

            for (var i = 0; i < nodesAtLevel.Count; i++)
            {
                var angle = 2 * Math.PI * i / nodesAtLevel.Count - Math.PI / 2;
                _positions[nodesAtLevel[i]] = (r * Math.Cos(angle), r * Math.Sin(angle));
            }
        }
        
        cr.Translate(w / 2.0 + _panX, h / 2.0 + _panY);
        cr.Scale(_zoom, _zoom);
        
        cr.SetSourceRgb(0.5, 0.5, 0.5);
        cr.LineWidth = 1.5 / _zoom; // keep edge width visually constant

        foreach (var (package, deps) in dependencyMap)
        {
            if (!_positions.TryGetValue(package, out var from)) continue;
            foreach (var dep in deps)
            {
                if (!_positions.TryGetValue(dep, out var to)) continue;
                cr.MoveTo(from.x, from.y);
                cr.LineTo(to.x, to.y);
                cr.Stroke();
            }
        }
        
        (double R, double G, double B)[] levelColors =
        [
            (0.85, 0.35, 0.35),
            (0.30, 0.55, 0.85),
            (0.25, 0.75, 0.50),
            (0.80, 0.60, 0.20),
        ];

        foreach (var (name, pos) in _positions)
        {
            var level = levels.GetValueOrDefault(name, 0);
            var color = levelColors[Math.Min(level, levelColors.Length - 1)];
            DrawNode(cr, pos.x, pos.y, nodeSize, name, color, _zoom);
        }
    }

    private static void DrawNode(Context cr, double x, double y, double size,
        string label, (double R, double G, double B) color,
        double zoom)
    {
        var half = size / 2;

        cr.SetSourceRgb(color.R, color.G, color.B);
        cr.Rectangle(x - half, y - half, size, size);
        cr.FillPreserve();

        cr.SetSourceRgb(1, 1, 1);
        cr.LineWidth = 1.5 / zoom;
        cr.Stroke();

        cr.SetSourceRgb(1, 1, 1);
        cr.SetFontSize(10 / zoom);
        cr.SelectFontFace("Sans", FontSlant.Normal, FontWeight.Bold);
        cr.TextExtents(label, out var te);
        cr.MoveTo(x - te.Width / 2, y + te.Height / 2);
        cr.ShowText(label);
    }

    public void Dispose()
    {
    }
}