#!/usr/bin/env python3
"""Measure the app's NNUE MultiPV difficulty profiles against a stronger search.

The selection logic mirrors PikafishMoveGateway: hard takes rank 1, normal
selects deterministically within 80 cp from MultiPV 3, and easy avoids rank 1
when a MultiPV 5 candidate remains within 220 cp. The report measures the
selected move with a longer reference search; it does not claim human Elo.

Usage:
  calibrate_strength.py <pikafish_cli> <pikafish.nnue> [--positions N]
"""

import argparse
import random
import re
import subprocess
import sys

MATE = 30000
START = (
    "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/"
    "RNBAKABNR w - - 0 1"
)
PROFILES = (
    ("easy", 300, 5, 220),
    ("normal", 600, 3, 80),
    ("hard", 1200, 1, 0),
)


class Engine:
    def __init__(self, path, eval_file):
        self.proc = subprocess.Popen(
            [path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.send("uci")
        uci_lines = self._read_until("uciok")
        if not any(line.startswith("option name EvalFile type ")
                   for line in uci_lines):
            raise RuntimeError("engine does not advertise EvalFile")
        self.send("setoption name Threads value 1")
        self.send("setoption name Hash value 16")
        self.send(f"setoption name EvalFile value {eval_file}")
        self.ready()

    def send(self, command):
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()

    def _read_until(self, token):
        output = []
        for raw_line in self.proc.stdout:
            line = raw_line.strip()
            output.append(line)
            if line.split(" ")[0] == token:
                return output
        raise RuntimeError("engine exited unexpectedly")

    def ready(self):
        self.send("isready")
        self._read_until("readyok")

    def new_game(self):
        self.send("ucinewgame")
        self.ready()

    def search(self, fen, movetime, multipv=1, moves=""):
        self.send(f"setoption name MultiPV value {multipv}")
        suffix = f" moves {moves}" if moves else ""
        self.send(f"position fen {fen}{suffix}")
        self.send(f"go movetime {movetime}")
        lines = self._read_until("bestmove")
        return _best_move(lines), _variations(lines)

    def fen_after(self, fen, moves):
        self.send(f"position fen {fen} moves {moves}")
        self.send("d")
        for line in self._read_until("Checkers:"):
            if line.startswith("Fen:"):
                return line[4:].strip()
        raise RuntimeError("no FEN in display output")

    def depth_candidates(self, fen, depth, count):
        self.send(f"setoption name MultiPV value {count}")
        self.send(f"position fen {fen}")
        self.send(f"go depth {depth}")
        lines = self._read_until("bestmove")
        return [item["move"] for item in _variations(lines) if item["move"]]

    def quit(self):
        self.send("quit")
        self.proc.wait(timeout=5)


def _best_move(lines):
    for line in reversed(lines):
        if line.startswith("bestmove"):
            move = line.split()[1]
            return None if move == "(none)" else move
    return None


def _variations(lines):
    latest = {}
    for line in lines:
        if not line.startswith("info ") or " pv " not in line:
            continue
        pv = line.split(" pv ", 1)[1].split()
        if not pv:
            continue
        rank_match = re.search(r"\bmultipv (\d+)", line)
        rank = int(rank_match.group(1)) if rank_match else 1
        cp_match = re.search(r"\bscore cp (-?\d+)", line)
        mate_match = re.search(r"\bscore mate (-?\d+)", line)
        latest[rank] = {
            "rank": rank,
            "move": pv[0],
            "cp": int(cp_match.group(1)) if cp_match else None,
            "mate": int(mate_match.group(1)) if mate_match else None,
        }
    return [latest[rank] for rank in sorted(latest)]


def _score(variation):
    if variation is None:
        return None
    mate = variation["mate"]
    if mate is not None:
        return MATE - abs(mate) if mate > 0 else -(MATE - abs(mate))
    return variation["cp"]


def _acceptable(best, candidate, max_loss):
    if candidate["rank"] == best["rank"]:
        return True
    if best["mate"] is not None:
        return (best["mate"] > 0 and candidate["mate"] is not None
                and candidate["mate"] > 0)
    if candidate["mate"] is not None:
        return candidate["mate"] > 0
    return (best["cp"] is not None and candidate["cp"] is not None
            and best["cp"] - candidate["cp"] <= max_loss)


def _stable_index(value, length):
    value_hash = 0x811C9DC5
    for byte in value.encode("ascii"):
        value_hash ^= byte
        value_hash = (value_hash * 0x01000193) & 0xFFFFFFFF
    return value_hash % length


def select_move(variations, fen, profile, max_loss):
    if not variations:
        return None
    if profile == "hard":
        return variations[0]["move"]
    acceptable = [candidate for candidate in variations
                  if _acceptable(variations[0], candidate, max_loss)]
    if not acceptable:
        return variations[0]["move"]
    pool = acceptable[1:] if profile == "easy" and len(acceptable) > 1 \
        else acceptable
    return pool[_stable_index(f"{fen}|{profile}", len(pool))]["move"]


def make_positions(engine, count, seed=7):
    rng = random.Random(seed)
    positions, moves = [], []
    engine.new_game()
    while len(positions) < count:
        fen = engine.fen_after(START, " ".join(moves)) if moves else START
        if len(moves) >= 6:
            positions.append(fen)
        candidates = engine.depth_candidates(fen, 6, 4)
        if not candidates:
            moves = []
            continue
        moves.append(rng.choice(candidates))
        if len(moves) > 40:
            moves = []
            engine.new_game()
    return positions


def reference_loss(engine, fen, move, movetime, best_score, cache):
    key = (fen, move)
    if key in cache:
        return cache[key]
    _, variations = engine.search(fen, movetime, moves=move)
    reply_score = _score(variations[0]) if variations else None
    value = -reply_score if reply_score is not None else None
    loss = None if value is None or best_score is None \
        else max(0, best_score - value)
    cache[key] = loss
    return loss


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("engine")
    parser.add_argument("eval_file")
    parser.add_argument("--positions", type=int, default=24)
    parser.add_argument("--reference-movetime", type=int, default=2000)
    args = parser.parse_args()

    generator = Engine(args.engine, args.eval_file)
    positions = make_positions(generator, args.positions)
    generator.quit()
    print(f"positions: {len(positions)}", file=sys.stderr)

    reference = Engine(args.engine, args.eval_file)
    best = {}
    for fen in positions:
        reference.new_game()
        ref_move, variations = reference.search(fen, args.reference_movetime)
        best[fen] = (
            ref_move,
            _score(variations[0]) if variations else None,
        )

    subject = Engine(args.engine, args.eval_file)
    cache, rows = {}, []
    for profile, movetime, multipv, max_loss in PROFILES:
        losses, agreement = [], 0
        for fen in positions:
            subject.new_game()
            _, variations = subject.search(fen, movetime, multipv=multipv)
            move = select_move(variations, fen, profile, max_loss)
            if move is None:
                continue
            ref_move, best_score = best[fen]
            if move == ref_move:
                agreement += 1
                losses.append(0)
                continue
            loss = reference_loss(reference, fen, move,
                                  args.reference_movetime, best_score, cache)
            if loss is not None:
                losses.append(min(loss, 2000))
        losses.sort()
        sample_count = len(losses) or 1
        rows.append((
            profile,
            movetime,
            multipv,
            sum(losses) / sample_count,
            losses[len(losses) // 2] if losses else 0,
            100.0 * sum(loss > 200 for loss in losses) / sample_count,
            100.0 * agreement / sample_count,
        ))

    subject.quit()
    reference.quit()

    print("profile  time  pv  mean loss  median  blunder>200  top agreement")
    for row in rows:
        print(f"{row[0]:>7} {row[1]:>5} {row[2]:>3} {row[3]:>10.1f} "
              f"{row[4]:>7.0f} {row[5]:>11.0f}% {row[6]:>13.0f}%")


if __name__ == "__main__":
    main()
