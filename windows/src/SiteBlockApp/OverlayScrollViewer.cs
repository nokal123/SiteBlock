using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace SiteBlock.App;

/// <summary>
/// A scroll area with a thin overlay scroll bar and no track, so the see-through panel shows through where a scroll bar would be.
/// The bar is a small rounded thumb drawn over the content's right edge. It shows while the pointer is over the area or for a second after scrolling, widens under the pointer, and can be dragged; the mouse wheel scrolls as usual.
/// </summary>
internal sealed class OverlayScrollViewer : Grid
{
    /// <summary>The shortest the thumb gets, so it stays easy to grab in a long list.</summary>
    private const double MinThumbHeight = 24;

    private readonly ScrollViewer _viewer;
    private readonly Border _thumb;
    private readonly DispatcherTimer _hideTimer;
    private Point? _dragStart;
    private double _dragStartOffset;

    /// <summary>Creates the area around <paramref name="content"/>.</summary>
    public OverlayScrollViewer(UIElement content)
    {
        // The built-in bar is hidden but scrolling still works: Hidden keeps the wheel and the keyboard working, unlike Disabled.
        _viewer = new ScrollViewer
        {
            Content = content,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Focusable = false,
            PanningMode = PanningMode.VerticalOnly,
        };
        _thumb = new Border
        {
            Width = 3,
            CornerRadius = new CornerRadius(2),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 0, 2, 0),
            Opacity = 0,
            Cursor = Cursors.Arrow,
        };
        _thumb.SetResourceReference(Border.BackgroundProperty, ThemeKeys.ScrollThumb);
        Children.Add(_viewer);
        Children.Add(_thumb);

        _hideTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _hideTimer.Tick += (_, _) =>
        {
            _hideTimer.Stop();
            if (!IsMouseOver && _dragStart is null) _thumb.Opacity = 0;
        };

        _viewer.ScrollChanged += (_, _) =>
        {
            PlaceThumb();
            Reveal();
        };
        SizeChanged += (_, _) => PlaceThumb();
        MouseEnter += (_, _) => Reveal();
        MouseLeave += (_, _) => _hideTimer.Start();
        _thumb.MouseEnter += (_, _) => _thumb.Width = 6;
        _thumb.MouseLeave += (_, _) =>
        {
            if (_dragStart is null) _thumb.Width = 3;
        };
        _thumb.MouseLeftButtonDown += StartDrag;
        _thumb.MouseMove += Drag;
        _thumb.MouseLeftButtonUp += EndDrag;
        _thumb.LostMouseCapture += (_, _) =>
        {
            _dragStart = null;
            _thumb.Width = 3;
        };
    }

    /// <summary>The inner scroll viewer, for callers that need to scroll it.</summary>
    public ScrollViewer Viewer => _viewer;

    /// <summary>Shows the thumb when there is something to scroll, and starts the timer that hides it again.</summary>
    private void Reveal()
    {
        if (_viewer.ExtentHeight <= _viewer.ViewportHeight + 0.5) return;
        _thumb.Opacity = 1;
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    /// <summary>Sizes and places the thumb from the scroll position, or hides it when everything fits.</summary>
    private void PlaceThumb()
    {
        double extent = _viewer.ExtentHeight;
        double viewport = _viewer.ViewportHeight;
        if (extent <= viewport + 0.5 || viewport <= 0)
        {
            _thumb.Visibility = Visibility.Collapsed;
            return;
        }
        _thumb.Visibility = Visibility.Visible;
        double height = Math.Max(MinThumbHeight, viewport * viewport / extent);
        double travel = viewport - height;
        double top = travel * (_viewer.VerticalOffset / (extent - viewport));
        _thumb.Height = height;
        _thumb.Margin = new Thickness(0, Math.Max(0, top), 2, 0);
    }

    /// <summary>Starts dragging the thumb.</summary>
    private void StartDrag(object sender, MouseButtonEventArgs e)
    {
        _dragStart = e.GetPosition(this);
        _dragStartOffset = _viewer.VerticalOffset;
        _thumb.CaptureMouse();
        e.Handled = true;
    }

    /// <summary>Scrolls by the distance the thumb was dragged, scaled from the thumb's track to the content.</summary>
    private void Drag(object sender, MouseEventArgs e)
    {
        if (_dragStart is not { } start) return;
        double extent = _viewer.ExtentHeight;
        double viewport = _viewer.ViewportHeight;
        double travel = viewport - _thumb.ActualHeight;
        if (travel <= 0) return;
        double moved = e.GetPosition(this).Y - start.Y;
        _viewer.ScrollToVerticalOffset(_dragStartOffset + moved * (extent - viewport) / travel);
    }

    /// <summary>Ends a drag.</summary>
    private void EndDrag(object sender, MouseButtonEventArgs e)
    {
        _dragStart = null;
        _thumb.ReleaseMouseCapture();
        e.Handled = true;
    }
}
