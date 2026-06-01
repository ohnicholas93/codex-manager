rotate_session_ids() {
  local apply="${1:-0}"

  have python3 || die "python3 is required to rotate session ids"

  python3 - "$(codex_home)" "$apply" <<'PY'
import json
import os
import secrets
import sqlite3
import sys
import time
import uuid
from pathlib import Path

codex_home_raw, apply_raw = sys.argv[1:3]
home = Path(codex_home_raw)
apply_changes = apply_raw == "1"
roots = [home / "sessions", home / "archived_sessions"]

def uuid7_string():
    if hasattr(uuid, "uuid7"):
        return str(uuid.uuid7())

    unix_ms = int(time.time() * 1000)
    random_bits = secrets.randbits(74)
    value = (unix_ms & ((1 << 48) - 1)) << 80
    value |= 0x7 << 76
    value |= ((random_bits >> 62) & 0x0FFF) << 64
    value |= 0b10 << 62
    value |= random_bits & ((1 << 62) - 1)
    return str(uuid.UUID(int=value))

def resolve_path(path):
    try:
        return path.resolve(strict=False)
    except OSError:
        return path.absolute()

root_resolved = [resolve_path(root) for root in roots]

def is_under_roots(path):
    resolved = resolve_path(path)
    for root in root_resolved:
        if resolved == root or root in resolved.parents:
            return True
    return False

def path_string_updates(path_map):
    updates = {}
    for old_path, new_path in path_map.items():
        updates[str(old_path)] = str(new_path)
        try:
            old_relative = old_path.relative_to(home)
            new_relative = new_path.relative_to(home)
        except ValueError:
            continue
        updates[str(old_relative)] = str(new_relative)
    return updates

def process_looks_like_codex(proc):
    try:
        comm = (proc / "comm").read_text(errors="ignore").strip().lower()
    except OSError:
        comm = ""
    if comm == "codex":
        return True

    try:
        exe = os.readlink(proc / "exe")
    except OSError:
        exe = ""
    if Path(exe).name.lower() == "codex":
        return True

    try:
        cmdline = (proc / "cmdline").read_bytes()
    except OSError:
        return False
    argv = [arg for arg in cmdline.split(b"\0") if arg]
    if not argv:
        return False
    argv0 = argv[0].decode("utf-8", errors="ignore")
    return Path(argv0).name.lower() == "codex"

def open_codex_rollout_state():
    open_inodes = set()
    deleted_rollouts = []
    proc_root = Path("/proc")
    if not proc_root.is_dir():
        return open_inodes, deleted_rollouts

    for proc in proc_root.iterdir():
        if not proc.name.isdigit() or not process_looks_like_codex(proc):
            continue
        fd_dir = proc / "fd"
        try:
            fds = list(fd_dir.iterdir())
        except OSError:
            continue
        for fd in fds:
            try:
                target = os.readlink(fd)
            except OSError:
                target = ""

            if target.endswith(".jsonl (deleted)"):
                deleted_path = Path(target[:-10])
                if is_under_roots(deleted_path):
                    deleted_rollouts.append((proc.name, target))

            if ".jsonl" not in target:
                continue

            rollout_target = target[:-10] if target.endswith(" (deleted)") else target
            if not is_under_roots(Path(rollout_target)):
                continue

            try:
                fd_stat = fd.stat()
            except OSError:
                continue
            open_inodes.add((fd_stat.st_dev, fd_stat.st_ino))

    return open_inodes, deleted_rollouts

def session_id_from_rollout(path):
    try:
        with path.open("r", encoding="utf-8") as file:
            for line in file:
                raw = line.rstrip("\n")
                if not raw.strip():
                    continue
                try:
                    item = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if item.get("type") != "session_meta":
                    continue
                payload = item.get("payload")
                if not isinstance(payload, dict):
                    return None
                thread_id = payload.get("id")
                if not isinstance(thread_id, str):
                    return None
                try:
                    uuid.UUID(thread_id)
                except ValueError:
                    return None
                return thread_id
    except (OSError, UnicodeDecodeError):
        return None
    return None

def parse_rollout_filename(path):
    name = path.name
    if not name.startswith("rollout-") or not name.endswith(".jsonl"):
        return None
    core = name.removeprefix("rollout-").removesuffix(".jsonl")
    for index, char in reversed(list(enumerate(core))):
        if char != "-":
            continue
        candidate = core[index + 1:]
        try:
            parsed = str(uuid.UUID(candidate))
        except ValueError:
            continue
        return f"rollout-{core[:index + 1]}", parsed
    return None

def fallback_rollout_prefix(path):
    stem = path.stem
    if stem.startswith("rollout-"):
        stem = stem.removeprefix("rollout-")
    return f"rollout-{stem}-"

def matching_replacement_rollout(old_path, old_id):
    parsed = parse_rollout_filename(old_path)
    if parsed is None:
        prefix = fallback_rollout_prefix(old_path)
    else:
        prefix, filename_id = parsed
        if filename_id != old_id:
            prefix = fallback_rollout_prefix(old_path)

    candidates = []
    try:
        possible_paths = old_path.parent.glob(prefix + "*.jsonl")
    except OSError:
        return None

    for candidate in possible_paths:
        if candidate == old_path or not candidate.is_file():
            continue
        candidate_id = session_id_from_rollout(candidate)
        if candidate_id is None or candidate_id == old_id:
            continue
        candidate_parsed = parse_rollout_filename(candidate)
        if candidate_parsed is None or candidate_parsed[1] != candidate_id:
            continue
        candidates.append((candidate, candidate_id))

    if len(candidates) != 1:
        return None
    return candidates[0]

def collect_stale_db_repairs():
    id_map = {}
    path_map = {}
    warnings = []

    for db_path in sorted(home.glob("state_*.sqlite")):
        conn = None
        try:
            conn = sqlite3.connect(str(db_path), timeout=5)
            conn.execute("PRAGMA busy_timeout = 5000")
            has_threads = conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'threads'"
            ).fetchone()
            if not has_threads:
                continue
            for thread_id, rollout_path in conn.execute("SELECT id, rollout_path FROM threads"):
                if not thread_id or not rollout_path:
                    continue
                try:
                    old_id = str(uuid.UUID(str(thread_id)))
                except ValueError:
                    continue
                old_path = Path(rollout_path)
                if not old_path.is_absolute():
                    old_path = home / old_path
                if not is_under_roots(old_path) or old_path.exists():
                    continue
                replacement = matching_replacement_rollout(old_path, old_id)
                if replacement is None:
                    warnings.append((old_path, "missing DB rollout path has no unique rotated replacement"))
                    continue
                new_path, new_id = replacement
                existing_new_id = id_map.get(old_id)
                if existing_new_id is not None and existing_new_id != new_id:
                    warnings.append((old_path, f"conflicting replacement ids {existing_new_id} and {new_id}"))
                    continue
                id_map[old_id] = new_id
                path_map[old_path] = new_path
        except sqlite3.Error as error:
            warnings.append((db_path, f"could not inspect Desktop thread index for stale paths: {error}"))
        finally:
            if conn is not None:
                conn.close()

    return id_map, path_map, warnings

def collect_rollout_paths_from_fs():
    paths = set()
    for root in roots:
        if root.is_dir():
            paths.update(path for path in root.rglob("rollout-*.jsonl") if path.is_file())
    return paths

def collect_rollout_paths_from_dbs():
    paths = set()
    for db_path in sorted(home.glob("state_*.sqlite")):
        conn = None
        try:
            conn = sqlite3.connect(str(db_path), timeout=5)
            conn.execute("PRAGMA busy_timeout = 5000")
            has_threads = conn.execute(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'threads'"
            ).fetchone()
            if not has_threads:
                continue
            for (rollout_path,) in conn.execute("SELECT rollout_path FROM threads"):
                if not rollout_path:
                    continue
                path = Path(rollout_path)
                if not path.is_absolute():
                    path = home / path
                if is_under_roots(path) and path.is_file():
                    paths.add(path)
        except sqlite3.Error as error:
            print(f"warning: could not inspect Desktop thread index {db_path}: {error}", file=sys.stderr)
        finally:
            if conn is not None:
                conn.close()
    return paths

def replace_id_strings(value, id_map):
    if isinstance(value, str):
        return id_map.get(value, value)
    if isinstance(value, list):
        return [replace_id_strings(item, id_map) for item in value]
    if isinstance(value, dict):
        return {key: replace_id_strings(item, id_map) for key, item in value.items()}
    return value

def replace_source_ids(source, id_map):
    if source is None:
        return None, False
    if not isinstance(source, str):
        source = str(source)
    if source in id_map:
        return id_map[source], True
    try:
        parsed = json.loads(source)
    except json.JSONDecodeError:
        return source, False
    replaced = replace_id_strings(parsed, id_map)
    if replaced == parsed:
        return source, False
    return json.dumps(replaced, separators=(",", ":")), True

def rotated_rollout_path(path, old_id, new_id):
    if old_id not in path.name:
        return path.with_name(f"{fallback_rollout_prefix(path)}{new_id}.jsonl")
    return path.with_name(path.name.replace(old_id, new_id, 1))

def rewritten_rollout_lines(path, id_map):
    try:
        original_stat = path.stat()
        original_lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    except (OSError, UnicodeDecodeError) as error:
        return None, None, f"read failed: {error}"

    new_lines = []
    changed = False
    for line in original_lines:
        newline = "\n" if line.endswith("\n") else ""
        raw = line[:-1] if newline else line
        try:
            item = json.loads(raw)
        except json.JSONDecodeError:
            new_lines.append(line)
            continue

        replaced = replace_id_strings(item, id_map)
        if replaced != item:
            changed = True
            new_lines.append(json.dumps(replaced, separators=(",", ":")) + newline)
        else:
            new_lines.append(line)

    if not changed:
        return None, None, "no matching ids"

    return original_stat, new_lines, None

def rewrite_rollout(path, id_map):
    original_stat, new_lines, reason = rewritten_rollout_lines(path, id_map)
    if reason is not None:
        return False, reason

    tmp = path.with_name(path.name + ".tmp.codex-manager")
    try:
        tmp.write_text("".join(new_lines), encoding="utf-8")
        os.chmod(tmp, original_stat.st_mode)

        try:
            latest_stat = path.stat()
        except OSError as error:
            tmp.unlink(missing_ok=True)
            return False, f"disappeared before rewrite: {error}"

        if (latest_stat.st_dev, latest_stat.st_ino) != (original_stat.st_dev, original_stat.st_ino):
            tmp.unlink(missing_ok=True)
            return False, "changed during rewrite"

        latest_open_inodes, _ = open_codex_rollout_state()
        if (latest_stat.st_dev, latest_stat.st_ino) in latest_open_inodes:
            tmp.unlink(missing_ok=True)
            return False, "became active during rewrite"

        os.replace(tmp, path)
        os.utime(path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        return True, None
    except OSError as error:
        tmp.unlink(missing_ok=True)
        return False, f"write failed: {error}"

def write_rotated_rollout(path, new_path, id_map):
    if new_path.exists():
        return False, f"target already exists: {new_path}"

    original_stat, new_lines, reason = rewritten_rollout_lines(path, id_map)
    if reason is not None:
        return False, reason

    tmp = new_path.with_name(new_path.name + ".tmp.codex-manager")
    try:
        tmp.write_text("".join(new_lines), encoding="utf-8")
        os.chmod(tmp, original_stat.st_mode)

        latest_stat = path.stat()
        if (latest_stat.st_dev, latest_stat.st_ino) != (original_stat.st_dev, original_stat.st_ino):
            tmp.unlink(missing_ok=True)
            return False, "changed during rewrite"

        latest_open_inodes, _ = open_codex_rollout_state()
        if (latest_stat.st_dev, latest_stat.st_ino) in latest_open_inodes:
            tmp.unlink(missing_ok=True)
            return False, "became active during rewrite"

        os.replace(tmp, new_path)
        os.utime(new_path, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        path.unlink()
        return True, None
    except OSError as error:
        tmp.unlink(missing_ok=True)
        new_path.unlink(missing_ok=True)
        return False, f"write failed: {error}"

def rotate_rollout(path, old_id, new_id, id_map):
    new_path = rotated_rollout_path(path, old_id, new_id)
    ok, reason = write_rotated_rollout(path, new_path, id_map)
    if not ok:
        return False, None, "skipped", reason
    return True, new_path, None, None

def table_exists(conn, name):
    return conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (name,),
    ).fetchone() is not None

def table_has_column(conn, table, column):
    return any(row[1] == column for row in conn.execute(f"PRAGMA table_info({table})"))

def update_state_db(db_path, id_map, path_map):
    changed = 0
    conn = None
    try:
        conn = sqlite3.connect(str(db_path), timeout=5)
        conn.execute("PRAGMA busy_timeout = 5000")
        conn.execute("PRAGMA foreign_keys = OFF")
        conn.execute("BEGIN")

        if table_exists(conn, "threads"):
            for old_id, new_id in id_map.items():
                changed += conn.execute(
                    "UPDATE threads SET id = ? WHERE id = ?",
                    (new_id, old_id),
                ).rowcount
            for old_path, new_path in path_map.items():
                changed += conn.execute(
                    "UPDATE threads SET rollout_path = ? WHERE rollout_path = ?",
                    (new_path, old_path),
                ).rowcount
            if table_has_column(conn, "threads", "source"):
                sources = list(conn.execute("SELECT rowid, source FROM threads"))
                for rowid, source in sources:
                    new_source, source_changed = replace_source_ids(source, id_map)
                    if not source_changed:
                        continue
                    changed += conn.execute(
                        "UPDATE threads SET source = ? WHERE rowid = ?",
                        (new_source, rowid),
                    ).rowcount

        table_updates = [
            ("thread_dynamic_tools", "thread_id"),
            ("stage1_outputs", "thread_id"),
            ("thread_spawn_edges", "parent_thread_id"),
            ("thread_spawn_edges", "child_thread_id"),
            ("agent_job_items", "assigned_thread_id"),
        ]
        for table, column in table_updates:
            if not table_exists(conn, table):
                continue
            for old_id, new_id in id_map.items():
                changed += conn.execute(
                    f"UPDATE {table} SET {column} = ? WHERE {column} = ?",
                    (new_id, old_id),
                ).rowcount

        conn.commit()
        return changed
    except sqlite3.Error as error:
        if conn is not None:
            try:
                conn.rollback()
            except sqlite3.Error:
                pass
        raise RuntimeError(f"could not update Desktop thread index {db_path}: {error}") from error
    finally:
        if conn is not None:
            conn.close()

def update_state_dbs(id_map, path_map=None):
    changed = 0
    updated_dbs = []
    db_paths = sorted(home.glob("state_*.sqlite"))
    path_map = path_map or {}

    try:
        for db_path in db_paths:
            changed += update_state_db(db_path, id_map, path_map)
            updated_dbs.append(db_path)
    except RuntimeError as error:
        inverse_map = {new_id: old_id for old_id, new_id in id_map.items()}
        inverse_path_map = {new_path: old_path for old_path, new_path in path_map.items()}
        revert_errors = []
        for db_path in reversed(updated_dbs):
            try:
                update_state_db(db_path, inverse_map, inverse_path_map)
            except RuntimeError as revert_error:
                revert_errors.append(str(revert_error))
        if revert_errors:
            detail = "; ".join(revert_errors)
            raise RuntimeError(f"{error}; additionally could not restore prior database updates: {detail}") from error
        raise

    return changed

def update_session_index(id_map):
    path = home / "session_index.jsonl"
    if not path.is_file():
        return 0

    latest_names = {}
    original_stat = None
    original_content = ""
    try:
        original_stat = path.stat()
        original_content = path.read_text(encoding="utf-8")
        for line in original_content.splitlines():
            raw = line.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except json.JSONDecodeError:
                continue
            entry_id = entry.get("id")
            name = entry.get("thread_name")
            if entry_id in id_map and isinstance(name, str) and name.strip():
                latest_names[entry_id] = name
    except (OSError, UnicodeDecodeError) as error:
        raise RuntimeError(f"could not read session index {path}: {error}") from error

    if not latest_names:
        return 0

    updated_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    additions = []
    for old_id, name in sorted(latest_names.items()):
        additions.append(json.dumps({
            "id": id_map[old_id],
            "thread_name": name,
            "updated_at": updated_at,
        }, separators=(",", ":")) + "\n")

    content = original_content
    if content and not content.endswith("\n"):
        content += "\n"
    content += "".join(additions)

    tmp = path.with_name(path.name + ".tmp.codex-manager")
    try:
        tmp.write_text(content, encoding="utf-8")
        if original_stat is not None:
            os.chmod(tmp, original_stat.st_mode)
        os.replace(tmp, path)
        return len(latest_names)
    except OSError as error:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"could not update session index {path}: {error}") from error

def rollback_rewrites(rotated_ids, rotated_paths, rollback_dbs, rollout_id_map=None):
    inverse_rollout_map = {
        new_id: old_id for old_id, new_id in (rollout_id_map or rotated_ids).items()
    }
    inverse_map = {new_id: old_id for old_id, new_id in rotated_ids.items()}
    inverse_path_map = path_string_updates({new_path: old_path for old_path, new_path in rotated_paths.items()})
    rollback_errors = []

    for old_path, new_path in rotated_paths.items():
        ok, reason = write_rotated_rollout(new_path, old_path, inverse_rollout_map)
        if not ok:
            rollback_errors.append(f"could not roll back rollout {new_path}: {reason}")

    if rollback_errors:
        return rollback_errors

    if not rollback_dbs:
        return rollback_errors

    try:
        update_state_dbs(inverse_map, inverse_path_map)
    except RuntimeError as error:
        rollback_errors.append(str(error))
        for old_path, new_path in rotated_paths.items():
            ok, reason = write_rotated_rollout(old_path, new_path, rotated_ids)
            if not ok:
                rollback_errors.append(f"could not restore rollout {new_path} to rotated id: {reason}")

    return rollback_errors

stale_repair_ids, stale_repair_paths, stale_repair_warnings = collect_stale_db_repairs()
paths = collect_rollout_paths_from_fs() | collect_rollout_paths_from_dbs()
open_inodes, deleted_rollout_fds = open_codex_rollout_state()

path_infos = []
ids_to_paths = {}
target_paths = {}
skipped_active = []
skipped_invalid = []

for path in sorted(paths, key=lambda p: str(p)):
    try:
        stat = path.stat()
    except OSError:
        skipped_invalid.append((path, "missing"))
        continue

    if (stat.st_dev, stat.st_ino) in open_inodes:
        skipped_active.append(path)
        continue

    old_id = session_id_from_rollout(path)
    if old_id is None:
        skipped_invalid.append((path, "missing or invalid session metadata"))
        continue

    path_infos.append((path, old_id))
    ids_to_paths.setdefault(old_id, []).append(path)

duplicate_ids = {old_id for old_id, id_paths in ids_to_paths.items() if len(id_paths) > 1}
if duplicate_ids:
    kept = []
    for path, old_id in path_infos:
        if old_id in duplicate_ids:
            skipped_invalid.append((path, f"duplicate session id {old_id}"))
        else:
            kept.append((path, old_id))
    path_infos = kept

new_ids = set(ids_to_paths.keys())
id_map = {}
for _, old_id in path_infos:
    while True:
        new_id = uuid7_string()
        if new_id not in new_ids:
            new_ids.add(new_id)
            id_map[old_id] = new_id
            break

for path, old_id in path_infos:
    new_path = rotated_rollout_path(path, old_id, id_map[old_id])
    if new_path in target_paths:
        skipped_invalid.append((path, f"duplicate target rollout path {new_path}"))
    elif new_path.exists() and new_path != path:
        skipped_invalid.append((path, f"target rollout path already exists {new_path}"))
    else:
        target_paths[new_path] = path

if len(target_paths) != len(path_infos):
    kept = []
    valid_paths = set(target_paths.values())
    for path, old_id in path_infos:
        if path in valid_paths:
            kept.append((path, old_id))
    path_infos = kept
    id_map = {old_id: id_map[old_id] for _, old_id in path_infos}

print("mode: " + ("apply" if apply_changes else "dry-run"))
print(f"stale sqlite repairs: {len(stale_repair_ids)}")
print(f"eligible sessions: {len(path_infos)}")
print(f"skipped active: {len(skipped_active)}")
print(f"skipped invalid: {len(skipped_invalid)}")

for path, old_id in path_infos:
    new_path = rotated_rollout_path(path, old_id, id_map[old_id])
    print(f"{old_id} -> {id_map[old_id]}  {path} -> {new_path}")

for path in skipped_active:
    print(f"warning: skipped active Codex session rollout: {path}", file=sys.stderr)
for path, reason in skipped_invalid:
    print(f"warning: skipped invalid session rollout ({reason}): {path}", file=sys.stderr)
for path, reason in stale_repair_warnings:
    print(f"warning: skipped stale sqlite repair ({reason}): {path}", file=sys.stderr)
for old_path, new_path in sorted(stale_repair_paths.items(), key=lambda item: str(item[0])):
    new_id = session_id_from_rollout(new_path)
    old_id = next((candidate for candidate, repaired in stale_repair_ids.items() if repaired == new_id), "unknown")
    print(f"repair stale sqlite: {old_id} -> {new_id}  {old_path} -> {new_path}")
if deleted_rollout_fds:
    print(
        "warning: detected active Codex rollout file descriptor(s) for deleted JSONL files; "
        "a previous live rewrite may already have detached persisted history.",
        file=sys.stderr,
    )
    for pid, target in deleted_rollout_fds:
        print(f"warning: pid {pid} has deleted rollout fd: {target}", file=sys.stderr)

if not apply_changes:
    print("rotated sessions: 0")
    print("updated sqlite rows: 0")
    print("updated session index names: 0")
    sys.exit(0)

repair_sqlite_rows = 0
repair_index_rows = 0
if stale_repair_ids:
    stale_repair_path_strings = path_string_updates(stale_repair_paths)
    try:
        repair_sqlite_rows = update_state_dbs(stale_repair_ids, stale_repair_path_strings)
    except RuntimeError as error:
        print(f"error: could not repair stale SQLite rollout references: {error}", file=sys.stderr)
        sys.exit(1)

    try:
        repair_index_rows = update_session_index(stale_repair_ids)
    except RuntimeError as error:
        print(f"error: could not repair stale session index references: {error}", file=sys.stderr)
        inverse_repair_ids = {new_id: old_id for old_id, new_id in stale_repair_ids.items()}
        inverse_repair_paths = {new_path: old_path for old_path, new_path in stale_repair_path_strings.items()}
        try:
            update_state_dbs(inverse_repair_ids, inverse_repair_paths)
        except RuntimeError as rollback_error:
            print(f"error: rollback failed: {rollback_error}", file=sys.stderr)
            sys.exit(2)
        sys.exit(1)

rotated = 0
rotated_ids = {}
rotated_paths = {}
for path, old_id in path_infos:
    ok, new_path, failure_kind, reason = rotate_rollout(path, old_id, id_map[old_id], id_map)
    if ok:
        rotated += 1
        rotated_ids[old_id] = id_map[old_id]
        rotated_paths[path] = new_path
    else:
        print(f"error: could not rotate session rollout ({reason}): {path}", file=sys.stderr)
        rollback_errors = rollback_rewrites(rotated_ids, rotated_paths, False, id_map)
        for rollback_error in rollback_errors:
            print(f"error: rollback failed: {rollback_error}", file=sys.stderr)
        sys.exit(2 if rollback_errors or failure_kind == "dirty" else 1)

try:
    rotated_path_strings = path_string_updates(rotated_paths)
    sqlite_rows = update_state_dbs(rotated_ids, rotated_path_strings) if rotated_ids else 0
except RuntimeError as error:
    print(f"error: {error}", file=sys.stderr)
    print("error: rolling back rewritten rollout files", file=sys.stderr)
    rollback_errors = rollback_rewrites(rotated_ids, rotated_paths, False, rotated_ids)
    for rollback_error in rollback_errors:
        print(f"error: rollback failed: {rollback_error}", file=sys.stderr)
    if rollback_errors:
        sys.exit(2)
    sys.exit(1)

try:
    index_rows = update_session_index(rotated_ids) if rotated_ids else 0
except RuntimeError as error:
    print(f"error: {error}", file=sys.stderr)
    print("error: rolling back rewritten rollout files and SQLite references", file=sys.stderr)
    rollback_errors = rollback_rewrites(rotated_ids, rotated_paths, True, rotated_ids)
    for rollback_error in rollback_errors:
        print(f"error: rollback failed: {rollback_error}", file=sys.stderr)
    if rollback_errors:
        sys.exit(2)
    sys.exit(1)

print(f"rotated sessions: {rotated}")
print(f"updated sqlite rows: {repair_sqlite_rows + sqlite_rows}")
print(f"updated session index names: {repair_index_rows + index_rows}")
PY
}
