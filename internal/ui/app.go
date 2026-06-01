package ui

import (
	"context"
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/XavierJp/TGV/internal/config"
	"github.com/XavierJp/TGV/internal/session"
	"github.com/XavierJp/TGV/internal/term"
)

type screen int

const (
	screenList screen = iota
	screenNew
)

// Model is the root bubbletea model. It owns every screen's state; the
// screens are simple enough (one list, one two-field form) not to warrant
// separate sub-models.
type Model struct {
	store   *session.Store
	manager *session.Manager
	cfg     *config.Config
	ctx     context.Context
	sub     <-chan session.Update

	screen screen
	width  int
	height int

	cursor int
	form   newForm

	flash      string
	flashStyle lipgloss.Style
}

func NewApp(ctx context.Context, store *session.Store, manager *session.Manager, cfg *config.Config) *Model {
	return &Model{
		store:   store,
		manager: manager,
		cfg:     cfg,
		ctx:     ctx,
		screen:  screenList,
		form:    newNewForm(),
	}
}

// Messages.
type (
	storeUpdateMsg struct{ u session.Update }
	flashClearMsg  struct{}
	flashMsg       struct {
		text  string
		style lipgloss.Style
	}
)

// storeUpdateCmd blocks on the subscription channel until the next update
// arrives. The Update loop re-issues the cmd after consuming — that gives
// a store-driven UI without polling in the view.
func storeUpdateCmd(sub <-chan session.Update) tea.Cmd {
	return func() tea.Msg {
		u, ok := <-sub
		if !ok {
			return nil
		}
		return storeUpdateMsg{u: u}
	}
}

func flashClearCmd(d time.Duration) tea.Cmd {
	return tea.Tick(d, func(time.Time) tea.Msg { return flashClearMsg{} })
}

// --- tea.Model ---

func (m *Model) Init() tea.Cmd {
	m.sub = m.store.Subscribe(32)
	return storeUpdateCmd(m.sub)
}

func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.form.setWidth(m.width)
		return m, nil

	case storeUpdateMsg:
		return m, storeUpdateCmd(m.sub)

	case flashClearMsg:
		m.flash = ""
		return m, nil

	case flashMsg:
		m.setFlash(msg.text, msg.style)
		return m, flashClearCmd(3 * time.Second)

	case tea.KeyMsg:
		switch m.screen {
		case screenList:
			return m.updateList(msg)
		case screenNew:
			return m.updateNew(msg)
		}
	}
	return m, nil
}

func (m *Model) updateList(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	sessions, _, _ := m.store.Snapshot()

	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit

	case "up", "k":
		if m.cursor > 0 {
			m.cursor--
		}
		return m, nil

	case "down", "j":
		if m.cursor < len(sessions)-1 {
			m.cursor++
		}
		return m, nil

	case "n":
		m.form.reset()
		m.screen = screenNew
		return m, m.form.focus()

	case "a":
		st := selected(sessions, m.cursor)
		if st == nil || st.Status != session.StatusRunning {
			return m, flashCmd("Session not running", styleWarn)
		}
		return m, m.openInTab(st.Name, "attach")

	case "s":
		st := selected(sessions, m.cursor)
		if st == nil || st.Status != session.StatusRunning {
			return m, flashCmd("Session not running", styleWarn)
		}
		return m, m.openInTab(st.Name, "shell")

	case "x":
		st := selected(sessions, m.cursor)
		if st == nil {
			return m, nil
		}
		m.store.Kill(m.ctx, st.Name)
		if m.cursor >= len(sessions)-1 && m.cursor > 0 {
			m.cursor--
		}
		return m, flashCmd("Killing "+st.Label(), styleWarn)
	}

	return m, nil
}

func (m *Model) updateNew(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.screen = screenList
		return m, nil
	case "ctrl+c":
		return m, tea.Quit
	case "tab", "shift+tab":
		m.form.toggleFocus()
		return m, m.form.focus()
	case "shift+enter":
		// Shift+Enter inserts a newline in the prompt (falls through to textarea).
	case "enter":
		return m.submitNew()
	}
	cmd := m.form.update(msg)
	return m, cmd
}

func (m *Model) submitNew() (tea.Model, tea.Cmd) {
	title := strings.TrimSpace(m.form.title.Value())
	prompt := strings.TrimSpace(m.form.prompt.Value())
	if title == "" {
		return m, flashCmd("Title is required", styleErr)
	}
	m.store.Spawn(m.ctx, title, prompt)
	m.screen = screenList
	m.form.reset()
	return m, flashCmd("Spawning '"+title+"'", styleInfo)
}

func (m *Model) openInTab(name, kind string) tea.Cmd {
	return func() tea.Msg {
		var argv []string
		switch kind {
		case "attach":
			argv = m.manager.AttachArgs(name)
		case "shell":
			argv = m.manager.ShellArgs(name)
		default:
			return nil
		}
		cmd := m.manager.RemoteCommand(argv)
		if _, err := term.OpenInNewTab(cmd, m.cfg.Terminal); err != nil {
			return flashMsg{text: "open failed: " + err.Error(), style: styleErr}
		}
		label := "codex attached"
		if kind == "shell" {
			label = "shell opened"
		}
		return flashMsg{text: label + " → new tab", style: styleOK}
	}
}

func (m *Model) setFlash(text string, style lipgloss.Style) {
	m.flash = text
	m.flashStyle = style
}

func flashCmd(text string, style lipgloss.Style) tea.Cmd {
	return func() tea.Msg { return flashMsg{text: text, style: style} }
}

// --- View ---
//
// Layout (vertical):
//
//   ┌─────────────────────────────────────────┐
//   │ TGV   xavier@host         ● 3 sessions  │  title bar
//   ├─────────────────────────────────────────┤  rule
//   │                                         │
//   │   Sessions                              │  section title
//   │                                         │
//   │   › ● add dark mode                     │  selected: title
//   │       tgv/add-dark · ↑2 ↓0 · PR #12     │  selected: details
//   │     ● fix login flow                    │
//   │       tgv/fix-login · clean             │
//   │                                         │
//   │            ████ TGV banner ████         │  banner (when room)
//   │                                         │
//   ├─────────────────────────────────────────┤  rule
//   │ n new  a attach  s shell  …             │  footer
//   └─────────────────────────────────────────┘
//
// The banner is only drawn when there's vertical headroom — never pushes
// the body up.

func (m *Model) View() string {
	if m.width == 0 || m.height == 0 {
		return ""
	}

	// Build the screen as a slice of exact lines, then join. This way every
	// section's contribution to total height is unambiguous — no off-by-one
	// from `strings.Repeat("\n", N)` (which lipgloss treats as N+1 lines).
	out := make([]string, 0, m.height)

	// 1-line top breathing room, then title bar (6 lines), then a rule.
	out = append(out, "")
	out = append(out, strings.Split(m.renderTitleBar(), "\n")...)
	out = append(out, m.renderRule())

	var body string
	switch m.screen {
	case screenList:
		body = m.renderList()
	case screenNew:
		body = m.form.view(m.width)
	}
	out = append(out, strings.Split(body, "\n")...)

	// Bottom-pinned chrome: bottomRule + (flash) + footer.
	flash := m.renderFlash()
	flashLines := []string(nil)
	if flash != "" {
		flashLines = strings.Split(flash, "\n")
	}
	bottomFixed := 1 /*bottomRule*/ + len(flashLines) + 1 /*footer*/

	// Pad between body and bottomRule.
	pad := m.height - len(out) - bottomFixed
	for i := 0; i < pad; i++ {
		out = append(out, "")
	}

	out = append(out, m.renderRule())
	out = append(out, flashLines...)
	out = append(out, m.renderFooter())

	// Defensive truncation — if body is taller than the screen, keep title
	// + topRule visible and drop tail content rather than scrolling top off.
	if len(out) > m.height {
		out = out[:m.height]
	}
	return strings.Join(out, "\n")
}

// renderTitleBar lays out the title row as three columns separated by
// vertical dividers:
//
//	[client KPIs · 30%] │ [server KPIs · 30%] │ [banner · remainder]
//
// Each KPI column is forced to exactly 30% of the screen width so the
// dividers stay locked to consistent x-positions regardless of column
// content. The banner is centered in whatever space is left; if it can't
// fit, it's dropped and the dividers/columns absorb the room.
func (m *Model) renderTitleBar() string {
	clientW := m.width * 17 / 100
	serverW := m.width * 28 / 100
	if clientW < 16 {
		clientW = 16
	}
	if serverW < 16 {
		serverW = 16
	}

	client := lipgloss.NewStyle().Width(clientW).Render(m.renderClientKPIs())
	server := lipgloss.NewStyle().Width(serverW).Render(m.renderServerKPIs())

	// 6-line vertical divider matching the banner height.
	dividerCell := styleRule.Render("│")
	dividerCol := strings.Repeat(dividerCell+"\n", 5) + dividerCell

	// Reserved: outer pad (4) + 2 columns + 2 dividers + 4 buffer spaces.
	reserved := 4 + 2 + 4 + clientW + serverW
	bannerArea := m.width - reserved
	parts := []string{client, " ", dividerCol, " ", server}

	if bannerArea >= bannerArtWidth() {
		centered := lipgloss.NewStyle().
			Width(bannerArea).
			Align(lipgloss.Center).
			Render(renderBannerArt())
		parts = append(parts, " ", dividerCol, " ", centered)
	}

	block := lipgloss.JoinHorizontal(lipgloss.Top, parts...)
	return lipgloss.NewStyle().Padding(0, 2).Render(block)
}

// renderClientKPIs is the left column. 6 lines, blank-spaced:
//
//	● Connected
//	743ms · just now
//	1 session
func (m *Model) renderClientKPIs() string {
	sessions, connected, listedAt := m.store.Snapshot()
	srv := m.store.SnapshotServer()

	connText := "Disconnected"
	connStyle := styleErr
	if connected {
		connText = "Connected"
		connStyle = styleOK
	}
	connLine := connStyle.Render("●") + " " + styleHeading.Render(connText)

	// Latency · age (one line).
	latency := renderLatency(srv.Latency.Milliseconds())
	netLine := latency
	if !listedAt.IsZero() {
		d := time.Since(listedAt)
		var age string
		if d < time.Second {
			age = "just now"
		} else {
			age = humanDur(d) + " ago"
		}
		netLine = latency + styleDim.Render(" · ") + styleMuted.Render(age)
	}

	count := fmt.Sprintf("%d sessions", len(sessions))
	if len(sessions) == 1 {
		count = "1 session"
	}
	countLine := styleMuted.Render(count)

	return strings.Join([]string{
		connLine,
		"",
		netLine,
		"",
		countLine,
		"",
	}, "\n")
}

// renderServerKPIs is the middle column: user@host + CPU / RAM / disk meters
// + CPU temp. 6 lines. Until the first probe lands, meters render at 0%.
func (m *Model) renderServerKPIs() string {
	host := styleHeading.Render(m.cfg.SSHTarget())
	srv := m.store.SnapshotServer()

	cpu := renderMeter("CPU", 0)
	ram := renderMeter("RAM", 0)
	disk := renderMeter("Disk", 0)
	temp := renderTemp("Temp", nil)

	if hm := srv.HostMetrics; hm != nil {
		cpu = renderMeter("CPU", hm.CPUPercent)
		ram = renderMeter("RAM", hm.MemFraction())
		disk = renderMeter("Disk", hm.DiskFraction())
		temp = renderTemp("Temp", hm.CPUTemp)
	}

	return strings.Join([]string{
		host,
		cpu,
		ram,
		disk,
		temp,
		"",
	}, "\n")
}

func (m *Model) renderRule() string {
	return styleRule.Render(strings.Repeat("─", m.width))
}

func (m *Model) renderList() string {
	sessions, _, _ := m.store.Snapshot()
	header := lipgloss.NewStyle().Padding(1, 2, 0, 2).Render(styleSectionTitle.Render("Sessions"))

	if len(sessions) == 0 {
		empty := styleMuted.Render("no sessions — press  n  to create one")
		return header + "\n" + lipgloss.NewStyle().Padding(0, 4).Render(empty)
	}

	if m.cursor >= len(sessions) {
		m.cursor = len(sessions) - 1
	}
	if m.cursor < 0 {
		m.cursor = 0
	}

	var b strings.Builder
	b.WriteString(header)
	b.WriteByte('\n')
	for i, st := range sessions {
		b.WriteString(renderSessionRow(st, m.width, i == m.cursor))
		b.WriteByte('\n')
	}
	return b.String()
}

func (m *Model) renderFooter() string {
	var help string
	switch m.screen {
	case screenList:
		help = "n new   a attach   s shell   x kill   ↑↓ move   q quit"
	case screenNew:
		help = "⇥ switch field   ↵ create   ⇧↵ newline in prompt   esc cancel"
	}
	return styleStatusBar.Width(m.width).Render(styleHelp.Render(help))
}

func (m *Model) renderFlash() string {
	if m.flash == "" {
		return ""
	}
	return lipgloss.NewStyle().Padding(0, 1).Render(m.flashStyle.Render(m.flash))
}

// renderSessionRow renders a session as two indented lines:
//
//	› ●  add dark mode
//	     tgv/add-dark-ab12  ↑2 ↓0  mod:3  +42 -8  PR #12 open
//
// The cursor (›) and the title color shift to `colorBrand` when selected.
func renderSessionRow(st *session.State, width int, selected bool) string {
	icon, iconStyle := statusIcon(st.Status)
	cursor := "  "
	titleStyle := styleSessionTitle
	if selected {
		cursor = styleCursor.Render("›") + " "
		titleStyle = styleSelectedTitle
	}

	displayName := st.DisplayName
	if displayName == "" {
		displayName = st.Name
	}

	titleLine := lipgloss.NewStyle().Padding(0, 0, 0, 2).Render(
		cursor + iconStyle.Render(icon) + "  " + titleStyle.Render(displayName),
	)

	// Details line — branch + metrics joined by middle-dot separators.
	var details []string
	details = append(details, styleSessionBranch.Render(st.Branch))

	if g := st.GitStatus; g != nil {
		if g.Ahead > 0 || g.Behind > 0 {
			details = append(details, styleInfo.Render(fmt.Sprintf("↑%d ↓%d", g.Ahead, g.Behind)))
		}
		var changes []string
		if len(g.Staged) > 0 {
			changes = append(changes, fmt.Sprintf("staged:%d", len(g.Staged)))
		}
		if len(g.Changed) > 0 {
			changes = append(changes, fmt.Sprintf("mod:%d", len(g.Changed)))
		}
		if len(g.Untracked) > 0 {
			changes = append(changes, fmt.Sprintf("?:%d", len(g.Untracked)))
		}
		if len(changes) > 0 {
			details = append(details, styleWarn.Render(strings.Join(changes, " ")))
		} else if g.Branch != "" {
			details = append(details, styleOK.Render("clean"))
		}
		if st.Insertions > 0 || st.Deletions > 0 {
			details = append(details,
				styleOK.Render(fmt.Sprintf("+%d", st.Insertions))+" "+
					styleErr.Render(fmt.Sprintf("-%d", st.Deletions)))
		}
	}
	if pr := st.PR; pr != nil {
		prStyle := styleInfo
		switch strings.ToUpper(pr.State) {
		case "MERGED":
			prStyle = styleAccent
		case "CLOSED":
			prStyle = styleMuted
		case "OPEN":
			prStyle = styleOK
		}
		details = append(details, prStyle.Render(fmt.Sprintf("PR #%d %s", pr.Number, strings.ToLower(pr.State))))
	}

	if st.Status == session.StatusCreating && len(st.StatusLog) > 0 {
		details = append(details, styleMuted.Italic(true).Render(st.StatusLog[len(st.StatusLog)-1]))
	}

	sep := styleDim.Render(" · ")
	// 7 = 2 (outer) + 2 (cursor) + 1 (icon) + 2 (icon-title gap) — aligns
	// with the title text on the line above.
	detailsLine := lipgloss.NewStyle().Padding(0, 0, 0, 7).Render(strings.Join(details, sep))

	_ = width // available for future right-aligned content
	return titleLine + "\n" + detailsLine
}

func statusIcon(s session.Status) (string, lipgloss.Style) {
	switch s {
	case session.StatusRunning:
		return "●", styleOK
	case session.StatusStopped:
		return "○", styleMuted
	case session.StatusCreating:
		return "⟳", styleInfo
	case session.StatusDeleting:
		return "✕", styleErr
	}
	return "?", styleMuted
}

func selected(list []*session.State, i int) *session.State {
	if i < 0 || i >= len(list) {
		return nil
	}
	return list[i]
}

func humanDur(d time.Duration) string {
	if d < time.Second {
		return "just now"
	}
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
	return fmt.Sprintf("%dh", int(d.Hours()))
}
