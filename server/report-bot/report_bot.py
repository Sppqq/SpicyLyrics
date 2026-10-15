#!/usr/bin/env python3
"""Private report queue. Only this controller has report/GitHub write credentials."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

HERE = Path(__file__).resolve().parent
ROOTS = ("SpicyLyrics/", "cloudflare/src/", "cloudflare/migrations/")
REPO = "Sppqq/sweet-lyrics-ios"
BASE = "https://sweet.sppq.dev"


class RequestError(RuntimeError):
    def __init__(self, host, status):
        self.status = status
        super().__init__(f"HTTP request to {host} failed ({status})")


def request(url, token, body=None):
    headers = {"Authorization": "Bearer " + token, "User-Agent": "sweet-report-controller"}
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode()
        headers["Content-Type"] = "application/json"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as error:
        # Log only the service host and status; never include response bodies or request data.
        host = urllib.parse.urlsplit(url).hostname or "unknown"
        raise RequestError(host, error.code) from None


def command(args, cwd=None, env=None, timeout=180):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        # Never send command output (which can contain reports or credentials) to journald.
        raise RuntimeError(f"{Path(args[0]).name} failed ({result.returncode})")
    return result.stdout.strip()


def database(state):
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    db = sqlite3.connect(state / "tasks.sqlite3")
    db.row_factory = sqlite3.Row
    db.execute("""CREATE TABLE IF NOT EXISTS tasks (
        report_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, kind TEXT NOT NULL,
        title TEXT NOT NULL, analysis TEXT NOT NULL, status TEXT NOT NULL,
        pr TEXT NOT NULL DEFAULT '', reply TEXT NOT NULL DEFAULT '',
        delivered INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL)""")
    db.commit()
    return db


def fingerprint(report):
    # Status changes and developer replies do not constitute new user input.
    content = {"report": report["report"], "thread": [m for m in report["thread"] if m["author"] == "user"]}
    content["report"] = {k: v for k, v in content["report"].items() if k not in ("status", "updated_at")}
    return hashlib.sha256(json.dumps(content, sort_keys=True).encode()).hexdigest()


def files(root):
    result = {}
    for p in root.rglob("*"):
        if p.is_symlink():
            raise ValueError("symlink in agent workspace")
        if p.is_file():
            if p.stat().st_size > 8 * 1024 * 1024:
                raise ValueError("oversized agent file")
            result[p.relative_to(root).as_posix()] = hashlib.sha256(p.read_bytes()).hexdigest()
    return result


def changed_files(before, after):
    changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
    for p in changed:
        if not p.startswith(ROOTS) or any(part.startswith(".") for part in Path(p).parts):
            raise ValueError("agent changed a forbidden path")
        if Path(p).suffix not in (".swift", ".metal", ".strings", ".js", ".sql"):
            raise ValueError("agent changed a forbidden file type")
    if len(changed) > 20:
        raise ValueError("repair exceeds file limit")
    return changed


def validate_result(result):
    schema = json.loads((HERE / "result.schema.json").read_text())
    if set(result) != set(schema["required"]):
        raise ValueError("invalid result fields")
    for field, spec in schema["properties"].items():
        expected = bool if spec["type"] == "boolean" else str
        if type(result[field]) is not expected or ("enum" in spec and result[field] not in spec["enum"]):
            raise ValueError("invalid result value")
    if not result["title"].strip() or len(result["title"]) > 160 or len(result["reply"]) > 6000:
        raise ValueError("invalid result length")
    if result["fix"] and (result["kind"] not in ("bug", "feature") or not result["validation"].strip()):
        raise ValueError("fix without validation")
    if result["kind"] == "feature" or result["fix"]:
        result["status"] = "in_progress"
    return result


def github(path, body=None):
    suffix = "/" + path if path else ""
    return request(f"https://api.github.com/repos/{REPO}" + suffix, os.environ["GH_TOKEN"], body)


def released_version(row, channel):
    match = re.fullmatch(r"https://github.com/Sppqq/sweet-lyrics-ios/pull/(\d+)", row["pr"])
    if not match:
        raise ValueError("invalid stored PR")
    pr = github("pulls/" + match[1])
    if not pr.get("merged_at"):
        return None
    for release in github("releases?per_page=30"):
        if release["draft"] or (channel in ("release", "stable") and release["prerelease"]):
            continue
        from urllib.parse import quote
        comparison = github("compare/" + quote(pr["merge_commit_sha"], safe="") + "..." + quote(release["tag_name"], safe=""))
        if comparison["status"] in ("ahead", "identical"):
            return release["tag_name"]
    return None


def publish(job, source, changed, result, report_id):
    branch = "bot/report-" + report_id[:8]
    existing = github("pulls?state=all&head=Sppqq:" + branch)
    if existing:
        pr = existing[0]
        if (pr["state"] != "open" or pr["base"]["ref"] != "main"
                or pr["head"]["ref"] != branch
                or pr["head"]["repo"]["full_name"] != REPO):
            raise ValueError("existing PR requires manual follow-up")
        return pr["html_url"]
    repo = job / "publish"
    commit_file = job / "publication-commit"
    if not commit_file.exists():
        # An interrupted preparation is safe to rebuild: nothing has been pushed yet.
        if repo.exists():
            shutil.rmtree(repo)
        command(["git", "clone", "--quiet", "--branch", "main", f"https://github.com/{REPO}.git", str(repo)])
        # Pin to the source commit so the proposed diff cannot silently incorporate a newer main.
        command(["git", "checkout", "-b", branch, (job / "commit").read_text().strip()], repo)
        for name in changed:
            target = repo / name
            if (source / name).exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source / name, target)
            else:
                target.unlink()
        command(["git", "diff", "--check"], repo)
        command(["git", "add", "--", *changed], repo)
        command(["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Sweet Lyrics Maintenance",
                 "-c", "user.email=noreply@sppq.dev", "commit", "-m", result["title"]], repo)
        pending_commit = job / "publication-commit.tmp"
        pending_commit.write_text(command(["git", "rev-parse", "HEAD"], repo))
        pending_commit.replace(commit_file)
    askpass = job / "askpass"
    askpass.write_text('#!/bin/sh\ncase "$1" in *Username*) echo x-access-token;; *) printf "%s\\n" "$GH_TOKEN";; esac\n')
    askpass.chmod(0o700)
    env = dict(os.environ, GIT_ASKPASS=str(askpass), GIT_TERMINAL_PROMPT="0")
    # Retry exactly the same commit after a push or PR request with an uncertain outcome.
    command(["git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", "push", "origin",
             commit_file.read_text().strip() + ":refs/heads/" + branch], repo, env)
    # The private analysis and sender's wording never become a public PR body.
    pr = github("pulls", {"title": result["title"], "head": branch, "base": "main", "draft": True,
        "body": "Prepared from a private support report. The proposed code change requires review.\n\n"
                "Validation: diff whitespace check passed. Native iOS build and device testing remain required."})
    if pr["head"]["ref"] != branch or pr["base"]["ref"] != "main":
        raise ValueError("unexpected PR destination")
    return pr["html_url"]


def analyze(state, report, previous):
    # The repair intent is saved before publishing. Recover it without rerunning the agent
    # when a push/PR succeeded but the process stopped before save_task committed.
    for pending in sorted(state.glob("job-*/repair.json")):
        repair = json.loads(pending.read_text())
        if repair["fingerprint"] == fingerprint(report):
            job = pending.parent
            source = job / "source"
            after = files(source)
            if after != repair["after"]:
                raise ValueError("pending repair content changed since validation")
            changed = changed_files(repair["before"], after)
            if changed != repair["changed"]:
                raise ValueError("pending repair changed since validation")
            result = validate_result(repair["result"])
            pr = publish(job, source, changed, result, report["report"]["id"])
            return result, pr
    job = Path(tempfile.mkdtemp(prefix="job-", dir=state))
    source, inputs, auth = job / "source", job / "input", job / "auth"
    inputs.mkdir()
    auth.mkdir()
    # Minimal private auth copy: no server configuration, MCPs, history, SSH or home directory.
    shutil.copyfile(state / "auth.json", auth / "auth.json")
    command(["git", "clone", "--quiet", f"https://github.com/{REPO}.git", str(source)])
    (job / "commit").write_text(command(["git", "rev-parse", "HEAD"], source))
    shutil.rmtree(source / ".git")
    (inputs / "report.json").write_text(json.dumps(report, ensure_ascii=False), encoding="utf-8")
    prs = github("pulls?state=open&per_page=100")
    context = {"previous_task": dict(previous) if previous else None,
               "open_prs": [{"url": p["html_url"], "title": p["title"], "branch": p["head"]["ref"]} for p in prs]}
    (inputs / "context.json").write_text(json.dumps(context, ensure_ascii=False), encoding="utf-8")
    shutil.copyfile(HERE / "result.schema.json", inputs / "schema.json")
    images = []
    unavailable_photos = 0
    for index, url in enumerate(report.get("photos", [])):
        if not url.startswith(BASE + "/v1/bot/report/" + report["report"]["id"] + "/photo/"):
            raise ValueError("unexpected photo URL")
        req = urllib.request.Request(url, headers={"Authorization": "Bearer " + os.environ["BOT_TOKEN"]})
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                ext = "png" if response.headers.get_content_type() == "image/png" else "jpg"
                data = response.read(2 * 1024 * 1024 + 1)
                if len(data) > 2 * 1024 * 1024:
                    raise ValueError("oversized photo")
        except urllib.error.HTTPError as error:
            if error.code not in (403, 404):
                raise RuntimeError(f"Photo request failed ({error.code})") from None
            unavailable_photos += 1
            continue
        name = f"photo-{index}.{ext}"
        (inputs / name).write_bytes(data)
        images += ["--image", "/input/" + name]
    context["unavailable_photos"] = unavailable_photos
    (inputs / "context.json").write_text(json.dumps(context, ensure_ascii=False), encoding="utf-8")
    before = files(source)
    container = "sweet-report-" + uuid.uuid4().hex[:12]
    output = job / "output"
    output.mkdir()
    output.chmod(0o770)
    args = ["docker", "run", "--rm", "--init", "--interactive", "--name", container, "--read-only",
            "--security-opt=no-new-privileges", "--security-opt=apparmor=unconfined",
            "--security-opt", f"seccomp={HERE / 'seccomp-codex.json'}", "--user", f"{os.getuid()}:{os.getgid()}",
            "--memory=2g", "--cpus=2", "--pids-limit=256", "--tmpfs", "/tmp:rw,nosuid,size=256m",
            "-v", f"{source}:/work:rw", "-v", f"{inputs}:/input:ro", "-v", f"{auth}:/auth:rw",
            "-v", f"{output}:/output:rw",
            os.environ.get("REPORT_BOT_IMAGE", "sweet-report-agent:local"),
            "exec", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--ephemeral",
            "--sandbox", "workspace-write", "--model", os.environ.get("REPORT_BOT_MODEL", "gpt-6-luna"),
            "-c", 'approval_policy="never"',
            "-c", 'sandbox_workspace_write.network_access=false',
            "-c", 'model_reasoning_effort="medium"', "--output-schema", "/input/schema.json",
            "--output-last-message", "/output/result.json", *images, "-"]
    # Externally sandboxed container: no host socket, credentials or other server files mounted.
    # Capture only the final JSON on stdout; stderr can contain raw logs and stays private.
    # Result JSON is written on a dedicated mount, never mixed with CLI diagnostics.
    try:
        run = subprocess.run(args, input=(HERE / "prompt.md").read_text(), text=True,
                             capture_output=True, timeout=1800)
        (job / "agent.stderr").write_text(run.stderr, encoding="utf-8")
        if run.returncode:
            raise RuntimeError("agent failed; details retained privately")
        result = validate_result(json.loads((output / "result.json").read_text()))
        (job / "result.json").write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
        changed = changed_files(before, files(source))
        if result["fix"] != bool(changed):
            raise ValueError("fix claim does not match code changes")
        if changed:
            repair = {"fingerprint": fingerprint(report), "before": before, "after": files(source), "changed": changed, "result": result}
            pending = job / "repair.tmp"
            pending.write_text(json.dumps(repair, ensure_ascii=False), encoding="utf-8")
            pending.replace(job / "repair.json")
        # Preserve a refreshed login even if publication needs a later retry.
        shutil.copyfile(auth / "auth.json", state / "auth.json")
        pr = publish(job, source, changed, result, report["report"]["id"]) if changed else ""
        return result, pr
    finally:
        subprocess.run(["docker", "rm", "-f", container], capture_output=True)
        shutil.rmtree(auth, ignore_errors=True)


def save_task(db, report, result, pr):
    reply = result["reply"].strip()
    if report["report"]["kind"] == "auto":
        reply = ""
    elif pr:
        reply += "\n\nИсправление подготовлено и ожидает проверки."
    elif result["kind"] == "feature":
        reply += "\n\nПожелание сохранено в списке задач разработчика."
    db.execute("""INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
        ON CONFLICT(report_id) DO UPDATE SET fingerprint=excluded.fingerprint, kind=excluded.kind,
        title=excluded.title, analysis=excluded.analysis, status=excluded.status,
        pr=CASE WHEN excluded.pr='' THEN tasks.pr ELSE excluded.pr END,
        reply=excluded.reply, delivered=0, updated_at=excluded.updated_at""",
        (report["report"]["id"], fingerprint(report), result["kind"], result["title"],
         result["analysis"] + "\nValidation: " + result["validation"], result["status"], pr, reply, int(time.time())))
    db.commit()  # Durable task BEFORE any acknowledgement to the sender.


def deliver(db, row):
    path = BASE + "/v1/bot/report/" + row["report_id"]
    try:
        current = request(path, os.environ["BOT_TOKEN"])
    except RequestError as error:
        if error.status != 404:
            raise
        # The sender/admin or retention job removed the report. Keep its private task,
        # but retire this outbox entry so it cannot prevent delivery of other replies.
        db.execute("UPDATE tasks SET delivered=1 WHERE report_id=?", (row["report_id"],))
        db.commit()
        return
    # A crash after the POST must not send the same response twice on restart.
    duplicate = any(m["author"] == "dev" and m["text"] == row["reply"] for m in current["thread"])
    if row["reply"] and not duplicate:
        request(path + "/reply", os.environ["BOT_TOKEN"], {"text": row["reply"], "status": row["status"]})
    else:
        request(path + "/status", os.environ["BOT_TOKEN"], {"status": row["status"]})
    db.execute("UPDATE tasks SET delivered=1 WHERE report_id=?", (row["report_id"],))
    db.commit()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["run", "tasks", "check"])
    parser.add_argument("--state", type=Path, default=Path.home() / ".local/state/sweet-report-bot")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    secrets = Path.home() / ".config/sweet-report-bot/secrets.json"
    if secrets.exists():
        for key, value in json.loads(secrets.read_text()).items():
            if key in ("BOT_TOKEN", "GH_TOKEN", "REPORT_BOT_MODEL", "REPORT_BOT_IMAGE"):
                os.environ[key] = value
    db = database(args.state)
    if args.action == "tasks":
        print(json.dumps([dict(r) for r in db.execute("SELECT * FROM tasks ORDER BY updated_at DESC")], ensure_ascii=False, indent=2))
        return
    if args.action == "check":
        inbox = request(BASE + "/v1/bot/inbox", os.environ["BOT_TOKEN"])
        github("")
        command(["docker", "image", "inspect", os.environ.get("REPORT_BOT_IMAGE", "sweet-report-agent:local")])
        print(f"Ready; {len(inbox['reports'])} report(s) waiting")
        return
    # Linux lock spans agent runs and outbox delivery; overlapping timers cannot double-process.
    import fcntl
    with (args.state / "run.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        if not args.dry_run:
            for row in db.execute("SELECT * FROM tasks WHERE delivered=0").fetchall():
                try:
                    deliver(db, row)
                except Exception:
                    print("Reply delivery failed; private state retained for retry.", file=sys.stderr)
        inbox = request(BASE + "/v1/bot/inbox", os.environ["BOT_TOKEN"])["reports"]
        for item in inbox[:8]:
            try:
                process_report(db, args, item)
            except Exception:
                print("Report processing failed; private state retained for retry.", file=sys.stderr)
        # Reports/logs are private and bounded; permanent task records are kept separately.
        for job in args.state.glob("job-*"):
            if job.is_dir() and job.stat().st_mtime < time.time() - 14 * 86400:
                # Uncommitted publication intents must survive until they can be recovered.
                pending = job / "repair.json"
                if pending.exists():
                    repair = json.loads(pending.read_text())
                    if not db.execute("SELECT 1 FROM tasks WHERE fingerprint=?", (repair["fingerprint"],)).fetchone():
                        continue
                shutil.rmtree(job)


def process_report(db, args, item):
    report_id = str(uuid.UUID(item["id"]))
    report = request(BASE + "/v1/bot/report/" + report_id, os.environ["BOT_TOKEN"])
    previous = db.execute("SELECT * FROM tasks WHERE report_id=?", (report_id,)).fetchone()
    if previous and previous["fingerprint"] == fingerprint(report):
        if previous["pr"]:
            version = released_version(previous, report["report"].get("channel"))
            if version and not args.dry_run:
                reply = "" if report["report"]["kind"] == "auto" else f"Исправление вышло в версии {version}."
                db.execute("UPDATE tasks SET status='closed', reply=?, delivered=0 WHERE report_id=?", (reply, report_id))
                db.commit()
                deliver(db, db.execute("SELECT * FROM tasks WHERE report_id=?", (report_id,)).fetchone())
                return
        if previous["pr"] or previous["kind"] == "feature":
            # Keep features durable; check existing repairs against actual release commits.
            if not args.dry_run:
                request(BASE + "/v1/bot/report/" + report_id + "/status", os.environ["BOT_TOKEN"], {"status": previous["status"]})
            return
    result, pr = analyze(args.state, report, previous) if not args.dry_run else (None, "")
    if result:
        save_task(db, report, result, pr)
        deliver(db, db.execute("SELECT * FROM tasks WHERE report_id=?", (report_id,)).fetchone())
    print("Report checked" if args.dry_run else "Report processed", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print(f"Report processing failed: {detail}. Private state retained.", file=sys.stderr)
        sys.exit(1)
