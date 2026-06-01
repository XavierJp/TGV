package session

import (
	"context"
	"sort"
	"sync"
	"time"
)

type Status int

const (
	StatusCreating Status = iota
	StatusRunning
	StatusStopped
	StatusDeleting
)

func (s Status) String() string {
	switch s {
	case StatusCreating:
		return "creating"
	case StatusRunning:
		return "running"
	case StatusStopped:
		return "stopped"
	case StatusDeleting:
		return "deleting"
	}
	return "unknown"
}

// State is the client-side view of one session. It's kept in the Store's
// internal map; the TUI reads immutable snapshots via Snapshot().
type State struct {
	Name        string
	Repo        string
	Branch      string
	DisplayName string
	Status      Status

	GitStatus      *GitStatus
	GitRefreshedAt time.Time
	Insertions     int
	Deletions      int

	PR            *PRInfo
	PRRefreshedAt time.Time

	StatusLog []string
}

func (s *State) Label() string {
	if s.DisplayName != "" {
		return s.DisplayName + " (" + s.Branch + ")"
	}
	return s.Branch
}

// Event describes something the UI may want to re-render for.
type Event int

const (
	EventSessionsChanged Event = iota
	EventDetailsChanged        // git status / PR / logs for one session
	EventConnectionChanged
	EventHostMetricsChanged
)

type Update struct {
	Event       Event
	SessionName string // populated for EventDetailsChanged
}

// Store owns the client-side session map and runs the polling goroutines.
// Subscribe() lets one consumer (the TUI) receive coalesced updates.
type Store struct {
	manager *Manager
	repoURL string

	mu        sync.RWMutex
	sessions  map[string]*State
	connected bool
	listedAt  time.Time

	hostMetrics   *HostMetrics
	hostMetricsAt time.Time

	subscribers []chan Update

	cancel context.CancelFunc
	done   chan struct{}
}

const (
	ListInterval    = 30 * time.Second
	DetailsInterval = 15 * time.Second
	PRInterval      = 60 * time.Second
	HostInterval    = 5 * time.Second
)

func NewStore(manager *Manager, repoURL string) *Store {
	return &Store{
		manager:  manager,
		repoURL:  repoURL,
		sessions: map[string]*State{},
	}
}

// Subscribe returns a channel of updates. Non-blocking send — drop if full.
func (s *Store) Subscribe(buf int) <-chan Update {
	ch := make(chan Update, buf)
	s.mu.Lock()
	s.subscribers = append(s.subscribers, ch)
	s.mu.Unlock()
	return ch
}

func (s *Store) emit(u Update) {
	s.mu.RLock()
	subs := append([]chan Update(nil), s.subscribers...)
	s.mu.RUnlock()
	for _, ch := range subs {
		select {
		case ch <- u:
		default:
			// Consumer is slow — drop. Next update supersedes.
		}
	}
}

func (s *Store) Start(parent context.Context) {
	ctx, cancel := context.WithCancel(parent)
	s.cancel = cancel
	s.done = make(chan struct{})

	go func() {
		defer close(s.done)

		// Kick an immediate list + details + host refresh, then settle into tickers.
		s.refreshList(ctx)
		s.refreshAllDetails(ctx)
		s.refreshHost(ctx)

		listTick := time.NewTicker(ListInterval)
		detailsTick := time.NewTicker(DetailsInterval)
		prTick := time.NewTicker(PRInterval)
		hostTick := time.NewTicker(HostInterval)
		defer listTick.Stop()
		defer detailsTick.Stop()
		defer prTick.Stop()
		defer hostTick.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-listTick.C:
				s.refreshList(ctx)
			case <-detailsTick.C:
				s.refreshAllDetails(ctx)
			case <-prTick.C:
				s.refreshAllPRs(ctx)
			case <-hostTick.C:
				s.refreshHost(ctx)
			}
		}
	}()
}

func (s *Store) Stop() {
	if s.cancel != nil {
		s.cancel()
	}
	if s.done != nil {
		<-s.done
	}
}

// ServerSnapshot is a read-only view of remote-server health: the last host
// probe and the SSH round-trip latency. Returned by SnapshotServer().
type ServerSnapshot struct {
	HostMetrics   *HostMetrics
	HostMetricsAt time.Time
	Latency       time.Duration
}

// SnapshotServer returns a copy of the current host metrics + SSH latency.
// Cheap and safe to call from the UI goroutine.
func (s *Store) SnapshotServer() ServerSnapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var hm *HostMetrics
	if s.hostMetrics != nil {
		cp := *s.hostMetrics
		hm = &cp
	}
	return ServerSnapshot{
		HostMetrics:   hm,
		HostMetricsAt: s.hostMetricsAt,
		Latency:       s.manager.ssh.LastLatency(),
	}
}

// Snapshot returns an ordered, deep-enough copy of the current session list.
// Returned State pointers are fresh copies — safe to read from the UI
// goroutine without further locking.
func (s *Store) Snapshot() ([]*State, bool, time.Time) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*State, 0, len(s.sessions))
	for _, st := range s.sessions {
		cp := *st
		// Defensive: don't share the StatusLog slice header (append elsewhere
		// could mutate it under the reader).
		if st.StatusLog != nil {
			cp.StatusLog = append([]string(nil), st.StatusLog...)
		}
		out = append(out, &cp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Label() < out[j].Label() })
	return out, s.connected, s.listedAt
}

func (s *Store) Get(name string) *State {
	s.mu.RLock()
	defer s.mu.RUnlock()
	st := s.sessions[name]
	if st == nil {
		return nil
	}
	cp := *st
	if st.StatusLog != nil {
		cp.StatusLog = append([]string(nil), st.StatusLog...)
	}
	return &cp
}

// Spawn inserts a CREATING placeholder and starts the remote spawn in a
// goroutine so the TUI sees the row immediately.
func (s *Store) Spawn(parent context.Context, title, prompt string) *State {
	title = trimSpaces(title)
	branch := BranchFromTitle(title)
	name := MakeSessionName(s.repoURL)

	state := &State{
		Name:        name,
		Repo:        s.repoURL,
		Branch:      branch,
		DisplayName: title,
		Status:      StatusCreating,
	}
	state.StatusLog = append(state.StatusLog, "Spawning '"+title+"' on "+branch+"…")

	s.mu.Lock()
	s.sessions[name] = state
	s.mu.Unlock()
	s.emit(Update{Event: EventSessionsChanged})

	go func() {
		ctx, cancel := context.WithTimeout(parent, 5*time.Minute)
		defer cancel()

		err := s.manager.Spawn(ctx, name, branch, prompt, func(step string) {
			s.mu.Lock()
			if st := s.sessions[name]; st != nil {
				st.StatusLog = appendCapped(st.StatusLog, step, 200)
			}
			s.mu.Unlock()
			s.emit(Update{Event: EventDetailsChanged, SessionName: name})
		})
		if err != nil {
			s.mu.Lock()
			if st := s.sessions[name]; st != nil {
				st.StatusLog = appendCapped(st.StatusLog, "✕ "+err.Error(), 200)
			}
			s.mu.Unlock()
			s.emit(Update{Event: EventDetailsChanged, SessionName: name})
			return
		}
		if title != "" {
			_ = s.manager.Rename(ctx, name, title)
		}
		s.refreshList(ctx) // flip CREATING → RUNNING ASAP
	}()

	// Return the snapshot the TUI can render straight away.
	cp := *state
	cp.StatusLog = append([]string(nil), state.StatusLog...)
	return &cp
}

func (s *Store) Kill(parent context.Context, name string) {
	s.mu.Lock()
	st := s.sessions[name]
	if st == nil {
		s.mu.Unlock()
		return
	}
	st.Status = StatusDeleting
	st.StatusLog = appendCapped(st.StatusLog, "Stopping…", 200)
	s.mu.Unlock()
	s.emit(Update{Event: EventSessionsChanged})

	go func() {
		ctx, cancel := context.WithTimeout(parent, 30*time.Second)
		defer cancel()
		if err := s.manager.Stop(ctx, name); err != nil {
			s.mu.Lock()
			if st := s.sessions[name]; st != nil {
				st.StatusLog = appendCapped(st.StatusLog, "✕ "+err.Error(), 200)
			}
			s.mu.Unlock()
		}
		s.refreshList(ctx)
	}()
}

func (s *Store) Rename(parent context.Context, name, displayName string) {
	s.mu.Lock()
	if st := s.sessions[name]; st != nil {
		st.DisplayName = displayName
	}
	s.mu.Unlock()
	s.emit(Update{Event: EventSessionsChanged})
	go func() {
		ctx, cancel := context.WithTimeout(parent, 10*time.Second)
		defer cancel()
		_ = s.manager.Rename(ctx, name, displayName)
	}()
}

// refreshList hits `docker ps` and reconciles into the state map.
func (s *Store) refreshList(ctx context.Context) {
	listed, err := s.manager.ListSessions(ctx)
	s.mu.Lock()
	if err != nil {
		if s.connected {
			s.connected = false
			s.mu.Unlock()
			s.emit(Update{Event: EventConnectionChanged})
			return
		}
		s.mu.Unlock()
		return
	}
	s.connected = true
	s.listedAt = time.Now()

	byName := make(map[string]Session, len(listed))
	for _, ss := range listed {
		byName[ss.Name] = ss
	}

	// Upsert
	for name, ss := range byName {
		if existing := s.sessions[name]; existing != nil {
			applyListed(existing, ss)
		} else {
			st := &State{
				Name:        ss.Name,
				Repo:        ss.Repo,
				Branch:      ss.Branch,
				DisplayName: ss.DisplayName,
			}
			if ss.Running {
				st.Status = StatusRunning
			} else {
				st.Status = StatusStopped
			}
			s.sessions[name] = st
		}
	}

	// Prune — but keep CREATING rows around until the server sees them.
	for name, st := range s.sessions {
		if _, ok := byName[name]; ok {
			continue
		}
		if st.Status == StatusCreating {
			continue
		}
		delete(s.sessions, name)
	}
	s.mu.Unlock()
	s.emit(Update{Event: EventSessionsChanged})
}

// refreshAllDetails pulls git status for every running session in parallel.
func (s *Store) refreshAllDetails(ctx context.Context) {
	s.mu.RLock()
	var running []string
	for name, st := range s.sessions {
		if st.Status == StatusRunning {
			running = append(running, name)
		}
	}
	s.mu.RUnlock()
	if len(running) == 0 {
		return
	}

	var wg sync.WaitGroup
	for _, name := range running {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			s.refreshDetails(ctx, name)
		}(name)
	}
	wg.Wait()
}

func (s *Store) refreshDetails(ctx context.Context, name string) {
	raw, err := s.manager.GitStatusRaw(ctx, name)
	if err != nil {
		return
	}
	parsed := ParseGitStatus(raw)
	ins, del, _ := s.manager.GitMetrics(ctx, name)

	s.mu.Lock()
	st := s.sessions[name]
	if st == nil {
		s.mu.Unlock()
		return
	}
	st.GitStatus = &parsed
	st.GitRefreshedAt = time.Now()
	st.Insertions = ins
	st.Deletions = del
	s.mu.Unlock()
	s.emit(Update{Event: EventDetailsChanged, SessionName: name})
}

// refreshHost fetches CPU / RAM / disk / temperature once. Failure is silent
// (the host probe takes 0.5s anyway — keep noise off the connection event
// stream); the UI shows "—" until a successful probe lands.
func (s *Store) refreshHost(ctx context.Context) {
	hm, err := s.manager.HostMetrics(ctx)
	if err != nil {
		return
	}
	s.mu.Lock()
	s.hostMetrics = hm
	s.hostMetricsAt = time.Now()
	s.mu.Unlock()
	s.emit(Update{Event: EventHostMetricsChanged})
}

func (s *Store) refreshAllPRs(ctx context.Context) {
	s.mu.RLock()
	type target struct{ name, branch string }
	var targets []target
	for _, st := range s.sessions {
		if st.Status == StatusRunning {
			targets = append(targets, target{st.Name, st.Branch})
		}
	}
	s.mu.RUnlock()
	if len(targets) == 0 {
		return
	}
	var wg sync.WaitGroup
	for _, t := range targets {
		wg.Add(1)
		go func(t target) {
			defer wg.Done()
			pr, err := s.manager.PRForBranch(ctx, t.name, t.branch)
			if err != nil {
				return
			}
			s.mu.Lock()
			if st := s.sessions[t.name]; st != nil {
				st.PR = pr
				st.PRRefreshedAt = time.Now()
			}
			s.mu.Unlock()
			s.emit(Update{Event: EventDetailsChanged, SessionName: t.name})
		}(t)
	}
	wg.Wait()
}

func applyListed(st *State, ss Session) {
	if st.Repo != ss.Repo {
		st.Repo = ss.Repo
	}
	if st.Branch != ss.Branch {
		st.Branch = ss.Branch
	}
	if ss.DisplayName != "" && st.DisplayName != ss.DisplayName {
		st.DisplayName = ss.DisplayName
	}
	switch st.Status {
	case StatusCreating:
		if ss.Running {
			st.Status = StatusRunning
			st.StatusLog = appendCapped(st.StatusLog, "Ready", 200)
		}
	case StatusDeleting:
		// Wait for list-prune to drop it.
	case StatusRunning, StatusStopped:
		if ss.Running {
			st.Status = StatusRunning
		} else {
			st.Status = StatusStopped
		}
	}
}

func appendCapped(s []string, line string, max int) []string {
	s = append(s, line)
	if len(s) > max {
		s = s[len(s)-max:]
	}
	return s
}

func trimSpaces(s string) string {
	// stdlib strings.TrimSpace but avoid the import just to keep this file self-contained
	start, end := 0, len(s)
	for start < end && isSpace(s[start]) {
		start++
	}
	for end > start && isSpace(s[end-1]) {
		end--
	}
	return s[start:end]
}

func isSpace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}
