package ui

import "github.com/charmbracelet/lipgloss"

// Banner gradient — purple → pink → red → orange. The same colors are
// reused across the UI as accents so the whole TUI shares one palette.
var bannerGradient = []lipgloss.Color{
	lipgloss.Color("#833AB4"), // 0 — purple
	lipgloss.Color("#9C2E9E"), // 1
	lipgloss.Color("#B52388"), // 2
	lipgloss.Color("#D01A5E"), // 3 — deep pink
	lipgloss.Color("#E91D3A"), // 4 — red
	lipgloss.Color("#F46A28"), // 5 — orange
}

var (
	colorBrand  = bannerGradient[5]               // orange — selection / TGV
	colorAccent = bannerGradient[3]               // deep pink — section titles
	colorInfo   = bannerGradient[0]               // purple — ahead/behind etc.
	colorErr    = bannerGradient[4]               // red — error states
	colorOK     = lipgloss.Color("#22C55E")       // intense green — connected / clean
	colorWarn   = lipgloss.Color("214")           // amber — kept distinct from brand
	colorMuted  = lipgloss.Color("243")
	colorDim    = lipgloss.Color("240")
	colorRule   = lipgloss.Color("238")
	colorHeading = lipgloss.Color("255")
)

var (
	styleHeading = lipgloss.NewStyle().
			Foreground(colorHeading).
			Bold(true)

	styleMuted = lipgloss.NewStyle().Foreground(colorMuted)
	styleDim   = lipgloss.NewStyle().Foreground(colorDim)
	styleAccent = lipgloss.NewStyle().Foreground(colorAccent)

	styleBrand = lipgloss.NewStyle().
			Foreground(colorBrand).
			Bold(true)

	styleRule = lipgloss.NewStyle().Foreground(colorRule)

	styleSectionTitle = lipgloss.NewStyle().
				Foreground(colorAccent).
				Bold(true).
				MarginBottom(1)

	styleOK   = lipgloss.NewStyle().Foreground(colorOK)
	styleWarn = lipgloss.NewStyle().Foreground(colorWarn)
	styleErr  = lipgloss.NewStyle().Foreground(colorErr)
	styleInfo = lipgloss.NewStyle().Foreground(colorInfo)

	styleStatusBar = lipgloss.NewStyle().
			Foreground(colorMuted).
			Padding(0, 1)

	styleHelp = lipgloss.NewStyle().Foreground(colorMuted)

	styleField = lipgloss.NewStyle().
			Padding(0, 1).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(colorDim)

	styleFieldFocused = lipgloss.NewStyle().
				Padding(0, 1).
				Border(lipgloss.RoundedBorder()).
				BorderForeground(colorAccent)

	styleLabel = lipgloss.NewStyle().Foreground(colorMuted)

	// Session row pieces.
	styleSessionTitle    = lipgloss.NewStyle().Foreground(colorHeading).Bold(true)
	styleSessionSubtitle = lipgloss.NewStyle().Foreground(colorMuted)
	styleSessionBranch   = lipgloss.NewStyle().Foreground(colorDim).Italic(true)
	styleSelectedTitle   = lipgloss.NewStyle().Foreground(colorBrand).Bold(true)
	styleCursor          = lipgloss.NewStyle().Foreground(colorBrand).Bold(true)
)
