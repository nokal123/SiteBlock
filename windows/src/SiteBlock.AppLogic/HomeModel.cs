using SiteBlock.Core;

namespace SiteBlock.AppLogic;

/// <summary>Which inline password form is open on the home screen.</summary>
public enum PasswordFormMode
{
    /// <summary>None is open.</summary>
    None,
    /// <summary>The form under the add field, opened by pressing Block before any password exists.</summary>
    FirstBlock,
    /// <summary>The form inside the "Choose a new password" banner, after a password reset cleared the password while sites stay blocked.</summary>
    NewPassword,
}

/// <summary>
/// The home screen's own state and rules: the text in the add field, the "Only this part" / "Whole site" choice that appears when the text has a path, and the two inline password forms.
/// The password is chosen at the first block: pressing Block with no password set opens the "Choose a SiteBlock password" form instead of sending anything. Call its members on the screen's thread.
/// </summary>
public sealed class HomeModel : ObservableModel
{
    /// <summary>The gray line above the add field.</summary>
    public const string AddCaption = "Block a whole site (youtube.com) or just part of one (youtube.com/shorts).";
    /// <summary>The add field's placeholder.</summary>
    public const string AddPrompt = "Add a site (e.g. reddit.com)";
    /// <summary>The add button.</summary>
    public const string BlockTitle = "Block";
    /// <summary>The narrow choice under the field.</summary>
    public const string OnlyThisPartTitle = "Only this part";
    /// <summary>The wide choice under the field.</summary>
    public const string WholeSiteTitle = "Whole site";
    /// <summary>The caption under "Whole site".</summary>
    public const string WholeSiteCaption = "Blocks the whole site, not just the part after its name.";
    /// <summary>The first-block form's button.</summary>
    public const string FirstBlockSubmitTitle = "Set password and block";
    /// <summary>The new-password form's button.</summary>
    public const string NewPasswordSubmitTitle = "Set password";
    /// <summary>The banner shown when a reset cleared the password while sites stay blocked.</summary>
    public const string NoPasswordText = "SiteBlock has no password right now, so no site can be unblocked. Your blocked sites stay blocked.";
    /// <summary>The banner's button.</summary>
    public const string ChooseNewPasswordTitle = "Choose a new password";

    private readonly StatusModel _status;
    private string _addText = "";
    private bool _onlyThisPart = true;
    private PasswordFormMode _passwordForm = PasswordFormMode.None;
    private bool _focusAddField;

    /// <summary>Creates the home model and its two password forms.</summary>
    public HomeModel(StatusModel status)
    {
        _status = status ?? throw new ArgumentNullException(nameof(status));
        FirstBlockForm = new SetupFormModel(status, FirstBlockSubmitTitle, SetPasswordAndBlockAsync);
        NewPasswordForm = new SetupFormModel(status, NewPasswordSubmitTitle, status.SetupAsync);
        // Once a password exists, neither form has anything left to do, so the open one closes.
        status.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(StatusModel.Snapshot) && status.Snapshot?.PasswordSet == true) PasswordForm = PasswordFormMode.None;
        };
    }

    /// <summary>The form opened by Block before any password exists.</summary>
    public SetupFormModel FirstBlockForm { get; }

    /// <summary>The form inside the "Choose a new password" banner.</summary>
    public SetupFormModel NewPasswordForm { get; }

    /// <summary>The text in the add field. When a path appears in it, "Only this part" is selected again.</summary>
    public string AddText
    {
        get => _addText;
        set
        {
            bool hadPath = HasPath;
            if (!SetField(ref _addText, value ?? "")) return;
            if (!hadPath && HasPath) OnlyThisPart = true;
            RaiseDerived();
        }
    }

    /// <summary>True for "Only this part" (a path rule), false for "Whole site". It matters only while the text has a path.</summary>
    public bool OnlyThisPart
    {
        get => _onlyThisPart;
        set
        {
            if (SetField(ref _onlyThisPart, value)) RaiseDerived();
        }
    }

    /// <summary>Which password form is open.</summary>
    public PasswordFormMode PasswordForm
    {
        get => _passwordForm;
        set
        {
            if (!SetField(ref _passwordForm, value)) return;
            if (value == PasswordFormMode.FirstBlock) FirstBlockForm.FocusPasswordRequested = true;
            if (value == PasswordFormMode.NewPassword) NewPasswordForm.FocusPasswordRequested = true;
            if (value != PasswordFormMode.FirstBlock) FirstBlockForm.Reset();
            if (value != PasswordFormMode.NewPassword) NewPasswordForm.Reset();
            RaiseDerived();
        }
    }

    /// <summary>Set to true when the add field should take the cursor; the view sets it back to false once it has.</summary>
    public bool FocusAddFieldRequested { get => _focusAddField; set => SetField(ref _focusAddField, value); }

    /// <summary>The typed text without surrounding spaces or line breaks (a pasted address often has them).</summary>
    public string TrimmedSite => AddText.Trim();

    /// <summary>True when the typed text has a path after the site name (youtube.com/shorts), which is when the part-or-whole choice shows.</summary>
    public bool HasPath => PathRuleParser.Split(TrimmedSite).Path is not null;

    /// <summary>True when Block adds a path rule instead of blocking the whole site.</summary>
    public bool BlocksOnlyThisPart => HasPath && OnlyThisPart;

    /// <summary>The rule "Only this part" would add, as the list shows it (youtube.com/shorts), or null when the text cannot be read as a rule. The service checks the text again when Block is pressed.</summary>
    public string? RuleCaption
    {
        get
        {
            try
            {
                var (domain, path) = PathRuleParser.Parse(TrimmedSite);
                return PathRuleParser.Display(domain, path);
            }
            catch (Exception)
            {
                return null;
            }
        }
    }

    /// <summary>The caption under the part-or-whole choice, or null when none shows (the text has no path, or "Only this part" is picked but the text is not a valid rule).</summary>
    public string? ChoiceCaption
    {
        get
        {
            if (!HasPath) return null;
            if (!OnlyThisPart) return WholeSiteCaption;
            return RuleCaption is { } rule ? $"Blocks {rule} and everything under it. The rest of the site stays open." : null;
        }
    }

    /// <summary>The sentence in the first-block form naming the site that will be blocked.</summary>
    public string FirstBlockDetail => $"{TrimmedSite} will be blocked as soon as the password is set.";

    /// <summary>True while the first-block form shows. It also needs "no password yet": once one is set (perhaps from the command line) the form has nothing left to do.</summary>
    public bool IsChoosingFirstPassword => PasswordForm == PasswordFormMode.FirstBlock && _status.Snapshot?.PasswordSet != true;

    /// <summary>True when a reset left sites blocked but no password to unblock them with, so the "Choose a new password" banner shows.</summary>
    public bool NeedsNewPassword => _status.Snapshot is { PasswordSet: false } snapshot && (snapshot.Blocked.Count > 0 || (snapshot.BlockedPaths?.Count ?? 0) > 0);

    /// <summary>True while the new-password form is open inside its banner.</summary>
    public bool IsChoosingNewPassword => PasswordForm == PasswordFormMode.NewPassword && NeedsNewPassword;

    /// <summary>True when the add field and the choice are switched off (while the first-block form is open, so the site cannot change).</summary>
    public bool AddFieldDisabled => IsChoosingFirstPassword;

    /// <summary>True when Block may be pressed.</summary>
    public bool CanPressBlock => TrimmedSite.Length > 0 && !_status.IsBusy && !IsChoosingFirstPassword;

    /// <summary>
    /// Block (or Enter in the field). Without a password nothing is sent: the first-block form opens with the typed site kept. Otherwise the whole site, or only the typed part, is blocked; the field is emptied only when the service accepts, so a typo can be fixed instead of retyped.
    /// Returns true when the service accepted a block.
    /// </summary>
    public async Task<bool> PressBlockAsync()
    {
        string site = TrimmedSite;
        if (!CanPressBlock || _status.Snapshot is not { } snapshot) return false;
        if (!snapshot.PasswordSet)
        {
            PasswordForm = PasswordFormMode.FirstBlock;
            return false;
        }
        bool accepted = BlocksOnlyThisPart ? await _status.AddPathAsync(site) : await _status.AddAsync(site);
        if (accepted) AddText = "";
        FocusAddFieldRequested = true;
        return accepted;
    }

    /// <summary>"Choose a new password" in the banner: opens the form inside it.</summary>
    public void OpenNewPasswordForm() => PasswordForm = PasswordFormMode.NewPassword;

    /// <summary>Cancel in either password form: closes it and puts the cursor back in the add field (the typed site stays).</summary>
    public void CancelPasswordForm()
    {
        PasswordForm = PasswordFormMode.None;
        FocusAddFieldRequested = true;
    }

    /// <summary>
    /// The first-block form's submit: sets the password and then blocks the typed site, which is sent only when the password was accepted. Returns true when the password was set, so the form closes;
    /// if the site itself was then refused, its reason shows under the add field and the text stays so it can be fixed. Returns false when the password was refused, so the form stays open with the reason inside.
    /// </summary>
    private async Task<bool> SetPasswordAndBlockAsync(string password)
    {
        switch (await _status.SetupThenAddAsync(password, TrimmedSite, BlocksOnlyThisPart))
        {
            case FirstBlockOutcome.PasswordNotSet:
                return false;
            case FirstBlockOutcome.PasswordSetSiteRefused:
                PasswordForm = PasswordFormMode.None;
                FocusAddFieldRequested = true;
                return true;
            default:
                AddText = "";
                PasswordForm = PasswordFormMode.None;
                FocusAddFieldRequested = true;
                return true;
        }
    }

    /// <summary>Forgets everything typed and closes both forms. The panel calls it when it closes.</summary>
    public void Reset()
    {
        AddText = "";
        OnlyThisPart = true;
        PasswordForm = PasswordFormMode.None;
        FirstBlockForm.Reset();
        NewPasswordForm.Reset();
    }

    /// <summary>Raises the properties computed from the text, the choice and the form.</summary>
    private void RaiseDerived()
    {
        OnPropertyChanged(nameof(TrimmedSite));
        OnPropertyChanged(nameof(HasPath));
        OnPropertyChanged(nameof(BlocksOnlyThisPart));
        OnPropertyChanged(nameof(ChoiceCaption));
        OnPropertyChanged(nameof(FirstBlockDetail));
        OnPropertyChanged(nameof(IsChoosingFirstPassword));
        OnPropertyChanged(nameof(IsChoosingNewPassword));
        OnPropertyChanged(nameof(CanPressBlock));
    }
}
