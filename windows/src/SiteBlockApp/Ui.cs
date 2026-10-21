using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace SiteBlock.App;

/// <summary>The kinds of button the panel draws.</summary>
internal enum ButtonKind
{
    /// <summary>A gray button with an edge.</summary>
    Standard,
    /// <summary>A button filled with the accent color (the main action of a form).</summary>
    Accent,
    /// <summary>A button filled with the blocked tone's red ("Keep blocked", "Block now").</summary>
    Blocked,
    /// <summary>A gray button with red text (uninstall).</summary>
    Destructive,
    /// <summary>A button with no box until the pointer is over it (Settings, Back, disclosures).</summary>
    Borderless,
}

/// <summary>
/// Small builders for the panel's elements, written in code so every part is checked when the app is built. Colors always come from <see cref="ThemeKeys"/> through resource references, so a switch between light and dark mode recolors everything at once.
/// </summary>
internal static class Ui
{
    /// <summary>The normal text size.</summary>
    public const double BodySize = 13;
    /// <summary>The size of captions and small text.</summary>
    public const double CaptionSize = 11.5;
    /// <summary>The size of headlines.</summary>
    public const double HeadlineSize = 14;
    /// <summary>The corner radius of cards, buttons and fields.</summary>
    public const double Radius = 6;

    private static readonly Dictionary<(ButtonKind, bool), Style> ButtonStyles = [];
    private static Style? _textBoxStyle;
    private static Style? _passwordBoxStyle;

    /// <summary>Gives an element a color from the theme.</summary>
    public static T Themed<T>(this T element, DependencyProperty property, string key) where T : FrameworkElement
    {
        element.SetResourceReference(property, key);
        return element;
    }

    /// <summary>A text line that wraps, in the given size and color.</summary>
    public static TextBlock Text(string text = "", string colorKey = ThemeKeys.Text, double size = BodySize, FontWeight? weight = null)
    {
        var block = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, FontWeight = weight ?? FontWeights.Normal };
        block.SetResourceReference(TextBlock.ForegroundProperty, colorKey);
        return block;
    }

    /// <summary>A gray caption line.</summary>
    public static TextBlock Caption(string text = "") => Text(text, ThemeKeys.TextSecondary, CaptionSize);

    /// <summary>A semibold headline.</summary>
    public static TextBlock Headline(string text) => Text(text, ThemeKeys.Text, HeadlineSize, FontWeights.SemiBold);

    /// <summary>One glyph from the icon font.</summary>
    public static TextBlock Glyph(string glyph, string colorKey = ThemeKeys.TextSecondary, double size = 14)
    {
        var block = new TextBlock { Text = glyph, FontFamily = Theme.IconFont, FontSize = size, VerticalAlignment = VerticalAlignment.Center, TextAlignment = TextAlignment.Center };
        block.SetResourceReference(TextBlock.ForegroundProperty, colorKey);
        return block;
    }

    /// <summary>A horizontal row of elements with a gap between them.</summary>
    public static StackPanel Row(double gap, params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        for (int i = 0; i < children.Length; i++)
        {
            if (i > 0 && children[i] is FrameworkElement element) element.Margin = new Thickness(gap, element.Margin.Top, element.Margin.Right, element.Margin.Bottom);
            panel.Children.Add(children[i]);
        }
        return panel;
    }

    /// <summary>A vertical stack whose children are separated by <paramref name="gap"/> pixels; collapsed children take no gap.</summary>
    public static SpacedStack Stack(double gap) => new(gap);

    /// <summary>A thin line across the panel.</summary>
    public static Border Divider()
    {
        var line = new Border { Height = 1, HorizontalAlignment = HorizontalAlignment.Stretch };
        line.SetResourceReference(Border.BackgroundProperty, ThemeKeys.Divider);
        return line;
    }

    /// <summary>The soft rounded box behind rows, banners and settings sections, filled and edged with the given theme colors.</summary>
    public static Border Card(UIElement child, string fillKey = ThemeKeys.CardFill, string edgeKey = ThemeKeys.CardEdge, Thickness? padding = null)
    {
        var card = new Border { Child = child, CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Padding = padding ?? new Thickness(12) };
        card.SetResourceReference(Border.BackgroundProperty, fillKey);
        card.SetResourceReference(Border.BorderBrushProperty, edgeKey);
        return card;
    }

    /// <summary>A button of the given kind with text content. Small buttons use a smaller font and padding.</summary>
    public static Button Button(string label, ButtonKind kind = ButtonKind.Standard, bool small = false, Action? onClick = null)
    {
        var button = new Button { Content = label, Style = ButtonStyle(kind, small), Cursor = Cursors.Hand };
        if (onClick is not null) button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>A borderless button holding a glyph and a label, such as the Settings and Back buttons.</summary>
    public static Button GlyphButton(string glyph, string label, Action onClick)
    {
        var content = Row(6, Glyph(glyph, ThemeKeys.Text, 12), Text(label, ThemeKeys.Text, CaptionSize));
        var button = new Button { Content = content, Style = ButtonStyle(ButtonKind.Borderless, true), Cursor = Cursors.Hand };
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>The cached style for a button kind and size: a rounded box drawn from the theme colors, lighter or darker under the pointer, and faded when switched off.</summary>
    public static Style ButtonStyle(ButtonKind kind, bool small)
    {
        if (ButtonStyles.TryGetValue((kind, small), out Style? cached)) return cached;
        var (fill, hover, pressed, edge, text) = kind switch
        {
            ButtonKind.Accent => (ThemeKeys.Accent, ThemeKeys.AccentHover, ThemeKeys.AccentHover, ThemeKeys.Accent, ThemeKeys.AccentText),
            ButtonKind.Blocked => (ThemeKeys.ToneButton(AppLogic.SiteTone.Blocked), ThemeKeys.ToneButton(AppLogic.SiteTone.Blocked), ThemeKeys.ToneButton(AppLogic.SiteTone.Blocked), ThemeKeys.ToneButton(AppLogic.SiteTone.Blocked), ThemeKeys.ToneButtonText),
            ButtonKind.Destructive => (ThemeKeys.ControlFill, ThemeKeys.ControlFillHover, ThemeKeys.ControlFillPressed, ThemeKeys.ControlEdge, ThemeKeys.Error),
            ButtonKind.Borderless => (ThemeKeys.Clear, ThemeKeys.SubtleHover, ThemeKeys.SubtleHover, ThemeKeys.Clear, ThemeKeys.Text),
            _ => (ThemeKeys.ControlFill, ThemeKeys.ControlFillHover, ThemeKeys.ControlFillPressed, ThemeKeys.ControlEdge, ThemeKeys.Text),
        };

        var border = new FrameworkElementFactory(typeof(Border), "Box");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(small ? 4 : Radius));
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        border.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Control.BorderBrushProperty));
        border.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Control.BorderThicknessProperty));
        border.SetValue(Border.PaddingProperty, new TemplateBindingExtension(Control.PaddingProperty));
        border.SetValue(UIElement.SnapsToDevicePixelsProperty, true);
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        // Labels such as "For a while" are shown exactly; an underscore never turns into an access key.
        presenter.SetValue(ContentPresenter.RecognizesAccessKeyProperty, false);
        border.AppendChild(presenter);

        var style = new Style(typeof(Button));
        style.Setters.Add(new Setter(Control.TemplateProperty, new ControlTemplate(typeof(Button)) { VisualTree = border }));
        style.Setters.Add(new Setter(Control.BackgroundProperty, new DynamicResourceExtension(fill)));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, new DynamicResourceExtension(edge)));
        style.Setters.Add(new Setter(Control.ForegroundProperty, new DynamicResourceExtension(text)));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(kind == ButtonKind.Borderless ? 0 : 1)));
        style.Setters.Add(new Setter(Control.PaddingProperty, small ? new Thickness(9, 3, 9, 4) : new Thickness(12, 5, 12, 6)));
        style.Setters.Add(new Setter(Control.FontSizeProperty, small ? CaptionSize : BodySize));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Center));
        style.Setters.Add(new Setter(FrameworkElement.FocusVisualStyleProperty, null));
        var over = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        over.Setters.Add(new Setter(Control.BackgroundProperty, new DynamicResourceExtension(hover)));
        if (kind == ButtonKind.Blocked) over.Setters.Add(new Setter(UIElement.OpacityProperty, 0.9));
        var down = new Trigger { Property = ButtonBase.IsPressedProperty, Value = true };
        down.Setters.Add(new Setter(Control.BackgroundProperty, new DynamicResourceExtension(pressed)));
        if (kind is ButtonKind.Blocked or ButtonKind.Accent) down.Setters.Add(new Setter(UIElement.OpacityProperty, 0.8));
        var focused = new Trigger { Property = UIElement.IsKeyboardFocusedProperty, Value = true };
        focused.Setters.Add(new Setter(Control.BorderBrushProperty, new DynamicResourceExtension(ThemeKeys.Accent)));
        var off = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        off.Setters.Add(new Setter(UIElement.OpacityProperty, 0.45));
        style.Triggers.Add(over);
        style.Triggers.Add(down);
        style.Triggers.Add(focused);
        style.Triggers.Add(off);
        style.Seal();
        ButtonStyles[(kind, small)] = style;
        return style;
    }

    /// <summary>The style shared by text and password fields: a rounded box whose edge turns to the accent color while the field has the cursor.</summary>
    private static Style FieldStyle(Type type)
    {
        var border = new FrameworkElementFactory(typeof(Border), "Box");
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(4));
        border.SetValue(Border.BackgroundProperty, new TemplateBindingExtension(Control.BackgroundProperty));
        border.SetValue(Border.BorderBrushProperty, new TemplateBindingExtension(Control.BorderBrushProperty));
        border.SetValue(Border.BorderThicknessProperty, new TemplateBindingExtension(Control.BorderThicknessProperty));
        border.SetValue(UIElement.SnapsToDevicePixelsProperty, true);
        // The text itself lives in the part WPF looks for by this name.
        var host = new FrameworkElementFactory(typeof(ScrollViewer), "PART_ContentHost");
        host.SetValue(FrameworkElement.MarginProperty, new Thickness(6, 4, 6, 4));
        host.SetValue(ScrollViewer.HorizontalScrollBarVisibilityProperty, ScrollBarVisibility.Hidden);
        host.SetValue(ScrollViewer.VerticalScrollBarVisibilityProperty, ScrollBarVisibility.Hidden);
        host.SetValue(UIElement.FocusableProperty, false);
        border.AppendChild(host);

        var style = new Style(type);
        style.Setters.Add(new Setter(Control.TemplateProperty, new ControlTemplate(type) { VisualTree = border }));
        style.Setters.Add(new Setter(Control.BackgroundProperty, new DynamicResourceExtension(ThemeKeys.InputFill)));
        style.Setters.Add(new Setter(Control.BorderBrushProperty, new DynamicResourceExtension(ThemeKeys.InputEdge)));
        style.Setters.Add(new Setter(Control.ForegroundProperty, new DynamicResourceExtension(ThemeKeys.Text)));
        style.Setters.Add(new Setter(Control.BorderThicknessProperty, new Thickness(1)));
        style.Setters.Add(new Setter(Control.FontSizeProperty, BodySize));
        style.Setters.Add(new Setter(Control.VerticalContentAlignmentProperty, VerticalAlignment.Center));
        style.Setters.Add(new Setter(FrameworkElement.FocusVisualStyleProperty, null));
        DependencyProperty caret = type == typeof(PasswordBox) ? PasswordBox.CaretBrushProperty : TextBoxBase.CaretBrushProperty;
        DependencyProperty selection = type == typeof(PasswordBox) ? PasswordBox.SelectionBrushProperty : TextBoxBase.SelectionBrushProperty;
        style.Setters.Add(new Setter(caret, new DynamicResourceExtension(ThemeKeys.Text)));
        style.Setters.Add(new Setter(selection, new DynamicResourceExtension(ThemeKeys.Accent)));
        var focused = new Trigger { Property = UIElement.IsKeyboardFocusWithinProperty, Value = true };
        focused.Setters.Add(new Setter(Control.BorderBrushProperty, new DynamicResourceExtension(ThemeKeys.Accent)));
        var off = new Trigger { Property = UIElement.IsEnabledProperty, Value = false };
        off.Setters.Add(new Setter(UIElement.OpacityProperty, 0.5));
        style.Triggers.Add(focused);
        style.Triggers.Add(off);
        style.Seal();
        return style;
    }

    /// <summary>A text field with gray placeholder text that shows while it is empty.</summary>
    public static (Grid Host, TextBox Box) PromptTextBox(string prompt)
    {
        var box = new TextBox { Style = _textBoxStyle ??= FieldStyle(typeof(TextBox)), MinHeight = 30 };
        TextBlock hint = PromptText(prompt);
        box.TextChanged += (_, _) => hint.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var host = new Grid();
        host.Children.Add(box);
        host.Children.Add(hint);
        return (host, box);
    }

    /// <summary>A password field with gray placeholder text that shows while it is empty. Typed characters show as dots.</summary>
    public static (Grid Host, PasswordBox Box) PromptPasswordBox(string prompt)
    {
        var box = new PasswordBox { Style = _passwordBoxStyle ??= FieldStyle(typeof(PasswordBox)), MinHeight = 30 };
        TextBlock hint = PromptText(prompt);
        box.PasswordChanged += (_, _) => hint.Visibility = box.Password.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var host = new Grid();
        host.Children.Add(box);
        host.Children.Add(hint);
        return (host, box);
    }

    /// <summary>The placeholder line inside a field; the pointer passes through it to the field.</summary>
    private static TextBlock PromptText(string prompt)
    {
        TextBlock hint = Text(prompt, ThemeKeys.TextTertiary);
        hint.TextWrapping = TextWrapping.NoWrap;
        hint.IsHitTestVisible = false;
        hint.VerticalAlignment = VerticalAlignment.Center;
        hint.Margin = new Thickness(9, 0, 9, 0);
        return hint;
    }

    /// <summary>Copies a model's password into the field only when they differ, so emptying the model empties the field without moving the cursor otherwise.</summary>
    public static void Sync(PasswordBox box, string value)
    {
        if (box.Password != value) box.Password = value;
    }

    /// <summary>Copies a model's text into the field only when they differ.</summary>
    public static void Sync(TextBox box, string value)
    {
        if (box.Text != value) box.Text = value;
    }

    /// <summary>Puts the cursor in an element once it is on screen.</summary>
    public static void FocusSoon(UIElement element) =>
        element.Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Input, () =>
        {
            if (!element.IsVisible) return;
            element.Focus();
            Keyboard.Focus(element);
        });

    /// <summary>Shows or hides an element without leaving a gap.</summary>
    public static void Show(this UIElement element, bool visible) => element.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;

    /// <summary>One line with a small icon in front: red for an error, gray with a green check for a confirmation.</summary>
    public static MessageLine Message() => new();
}

/// <summary>A vertical stack that puts a fixed gap between its visible children and none around collapsed ones. Each child keeps its own margin; the gap is added between them.</summary>
internal sealed class SpacedStack : Panel
{
    private readonly double _gap;

    /// <summary>Creates the stack with the gap between children.</summary>
    public SpacedStack(double gap) => _gap = gap;

    /// <summary>Adds children in order and returns the stack.</summary>
    public SpacedStack With(params UIElement[] children)
    {
        foreach (UIElement child in children) Children.Add(child);
        return this;
    }

    /// <summary>Measures every child at the available width and adds up the heights of the visible ones plus the gaps between them.</summary>
    protected override Size MeasureOverride(Size availableSize)
    {
        var childSpace = new Size(availableSize.Width, double.PositiveInfinity);
        double width = 0;
        double height = 0;
        bool first = true;
        foreach (UIElement child in InternalChildren)
        {
            child.Measure(childSpace);
            if (child.Visibility == Visibility.Collapsed) continue;
            if (!first) height += _gap;
            first = false;
            height += child.DesiredSize.Height;
            width = Math.Max(width, child.DesiredSize.Width);
        }
        return new Size(width, height);
    }

    /// <summary>Places the visible children one below the other at the full width, with the gap between them.</summary>
    protected override Size ArrangeOverride(Size finalSize)
    {
        double top = 0;
        bool first = true;
        foreach (UIElement child in InternalChildren)
        {
            if (child.Visibility == Visibility.Collapsed)
            {
                child.Arrange(new Rect(0, top, finalSize.Width, 0));
                continue;
            }
            if (!first) top += _gap;
            first = false;
            child.Arrange(new Rect(0, top, finalSize.Width, child.DesiredSize.Height));
            top += child.DesiredSize.Height;
        }
        return finalSize;
    }
}

/// <summary>One message line: a red error icon and red text, or a green check and gray text. Hidden while it has no text.</summary>
internal sealed class MessageLine : Grid
{
    private readonly TextBlock _icon = Ui.Glyph(Glyphs.Error, ThemeKeys.Error, 11);
    private readonly TextBlock _text = Ui.Text("", ThemeKeys.Error, Ui.CaptionSize);

    /// <summary>Creates an empty, hidden line.</summary>
    public MessageLine()
    {
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _icon.VerticalAlignment = VerticalAlignment.Top;
        _icon.Margin = new Thickness(0, 2, 5, 0);
        SetColumn(_text, 1);
        Children.Add(_icon);
        Children.Add(_text);
        Visibility = Visibility.Collapsed;
    }

    /// <summary>Shows the sentence (or hides the line when it is null) in the error or confirmation style.</summary>
    public void Set(string? text, bool isError)
    {
        this.Show(text is not null);
        if (text is null) return;
        if (_text.Text != text) _text.Text = text;
        _icon.Text = isError ? Glyphs.Error : Glyphs.Completed;
        _icon.SetResourceReference(TextBlock.ForegroundProperty, isError ? ThemeKeys.Error : ThemeKeys.Success);
        _text.SetResourceReference(TextBlock.ForegroundProperty, isError ? ThemeKeys.Error : ThemeKeys.TextSecondary);
    }
}

/// <summary>A drop-down picker drawn as a button that opens a menu of choices, like the Mac's menu pickers. The button shows the current choice's words and a small arrow.</summary>
internal sealed class MenuPicker<T> : Button
{
    private readonly TextBlock _label = Ui.Text("", ThemeKeys.Text, Ui.CaptionSize);
    private IReadOnlyList<(T Value, string Label)> _options = [];
    private T _selected = default!;

    /// <summary>Called with the chosen value when the person picks one.</summary>
    public event Action<T>? Picked;

    /// <summary>Creates the picker button.</summary>
    public MenuPicker()
    {
        Style = Ui.ButtonStyle(ButtonKind.Standard, small: true);
        _label.TextWrapping = TextWrapping.NoWrap;
        Content = Ui.Row(6, _label, Ui.Glyph(Glyphs.ChevronDown, ThemeKeys.TextSecondary, 9));
        Cursor = Cursors.Hand;
        Click += (_, _) => OpenMenu();
    }

    /// <summary>Replaces the choices and the current value, and shows the current value's words.</summary>
    public void Set(IReadOnlyList<(T Value, string Label)> options, T selected, string selectedLabel)
    {
        _options = options;
        _selected = selected;
        if (_label.Text != selectedLabel) _label.Text = selectedLabel;
    }

    /// <summary>Opens the menu under the button, with a check by the current choice.</summary>
    private void OpenMenu()
    {
        var menu = new ContextMenu { PlacementTarget = this, Placement = PlacementMode.Bottom };
        foreach (var (value, label) in _options)
        {
            var item = new MenuItem { Header = label, IsCheckable = true, IsChecked = EqualityComparer<T>.Default.Equals(value, _selected) };
            T chosen = value;
            item.Click += (_, _) => Picked?.Invoke(chosen);
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }
}
