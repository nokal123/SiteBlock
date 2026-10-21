using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using SiteBlock.AppLogic;

namespace SiteBlock.App.Views;

/// <summary>
/// The blocked list: "No sites blocked yet." when empty, otherwise a heading and one box that shows exactly four closed rows and scrolls when there are more, so the panel never changes size as sites are added.
/// The box holds the site rows and, under them, the "Blocked parts of sites" group with its note.
/// </summary>
internal sealed class BlockedListView
{
    private readonly ViewContext _context;
    private readonly Grid _root = new();
    private readonly StackPanel _empty;
    private readonly SpacedStack _list = Ui.Stack(6);
    private readonly TextBlock _heading = Ui.Text("", ThemeKeys.Text, 12.5, FontWeights.SemiBold);
    private readonly TextBlock _count = Ui.Text("", ThemeKeys.TextSecondary, 12.5);
    private readonly SpacedStack _rows = Ui.Stack(BlockedListModel.RowSpacing);
    private readonly OverlayScrollViewer _box;
    private readonly TextBlock _topNote = Note();
    private readonly SpacedStack _innerGroup;
    private readonly TextBlock _innerCount = Ui.Text("", ThemeKeys.TextSecondary, 12.5);
    private readonly Dictionary<BlockedRowModel, BlockedRowView> _views = [];
    private double _rowHeight = 56;

    /// <summary>Creates the list view.</summary>
    public BlockedListView(ViewContext context)
    {
        _context = context;
        TextBlock emptyText = Ui.Text(BlockedListModel.EmptyText, ThemeKeys.TextSecondary);
        emptyText.HorizontalAlignment = HorizontalAlignment.Center;
        TextBlock shield = Ui.Glyph(Glyphs.Shield, ThemeKeys.TextTertiary, 26);
        shield.HorizontalAlignment = HorizontalAlignment.Center;
        _empty = new StackPanel { Margin = new Thickness(0, 18, 0, 18) };
        _empty.Children.Add(shield);
        emptyText.Margin = new Thickness(0, 6, 0, 0);
        _empty.Children.Add(emptyText);

        _heading.TextWrapping = TextWrapping.NoWrap;
        _innerGroup = Ui.Stack(4).With(Ui.Row(6, Ui.Text(BlockedListModel.RulesHeading, ThemeKeys.Text, 12.5, FontWeights.SemiBold), _innerCount), Note());
        _innerGroup.Margin = new Thickness(0, 6, 0, 0);
        _box = new OverlayScrollViewer(_rows);
        _list.With(Ui.Row(6, _heading, _count), _box);
        _root.Children.Add(_empty);
        _root.Children.Add(_list);
    }

    /// <summary>The element to place.</summary>
    public FrameworkElement Element => _root;

    /// <summary>The one gray line under the "Blocked parts of sites" heading.</summary>
    private static TextBlock Note() => Ui.Caption(BlockedListModel.LimitsNote);

    /// <summary>Brings the headings, the rows (in the service's order) and the box height up to date. Rows that left the list stop listening to their models.</summary>
    public void Update()
    {
        BlockedListModel list = _context.Panel.List;
        _empty.Show(list.IsEmpty);
        _list.Show(!list.IsEmpty);
        if (list.IsEmpty)
        {
            DropRowsExcept([]);
            return;
        }
        SetText(_heading, list.TopHeading);
        SetText(_count, list.TopCount.ToString(System.Globalization.CultureInfo.InvariantCulture));
        SetText(_innerCount, list.RuleRows.Count.ToString(System.Globalization.CultureInfo.InvariantCulture));

        // The wanted order: [note when only rules], site rows, [inner heading and note], rule rows.
        var wanted = new List<UIElement>();
        if (list.NoteAtTop) wanted.Add(_topNote);
        wanted.AddRange(list.SiteRows.Select(ViewFor));
        if (list.ShowsInnerRuleHeading) wanted.Add(_innerGroup);
        wanted.AddRange(list.RuleRows.Select(ViewFor));
        DropRowsExcept([.. list.SiteRows, .. list.RuleRows]);
        if (!_rows.Children.Cast<UIElement>().SequenceEqual(wanted))
        {
            _rows.Children.Clear();
            foreach (UIElement element in wanted) _rows.Children.Add(element);
        }
        foreach (BlockedRowView view in _views.Values) view.Update();

        // The box is sized from the height of a closed row on screen, so exactly four fit at any text size.
        double measured = _views.Values.Where(view => view.Model.IsPlainClosed && view.ActualHeight > 0).Select(view => view.ActualHeight).DefaultIfEmpty(_rowHeight).Min();
        if (Math.Abs(measured - _rowHeight) > 0.5) _rowHeight = measured;
        double height = BlockedListModel.BoxHeight(_rowHeight);
        if (Math.Abs(_box.Height - height) > 0.5 || double.IsNaN(_box.Height)) _box.Height = height;
    }

    /// <summary>The view of one row, made the first time the row is seen.</summary>
    private BlockedRowView ViewFor(BlockedRowModel row)
    {
        if (_views.TryGetValue(row, out BlockedRowView? view)) return view;
        view = new BlockedRowView(_context, row);
        // A row's first layout gives the height the box is sized from.
        view.SizeChanged += (_, _) => _context.RequestUpdate();
        _views[row] = view;
        return view;
    }

    /// <summary>Forgets the views of rows that are no longer in the list.</summary>
    private void DropRowsExcept(IReadOnlyCollection<BlockedRowModel> keep)
    {
        var keepSet = keep.ToHashSet();
        foreach (BlockedRowModel gone in _views.Keys.Where(row => !keepSet.Contains(row)).ToList())
        {
            _views[gone].Detach();
            _views.Remove(gone);
        }
    }

    /// <summary>Sets a text only when it changed, so nothing is laid out again for nothing.</summary>
    private static void SetText(TextBlock block, string text)
    {
        if (block.Text != text) block.Text = text;
    }
}

/// <summary>
/// One blocked site or blocked part of a site: the lock, the name and the button that fits; a live countdown while an unblock waits or a temporary unblock is open; the "For a while" / "For good" choice and forms;
/// the row's message line; and a disclosure with the host names or the sentence that explains the rule. The box is gray, red while an unblock waits, and green while a temporary unblock is open.
/// </summary>
internal sealed class BlockedRowView : Border
{
    private readonly ViewContext _context;
    private readonly LockIconView _icon = new();
    private readonly TextBlock _title = Ui.Text("", ThemeKeys.Text, Ui.BodySize, FontWeights.Medium);
    private readonly Button _keepBlocked;
    private readonly Button _unblock;
    private readonly TextBlock _lineLead = Ui.Text("", ThemeKeys.Text, 12.5, FontWeights.SemiBold);
    private readonly TextBlock _lineText = Ui.Text("", ThemeKeys.Text, 12.5);
    private readonly StackPanel _line;
    private readonly DockPanel _choice;
    private readonly SpacedStack _forGood;
    private readonly TextBlock _forGoodText = Ui.Caption();
    private readonly PasswordBox _forGoodPassword;
    private readonly Button _startCountdown;
    private readonly ContentControl _temporaryHost = new() { Focusable = false };
    private TemporaryUnblockFormView? _temporaryView;
    private readonly FeedbackLine _feedback;
    private readonly Button _disclosure;
    private readonly TextBlock _chevron = Ui.Glyph(Glyphs.ChevronRight, ThemeKeys.TextSecondary, 8);
    private readonly TextBlock _detailLabel = Ui.Text("", ThemeKeys.TextSecondary, Ui.CaptionSize);
    private readonly UniformGrid _hosts = new() { Columns = 2, Margin = new Thickness(14, 0, 0, 0) };
    private readonly TextBlock _ruleSentence = Ui.Caption();
    private IReadOnlyList<string> _shownHosts = [];
    private SiteTone? _shownTone;
    private TemporaryUnblockFormModel? _watchedForm;

    /// <summary>Creates the row view and starts listening to its model.</summary>
    public BlockedRowView(ViewContext context, BlockedRowModel model)
    {
        _context = context;
        Model = model;
        CornerRadius = new CornerRadius(8);
        BorderThickness = new Thickness(1);
        Padding = new Thickness(10, 9, 10, 9);

        _title.TextWrapping = TextWrapping.NoWrap;
        _title.TextTrimming = TextTrimming.CharacterEllipsis;
        _title.VerticalAlignment = VerticalAlignment.Center;
        _title.Margin = new Thickness(8, 0, 8, 0);
        _keepBlocked = Ui.Button("", ButtonKind.Blocked, small: true, () => _ = RunAsync(Model.KeepBlockedAsync));
        _unblock = Ui.Button("Unblock…", small: true, onClick: () =>
        {
            Model.OpenChoice();
            _context.RequestUpdate();
        });
        var titleLine = new DockPanel();
        DockPanel.SetDock(_icon, Dock.Left);
        DockPanel.SetDock(_keepBlocked, Dock.Right);
        DockPanel.SetDock(_unblock, Dock.Right);
        titleLine.Children.Add(_icon);
        titleLine.Children.Add(_keepBlocked);
        titleLine.Children.Add(_unblock);
        titleLine.Children.Add(_title);

        _line = Ui.Row(4, _lineLead, _lineText);

        // "For a while" comes first, because it ends on its own.
        _choice = new DockPanel { LastChildFill = false };
        StackPanel choices = Ui.Row(6, Ui.Button("For a while", ButtonKind.Accent, small: true, () =>
        {
            Model.ChooseForAWhile();
            _context.RequestUpdate();
        }), Ui.Button("For good", small: true, onClick: () =>
        {
            Model.ChooseForGood();
            _context.RequestUpdate();
        }));
        Button cancelChoice = Ui.Button("Cancel", small: true, onClick: CloseForm);
        DockPanel.SetDock(choices, Dock.Left);
        DockPanel.SetDock(cancelChoice, Dock.Right);
        _choice.Children.Add(choices);
        _choice.Children.Add(cancelChoice);

        (Grid passwordHost, _forGoodPassword) = Ui.PromptPasswordBox("Password");
        _forGoodPassword.PasswordChanged += (_, _) => Model.ForGoodPassword = _forGoodPassword.Password;
        _forGoodPassword.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            e.Handled = true;
            _ = RunAsync(Model.StartCountdownAsync);
        };
        _startCountdown = Ui.Button("Start countdown", ButtonKind.Accent, small: true, () => _ = RunAsync(Model.StartCountdownAsync));
        var forGoodRow = new DockPanel();
        StackPanel forGoodButtons = Ui.Row(6, Ui.Button("Cancel", small: true, onClick: CloseForm), _startCountdown);
        forGoodButtons.Margin = new Thickness(6, 0, 0, 0);
        DockPanel.SetDock(forGoodButtons, Dock.Right);
        forGoodRow.Children.Add(forGoodButtons);
        forGoodRow.Children.Add(passwordHost);
        _forGood = Ui.Stack(6).With(_forGoodText, forGoodRow);

        _feedback = new FeedbackLine(() => Model.Item.Scope);

        _chevron.RenderTransformOrigin = new Point(0.5, 0.5);
        _chevron.RenderTransform = new RotateTransform();
        _disclosure = new Button { Content = Ui.Row(4, _chevron, _detailLabel), Style = Ui.ButtonStyle(ButtonKind.Borderless, small: true), HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(2, 1, 4, 1), Cursor = Cursors.Hand };
        _disclosure.Click += (_, _) =>
        {
            Model.ToggleDetail();
            _context.RequestUpdate();
        };
        _ruleSentence.Margin = new Thickness(14, 0, 0, 0);

        Child = Ui.Stack(6).With(titleLine, _line, _choice, _forGood, _temporaryHost, _feedback.Element, _disclosure, _hosts, _ruleSentence);
        Model.PropertyChanged += OnModelChanged;
    }

    /// <summary>The row model this view shows.</summary>
    public BlockedRowModel Model { get; }

    /// <summary>Stops listening to the model, when the row leaves the list.</summary>
    public void Detach()
    {
        Model.PropertyChanged -= OnModelChanged;
        WatchForm(null);
    }

    /// <summary>Redraws when anything about the row changes.</summary>
    private void OnModelChanged(object? sender, PropertyChangedEventArgs e) => _context.RequestUpdate();

    /// <summary>Listens to the row's open "For a while" form (and stops listening to an earlier one), so picks and typing redraw the row.</summary>
    private void WatchForm(TemporaryUnblockFormModel? form)
    {
        if (ReferenceEquals(form, _watchedForm)) return;
        if (_watchedForm is not null) _watchedForm.PropertyChanged -= OnModelChanged;
        _watchedForm = form;
        if (form is not null) form.PropertyChanged += OnModelChanged;
    }

    /// <summary>Brings every part of the row up to date with its model and the clock.</summary>
    public void Update()
    {
        RowPresentation shown = Model.Present();
        StatusModel status = _context.Status;

        if (_shownTone != shown.Tone)
        {
            _shownTone = shown.Tone;
            SetResourceReference(BackgroundProperty, ThemeKeys.ToneFill(shown.Tone));
            SetResourceReference(BorderBrushProperty, ThemeKeys.ToneEdge(shown.Tone));
            _lineLead.SetResourceReference(TextBlock.ForegroundProperty, ThemeKeys.ToneAccent(shown.Tone == SiteTone.Neutral ? SiteTone.Blocked : shown.Tone));
            _lineText.SetResourceReference(TextBlock.ForegroundProperty, ThemeKeys.ToneAccent(shown.Tone == SiteTone.Neutral ? SiteTone.Blocked : shown.Tone));
        }
        _icon.Set(shown.Icon, shown.Tone);
        if (_title.Text != Model.Item.Title)
        {
            _title.Text = Model.Item.Title;
            _title.ToolTip = Model.Item.Title;
        }

        bool counting = shown.Button is RowButton.KeepBlocked or RowButton.BlockNow;
        _keepBlocked.Show(counting);
        if (counting) _keepBlocked.Content = shown.ButtonLabel;
        _keepBlocked.IsEnabled = !status.IsBusy;
        _unblock.Show(shown.Button == RowButton.Unblock);

        _line.Show(shown.LineText is not null);
        _lineLead.Show(shown.LineLead is not null);
        _lineLead.Text = shown.LineLead ?? "";
        _lineText.Text = shown.LineText ?? "";

        UnblockStep step = shown.ShowsUnblockFlow ? Model.Step : UnblockStep.Closed;
        _choice.Show(step == UnblockStep.Choosing);
        _forGood.Show(step == UnblockStep.ForGood);
        if (step == UnblockStep.ForGood)
        {
            string explanation = Model.ForGoodExplanation(status.Snapshot?.DelaySeconds ?? 0);
            if (_forGoodText.Text != explanation) _forGoodText.Text = explanation;
            Ui.Sync(_forGoodPassword, Model.ForGoodPassword);
            _startCountdown.IsEnabled = Model.CanStartCountdown;
            if (Model.FocusPasswordRequested)
            {
                Model.FocusPasswordRequested = false;
                Ui.FocusSoon(_forGoodPassword);
            }
        }
        UpdateTemporaryForm(step == UnblockStep.ForAWhile ? Model.TemporaryForm : null);

        _feedback.Update(status.Feedback);

        if (_detailLabel.Text != shown.DetailLabel) _detailLabel.Text = shown.DetailLabel;
        _disclosure.ToolTip = shown.DetailHelp;
        AutomationName(_disclosure, Model.ShowDetail ? "Hide details" : "Show details");
        ((RotateTransform)_chevron.RenderTransform).Angle = Model.ShowDetail ? 90 : 0;
        bool showHosts = Model.ShowDetail && Model.Item.Kind == RowKind.Site;
        _hosts.Show(showHosts);
        if (showHosts && !_shownHosts.SequenceEqual(Model.Item.Hosts)) FillHosts(Model.Item.Hosts);
        _ruleSentence.Show(Model.ShowDetail && shown.RuleSentence is not null);
        _ruleSentence.Text = shown.RuleSentence ?? "";
    }

    /// <summary>Shows the "For a while" form for the given model (making its view when the form is new) or removes it.</summary>
    private void UpdateTemporaryForm(TemporaryUnblockFormModel? form)
    {
        WatchForm(Model.TemporaryForm);
        if (form is null)
        {
            _temporaryView = null;
            _temporaryHost.Content = null;
            _temporaryHost.Show(false);
            return;
        }
        if (_temporaryView?.Form != form)
        {
            _temporaryView = new TemporaryUnblockFormView(_context, Model, form);
            _temporaryHost.Content = _temporaryView.Element;
        }
        _temporaryHost.Show(true);
        _temporaryView.Update();
    }

    /// <summary>Fills the two-column host list with every host name, in a small fixed-width font.</summary>
    private void FillHosts(IReadOnlyList<string> hosts)
    {
        _shownHosts = hosts;
        _hosts.Children.Clear();
        foreach (string host in hosts)
        {
            TextBlock name = Ui.Text(host, ThemeKeys.TextSecondary, 10.5);
            name.FontFamily = Theme.MonoFont;
            name.TextWrapping = TextWrapping.NoWrap;
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            name.ToolTip = host;
            _hosts.Children.Add(name);
        }
    }

    /// <summary>Sets the name a screen reader reads for an element.</summary>
    private static void AutomationName(DependencyObject element, string name) => System.Windows.Automation.AutomationProperties.SetName(element, name);

    /// <summary>Closes the open unblock form and redraws.</summary>
    private void CloseForm()
    {
        Model.CloseForm();
        _context.RequestUpdate();
    }

    /// <summary>Runs one of the row's commands and redraws when it ends.</summary>
    private async Task RunAsync(Func<Task<bool>> command)
    {
        await command();
        _context.RequestUpdate();
    }
}
