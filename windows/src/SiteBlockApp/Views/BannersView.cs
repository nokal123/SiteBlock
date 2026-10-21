using System.Windows;
using System.Windows.Controls;
using SiteBlock.AppLogic;

namespace SiteBlock.App.Views;

/// <summary>
/// The notices at the top of the home and Settings screens: hosts file trouble, a lockout, a pending delay change, a scheduled uninstall, a running password reset and an available update, each with its live countdown and buttons, plus the message line for banner buttons.
/// Each banner keeps its element while it shows, so its buttons do not flicker as the countdown ticks.
/// </summary>
internal sealed class BannersView
{
    private readonly ViewContext _context;
    private readonly SpacedStack _stack = Ui.Stack(8);
    private readonly Dictionary<BannerKind, BannerCard> _cards = [];
    private readonly FeedbackLine _feedback = new(() => FeedbackScope.Banner);

    /// <summary>Creates the (empty) banner area.</summary>
    public BannersView(ViewContext context)
    {
        _context = context;
        _stack.Children.Add(_feedback.Element);
    }

    /// <summary>The element to place.</summary>
    public FrameworkElement Element => _stack;

    /// <summary>Shows exactly the banners the models call for, in their fixed order, with fresh countdowns; hides the whole area when there is nothing.</summary>
    public void Update()
    {
        PanelModel panel = _context.Panel;
        _stack.Show(panel.HasBannerContent);
        IReadOnlyList<Banner> banners = panel.CurrentBanners();
        var wanted = banners.Select(banner => banner.Kind).ToHashSet();
        foreach (BannerKind gone in _cards.Keys.Where(kind => !wanted.Contains(kind)).ToList())
        {
            _stack.Children.Remove(_cards[gone]);
            _cards.Remove(gone);
        }
        int index = 0;
        foreach (Banner banner in banners)
        {
            if (!_cards.TryGetValue(banner.Kind, out BannerCard? card))
            {
                card = new BannerCard(banner.Kind, banner.Tint, action => _ = RunAsync(action));
                _cards[banner.Kind] = card;
            }
            // Keep the cards in the order the model gives, before the message line.
            int current = _stack.Children.IndexOf(card);
            if (current != index)
            {
                if (current >= 0) _stack.Children.RemoveAt(current);
                _stack.Children.Insert(index, card);
            }
            card.Set(banner, _context.Status.IsBusy);
            index++;
        }
        _feedback.Update(_context.Status.Feedback);
    }

    /// <summary>Carries out a banner button and redraws.</summary>
    private async Task RunAsync(BannerActionKind action)
    {
        await Banners.PerformAsync(_context.Status, action);
        _context.RequestUpdate();
    }

    /// <summary>One banner: a tinted box with an icon, its sentence, the update step or failure lines, and its buttons.</summary>
    private sealed class BannerCard : Border
    {
        private readonly TextBlock _text = Ui.Text();
        private readonly MessageLine _error = new();
        private readonly TextBlock _notice = Ui.Caption();
        private readonly TextBlock _stepText = Ui.Text("", ThemeKeys.TextSecondary);
        private readonly StackPanel _step;
        private readonly StackPanel _buttons = new() { Orientation = Orientation.Horizontal };
        private readonly Action<BannerActionKind> _perform;
        private IReadOnlyList<BannerAction> _actions = [];

        /// <summary>Creates the box for one kind of banner in its tint.</summary>
        public BannerCard(BannerKind kind, BannerTint tint, Action<BannerActionKind> perform)
        {
            _perform = perform;
            CornerRadius = new CornerRadius(8);
            BorderThickness = new Thickness(1);
            Padding = new Thickness(10);
            SetResourceReference(BackgroundProperty, ThemeKeys.BannerFill(tint));
            SetResourceReference(BorderBrushProperty, ThemeKeys.BannerEdge(tint));
            TextBlock icon = Ui.Glyph(IconFor(kind), ThemeKeys.BannerAccent(tint), 14);
            icon.VerticalAlignment = VerticalAlignment.Top;
            icon.Width = 18;
            icon.Margin = new Thickness(0, 1, 8, 0);
            _step = Ui.Row(6, new Spinner(), _stepText);
            SpacedStack content = Ui.Stack(6).With(_text, _step, _error, _notice, _buttons);
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(content, 1);
            grid.Children.Add(icon);
            grid.Children.Add(content);
            Child = grid;
        }

        /// <summary>The icon of each kind: a warning, a lock, a timer, a bin, a key or a download arrow.</summary>
        private static string IconFor(BannerKind kind) => kind switch
        {
            BannerKind.HostsWarning => Glyphs.Warning,
            BannerKind.Lockout => Glyphs.Lock,
            BannerKind.DelayChange => Glyphs.Timer,
            BannerKind.Uninstall => Glyphs.Delete,
            BannerKind.Recovery => Glyphs.Key,
            _ => Glyphs.Download,
        };

        /// <summary>Shows the banner's current words and buttons; buttons that wait on the service are off while a command runs.</summary>
        public void Set(Banner banner, bool busy)
        {
            if (_text.Text != banner.Text) _text.Text = banner.Text;
            _step.Show(banner.StepText is not null);
            if (banner.StepText is { } step && _stepText.Text != step) _stepText.Text = step;
            _error.Set(banner.ErrorText, true);
            _notice.Show(banner.NoticeText is not null);
            _notice.Text = banner.NoticeText ?? "";
            if (!_actions.SequenceEqual(banner.Actions))
            {
                _actions = banner.Actions;
                _buttons.Children.Clear();
                foreach (BannerAction action in banner.Actions)
                {
                    Button button = Ui.Button(action.Label, action.Prominent ? ButtonKind.Accent : ButtonKind.Standard, small: true, () => _perform(action.Kind));
                    button.Tag = action;
                    if (_buttons.Children.Count > 0) button.Margin = new Thickness(8, 0, 0, 0);
                    _buttons.Children.Add(button);
                }
            }
            _buttons.Show(banner.Actions.Count > 0);
            foreach (Button button in _buttons.Children.OfType<Button>())
            {
                if (button.Tag is BannerAction action) button.IsEnabled = !(action.DisabledWhileBusy && busy);
            }
        }
    }
}
