"""Textual TUI for tgv session management."""

from __future__ import annotations

import os
import subprocess

from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, Horizontal
from textual.screen import ModalScreen
from textual.widgets import (
    Header,
    Footer,
    Static,
    ListView,
    ListItem,
    Input,
    Button,
    Label,
)

from tgv.banner import BANNER_TUI
from tgv.config import Config
from tgv.session import Session, list_sessions, spawn, stop, attach_command
from tgv.server import ssh_run


class SessionItem(ListItem):
    """A session entry in the list."""

    def __init__(self, session: Session) -> None:
        super().__init__()
        self.session = session

    def compose(self) -> ComposeResult:
        s = self.session
        icon = "●" if s.status == "running" else "○"
        yield Static(
            f" {icon}  {s.name:<20} {s.repo:<25} {s.branch:<15} {s.created}",
            classes="session-row",
        )


class NewSessionScreen(ModalScreen[dict | None]):
    """Modal dialog to create a new session."""

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def compose(self) -> ComposeResult:
        with Vertical(id="new-session-dialog"):
            yield Label("New Session", id="dialog-title")
            yield Label("Branch (leave empty for default):")
            yield Input(placeholder="main", id="branch-input")
            yield Label("Prompt for Claude (optional):")
            yield Input(placeholder="fix the login bug in auth.ts", id="prompt-input")
            with Horizontal(id="dialog-buttons"):
                yield Button("Create", variant="primary", id="create-btn")
                yield Button("Cancel", id="cancel-btn")

    @on(Button.Pressed, "#create-btn")
    def on_create(self) -> None:
        branch = self.query_one("#branch-input", Input).value.strip()
        prompt = self.query_one("#prompt-input", Input).value.strip()
        self.dismiss({"branch": branch, "prompt": prompt})

    @on(Button.Pressed, "#cancel-btn")
    def on_cancel(self) -> None:
        self.dismiss(None)

    def action_cancel(self) -> None:
        self.dismiss(None)


class TGVApp(App):
    """tgv — Terminal à Grande Vitesse."""

    TITLE = "tgv — Terminal à Grande Vitesse"
    CSS = """
    #banner {
        height: auto;
        width: 100%;
        content-align: center middle;
        padding: 1 1 0 1;
    }
    #new-session-dialog {
        width: 60;
        height: auto;
        border: thick $accent;
        background: $surface;
        padding: 1 2;
    }
    #dialog-title {
        text-style: bold;
        width: 100%;
        content-align: center middle;
        margin-bottom: 1;
    }
    #dialog-buttons {
        margin-top: 1;
        align: center middle;
        height: 3;
    }
    #dialog-buttons Button {
        margin: 0 1;
    }
    .session-row {
        height: 1;
    }
    #status-bar {
        height: 1;
        dock: bottom;
        background: $accent;
        color: $text;
        padding: 0 1;
    }
    #empty-message {
        width: 100%;
        height: 100%;
        content-align: center middle;
        color: $text-muted;
    }
    """

    BINDINGS = [
        Binding("n", "new_session", "New"),
        Binding("k", "kill_session", "Kill"),
        Binding("enter", "attach_session", "Attach"),
        Binding("r", "refresh", "Refresh"),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(self, config: Config) -> None:
        super().__init__()
        self.config = config
        self.sessions: list[Session] = []

    def compose(self) -> ComposeResult:
        yield Static(BANNER_TUI, id="banner", markup=True)
        yield ListView(id="session-list")
        yield Static("", id="status-bar")
        yield Footer()

    def on_mount(self) -> None:
        self.refresh_sessions()

    @work(thread=True)
    def refresh_sessions(self) -> None:
        """Fetch sessions from remote server."""
        try:
            self.sessions = list_sessions(self.config)
            self.call_from_thread(self._update_list)
            self.call_from_thread(
                self._set_status,
                f"Connected to {self.config.ssh_target} | {len(self.sessions)} session(s)",
            )
        except Exception as e:
            self.call_from_thread(
                self._set_status, f"Error: {e}"
            )

    def _update_list(self) -> None:
        """Update the session list widget."""
        list_view = self.query_one("#session-list", ListView)
        list_view.clear()
        if not self.sessions:
            list_view.append(ListItem(Static("  No sessions. Press [N] to create one.", id="empty-message")))
        else:
            for session in self.sessions:
                list_view.append(SessionItem(session))

    def _set_status(self, text: str) -> None:
        self.query_one("#status-bar", Static).update(text)

    def action_new_session(self) -> None:
        self.push_screen(NewSessionScreen(), self._on_new_session_result)

    @work(thread=True)
    def _on_new_session_result(self, result: dict | None) -> None:
        if result is None:
            return
        self.call_from_thread(self._set_status, "Spawning session...")
        try:
            name = spawn(
                self.config,
                branch=result["branch"],
                prompt=result["prompt"],
            )
            self.call_from_thread(
                self.notify, f"Session {name} created", severity="information"
            )
            self.refresh_sessions()
        except Exception as e:
            self.call_from_thread(
                self.notify, f"Failed to create session: {e}", severity="error"
            )

    def action_kill_session(self) -> None:
        session = self._selected_session()
        if session:
            self._do_kill(session.name)

    @work(thread=True)
    def _do_kill(self, name: str) -> None:
        try:
            stop(self.config, name)
            self.call_from_thread(
                self.notify, f"Session {name} removed", severity="information"
            )
            self.refresh_sessions()
        except Exception as e:
            self.call_from_thread(
                self.notify, f"Failed to kill session: {e}", severity="error"
            )

    def action_attach_session(self) -> None:
        session = self._selected_session()
        if not session:
            return
        if session.status != "running":
            self.notify("Session is not running", severity="warning")
            return
        # Suspend TUI, attach via ET, resume TUI when detached
        cmd = attach_command(session.name)
        with self.suspend():
            subprocess.run([
                "et",
                f"-p", str(self.config.server.et_port),
                self.config.ssh_target,
                "-c", cmd,
            ])

    def action_refresh(self) -> None:
        self.refresh_sessions()

    def _selected_session(self) -> Session | None:
        list_view = self.query_one("#session-list", ListView)
        if list_view.highlighted_child and isinstance(list_view.highlighted_child, SessionItem):
            return list_view.highlighted_child.session
        return None
