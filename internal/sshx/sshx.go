package sshx

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/pkg/sftp"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

type ExecResult struct {
	Stdout   string
	Stderr   string
	ExitCode int
}

func (r ExecResult) Success() bool { return r.ExitCode == 0 }

// Manager keeps one long-lived SSH client and reconnects on failure.
// ssh.Client supports concurrent NewSession calls, so Exec is safe from
// multiple goroutines at once.
type Manager struct {
	host string
	port int
	user string

	mu          sync.Mutex
	client      *ssh.Client
	lastLatency time.Duration // round-trip of the last successful Exec
}

func New(host string, port int, user string) *Manager {
	if port == 0 {
		port = 22
	}
	return &Manager{host: host, port: port, user: user}
}

func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.client != nil {
		_ = m.client.Close()
		m.client = nil
	}
}

func (m *Manager) IsConnected() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.client != nil
}

func (m *Manager) ResetConnection() {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.client != nil {
		_ = m.client.Close()
		m.client = nil
	}
}

func (m *Manager) getClient(ctx context.Context) (*ssh.Client, error) {
	m.mu.Lock()
	if m.client != nil {
		c := m.client
		m.mu.Unlock()
		return c, nil
	}
	m.mu.Unlock()

	client, err := m.dial(ctx)
	if err != nil {
		return nil, err
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if m.client != nil {
		// Lost the race with a concurrent dial — reuse the winner.
		_ = client.Close()
		return m.client, nil
	}
	m.client = client
	return client, nil
}

func (m *Manager) dial(ctx context.Context) (*ssh.Client, error) {
	auth, err := loadAuth()
	if err != nil {
		return nil, err
	}
	cfg := &ssh.ClientConfig{
		User:            m.user,
		Auth:            auth,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         30 * time.Second,
	}
	addr := fmt.Sprintf("%s:%d", m.host, m.port)

	type result struct {
		c   *ssh.Client
		err error
	}
	ch := make(chan result, 1)
	go func() {
		c, err := ssh.Dial("tcp", addr, cfg)
		ch <- result{c, err}
	}()
	select {
	case r := <-ch:
		return r.c, r.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// Exec runs a non-interactive command and captures output.
// On transport failure the client is cleared so the next call reconnects.
// Tracks round-trip time on success — surface it via LastLatency().
func (m *Manager) Exec(ctx context.Context, command string) (ExecResult, error) {
	client, err := m.getClient(ctx)
	if err != nil {
		return ExecResult{}, err
	}
	session, err := client.NewSession()
	if err != nil {
		m.ResetConnection()
		return ExecResult{}, err
	}
	defer session.Close()

	var stdout, stderr bytes.Buffer
	session.Stdout = &stdout
	session.Stderr = &stderr

	start := time.Now()
	runErr := session.Run(command)
	elapsed := time.Since(start)

	exitCode := 0
	if runErr != nil {
		if ee, ok := runErr.(*ssh.ExitError); ok {
			exitCode = ee.ExitStatus()
		} else {
			// Transport / channel error — kill the client so we reconnect next call.
			m.ResetConnection()
			return ExecResult{}, runErr
		}
	}
	m.mu.Lock()
	m.lastLatency = elapsed
	m.mu.Unlock()
	return ExecResult{
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
		ExitCode: exitCode,
	}, nil
}

// LastLatency returns the round-trip duration of the most recent successful
// Exec — a good proxy for "how snappy is the connection right now". Zero
// before the first call.
func (m *Manager) LastLatency() time.Duration {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.lastLatency
}

// WriteFile uploads `data` to `remotePath` via SFTP with the given permissions.
// Used for secret files (prompt, gh token) so they never hit a shell arg list.
func (m *Manager) WriteFile(ctx context.Context, remotePath string, data []byte, permissions os.FileMode) error {
	client, err := m.getClient(ctx)
	if err != nil {
		return err
	}
	sc, err := sftp.NewClient(client)
	if err != nil {
		m.ResetConnection()
		return err
	}
	defer sc.Close()

	f, err := sc.OpenFile(remotePath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Chmod(permissions); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

func loadAuth() ([]ssh.AuthMethod, error) {
	var methods []ssh.AuthMethod

	// 1. SSH agent
	if sock := os.Getenv("SSH_AUTH_SOCK"); sock != "" {
		if conn, err := net.Dial("unix", sock); err == nil {
			ag := agent.NewClient(conn)
			methods = append(methods, ssh.PublicKeysCallback(ag.Signers))
		}
	}

	// 2. ~/.ssh keys (ed25519 → rsa → ecdsa)
	home, _ := os.UserHomeDir()
	for _, name := range []string{"id_ed25519", "id_rsa", "id_ecdsa"} {
		p := filepath.Join(home, ".ssh", name)
		raw, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		signer, err := ssh.ParsePrivateKey(raw)
		if err != nil {
			continue
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}

	if len(methods) == 0 {
		return nil, fmt.Errorf("no usable SSH auth (no agent, no ~/.ssh keys)")
	}
	return methods, nil
}
