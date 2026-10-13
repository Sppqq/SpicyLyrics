// Sweet Lyrics report collector: the app posts a bug report (log, a note, a few photos), this
// stores it in D1 (text) and R2 (photos). /admin is a small page for reading them.

const MAX_BODY = 8 * 1024 * 1024;
const MAX_LOG = 300_000;
const MAX_MESSAGE = 4_000;
const MAX_FIELD = 200;
const MAX_PHOTOS = 3;
const MAX_PHOTO = 2 * 1024 * 1024;
const RETENTION_DAYS = 90;
// Anonymous endpoint: keep one install or one network from filling the database.
const LIMITS = { installPerHour: 12, ipPerHour: 40, ipPerDay: 200 };
const UUID = /^[0-9a-fA-F-]{36}$/;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (url.pathname === "/v1/report" && request.method === "POST") return await receive(request, env);
      if (url.pathname === "/") return text("Sweet Lyrics reports\n");
      if (url.pathname.startsWith("/admin")) return await admin(request, env, url);
      return text("Not found\n", 404);
    } catch (error) {
      console.error(error);
      return json({ error: "server" }, 500);
    }
  },

  async scheduled(_event, env) {
    const cutoff = Math.floor(Date.now() / 1000) - RETENTION_DAYS * 86400;
    const old = await env.DB.prepare("SELECT id, photos, photo_exts FROM reports WHERE created_at < ?").bind(cutoff).all();
    for (const row of old.results) await deletePhotos(env, row);
    await env.DB.prepare("DELETE FROM reports WHERE created_at < ?").bind(cutoff).run();
  },
};

// MARK: Receiving

async function receive(request, env) {
  const length = Number(request.headers.get("content-length") || 0);
  if (!length) return json({ error: "length" }, 411);
  if (length > MAX_BODY) return json({ error: "too big" }, 413);
  if (!(request.headers.get("content-type") || "").startsWith("multipart/form-data")) return json({ error: "type" }, 415);

  const now = Math.floor(Date.now() / 1000);
  const ipHash = await sha256Hex((request.headers.get("cf-connecting-ip") || "?") + (env.IP_SALT || env.ADMIN_TOKEN || "sl"));
  const byIp = await env.DB.prepare(
    "SELECT SUM(created_at > ?) AS hour, COUNT(*) AS day FROM reports WHERE ip_hash = ? AND created_at > ?"
  ).bind(now - 3600, ipHash, now - 86400).first();
  if ((byIp?.hour || 0) >= LIMITS.ipPerHour || (byIp?.day || 0) >= LIMITS.ipPerDay) return json({ error: "slow down" }, 429);

  const form = await request.formData();
  let meta;
  try {
    meta = JSON.parse(String(form.get("meta") || "{}"));
  } catch {
    return json({ error: "meta" }, 400);
  }
  const kind = meta.kind === "auto" ? "auto" : meta.kind === "manual" ? "manual" : null;
  const installId = String(meta.installId || "");
  if (!kind || !UUID.test(installId)) return json({ error: "meta" }, 400);

  const perInstall = await env.DB.prepare("SELECT COUNT(*) AS n FROM reports WHERE install_id = ? AND created_at > ?")
    .bind(installId, now - 3600).first();
  if ((perInstall?.n || 0) >= LIMITS.installPerHour) return json({ error: "slow down" }, 429);

  const id = crypto.randomUUID();
  const photos = [];
  for (const file of form.getAll("photo")) {
    if (photos.length >= MAX_PHOTOS) break;
    if (typeof file === "string" || file.size === 0 || file.size > MAX_PHOTO) continue;
    const bytes = new Uint8Array(await file.arrayBuffer());
    const ext = imageExtension(bytes);
    if (!ext) continue;
    await env.PHOTOS.put(`${id}/${photos.length}.${ext}`, bytes, {
      httpMetadata: { contentType: ext === "png" ? "image/png" : "image/jpeg" },
    });
    photos.push(ext);
  }

  const field = (value) => String(value ?? "").slice(0, MAX_FIELD);
  await env.DB.prepare(
    `INSERT INTO reports (id, created_at, kind, error_kind, message, app_version, build, channel, os, device, locale,
                          install_id, ip_hash, log, photos, photo_exts)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    id, now, kind, field(meta.errorKind), String(meta.message ?? "").slice(0, MAX_MESSAGE),
    field(meta.appVersion), field(meta.build), field(meta.channel), field(meta.os), field(meta.device), field(meta.locale),
    installId, ipHash, String(form.get("log") || "").slice(0, MAX_LOG), photos.length, photos.join(","),
  ).run();
  return json({ ok: true, id });
}

function imageExtension(bytes) {
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "jpg";
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return "png";
  return null;
}

async function deletePhotos(env, row) {
  const keys = (row.photo_exts || "").split(",").filter(Boolean).map((ext, i) => `${row.id}/${i}.${ext}`);
  if (keys.length) await env.PHOTOS.delete(keys);
}

// MARK: Admin

async function admin(request, env, url) {
  if (!(await authorized(request, env))) {
    return new Response("Sign in", { status: 401, headers: { "www-authenticate": 'Basic realm="Sweet Lyrics reports"' } });
  }
  const parts = url.pathname.split("/").filter(Boolean); // admin, r|p, id, ...

  if (parts.length === 1) {
    const kind = url.searchParams.get("kind");
    const rows = await env.DB.prepare(
      `SELECT id, created_at, kind, error_kind, message, app_version, build, channel, os, device, photos
       FROM reports ${kind ? "WHERE kind = ?" : ""} ORDER BY created_at DESC LIMIT 200`
    ).bind(...(kind ? [kind] : [])).all();
    const body = rows.results.map((r) =>
      `<tr><td><a href="/admin/r/${r.id}">${esc(when(r.created_at))}</a></td><td>${esc(r.kind)}</td>` +
      `<td>${esc(r.app_version)} ${esc(r.channel)} (${esc(r.build)})</td><td>${esc(r.os)}</td><td>${esc(r.device)}</td>` +
      `<td>${r.photos ? "photos: " + r.photos : ""}</td><td>${esc(r.error_kind || "")} ${esc((r.message || "").slice(0, 120))}</td></tr>`
    ).join("");
    return page("Reports",
      `<p><a href="/admin">all</a> · <a href="/admin?kind=manual">manual</a> · <a href="/admin?kind=auto">auto</a></p>` +
      `<table><tr><th>When</th><th>Kind</th><th>App</th><th>iOS</th><th>Device</th><th></th><th>Note / error</th></tr>${body}</table>`);
  }

  if (parts[1] === "r" && parts[2]) {
    const row = await env.DB.prepare("SELECT * FROM reports WHERE id = ?").bind(parts[2]).first();
    if (!row) return text("Not found\n", 404);
    if (parts[3] === "log.txt") {
      return new Response(row.log || "", { headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" } });
    }
    if (parts[3] === "delete" && request.method === "POST") {
      if (request.headers.get("origin") !== url.origin) return text("Forbidden\n", 403);
      await deletePhotos(env, row);
      await env.DB.prepare("DELETE FROM reports WHERE id = ?").bind(row.id).run();
      return Response.redirect(url.origin + "/admin", 303);
    }
    const exts = (row.photo_exts || "").split(",").filter(Boolean);
    const images = exts.map((_, i) =>
      `<a href="/admin/p/${row.id}/${i}"><img src="/admin/p/${row.id}/${i}" style="max-width:320px;margin:4px"></a>`).join("");
    return page("Report",
      `<p><a href="/admin">← all</a></p>` +
      `<p><b>${esc(when(row.created_at))}</b> · ${esc(row.kind)} ${esc(row.error_kind || "")}</p>` +
      `<p>${esc(row.app_version)} ${esc(row.channel)} (${esc(row.build)}) · iOS ${esc(row.os)} · ${esc(row.device)} · ${esc(row.locale)}` +
      `<br>install ${esc(row.install_id)}</p>` +
      (row.message ? `<h3>Note</h3><pre>${esc(row.message)}</pre>` : "") +
      (images ? `<h3>Photos</h3>${images}` : "") +
      `<h3>Log</h3><p><a href="/admin/r/${row.id}/log.txt">log.txt</a></p><pre>${esc(row.log || "")}</pre>` +
      `<form method="post" action="/admin/r/${row.id}/delete" onsubmit="return confirm('Delete this report?')"><button>Delete</button></form>`);
  }

  if (parts[1] === "p" && parts[2] && parts[3]) {
    const row = await env.DB.prepare("SELECT photo_exts FROM reports WHERE id = ?").bind(parts[2]).first();
    const index = Number(parts[3]);
    const ext = (row?.photo_exts || "").split(",").filter(Boolean)[index];
    if (!ext) return text("Not found\n", 404);
    const object = await env.PHOTOS.get(`${parts[2]}/${index}.${ext}`);
    if (!object) return text("Not found\n", 404);
    return new Response(object.body, {
      headers: { "content-type": ext === "png" ? "image/png" : "image/jpeg", "cache-control": "private, max-age=3600" },
    });
  }
  return text("Not found\n", 404);
}

async function authorized(request, env) {
  if (!env.ADMIN_TOKEN) return false;
  const header = request.headers.get("authorization") || "";
  if (!header.startsWith("Basic ")) return false;
  let password = "";
  try {
    password = atob(header.slice(6)).split(":").slice(1).join(":");
  } catch {
    return false;
  }
  const [a, b] = await Promise.all([sha256(password), sha256(env.ADMIN_TOKEN)]);
  return crypto.subtle.timingSafeEqual(a, b);
}

// MARK: Helpers

async function sha256(value) {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
}

async function sha256Hex(value) {
  return [...new Uint8Array(await sha256(value))].slice(0, 12).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const ESCAPES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
const esc = (value) => String(value ?? "").replace(/[&<>"']/g, (c) => ESCAPES[c]);
const when = (seconds) => new Date(seconds * 1000).toISOString().replace("T", " ").slice(0, 19) + " UTC";

function page(title, body) {
  return new Response(
    `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${esc(title)}</title>` +
      `<style>body{font:14px system-ui;margin:16px}table{border-collapse:collapse}td,th{padding:4px 10px;border-bottom:1px solid #8884;` +
      `text-align:left;vertical-align:top}pre{white-space:pre-wrap;word-break:break-word;font-size:12px;background:#8881;padding:8px}</style>${body}`,
    {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "x-robots-tag": "noindex",
        "content-security-policy": "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; form-action 'self'; script-src 'unsafe-inline'",
      },
    },
  );
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
const text = (value, status = 200) =>
  new Response(value, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
