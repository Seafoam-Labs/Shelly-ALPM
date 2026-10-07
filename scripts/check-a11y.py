#!/usr/bin/env python3
"""Check the Shelly UI's screen-reader structure.

Run it from the repository root after building the UI:

    cd Shelly.Ui.Gtk && zig build
    python3 scripts/check-a11y.py

This is a developer check, not a CI check. `.github/workflows/build-and-publish.yml`
runs the widget tests with GTK_A11Y=none, which switches the AT-SPI bridge off by
construction, so nothing that reads the tree can ever pass there.

Keep it clean under `ruff check`, `ruff format --check` and `ty check`: the repo
carries no config for either tool, so run them on this file. PyGObject is the one
non-stdlib import, and it only exists at runtime: gi builds `gi.repository.Atspi`
from a typelib, so `ty` cannot see it and the AT-SPI surface this script reads is
declared by the protocols below.

Three phases, cheapest first:

  markup   Parse the GtkBuilder files. Cheap, deterministic, and it catches the
           silent failure mode: `<property name="role">` inside an `<accessibility>`
           block is rejected by GTK with a warning while
           `gtk4-builder-tool validate` still exits 0.
  tree     Read roles, names and descriptions back over the bus from a UI instance
           this script starts in a throwaway HOME. GTK4 has no getter for accessible
           properties, so a name that was rejected, or one whose buffer died, is only
           visible here.
  focus    Drive the first-run wizard with AT-SPI actions and report where focus
           lands. The reported bug was a page change that produced no speech at all.

The script never touches your keyboard (AT-SPI actions, not key injection) and never
writes to your configuration. Exit code 0 means passed or skipped; 1 means failure.
A missing display or an unreachable bridge prints a note and exits 0.

  --verbose   also dump the tree that was read
  --no-wizard skip the focus phase, which needs a first-run configuration
"""

from __future__ import annotations

import argparse
import atexit
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from functools import partial
from typing import Protocol, TypeVar, cast

UI_ROOT = os.path.join("Shelly.Ui.Gtk", "src")
BINARY = os.path.join(UI_ROOT, "..", "zig-out", "bin", "Shelly_Ui_Gtk")
APP_MATCH = "shelly"

# stdout and stderr are log files, not pipes: no text mode is set, so typeshed
# types the handle over bytes.
Process = subprocess.Popen[bytes]

# Controls that must be reachable by name. Containers and text roles are absent on
# purpose: a scrolled window or a table cell is legitimately unnamed, and a link
# announces the text it displays. GTK surfaces a plain button as "button" here,
# not "push button", so both spellings are accepted.
BUTTON_ROLES = ("button", "push button", "toggle button", "check box", "switch")
NAV_PAGES = ("Recommended", "Package", "AUR", "Flatpak", "AppImage", "Search", "Update")

# Icons left in the tree on purpose. Each one is a decision, not an oversight.
ICON_EXCEPTIONS = {
    # Its sibling empty_label carries no text at all, so the icon is the only
    # content that empty state has. Name the label first, then classify the icon.
    os.path.join(UI_ROOT, "dialog", "ui", "version_history.ui"),
}
MUST_NAME_ROLES = (
    *BUTTON_ROLES,
    "radio button",
    "combo box",
    "spin button",
    "slider",
    "entry",
)

_T = TypeVar("_T")


@dataclass
class Report:
    failures: list[str] = field(default_factory=list)
    passed: int = 0
    skipped: int = 0

    def expect(self, label: str, ok: bool, detail: str = "") -> None:
        if ok:
            self.passed += 1
            return
        text = f"{label}{': ' + detail if detail else ''}"
        self.failures.append(text)
        print("FAIL " + text)

    def skip(self, label: str) -> None:
        self.skipped += 1
        print("SKIP " + label)

    def summary(self) -> int:
        print(
            f"\npassed {self.passed}, skipped {self.skipped}, failed {len(self.failures)}"
        )
        for failure in self.failures:
            print("  - " + failure)
        return 1 if self.failures else 0


# --------------------------------------------------------------------------
# phase 1: markup


def check_markup(rep: Report) -> None:
    files = sorted(glob.glob(os.path.join(UI_ROOT, "**", "*.ui"), recursive=True))
    if not files:
        rep.skip(f"markup phase: no .ui files under {UI_ROOT}")
        return

    for path in files:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            rep.expect(f"{path} parses", False, str(exc))
            continue

        parents: dict[int, ET.Element] = {}
        for parent in root.iter("object"):
            for child in parent.iter("child"):
                inner = child.find("object")
                if inner is not None:
                    parents[id(inner)] = parent

        for obj in root.iter("object"):
            kind = obj.get("class")
            ident = obj.get("id") or "<no id>"

            if kind == "GtkSwitch":
                # A switch has no label child of its own, and the row's sibling
                # label never reaches it: without this it announces as bare "switch".
                rep.expect(
                    f"{path} {kind}/{ident} has an accessible label",
                    bool(labelled(obj)),
                    'no <accessibility><property name="label">',
                )

            if (
                kind == "GtkImage"
                and path not in ICON_EXCEPTIONS
                and not inside_control(parents, obj)
            ):
                # An icon that is a control's content is covered by that control's
                # name, and a lone icon beside a label that already says what it
                # means is decoration: it should leave the tree entirely.
                decorative = any(
                    prop.get("name") == "accessible-role"
                    and (prop.text or "").strip() == "presentation"
                    for prop in obj
                    if prop.tag == "property"
                )
                label = ident if ident != "<no id>" else os.path.basename(path)
                rep.expect(
                    f"{path} {label} is presentation",
                    decorative,
                    'add <property name="accessible-role">presentation</property>, '
                    "or a name if the icon carries meaning no text repeats",
                )

            if declares_role(obj, "group") and not labelled(obj):
                # A group with no name is structure no reader can use: the role is
                # only worth declaring when it carries a label. Containers that get
                # their name at runtime declare no role here, they are the exception
                # that has to stay visible in the markup.
                rep.expect(
                    f"{path} {kind}/{ident} group has an accessible label",
                    False,
                    'add <accessibility><property name="label">, or drop the '
                    "accessible-role: a group with no name is noise in the tree",
                )

            for bad in obj.iter("property"):
                if bad.get("name") == "role" and is_inside_accessibility(obj, bad):
                    rep.expect(
                        f"{path} {kind}/{ident} does not use "
                        '<accessibility><property name="role">',
                        False,
                        "GTK rejects it and keeps the default role; use the widget's "
                        "accessible-role property",
                    )
    print(f"markup: {len(files)} files checked")


CONTROL_CLASSES = (
    "GtkButton",
    "GtkMenuButton",
    "GtkToggleButton",
    "GtkLinkButton",
    "GtkCheckButton",
    "GtkExpander",
    "GtkComboBoxText",
    "GtkDropDown",
)


def inside_control(parents: dict[int, ET.Element], obj: ET.Element) -> bool:
    """True when a button or similar control owns this icon as its content: the
    control's own accessible name covers it, so the icon is not a separate claim
    on the tree."""
    node = parents.get(id(obj))
    depth = 0
    while node is not None and depth < 6:
        if node.get("class") in CONTROL_CLASSES:
            return True
        node = parents.get(id(node))
        depth += 1
    return False


def labelled(obj: ET.Element) -> list[ET.Element]:
    """The <accessibility><property name="label"> text, if the object declares one."""
    return [
        p
        for p in accessible_properties(obj)
        if p.get("name") == "label" and (p.text or "").strip()
    ]


def declares_role(obj: ET.Element, role: str) -> bool:
    """True when markup sets this object's accessible role to the given value."""
    return any(
        p.get("name") == "accessible-role" and (p.text or "").strip() == role
        for p in obj
        if p.tag == "property"
    )


def accessible_properties(obj: ET.Element) -> list[ET.Element]:
    """The <property> elements inside this object's <accessibility> block."""
    for child in obj:
        if child.tag == "accessibility":
            return [p for p in child if p.tag == "property"]
    return []


def is_inside_accessibility(obj: ET.Element, prop: ET.Element) -> bool:
    return any(child.tag == "accessibility" and prop in list(child) for child in obj)


# --------------------------------------------------------------------------
# phase 2 and 3: the live tree


class AtspiState(Protocol):
    """A STATE_* enum member; PyGObject exposes the nick as `value_nick`."""

    value_nick: str


class StateSet(Protocol):
    def get_states(self) -> list[AtspiState]: ...


class Action(Protocol):
    def do_action(self, index: int) -> bool: ...


class Accessible(Protocol):
    """The slice of libatspi this script reads, named as gi exposes it at runtime."""

    def get_role_name(self) -> str: ...
    def get_name(self) -> str | None: ...
    def get_description(self) -> str | None: ...
    def get_state_set(self) -> StateSet: ...
    def get_attributes(self) -> dict[str, str] | None: ...
    def get_child_count(self) -> int: ...
    def get_child_at_index(self, index: int) -> Accessible | None: ...
    def get_action_iface(self) -> Action | None: ...


class AtspiBridge(Protocol):
    def init(self) -> None: ...
    def get_desktop(self, index: int) -> Accessible: ...


def read_back(read: Callable[[], _T], fallback: _T) -> _T:
    """Do one AT-SPI read, falling back when it raises.

    A read is a round trip over the bus to another process, so it can fail on a node
    whose application died mid-walk. One dead node must not abort the run.
    """
    try:
        return read()
    except Exception:  # noqa: BLE001
        # The bus returns whatever GLib error the peer raised, and gi's wrapping of
        # it has changed across versions.
        return fallback


class Node:
    __slots__ = ("attrs", "desc", "name", "node", "path", "role", "states")

    node: Accessible
    path: tuple[int, ...]
    role: str
    name: str
    desc: str
    states: set[str]
    attrs: dict[str, str]

    def __init__(self, node: Accessible, path: tuple[int, ...]) -> None:
        self.node = node
        self.path = path
        self.role = read_back(node.get_role_name, "?")
        self.name = read_back(lambda: node.get_name() or "", "")
        self.desc = read_back(lambda: node.get_description() or "", "")
        self.states = read_back(
            lambda: {state.value_nick for state in node.get_state_set().get_states()},
            set(),
        )
        self.attrs = read_back(lambda: dict(node.get_attributes() or {}), {})

    @property
    def showing(self) -> bool:
        return "showing" in self.states and "visible" in self.states

    def __repr__(self) -> str:
        return (
            f"[{self.role}] name={self.name!r} desc={self.desc!r} "
            f"attrs={self.attrs} states={','.join(sorted(self.states))}"
        )


def collect(app: Accessible) -> list[Node]:
    nodes: list[Node] = []

    def walk(node: Accessible, path: tuple[int, ...]) -> None:
        nodes.append(Node(node, path))
        for index in range(read_back(node.get_child_count, 0)):
            child = read_back(partial(node.get_child_at_index, index), None)
            if child is not None:
                walk(child, (*path, index))

    for i in range(app.get_child_count()):
        window = app.get_child_at_index(i)
        if window is not None:
            walk(window, (i,))
    return nodes


def find_app(bridge: AtspiBridge) -> Accessible | None:
    desktop = bridge.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is not None and APP_MATCH in (app.get_name() or "").lower():
            return app
    return None


def wait_for_app(bridge: AtspiBridge, timeout: float = 60.0) -> Accessible | None:
    deadline = time.time() + timeout
    app = None
    while time.time() < deadline and app is None:
        app = find_app(bridge)
        if app is None:
            time.sleep(0.5)
    if app is None:
        return None

    # The package list arrives asynchronously over the CLI, and the row checks scan
    # those rows, so wait for at least one rather than for a fixed pause: a list
    # that never loaded silently makes every row assertion vacuous.
    row_deadline = time.time() + 30.0
    while time.time() < row_deadline:
        if any(node.role == "table cell" and node.showing for node in collect(app)):
            return app
        time.sleep(1.0)
    return app


def start_app(home: str, wizard: bool) -> Process:
    """Launch the UI against a private HOME. wizard=False pre-seeds the config so
    first-run setup does not appear. XDG_CONFIG_HOME wins over HOME, so both must
    point at the sandbox or the real config is read and NewInstall is whatever the
    user left it at."""
    if not wizard:
        # The UI keeps its settings in shelly/settings.json, not the CLI's
        # config.json: seed the wrong file and the first-run wizard is mounted
        # over the window this phase is supposed to be reading.
        cfg = os.path.join(home, "config", "shelly")
        os.makedirs(cfg, exist_ok=True)
        with open(os.path.join(cfg, "settings.json"), "w") as handle:
            json.dump({"NewInstall": False}, handle)

    env = dict(os.environ)
    env["HOME"] = home
    env["XDG_CONFIG_HOME"] = os.path.join(home, "config")
    env["XDG_DATA_HOME"] = os.path.join(home, "data")
    env["XDG_STATE_HOME"] = os.path.join(home, "state")
    env["GTK_A11Y"] = "atspi"
    # The UI locates the CLI at ../Shelly.Cli.Zig/zig-out/bin/shelly relative to its
    # working directory, so it has to run from Shelly.Ui.Gtk: anywhere else starts it
    # with no package list, and the tree this phase reads has no rows in it.
    # Popen gives the child its own dup of the fd, so the parent's copy is closed
    # again on return.
    with open(os.path.join(home, "app.log"), "w") as log:
        return subprocess.Popen(
            [os.path.abspath(BINARY)],
            env=env,
            stdout=log,
            stderr=log,
            cwd=os.path.dirname(UI_ROOT),
        )


def kill_app(proc: Process) -> None:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(10)
        except subprocess.TimeoutExpired:
            proc.kill()


def find(
    nodes: Sequence[Node], role: str | tuple[str, ...], name: str | None = None
) -> Node | None:
    roles = (role,) if isinstance(role, str) else role
    for node in nodes:
        if node.role in roles and (name is None or node.name == name) and node.showing:
            return node
    return None


def click(node: Node) -> bool:
    action = read_back(node.node.get_action_iface, None)
    if action is None:
        return False
    return read_back(lambda: bool(action.do_action(0)), False)


def focused_node(nodes: Sequence[Node]) -> Node | None:
    for node in nodes:
        if "focused" in node.states:
            return node
    return None


def check_main_window(rep: Report, nodes: Sequence[Node]) -> None:
    # Entries the user disabled are hidden rather than greyed out, so assert on the
    # ones actually present instead of on a fixed list.
    named = [
        n
        for n in nodes
        if n.role in BUTTON_ROLES and n.showing and n.name.strip() in NAV_PAGES
    ]
    rep.expect(
        "nav buttons report their page name",
        len(named) >= 2,
        f"{len(named)} named nav buttons",
    )
    for label in ("Package", "Update"):
        # These two are always enabled, so an unnamed one is a regression.
        rep.expect(
            f"nav button {label!r} is named",
            find(nodes, BUTTON_ROLES, label) is not None,
        )
    rep.expect(
        "sidebar chevron is named",
        find(nodes, BUTTON_ROLES, "Collapse sidebar") is not None
        or find(nodes, BUTTON_ROLES, "Expand sidebar") is not None,
    )
    rep.expect(
        "main menu is named", find(nodes, "toggle button", "Main menu") is not None
    )

    entries = [n for n in nodes if n.role == "entry" and n.showing]
    unnamed = [n for n in entries if not n.name.strip()]
    rep.expect(
        "search entries are named",
        not unnamed,
        f"{len(unnamed)} of {len(entries)} unnamed",
    )

    controls = [
        n
        for n in nodes
        if n.role in MUST_NAME_ROLES
        and n.showing
        and not n.name.strip()
        and not n.desc.strip()
    ]
    rep.expect(
        "no visible control lacks a name and a description",
        not controls,
        f"{len(controls)} blank: {sorted({n.role for n in controls})}",
    )

    # The check above only means something if list rows were on the bus to scan.
    rows = [n for n in nodes if n.role == "table cell" and n.showing]
    rep.expect(
        "the package list rendered rows",
        bool(rows),
        f"{len(rows)} rows; an empty list means the CLI is unreachable from this working directory",
    )

    headings = [n for n in nodes if n.role == "heading" and n.showing]
    rep.expect(
        "every heading carries a level",
        all(n.attrs.get("level") for n in headings),
        f"{sum(1 for n in headings if not n.attrs.get('level'))} headings without attrs level",
    )

    # A page with no title widget of its own is still named: GTK gives a stack's
    # child the accessible name of its StackPage title, which is what tells a
    # reader which page focus landed in.
    page_names = (*NAV_PAGES, "Settings", "Utilities")
    containers = [n for n in nodes if n.role in ("panel", "grouping") and n.showing]
    named_pages = [n for n in containers if n.name.strip() in page_names]
    rep.expect(
        "the visible page names itself",
        bool(named_pages),
        f"{len(named_pages)} of {len(containers)} containers carry a page name",
    )


def check_wizard(rep: Report, app: Accessible) -> None:
    nodes = collect(app)
    dialog = find(nodes, "dialog", "Welcome to Shelly v3")
    if dialog is None:
        rep.skip("wizard phase: no first-run dialog (is the sandbox config new?)")
        return

    rep.expect(
        "the lockout reports a modal dialog",
        "modal" in dialog.states,
        f"states={','.join(sorted(dialog.states))}",
    )
    rep.expect(
        "wizard page 1 is a named group",
        find(nodes, "grouping", "Welcome to Shelly v3") is not None,
    )
    heading = find(nodes, "heading", "Welcome to Shelly v3")
    rep.expect(
        "wizard page 1 has a level 1 heading",
        heading is not None and heading.attrs.get("level") == "1",
    )

    nxt = find(nodes, BUTTON_ROLES, "Next")
    if nxt is None or not click(nxt):
        rep.skip("wizard phase: could not activate Next over AT-SPI")
        return
    time.sleep(1.5)

    nodes = collect(app)
    rep.expect(
        "wizard page 2 is a named group",
        find(nodes, "grouping", "Select Your Sources") is not None,
    )
    boxes = [n for n in nodes if n.role == "check box" and n.showing]
    unnamed = [n.name for n in boxes if not n.name.strip()]
    rep.expect(
        "wizard source check boxes are named",
        len(boxes) >= 4 and not unnamed,
        f"{len(boxes)} found, {len(unnamed)} unnamed",
    )
    switches = [n for n in nodes if n.role == "switch" and n.showing]
    rep.expect("wizard switches are named", all(n.name.strip() for n in switches))

    target = focused_node(nodes)
    if target is None:
        # STATE_FOCUSED is only set while the toplevel holds the compositor's
        # focus, so this is the one check that needs the window to be active.
        rep.skip(
            "focus phase: the UI window is not the active window, so nothing "
            "reports STATE_FOCUSED. Press Next in Orca to check this by ear."
        )
    else:
        rep.expect(
            "focus moved into the new page",
            target.role in ("check box", "switch", "combo box"),
            f"focus is on [{target.role}] {target.name!r}",
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check Shelly's UI for screen-reader structure."
    )
    parser.add_argument(
        "--verbose", action="store_true", help="dump the tree that was read"
    )
    parser.add_argument(
        "--no-wizard", action="store_true", help="skip the first-run focus phase"
    )
    args = parser.parse_args()

    rep = Report()
    check_markup(rep)

    os.environ.pop("GTK_A11Y", None)
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        print("\nNo display: the live phases need a running graphical session.")
        return rep.summary()
    if not os.path.exists(os.path.abspath(BINARY)):
        print(
            f"\nBuild the UI first (cd Shelly.Ui.Gtk && zig build): {BINARY} is missing."
        )
        return rep.summary()

    try:
        import gi

        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi  # ty: ignore[unresolved-import]
    except Exception as exc:  # noqa: BLE001 - any failure here ends the live phases
        print(f"\nAT-SPI is unreachable here ({exc}); the live phases are skipped.")
        return rep.summary()

    # gi builds this module from a typelib at runtime, so the cast is the boundary:
    # everything downstream is checked against the protocols above.
    bridge = cast("AtspiBridge", Atspi)
    bridge.init()
    if find_app(bridge) is not None:
        print("\nA Shelly UI is already on the accessibility bus. Quit it first: the")
        print(
            "sandboxed instance this script starts would be indistinguishable from it."
        )
        return 1

    if shutil.which("orca"):
        print("NOTE: Orca is installed. This script does not need it running, and a")
        print("      running Orca moves focus on its own, so stop it first:")
        print("      pkill -x orca")

    home = tempfile.mkdtemp(prefix="shelly-a11y-")
    atexit.register(shutil.rmtree, home, ignore_errors=True)

    print("\nreading the main window ...")
    proc = start_app(home, wizard=False)
    atexit.register(kill_app, proc)
    app = wait_for_app(bridge)
    if app is None:
        with open(os.path.join(home, "app.log"), errors="replace") as handle:
            tail = handle.read()[-2000:]
        print("the UI did not appear on the accessibility bus:\n" + tail)
        return 1
    nodes = collect(app)
    if args.verbose:
        for node in nodes:
            print("  " * len(node.path) + repr(node))
    check_main_window(rep, nodes)
    kill_app(proc)

    if not args.no_wizard:
        print("reading the first-run wizard ...")
        wizard_home = tempfile.mkdtemp(prefix="shelly-a11y-wizard-")
        atexit.register(shutil.rmtree, wizard_home, ignore_errors=True)
        proc = start_app(wizard_home, wizard=True)
        atexit.register(kill_app, proc)
        app = wait_for_app(bridge)
        if app is None:
            rep.skip("wizard phase: the UI did not appear on the bus")
        else:
            check_wizard(rep, app)
            kill_app(proc)

    return rep.summary()


if __name__ == "__main__":
    sys.exit(main())
