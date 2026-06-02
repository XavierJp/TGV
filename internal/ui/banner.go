package ui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// Same ASCII as the retired src/banner.rs and Swift SplashView. The 6-color
// gradient lives in styles.go (`bannerGradient`) so the same palette accents
// the rest of the UI.
var bannerLines = []string{
	"████████╗ ██████╗ ██╗   ██╗",
	"╚══██╔══╝██╔════╝ ██║   ██║",
	"   ██║   ██║  ███╗██║   ██║",
	"   ██║   ██║   ██║╚██╗ ██╔╝",
	"   ██║   ╚██████╔╝ ╚████╔╝ ",
	"   ╚═╝    ╚═════╝   ╚═══╝  ",
}

const bannerTagline = "Terminal à Grande Vitesse"

// renderBannerArt returns the 6-line gradient figlet, left-aligned, no
// tagline. The header lays it out next to the KPIs column.
func renderBannerArt() string {
	var b strings.Builder
	for i, line := range bannerLines {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString(lipgloss.NewStyle().Foreground(bannerGradient[i]).Render(line))
	}
	return b.String()
}

// bannerArtWidth is the column count of the widest banner line.
func bannerArtWidth() int {
	max := 0
	for _, l := range bannerLines {
		if w := lipgloss.Width(l); w > max {
			max = w
		}
	}
	return max
}

// bannerArtHeight is the line count of the banner art (no tagline).
func bannerArtHeight() int { return len(bannerLines) }
