"""Finite regex fixtures shared by the independent oracle tests."""

from __future__ import annotations

import itertools

A = ord("a")
B = ord("b")


def render(node: tuple) -> str:
    """Render the tiny independent fixture AST as a regex."""
    kind, *fields = node
    if kind == "eps":
        return "(?:)"
    if kind == "atom":
        values = fields[0]
        return chr(values[0]) if len(values) == 1 else f"[{''.join(map(chr, values))}]"
    if kind == "cat":
        return f"(?:{render(fields[0])})(?:{render(fields[1])})"
    if kind == "alt":
        return f"(?:{render(fields[0])}|{render(fields[1])})"
    if kind == "rep":
        child, minimum, maximum = fields
        return f"(?:{render(child)}){{{minimum},{maximum}}}"
    raise ValueError(f"unknown fixture AST {kind}")


def finite_asts() -> tuple[tuple, ...]:
    """Exhaust every constructor through depth two over a two-byte quotient."""
    atoms = (
        ("eps",),
        ("atom", (A,)),
        ("atom", (B,)),
        ("atom", (A, B)),
    )
    level_one: set[tuple] = set()
    for left, right in itertools.product(atoms, repeat=2):
        level_one.add(("cat", left, right))
        level_one.add(("alt", left, right))
    for child in atoms:
        for bounds in ((0, 1), (0, 2), (1, 2), (2, 3)):
            level_one.add(("rep", child, *bounds))

    all_nodes = set(atoms) | level_one
    for left, right in itertools.product(level_one, atoms):
        all_nodes.add(("cat", left, right))
        all_nodes.add(("alt", left, right))
    for child in level_one:
        for bounds in ((0, 1), (1, 2)):
            all_nodes.add(("rep", child, *bounds))
    return tuple(sorted(all_nodes, key=repr))
