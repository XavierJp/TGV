package ui

import (
	"strings"

	"github.com/charmbracelet/bubbles/textarea"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type formField int

const (
	fieldTitle formField = iota
	fieldPrompt
)

type newForm struct {
	title   textinput.Model
	prompt  textarea.Model
	focused formField
	width   int
}

func newNewForm() newForm {
	ti := textinput.New()
	ti.Placeholder = "e.g. Add dark mode"
	ti.CharLimit = 200
	ti.Prompt = ""

	ta := textarea.New()
	ta.Placeholder = "Optional — what should codex start working on?"
	ta.ShowLineNumbers = false
	ta.SetHeight(10)
	ta.Prompt = ""

	return newForm{
		title:   ti,
		prompt:  ta,
		focused: fieldTitle,
	}
}

func (f *newForm) setWidth(w int) {
	f.width = w
	// Body has 2-pad on each side (= 4) and each field's border + 1-pad adds
	// another 4. So the input area is `w - 8`. Floor at 20 to keep the field
	// usable when the terminal is narrow.
	inner := w - 8
	if inner < 20 {
		inner = 20
	}
	f.title.Width = inner
	f.prompt.SetWidth(inner)
}

func (f *newForm) reset() {
	f.title.SetValue("")
	f.prompt.SetValue("")
	f.focused = fieldTitle
	f.title.Focus()
	f.prompt.Blur()
}

func (f *newForm) focus() tea.Cmd {
	if f.focused == fieldTitle {
		f.prompt.Blur()
		return f.title.Focus()
	}
	f.title.Blur()
	return f.prompt.Focus()
}

func (f *newForm) toggleFocus() {
	if f.focused == fieldTitle {
		f.focused = fieldPrompt
	} else {
		f.focused = fieldTitle
	}
}

func (f *newForm) update(msg tea.Msg) tea.Cmd {
	var cmd tea.Cmd
	if f.focused == fieldTitle {
		f.title, cmd = f.title.Update(msg)
	} else {
		f.prompt, cmd = f.prompt.Update(msg)
	}
	return cmd
}

func (f *newForm) view(width int) string {
	header := lipgloss.NewStyle().Padding(1, 2, 0, 2).Render(styleSectionTitle.Render("New Session"))

	titleField := f.title.View()
	if f.focused == fieldTitle {
		titleField = styleFieldFocused.Render(titleField)
	} else {
		titleField = styleField.Render(titleField)
	}

	promptField := f.prompt.View()
	if f.focused == fieldPrompt {
		promptField = styleFieldFocused.Render(promptField)
	} else {
		promptField = styleField.Render(promptField)
	}

	titleBlock := lipgloss.JoinVertical(lipgloss.Left,
		styleLabel.Render("Title"),
		titleField,
	)
	promptBlock := lipgloss.JoinVertical(lipgloss.Left,
		styleLabel.Render("Prompt"),
		promptField,
	)

	body := lipgloss.JoinVertical(lipgloss.Left, titleBlock, "", promptBlock)
	// 2-pad to align with the "New Session" section title and the rest of
	// the UI. Field width is sized accordingly in setWidth().
	body = lipgloss.NewStyle().Padding(0, 2).Render(body)

	return strings.Join([]string{header, body}, "\n")
}
