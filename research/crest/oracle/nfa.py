"""Thompson epsilon-NFA and exact NFA x ranked-run-monitor reachability."""

from __future__ import annotations

import itertools
from collections import deque
from dataclasses import dataclass

if __package__:
    from .syntax import (
        Alternate,
        Atom,
        Concat,
        EmptyLanguage,
        Epsilon,
        Node,
        Repeat,
        ResourceLimitExceeded,
    )
else:  # Direct execution through oracle.py.
    from syntax import (
        Alternate,
        Atom,
        Concat,
        EmptyLanguage,
        Epsilon,
        Node,
        Repeat,
        ResourceLimitExceeded,
    )


MAX_NFA_STATES = 20_000
MAX_PRODUCT_STATES = 2_000_000


@dataclass(frozen=True, slots=True)
class NFA:
    start: int
    accept: int
    epsilon: tuple[tuple[int, ...], ...]
    consuming: tuple[tuple[tuple[frozenset[int], int], ...], ...]

    @property
    def state_count(self) -> int:
        return len(self.epsilon)


@dataclass(frozen=True, slots=True)
class ExactResult:
    threshold: int
    nfa_states: int
    shortest_witness_length: int
    emptiness_checks: int
    max_product_states_visited: int


@dataclass(frozen=True, slots=True)
class _Fragment:
    start: int
    end: int


def compile_nfa(node: Node) -> NFA:
    """Compile the independent syntax tree to a Thompson epsilon-NFA."""
    builder = _Builder()
    try:
        fragment = builder.compile(node)
    except RecursionError as error:
        raise ResourceLimitExceeded(
            "AST nesting exceeds the exact compiler's recursion limit",
            construct="AST nesting",
        ) from error
    return NFA(
        fragment.start,
        fragment.end,
        tuple(tuple(edges) for edges in builder.epsilon),
        tuple(tuple(edges) for edges in builder.consuming),
    )


def exact_forced_run(
    nfa: NFA,
    predicate: frozenset[int],
    rank: int = 1,
) -> ExactResult:
    """Return the exact minimum rank-th-largest predicate run over the language."""
    invalid = [byte for byte in predicate if not 0 <= byte <= 255]
    if invalid:
        raise ValueError(f"predicate contains non-byte values: {invalid[:3]}")
    if rank < 1:
        raise ValueError("run rank must be positive")

    shortest = _shortest_word_length(nfa)
    if shortest is None:
        raise EmptyLanguage("the regex accepts no strings", construct="empty language")
    if shortest == 0:
        return ExactResult(0, nfa.state_count, 0, 0, 0)

    checks = 0
    max_visited = 0
    low, high = 1, shortest + 1
    while low < high:
        threshold = (low + high) // 2
        exists, visited = _accepts_below_threshold(nfa, predicate, rank, threshold)
        checks += 1
        max_visited = max(max_visited, visited)
        if exists:
            high = threshold
        else:
            low = threshold + 1
    return ExactResult(low - 1, nfa.state_count, shortest, checks, max_visited)


def accepts_word(nfa: NFA, word: bytes) -> bool:
    """Reference NFA simulation used by independent finite-language tests."""
    current = _epsilon_closure(nfa, {nfa.start})
    for byte in word:
        following: set[int] = set()
        for state in current:
            for label, target in nfa.consuming[state]:
                if byte in label:
                    following.add(target)
        current = _epsilon_closure(nfa, following)
        if not current:
            return False
    return nfa.accept in current


def _epsilon_closure(nfa: NFA, states: set[int]) -> set[int]:
    closure = set(states)
    pending = list(states)
    while pending:
        state = pending.pop()
        for target in nfa.epsilon[state]:
            if target not in closure:
                closure.add(target)
                pending.append(target)
    return closure


def _shortest_word_length(nfa: NFA) -> int | None:
    infinity = nfa.state_count + 1
    distance = [infinity] * nfa.state_count
    distance[nfa.start] = 0
    pending = deque([nfa.start])
    while pending:
        state = pending.popleft()
        base = distance[state]
        for target in nfa.epsilon[state]:
            if base < distance[target]:
                distance[target] = base
                pending.appendleft(target)
        for label, target in nfa.consuming[state]:
            if label and base + 1 < distance[target]:
                distance[target] = base + 1
                pending.append(target)
    result = distance[nfa.accept]
    return None if result == infinity else result


def _accepts_below_threshold(
    nfa: NFA,
    predicate: frozenset[int],
    rank: int,
    threshold: int,
) -> tuple[bool, int]:
    """Decide whether an accepted word has fewer than rank runs reaching threshold."""
    if threshold < 1:
        raise ValueError("run threshold must be positive")

    start = (nfa.start, 0, 0)
    seen = {start}
    pending = deque([start])
    while pending:
        state, run, completed = pending.popleft()
        if state == nfa.accept and completed + (run == threshold) < rank:
            return True, len(seen)
        for target in nfa.epsilon[state]:
            _enqueue((target, run, completed), seen, pending)
        for label, target in nfa.consuming[state]:
            if label - predicate:
                closed = completed + (run == threshold)
                if closed < rank:
                    _enqueue((target, 0, closed), seen, pending)
            if label & predicate:
                _enqueue((target, min(threshold, run + 1), completed), seen, pending)
        if len(seen) > MAX_PRODUCT_STATES:
            raise ResourceLimitExceeded(
                f"NFA x monitor reachability exceeds {MAX_PRODUCT_STATES} states",
                construct="product automaton",
            )
    return False, len(seen)


def _enqueue(
    state: tuple[int, int, int],
    seen: set[tuple[int, int, int]],
    pending: deque[tuple[int, int, int]],
) -> None:
    if state not in seen:
        seen.add(state)
        pending.append(state)


class _Builder:
    def __init__(self) -> None:
        self.epsilon: list[list[int]] = []
        self.consuming: list[list[tuple[frozenset[int], int]]] = []

    def compile(self, node: Node) -> _Fragment:
        if isinstance(node, Epsilon):
            return self._epsilon_fragment()
        if isinstance(node, Atom):
            start, end = self._states(2)
            self.consuming[start].append((node.bytes, end))
            return _Fragment(start, end)
        if isinstance(node, Concat):
            return self._concatenate([self.compile(part) for part in node.parts])
        if isinstance(node, Alternate):
            return self._alternate([self.compile(branch) for branch in node.branches])
        if isinstance(node, Repeat):
            return self._repeat(node)
        raise TypeError(f"unknown independent AST node: {type(node).__name__}")

    def _repeat(self, node: Repeat) -> _Fragment:
        mandatory = [self.compile(node.child) for _ in range(node.minimum)]
        if node.maximum is None:
            mandatory.append(self._star(self.compile(node.child)))
        else:
            mandatory.extend(
                self._optional(self.compile(node.child)) for _ in range(node.maximum - node.minimum)
            )
        return self._concatenate(mandatory)

    def _star(self, child: _Fragment) -> _Fragment:
        start, end = self._states(2)
        self.epsilon[start].extend((end, child.start))
        self.epsilon[child.end].extend((end, child.start))
        return _Fragment(start, end)

    def _optional(self, child: _Fragment) -> _Fragment:
        start, end = self._states(2)
        self.epsilon[start].extend((end, child.start))
        self.epsilon[child.end].append(end)
        return _Fragment(start, end)

    def _alternate(self, branches: list[_Fragment]) -> _Fragment:
        start, end = self._states(2)
        for branch in branches:
            self.epsilon[start].append(branch.start)
            self.epsilon[branch.end].append(end)
        return _Fragment(start, end)

    def _concatenate(self, parts: list[_Fragment]) -> _Fragment:
        if not parts:
            return self._epsilon_fragment()
        for left, right in itertools.pairwise(parts):
            self.epsilon[left.end].append(right.start)
        return _Fragment(parts[0].start, parts[-1].end)

    def _epsilon_fragment(self) -> _Fragment:
        start, end = self._states(2)
        self.epsilon[start].append(end)
        return _Fragment(start, end)

    def _states(self, count: int) -> tuple[int, ...]:
        if len(self.epsilon) + count > MAX_NFA_STATES:
            raise ResourceLimitExceeded(
                f"Thompson NFA exceeds {MAX_NFA_STATES} states",
                construct="Thompson NFA",
            )
        first = len(self.epsilon)
        self.epsilon.extend([] for _ in range(count))
        self.consuming.extend([] for _ in range(count))
        return tuple(range(first, first + count))
