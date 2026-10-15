import copy
import json
import argparse
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

import report_bot as bot


class ReportBotTests(unittest.TestCase):
    def setUp(self):
        self.report = {"report": {"id": "abc", "kind": "manual", "message": "cache", "status": "open", "updated_at": 0}, "thread": []}
        self.result = {"kind": "feature", "title": "Cache size", "analysis": "Add size display",
                       "reply": "Спасибо!", "status": "closed", "fix": False, "validation": "Not implemented"}

    def test_feature_is_durable_before_reply(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = bot.database(Path(tmp))
            result = bot.validate_result(self.result)
            bot.save_task(db, self.report, result, "")
            db.close()
            db = bot.database(Path(tmp))
            row = db.execute("SELECT * FROM tasks").fetchone()
            self.assertEqual(row["status"], "in_progress")
            self.assertIn("списке задач", row["reply"])
            self.assertEqual(row["delivered"], 0)
            db.close()

    def test_user_reply_changes_fingerprint_but_dev_reply_does_not(self):
        original = bot.fingerprint(self.report)
        self.report["report"].update(status="closed", updated_at=40)
        self.report["thread"].append({"author": "dev", "text": "hello"})
        self.assertEqual(original, bot.fingerprint(self.report))
        self.report["thread"].append({"author": "user", "text": "clarification"})
        self.assertNotEqual(original, bot.fingerprint(self.report))

    def test_reject_workflow_and_hidden_file_edits(self):
        for name in (".github/workflows/build.yml", "SpicyLyrics/.claude/settings.js", "cloudflare/src/package.json"):
            with self.assertRaises(ValueError):
                bot.changed_files({}, {name: "modified"})
        self.assertEqual(bot.changed_files({"SpicyLyrics/Cache.swift": "old"}, {"SpicyLyrics/Cache.swift": "new"}), ["SpicyLyrics/Cache.swift"])

    def test_invalid_claim_and_result_types(self):
        bad = dict(self.result, fix="yes")
        with self.assertRaises(ValueError):
            bot.validate_result(bad)
        with self.assertRaises(ValueError):
            bot.validate_result(dict(self.result, fix=True, validation=""))

    def test_auto_reports_have_no_reply(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = bot.database(Path(tmp))
            self.report["report"]["kind"] = "auto"
            bot.save_task(db, self.report, bot.validate_result(self.result), "")
            self.assertEqual(db.execute("SELECT reply FROM tasks").fetchone()[0], "")
            db.close()

    def test_crash_retry_does_not_send_duplicate(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = bot.database(Path(tmp))
            bot.save_task(db, self.report, bot.validate_result(self.result), "")
            row = db.execute("SELECT * FROM tasks").fetchone()
            current = copy.deepcopy(self.report)
            current["thread"].append({"author": "dev", "text": row["reply"]})
            with patch.dict(bot.os.environ, {"BOT_TOKEN": "test"}), patch.object(bot, "request", side_effect=[current, {"ok": True}]) as req:
                bot.deliver(db, row)
            self.assertTrue(req.call_args_list[1].args[0].endswith("/status"))
            self.assertEqual(db.execute("SELECT delivered FROM tasks").fetchone()[0], 1)
            db.close()

    def test_photos_use_container_paths_and_pending_repair_resumes(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            (state / "auth.json").write_text('{}')
            report = copy.deepcopy(self.report)
            report["photos"] = [bot.BASE + "/v1/bot/report/abc/photo/0"]
            result = dict(self.result, kind="bug", fix=True, status="in_progress")
            response = MagicMock()
            response.__enter__.return_value = response
            response.headers.get_content_type.return_value = "image/png"
            response.read.return_value = b"photo"

            def command(args, *unused, **kwargs):
                if args[:2] == ["git", "clone"]:
                    source = Path(args[-1])
                    (source / ".git").mkdir(parents=True)
                    (source / "SpicyLyrics").mkdir()
                    (source / "SpicyLyrics/Fix.swift").write_text("before")
                return "a" * 40

            def run(args, **kwargs):
                if args[:2] == ["docker", "run"]:
                    self.assertEqual(args[args.index("--image") + 1], "/input/photo-0.png")
                    mounts = [args[i + 1] for i, value in enumerate(args) if value == "-v"]
                    source = Path(next(m.split(":")[0] for m in mounts if ":/work:" in m))
                    output = Path(next(m.split(":")[0] for m in mounts if ":/output:" in m))
                    (source / "SpicyLyrics/Fix.swift").write_text("after")
                    (output / "result.json").write_text(json.dumps(result))
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

            with patch.dict(bot.os.environ, BOT_TOKEN="test"), \
                    patch.object(bot, "command", side_effect=command), \
                    patch.object(bot, "github", return_value=[]), \
                    patch.object(bot.urllib.request, "urlopen", return_value=response), \
                    patch.object(bot.subprocess, "run", side_effect=run), \
                    patch.object(bot, "publish", side_effect=RuntimeError("uncertain publication")):
                with self.assertRaises(RuntimeError):
                    bot.analyze(state, report, None)
            self.assertEqual(len(list(state.glob("job-*/repair.json"))), 1)
            # A restart must reuse the reviewed source and result without launching Codex.
            with patch.object(bot, "publish", return_value="https://github.com/test/pr/1") as publish, \
                    patch.object(bot.subprocess, "run") as run:
                recovered, pr = bot.analyze(state, report, None)
            run.assert_not_called()
            self.assertTrue(recovered["fix"])
            self.assertEqual(pr, "https://github.com/test/pr/1")
            self.assertEqual(publish.call_args.args[2], ["SpicyLyrics/Fix.swift"])

    def test_existing_open_pr_is_reused_without_push(self):
        pr = {"state": "open", "base": {"ref": "main"},
              "head": {"ref": "bot/report-abc", "repo": {"full_name": bot.REPO}},
              "html_url": "https://github.com/test/pr/1"}
        with patch.object(bot, "github", return_value=[pr]), patch.object(bot, "command") as cmd:
            self.assertEqual(bot.publish(Path("unused"), Path("unused"), [], self.result, "abc"), pr["html_url"])
            cmd.assert_not_called()
            pr["state"] = "closed"
            with self.assertRaises(ValueError):
                bot.publish(Path("unused"), Path("unused"), [], self.result, "abc")

    def test_retry_after_push_reuses_persisted_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            job = Path(tmp)
            (job / "publish").mkdir()
            (job / "publication-commit").write_text("a" * 40)
            pr = {"head": {"ref": "bot/report-abc"}, "base": {"ref": "main"}, "html_url": "pr"}
            with patch.object(bot, "github", side_effect=[[], pr]), patch.object(bot, "command") as cmd:
                self.assertEqual(bot.publish(job, job / "source", [], self.result, "abc"), "pr")
            self.assertEqual(cmd.call_count, 1)
            self.assertEqual(cmd.call_args.args[0][-1], "a" * 40 + ":refs/heads/bot/report-abc")

    def test_missing_report_retires_outbox_but_transient_errors_retry(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = bot.database(Path(tmp))
            bot.save_task(db, self.report, bot.validate_result(self.result), "")
            row = db.execute("SELECT * FROM tasks").fetchone()
            with patch.dict(bot.os.environ, BOT_TOKEN="test"), \
                    patch.object(bot, "request", side_effect=bot.RequestError("example", 503)):
                with self.assertRaises(bot.RequestError):
                    bot.deliver(db, row)
            self.assertEqual(db.execute("SELECT delivered FROM tasks").fetchone()[0], 0)
            with patch.dict(bot.os.environ, BOT_TOKEN="test"), \
                    patch.object(bot, "request", side_effect=bot.RequestError("example", 404)):
                bot.deliver(db, row)
            self.assertEqual(db.execute("SELECT delivered FROM tasks").fetchone()[0], 1)
            db.close()

    def test_one_failed_delivery_and_report_do_not_block_queue(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            db = bot.database(state)
            bot.save_task(db, self.report, bot.validate_result(self.result), "")
            db.close()
            args = argparse.Namespace(action="run", state=state, dry_run=False)
            with patch.dict(bot.os.environ, BOT_TOKEN="test"), \
                    patch.object(bot.argparse.ArgumentParser, "parse_args", return_value=args), \
                    patch.object(bot.Path, "home", return_value=state), \
                    patch.object(bot, "deliver", side_effect=RuntimeError("retry")), \
                    patch.object(bot, "request", return_value={"reports": [{"id": "first"}, {"id": "second"}]}), \
                    patch.object(bot, "process_report", side_effect=[RuntimeError("bad report"), None]) as process, \
                    patch("sys.stderr", new_callable=io.StringIO):
                bot.main()
            self.assertEqual(process.call_count, 2)
            self.assertEqual(process.call_args.args[2], {"id": "second"})


if __name__ == "__main__":
    unittest.main()
