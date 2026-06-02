package ui

import (
	"fmt"
	"strings"
)

// meterSegments is how many cells the bar uses. 10 looks balanced — each
// cell is roughly a 10% step, easy to read at a glance.
const meterSegments = 10

// renderMeter draws a 10-segment bar + label + percentage:
//
//	CPU  ▮▮▮▮▮▯▯▯▯▯  47%
//
// Severity coloring (green / amber / red) on the filled cells kicks in at
// >65 / >85. Empty cells stay dim.
func renderMeter(label string, pct float64) string {
	if pct < 0 {
		pct = 0
	}
	if pct > 1 {
		pct = 1
	}
	filled := int(pct*meterSegments + 0.5)
	if filled > meterSegments {
		filled = meterSegments
	}

	st := styleOK
	switch {
	case pct >= 0.85:
		st = styleErr
	case pct >= 0.65:
		st = styleWarn
	}

	bar := st.Render(strings.Repeat("▮", filled)) +
		styleDim.Render(strings.Repeat("▯", meterSegments-filled))

	return styleMuted.Render(fmt.Sprintf("%-4s", label)) +
		" " + bar +
		" " + styleHeading.Render(fmt.Sprintf("%3.0f%%", pct*100))
}

// renderTemp renders a CPU temperature with severity coloring.
//
//	CPU 72°C
//
// nil temp renders as "CPU  —". `c` is degrees Celsius.
func renderTemp(label string, c *float64) string {
	if c == nil {
		return styleMuted.Render(fmt.Sprintf("%-4s", label)) + " " + styleDim.Render("—")
	}
	v := *c
	st := styleOK
	switch {
	case v >= 85:
		st = styleErr
	case v >= 70:
		st = styleWarn
	}
	return styleMuted.Render(fmt.Sprintf("%-4s", label)) + " " + st.Render(fmt.Sprintf("%4.0f°C", v))
}

// renderLatency draws "743ms" in green/amber/red by RTT severity.
// Zero/negative duration renders as a muted "—".
func renderLatency(ms int64) string {
	if ms <= 0 {
		return styleDim.Render("—")
	}
	st := styleOK
	switch {
	case ms >= 300:
		st = styleErr
	case ms >= 100:
		st = styleWarn
	}
	return st.Render(fmt.Sprintf("%dms", ms))
}
