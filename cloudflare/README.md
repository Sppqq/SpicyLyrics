# Report collector (Cloudflare Worker)

Receives the reports the app sends (Settings → Error Reports): a note, up to three photos and the sync
log. Text goes to D1, photos to R2. Reports are deleted after 90 days (nightly cron).

- `POST /v1/report`: multipart form: `meta` (JSON), `log` (text), `photo` (up to 3 JPEG/PNG, 2 MB each).
  Limits: 8 MB per request, 12 reports per hour per install, 40 per hour / 200 per day per network.
- `/admin`: the list, a report with its photos and log, delete. HTTP Basic: any user name, the password
  is the `ADMIN_TOKEN` secret.

Only a random per-install id, the app and iOS version and the phone model are stored with a report. The
network address is stored only as a salted hash (salt: the `IP_SALT` secret), for the limits above.
Without `IP_SALT` the admin password is the salt, and changing it resets the limits.

## Set up

```sh
cd cloudflare
npx wrangler login
npx wrangler d1 create sweet-lyrics-reports          # put the id in wrangler.toml
npx wrangler r2 bucket create sweet-lyrics-report-photos
npx wrangler d1 execute sweet-lyrics-reports --remote --file=schema.sql
npx wrangler secret put ADMIN_TOKEN                  # the admin password
npx wrangler secret put IP_SALT                      # any long random string, never changed
npx wrangler deploy
```

The app posts to the URL in `SpicyLyrics/Support/ReportService.swift` (`endpoint`).
