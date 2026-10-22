"""M10 measurement successor. No provider calls and no identity features."""
from __future__ import annotations

import hashlib
import json
import math
import re
import shlex
from pathlib import Path


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def task_contract(task):
    editable = task.get("editable_roots", task.get("editable_files"))
    check = task.get("check_command", task.get("test_command"))
    if not isinstance(editable, list) or not editable or not isinstance(check, list) or not check:
        raise ValueError("Task lacks an explicit editable-path or test-command contract")
    return editable, check


def relative(path, root):
    clean = str(path).replace("\\", "/")
    prefix = str(root).rstrip("/") + "/"
    if clean.startswith(prefix):
        clean = clean[len(prefix):]
    return clean.removeprefix("./")


def matches(path, allowed):
    return any(path == a.rstrip("/") or (a.endswith("/") and path.startswith(a)) for a in allowed)


def command_segments(command):
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars=";&|\n")
        lex.whitespace = " \t\r"
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        return []
    segments, current = [], []
    for token in tokens:
        if token and all(c in ";&|\n" for c in token):
            if current:
                segments.append(current)
            current = []
        else:
            current.append(token)
    if current:
        segments.append(current)
    return segments


def is_documented_test(command, check):
    for words in command_segments(command):
        words = list(words)
        while words and (words[0] == "env" or re.fullmatch(r"[A-Za-z_]\w*=.*", words[0])):
            words.pop(0)
        if not words:
            continue
        words[0] = Path(words[0]).name
        expected = [Path(check[0]).name, *check[1:]]
        if words[:len(expected)] == expected:
            return True
    return False


def is_other_test(command):
    for words in command_segments(command):
        if not words:
            continue
        name = Path(words[0]).name
        if name in {"pytest", "pytest-3"}:
            return True
        if name in {"go", "cargo", "npm", "pnpm", "yarn"} and len(words) > 1 and words[1] == "test":
            return True
        if name.startswith("python") and "unittest" in words:
            return True
        if name == "node" and "--test" in words:
            return True
    return False


def event_rows(parts, root, editable, check):
    events = []
    for part in parts:
        if part.get("type") != "tool":
            continue
        state = part.get("state") or {}
        args = state.get("input") or {}
        tool = part.get("tool", "")
        command = args.get("command", args.get("cmd", ""))
        paths = [relative(args[k], root) for k in ("filePath", "path", "file_path", "target") if isinstance(args.get(k), str)]
        patch = args.get("patchText", args.get("patch", ""))
        if isinstance(patch, str):
            paths.extend(relative(p, root) for p in re.findall(r"^\*\*\* (?:Update|Add|Delete) File: (.+)$", patch, re.M))
        documented = is_documented_test(command, check)
        test = documented or is_other_test(command)
        edit = tool in {"edit", "write", "apply_patch", "multiedit", "patch"}
        # Shell edits are conservative observations, not inferred from output text.
        shell_edit = tool == "bash" and bool(re.search(r"(?:\.write_text\(|\.write_bytes\(|\bsed\s+-i\b|\bcat\s+[^\n]*>[^&]|\btee\s+)", command))
        edit = edit or shell_edit
        metadata = state.get("metadata") or {}
        code = metadata.get("exit", metadata.get("exitCode", state.get("exit_code")))
        complete = state.get("status") in {"completed", "error"}
        failed = (isinstance(code, int) and code != 0) or state.get("status") == "error"
        # Unknown execution result does not turn into a passing test.
        passed = complete and state.get("status") == "completed" and code == 0
        events.append({"ordinal": len(events), "tool": tool, "read": tool in {"read", "glob", "grep", "list"},
                       "edit": edit, "paths": sorted(set(paths)), "test": test,
                       "documented": documented, "complete": complete, "failed": failed,
                       "passed": passed, "signature": digest([tool, args]),
                       "command_hash": hashlib.sha256(command.encode()).hexdigest()})
    return events


def extract(db, task, before_rows, after_rows, hidden_score):
    editable, check = task_contract(task)
    root = db["session"]["directory"]
    events = event_rows(db["parts"], root, editable, check)
    edits = [i for i, e in enumerate(events) if e["edit"]]
    first, last = (edits[0], edits[-1]) if edits else (len(events), -1)
    relevant = set(p for e in events[:first] if e["read"] for p in e["paths"] if matches(p, editable) or p in {"TASK.md", "task.json", "README.md"})
    baseline = any(e["test"] and e["complete"] for e in events[:first])
    verified = any(e["documented"] and e["passed"] for e in events[last + 1:])
    attempts = [e for e in events if e["test"]]
    failed = [e for e in attempts if e["failed"]]
    recovered = sum(any(e["test"] and e["passed"] for e in events[f["ordinal"] + 1:]) for f in failed)
    edit_episodes = sum(e["edit"] and (i == 0 or not events[i - 1]["edit"]) for i, e in enumerate(events))
    before = {r["path"]: r for r in before_rows if r.get("kind", "file") == "file"}
    after = {r["path"]: r for r in after_rows if r.get("kind", "file") == "file"}
    changed = [p for p in sorted(before.keys() | after.keys()) if before.get(p, {}).get("sha256") != after.get(p, {}).get("sha256")]
    unrelated = [p for p in changed if not matches(p, editable)]
    hygiene = not unrelated
    seen, redundant = set(), 0
    for e in events:
        if e["edit"]:
            seen.clear()
        if e["signature"] in seen:
            redundant += 1
        seen.add(e["signature"])
    # No semantic judgement is fabricated by these measurements.
    raw = {"tool_calls":len(events), "edit_episodes":edit_episodes, "relevant_reads":len(relevant),
           "baseline":baseline, "documented_pass_after_edit":verified, "test_attempts":len(attempts),
           "failed_tests":len(failed), "recovered_tests":recovered, "unrelated_changes":len(unrelated),
           "hygiene_clean":hygiene, "redundant_calls":redundant}
    return {"measurements": raw, "groups": {
        "E": hidden_score / 100,
        "W": (min(len(relevant) / 3, 1) + baseline + verified + hygiene) / 4,
        "R": recovered / len(failed) if failed else None,
        "F": -math.log1p(len(events) + 2 * edit_episodes + redundant) if hidden_score >= 95 else None,
    }, "events":events, "changed_paths": changed, "unrelated_paths": unrelated}
