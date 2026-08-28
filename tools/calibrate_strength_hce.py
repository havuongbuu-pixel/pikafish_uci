#!/usr/bin/env python3
"""Measures how much strength UCI_Elo actually removes, to pick the app's
difficulty mapping from data instead of from guesswork.

Method, for each Elo setting and each test position:

  1. Ask the limited engine for a move at a fixed movetime.
  2. Score that move with a full-strength reference search: play it, search the
     reply, negate. Centipawn loss is the reference best score minus that.

Centipawn loss is the right measure for a game opponent. What makes a bot feel
weak is not its average score but how often it throws material away, so the
report carries the blunder rate alongside the mean.

Usage: calibrate_strength.py <pikafish_cli> [--positions N] [--movetime MS]
"""
import argparse
import random
import re
import subprocess
import sys

MATE = 30000


class Engine:
    def __init__(self, path):
        self.proc = subprocess.Popen(
            [path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, bufsize=1,
        )
        self.send("uci")
        self._read_until("uciok")
        # Pin the rules the app pins, so measurements match shipped behaviour.
        for opt, val in (("Sixty Move Rule", "true"),
                         ("Chase With Check", "true"),
                         ("Strict Three Fold", "false"),
                         ("Threads", "1"), ("Hash", "16")):
            self.send(f"setoption name {opt} value {val}")
        self.ready()

    def send(self, cmd):
        self.proc.stdin.write(cmd + "\n")
        self.proc.stdin.flush()

    def _read_until(self, token):
        out = []
        for line in self.proc.stdout:
            line = line.strip()
            out.append(line)
            if line.split(" ")[0] == token:
                return out
        raise RuntimeError("engine exited unexpectedly")

    def ready(self):
        self.send("isready")
        self._read_until("readyok")

    def new_game(self):
        self.send("ucinewgame")
        self.ready()

    def set_elo(self, elo):
        self.send(f"setoption name UCI_LimitStrength value "
                  f"{'true' if elo else 'false'}")
        if elo:
            self.send(f"setoption name UCI_Elo value {elo}")
        self.ready()

    def set_skill(self, level):
        """Skill Level is the other weakening knob, and unlike UCI_Elo it is
        not calibrated to a rating. Both are measured so the choice is made on
        evidence rather than on which one has the friendlier name."""
        self.send("setoption name UCI_LimitStrength value false")
        self.send(f"setoption name Skill Level value {level}")
        self.ready()

    def search(self, fen, movetime, moves=""):
        self.send(f"position fen {fen}" + (f" moves {moves}" if moves else ""))
        self.send(f"go movetime {movetime}")
        lines = self._read_until("bestmove")
        return _best_move(lines), _score(lines)

    def fen_after(self, fen, moves):
        self.send(f"position fen {fen} moves {moves}")
        self.send("d")
        for line in self._read_until("Checkers:"):
            if line.startswith("Fen:"):
                return line[4:].strip()
        raise RuntimeError("no FEN in display output")

    def multipv_moves(self, fen, depth, count):
        """Depth-limited on purpose. Generating positions with a movetime makes
        the position set depend on how busy the machine was, so two runs of this
        script would not measure the same thing."""
        self.send(f"setoption name MultiPV value {count}")
        self.send(f"position fen {fen}")
        self.send(f"go depth {depth}")
        lines = self._read_until("bestmove")
        self.send("setoption name MultiPV value 1")
        best = {}
        for line in lines:
            if not line.startswith("info ") or " pv " not in line:
                continue
            rank = re.search(r"multipv (\d+)", line)
            pv = line.split(" pv ", 1)[1].split()
            if rank and pv:
                best[int(rank.group(1))] = pv[0]
        return [best[k] for k in sorted(best)]

    def quit(self):
        self.send("quit")
        self.proc.wait(timeout=5)


def _best_move(lines):
    for line in reversed(lines):
        if line.startswith("bestmove"):
            move = line.split()[1]
            return None if move == "(none)" else move
    return None


def _score(lines):
    """Score of the principal variation, side-to-move relative."""
    for line in reversed(lines):
        if not line.startswith("info ") or "score" not in line:
            continue
        if re.search(r"multipv (\d+)", line) and \
                re.search(r"multipv (\d+)", line).group(1) != "1":
            continue
        cp = re.search(r"score cp (-?\d+)", line)
        if cp:
            return int(cp.group(1))
        mate = re.search(r"score mate (-?\d+)", line)
        if mate:
            n = int(mate.group(1))
            return MATE - abs(n) if n > 0 else -(MATE - abs(n))
    return None


START = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1"


def make_positions(engine, count, seed=7):
    """Walks away from the start position along varied but sane lines.

    Sampling from MultiPV rather than playing random legal moves keeps the
    positions realistic; measuring a bot on nonsense positions would say
    nothing about how it plays a game.

    The walk is deterministic — fixed seed, fixed search depth — so two runs
    measure the same positions and their numbers can be compared. Note that a
    run at N positions is a prefix of a run at more, so those are comparable
    too.
    """
    rng = random.Random(seed)
    positions, moves = [], []
    engine.new_game()
    while len(positions) < count:
        fen = engine.fen_after(START, " ".join(moves)) if moves else START
        if len(moves) >= 6:
            positions.append(fen)
        candidates = engine.multipv_moves(fen, 6, 4)
        if not candidates:
            moves = []
            continue
        moves.append(rng.choice(candidates))
        if len(moves) > 40:
            moves = []
            engine.new_game()
    return positions


def reference_loss(ref, fen, move, movetime, best_score, cache):
    key = (fen, move)
    if key in cache:
        return cache[key]
    _, reply = ref.search(fen, movetime, moves=move)
    value = -reply if reply is not None else None
    loss = None if value is None or best_score is None else max(0, best_score - value)
    cache[key] = loss
    return loss


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("engine")
    ap.add_argument("--positions", type=int, default=24)
    ap.add_argument("--movetime", type=int, default=250)
    ap.add_argument("--reference-movetime", type=int, default=800)
    ap.add_argument("--knob", choices=["elo", "skill"], default="elo")
    args = ap.parse_args()

    settings = ([1350, 1600, 1900, 2200, 2500, 2850, None]
                if args.knob == "elo" else [0, 3, 5, 8, 10, 14, 20])

    gen = Engine(args.engine)
    positions = make_positions(gen, args.positions)
    gen.quit()
    print(f"positions: {len(positions)}", file=sys.stderr)

    ref = Engine(args.engine)
    ref.set_elo(None)
    best = {}
    for fen in positions:
        ref.new_game()
        best[fen] = ref.search(fen, args.reference_movetime)

    subject = Engine(args.engine)
    cache = {}
    rows = []
    for elo in settings:
        if args.knob == "elo":
            subject.set_elo(elo)
        else:
            subject.set_skill(elo)
        losses, agree = [], 0
        for fen in positions:
            subject.new_game()
            move, _ = subject.search(fen, args.movetime)
            ref_move, ref_score = best[fen]
            if move is None:
                continue
            if move == ref_move:
                agree += 1
                losses.append(0)
                continue
            loss = reference_loss(ref, fen, move, args.reference_movetime,
                                  ref_score, cache)
            if loss is not None:
                losses.append(min(loss, 2000))
        losses.sort()
        n = len(losses) or 1
        rows.append({
            "elo": elo,
            "mean": sum(losses) / n,
            "median": losses[n // 2] if losses else 0,
            "blunders": 100.0 * sum(1 for x in losses if x > 200) / n,
            "agree": 100.0 * agree / n,
        })

    subject.quit()
    ref.quit()

    print(f"{args.knob:>6} {'mean cp loss':>13} {'median':>7} "
          f"{'blunder>200':>12} {'top-move agree':>15}")
    for r in rows:
        label = r["elo"] if r["elo"] is not None else "full"
        print(f"{label:>6} {r['mean']:>13.1f} {r['median']:>7.0f} "
              f"{r['blunders']:>11.0f}% {r['agree']:>14.0f}%")


if __name__ == "__main__":
    main()
