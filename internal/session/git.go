package session

import (
	"strconv"
	"strings"
)

type GitStatus struct {
	Branch    string
	Upstream  string
	Ahead     int
	Behind    int
	Staged    []GitEntry
	Changed   []GitEntry
	Untracked []GitEntry
}

func (g GitStatus) IsEmpty() bool {
	return len(g.Staged) == 0 && len(g.Changed) == 0 && len(g.Untracked) == 0
}

type GitEntryStatus int

const (
	GitModified GitEntryStatus = iota
	GitAdded
	GitDeleted
	GitRenamed
	GitCopied
	GitUntracked
)

type GitEntry struct {
	Status GitEntryStatus
	Path   string
}

// ParseGitStatus parses `git status --porcelain=v1 -b` output.
// First char = index (staged) status, second = work-tree status.
func ParseGitStatus(output string) GitStatus {
	var g GitStatus
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "## ") {
			parseBranchLine(line[3:], &g)
			continue
		}
		if len(line) < 3 {
			continue
		}
		x := line[0]
		y := line[1]
		path := line[3:]
		if x == '?' && y == '?' {
			g.Untracked = append(g.Untracked, GitEntry{Status: GitUntracked, Path: path})
			continue
		}
		if x != ' ' && x != '?' {
			g.Staged = append(g.Staged, GitEntry{Status: charToStatus(x), Path: path})
		}
		if y != ' ' && y != '?' {
			g.Changed = append(g.Changed, GitEntry{Status: charToStatus(y), Path: path})
		}
	}
	return g
}

func charToStatus(c byte) GitEntryStatus {
	switch c {
	case 'M':
		return GitModified
	case 'A':
		return GitAdded
	case 'D':
		return GitDeleted
	case 'R':
		return GitRenamed
	case 'C':
		return GitCopied
	}
	return GitModified
}

// parseBranchLine: "main...origin/main [ahead 2, behind 1]"
func parseBranchLine(line string, g *GitStatus) {
	rest := line
	if i := strings.Index(rest, " ["); i >= 0 {
		bracket := strings.TrimSuffix(rest[i+2:], "]")
		for _, part := range strings.Split(bracket, ", ") {
			t := strings.TrimSpace(part)
			if strings.HasPrefix(t, "ahead ") {
				g.Ahead, _ = strconv.Atoi(strings.TrimPrefix(t, "ahead "))
			} else if strings.HasPrefix(t, "behind ") {
				g.Behind, _ = strconv.Atoi(strings.TrimPrefix(t, "behind "))
			}
		}
		rest = rest[:i]
	}
	parts := strings.SplitN(rest, "...", 2)
	g.Branch = parts[0]
	if len(parts) == 2 && parts[1] != "" {
		g.Upstream = parts[1]
	}
}
