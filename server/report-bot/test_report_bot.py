import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

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


if __name__ == "__main__":
    unittest.main()
