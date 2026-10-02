"""Brings pinned panes to herdr's focused tab, as a column on the right.

bigtty pins a pane by tagging it (pane tokens: btty_pin = its order,
btty_pin_width = the column's share of the tab). bigtty moves pins itself
when you switch spaces in bigtty; this does the same when you switch in
herdr's terminal UI. Same rule, so the two agree: the pins go to the tab
that's focused, the first beside the pane along the right edge (a
full-height column when there is one), the rest stacked below it.
"""
import fcntl
import json
import os
import socket
import time

SOCKET = os.environ.get("HERDR_SOCKET_PATH", "")
STATE = os.environ.get("HERDR_PLUGIN_STATE_DIR") or "/tmp"


def call(method, params=None):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect(SOCKET)
    s.sendall((json.dumps({"id": "pins", "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    reply = json.loads(buf)
    if "error" in reply:
        raise RuntimeError(reply["error"])
    return reply["result"]


def leaves(node):
    if node.get("type") == "pane":
        return [node["pane_id"]]
    return leaves(node["first"]) + leaves(node["second"])


def without(node, ids):
    if node.get("type") == "pane":
        return None if node["pane_id"] in ids else node
    a, b = without(node["first"], ids), without(node["second"], ids)
    if a is None:
        return b
    if b is None:
        return a
    return {**node, "first": a, "second": b}


def right_edge_leaf(node):
    """The pane along the right edge spanning the full height, and its share
    of the width: down the second halves of right splits."""
    share = 1.0
    while node.get("type") == "split" and node.get("direction") == "right":
        share *= 1 - node["ratio"]
        node = node["second"]
    return (node["pane_id"], share) if node.get("type") == "pane" else None


def follow():
    snap = call("session.snapshot")["snapshot"]
    tab = snap.get("focused_tab_id")
    pins = sorted(
        (p for p in snap["panes"] if (p.get("tokens") or {}).get("btty_pin")),
        key=lambda p: int(p["tokens"]["btty_pin"]) if p["tokens"]["btty_pin"].isdigit() else 0,
    )
    if not tab or not pins:
        return
    layout = call("layout.export", {"tab_id": tab})["layout"]
    if layout.get("zoomed"):
        return  # herdr won't move into a zoomed tab
    here = set(leaves(layout["root"]))
    if all(p["pane_id"] in here for p in pins):
        return
    pin_ids = {p["pane_id"] for p in pins}
    others = without(layout["root"], pin_ids)
    if others is None:
        return  # nothing but pins here
    try:
        width = float(pins[0]["tokens"].get("btty_pin_width") or 0.32)
    except ValueError:
        width = 0.32
    placed = [p["pane_id"] for p in pins if p["pane_id"] in here]
    for pin in pins:
        if pin["pane_id"] in here:
            continue
        if placed:
            destination = {"type": "tab", "tab_id": tab, "split": "down", "target_pane_id": placed[-1]}
        else:
            edge = right_edge_leaf(others)
            if edge:
                ratio = min(0.9, max(0.1, 1 - width / max(edge[1], 0.0001)))
                destination = {"type": "tab", "tab_id": tab, "split": "right", "target_pane_id": edge[0], "ratio": ratio}
            else:
                destination = {"type": "tab", "tab_id": tab, "split": "right", "target_pane_id": leaves(others)[-1], "ratio": 1 - width}
        moved = call("pane.move", {"pane_id": pin["pane_id"], "destination": destination, "focus": False})["move_result"]
        if not moved.get("changed"):
            break
        placed.append(moved["pane"]["pane_id"])


def main():
    if not SOCKET:
        return
    # Quick switching fires several hooks: let it settle, then one at a time,
    # each acting on whatever is focused by then.
    time.sleep(0.12)
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "follow.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        follow()


if __name__ == "__main__":
    main()
