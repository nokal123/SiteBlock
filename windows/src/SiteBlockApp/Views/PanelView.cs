using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using SiteBlock.AppLogic;

namespace SiteBlock.App.Views;

/// <summary>
/// The panel's content: picks the screen (connecting, not running, home, Settings) from the model and keeps it up to date.
/// Every model change asks for one redraw, and many changes in a row are folded into a single redraw on the next pass of the window's message loop.
/// </summary>
internal sealed class PanelView : ContentControl
{
    private readonly PanelModel _model;
    private readonly ViewContext _context;
    private IScreenView? _screen;
    private PanelScreen? _shownScreen;
    private bool _updateQueued;

    /// <summary>Creates the view and starts listening to every model whose changes it shows.</summary>
    public PanelView(PanelModel model)
    {
        _model = model;
        _context = new ViewContext(model, RequestUpdate);
        Focusable = false;
        INotifyPropertyChanged[] watched = [model, model.Status, model.Home, model.Home.FirstBlockForm, model.Home.NewPasswordForm, model.Settings];
        foreach (INotifyPropertyChanged source in watched) source.PropertyChanged += (_, _) => RequestUpdate();
        Update();
    }

    /// <summary>Asks for a redraw soon; requests made before it runs are folded into it.</summary>
    public void RequestUpdate()
    {
        if (_updateQueued) return;
        _updateQueued = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            _updateQueued = false;
            Update();
        });
    }

    /// <summary>Shows the right screen (building it when the screen changed) and brings it up to date.</summary>
    public void Update()
    {
        PanelScreen wanted = _model.Screen;
        if (_shownScreen != wanted || _screen is null)
        {
            _shownScreen = wanted;
            _screen = wanted switch
            {
                PanelScreen.NotRunning => new NotRunningScreen(_context),
                PanelScreen.Home => new HomeScreen(_context),
                PanelScreen.Settings => new SettingsScreen(_context),
                _ => new ConnectingScreen(),
            };
            Content = _screen.Root;
        }
        _screen.Update();
    }

    /// <summary>Throws the current screen away, so the next update builds it fresh (with empty fields). The panel calls it when it closes.</summary>
    public void Reset()
    {
        _screen = null;
        _shownScreen = null;
        Content = null;
        Update();
    }
}
