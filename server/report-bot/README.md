# Private report bot

`report_bot.py` is installed only on the server. It reads report threads and photos through the
existing Worker API, runs one Codex session in a disposable Docker container, and saves private
analysis and feature requests in `~/.local/state/sweet-report-bot/tasks.sqlite3`.
If a report photo returns 403 or 404, it records that the image was unavailable and continues with
the report text; it does not guess what the missing image showed.

The service account owns a separate copy of Codex's ChatGPT login and a mode-600 JSON secrets file
at `~/.config/sweet-report-bot/secrets.json`. The container gets only the Codex auth file; it has
no report or GitHub tokens, no Docker socket, and only the copied repository, report input, auth,
and response directories. The Codex CLI keeps the auth mount for model requests; the bwrap wrapper
hides `/auth` and its own executable from sandboxed commands. Those commands have no network access.
The container runs as the service UID with a read-only root filesystem and `no-new-privileges`.
Its seccomp profile is Moby's default with only the namespace and mount calls required by bwrap
added. This host's Docker AppArmor profile blocks those bwrap mounts, so AppArmor is disabled for
this container only; filesystem isolation remains enforced by bwrap and seccomp. The controller
checks every changed path and file type before a commit.
Only an allow-listed source diff is pushed to a draft PR; it is never merged. PR metadata does
not include report text, logs, photos, or internal analysis.
Commit and PR titles are controller-generated from the task kind and short report ID. Before
publication (including retries), the diff is checked for email addresses, phone numbers and
recognizable tokens from the private note, log and user messages. This is a heuristic privacy
check, not a guarantee against every possible encoding of private data.

The service replies only after saving the task. Feature requests are marked as tasks and are not
described as completed fixes. Rechecks compare the actual PR merge commit against published release
tags before saying a fix is out. Unsent replies are kept in a SQLite outbox so a restart can resume.
Photo arguments use paths inside the container's `/input` mount. Before publishing, the controller
journals the validated repair and persists its commit before pushing. Retries reuse that commit or
the existing open PR, so an interrupted publication does not require another agent run. Missing
reports retire their outbox entries; transient delivery and per-report failures remain retryable
without stopping the rest of the queue.
New repairs for an existing open PR start from its current branch head and append a commit
without force-pushing. A PR closed without merge returns the task to open/manual review.
Replies are bounded to the Worker's 4000 UTF-16-unit limit before entering the outbox.
Deploy the Worker before this controller: `expect_user_revision` guards bot replies/status updates
with the last user message ID, checked inside a transactional D1 batch. A mismatch returns 409
without changing the thread or status; the controller discards the stale reply and reanalyzes
the report on the next inbox pass. The field is optional for older API clients.
Temporary report copies expire after 14 days, except unpublished repair journals retained for
recovery; task metadata remains locally for follow-up.

Use `report_bot.py tasks` over SSH to see saved tasks. Do not copy the database or transient reports
to a public repository. The timer should be enabled only after verifying the private credentials,
Docker image, sandbox, and current GitHub authorization. Disable the old GitHub schedule before
enabling this timer.

The image build expects the matching Codex CLI, `codex-code-mode-host`, and `codex-bwrap-real`
release binaries in its build directory; keep those binaries out of Git and refresh them together.
For manual validation, run `python3 ~/.local/share/sweet-report-bot/report_bot.py tasks` and
`systemctl --user start sweet-report-bot.service`. After retiring the GitHub schedule, enable the
timer with `systemctl --user enable --now sweet-report-bot.timer`.
