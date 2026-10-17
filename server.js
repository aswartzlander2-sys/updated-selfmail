'use strict';

const express = require('express');
const nodemailer = require('nodemailer');
const dns = require('dns').promises;
const { Resolver } = require('dns').promises;

// Checks go straight to public resolvers rather than the system one: a local
// stub (systemd-resolved) caches NXDOMAIN for the zone's negative TTL, so a
// record added seconds ago can read as missing for many minutes.
const pubdns = new Resolver({ timeout: 4000, tries: 2 });
try { pubdns.setServers(['1.1.1.1', '8.8.8.8', '9.9.9.9']); } catch (e) { /* fall back */ }
const { execFile } = require('child_process');
const net = require('net');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = parseInt(process.env.SELFMAIL_PORT || '8088', 10);
const CFG_FILE = process.env.SELFMAIL_CONFIG || '/etc/selfmail/config.json';
const MAILROOT = process.env.SELFMAIL_MAILROOT || '/var/mail/vhosts';
const USER = process.env.SELFMAIL_USER || 'admin';
const PASS = process.env.SELFMAIL_PASS || '';
const INBOUND_SECRET = process.env.SELFMAIL_INBOUND_SECRET || '';
const APP_DIR = __dirname;
const SENT_LOG = path.join(APP_DIR, 'sent.json');

const NL = String.fromCharCode(10);

const DEFAULTS = {
  domain: '',            // right-hand side of addresses, e.g. mail.example.com
  mxhost: '',            // this server's own name, e.g. mx.example.com
  selector: 'mail',      // DKIM selector
  publicIp: '',
  mailbox: 'admin',      // local part of the primary mailbox
  fromName: '',
  defaultTo: '',
  dmarcRua: '',
  dmarcPolicy: 'none',
  mode: 'relay',         // 'relay' = webhook (default) | 'direct' = own MX on port 25
  relayProvider: 'forwardemail',
  webhookUrl: '',        // public https URL of this app, for relay mode
};

function loadCfg() {
  try {
    return Object.assign({}, DEFAULTS, JSON.parse(fs.readFileSync(CFG_FILE, 'utf8')));
  } catch (e) {
    return Object.assign({}, DEFAULTS);
  }
}
function saveCfg(c) {
  fs.mkdirSync(path.dirname(CFG_FILE), { recursive: true });
  fs.writeFileSync(CFG_FILE, JSON.stringify(c, null, 2));
}

// --- authentication ---------------------------------------------------
// Credentials come from three places, any of which is accepted:
//   1. /etc/selfmail/users.json  { "<user>": "<sha256(password)>" }  (login.sh)
//   2. the SELFMAIL_USER / SELFMAIL_PASS environment pair
//   3. a built-in default, unless SELFMAIL_DISABLE_DEFAULT=1
// The built-in default is a published, well-known credential - change it or
// disable it before exposing the UI to anyone you do not trust.
const USERS_FILE = process.env.SELFMAIL_USERS || '/etc/selfmail/users.json';
const DEFAULT_USER = 'adminpass';
const DEFAULT_PASS = 'adminpass26!';

function sha256(x) { return crypto.createHash('sha256').update(String(x)).digest('hex'); }

function loadUsers() {
  try { return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8')) || {}; }
  catch (e) { return {}; }
}

// constant-time compare so a wrong password cannot be timed
function eq(a, b) {
  const ab = Buffer.from(String(a)); const bb = Buffer.from(String(b));
  if (ab.length !== bb.length) return false;
  try { return crypto.timingSafeEqual(ab, bb); } catch (e) { return false; }
}

function checkAuth(user, pass) {
  if (!user) return false;
  const users = loadUsers();
  if (Object.prototype.hasOwnProperty.call(users, user) && eq(users[user], sha256(pass))) return true;
  if (USER && PASS && user === USER && eq(pass, PASS)) return true;
  if (process.env.SELFMAIL_DISABLE_DEFAULT !== '1' && user === DEFAULT_USER && eq(pass, DEFAULT_PASS)) return true;
  return false;
}

const app = express();
app.set('trust proxy', true);

const sh = (cmd, args) => new Promise(function (resolve) {
  execFile(cmd, args, { timeout: 20000, maxBuffer: 8e6 }, function (e, so, se) {
    resolve((so || '') + (se || ''));
  });
});

// ---------------------------------------------------------------------
// Inbound webhook. Mounted BEFORE auth: a mail relay posts here and
// cannot present basic-auth credentials, so the path secret authorises it.
// ---------------------------------------------------------------------
app.use('/inbound', express.text({ type: '*/*', limit: '30mb' }));

app.post('/inbound/:secret', async (req, res) => {
  if (!INBOUND_SECRET || req.params.secret !== INBOUND_SECRET) {
    return res.status(403).json({ error: 'forbidden' });
  }
  const c = loadCfg();
  let raw = req.body;
  if (raw && typeof raw === 'object') raw = JSON.stringify(raw);
  raw = String(raw || '');

  // Relays differ: some POST raw MIME, others wrap it in JSON. Accept both,
  // and rebuild a message from fields when no raw copy is included.
  if (raw.charAt(0) === '{') {
    try {
      const o = JSON.parse(raw);
      let r = o.raw || o.message || o.email || o.mime;
      if (r && typeof r === 'object') r = r.raw || r.data || null;
      if (!r) {
        const addr = function (v) {
          if (!v) return '';
          if (typeof v === 'string') return v;
          if (Array.isArray(v)) return v.map(addr).join(', ');
          return v.text || v.address || (v.value ? addr(v.value) : '');
        };
        const h = [];
        h.push('From: ' + (addr(o.from) || 'unknown@unknown'));
        h.push('To: ' + (addr(o.to) || c.mailbox + '@' + c.domain));
        if (o.subject) h.push('Subject: ' + o.subject);
        h.push('Date: ' + (o.date || new Date().toUTCString()));
        if (o.messageId) h.push('Message-ID: ' + o.messageId);
        const isHtml = !o.text && o.html;
        h.push('Content-Type: text/' + (isHtml ? 'html' : 'plain') + '; charset=utf-8');
        r = h.join(NL) + NL + NL + (o.text || o.html || '');
      }
      raw = r;
    } catch (e) { /* not JSON after all */ }
  }
  if (!raw.trim()) return res.status(400).json({ error: 'empty body' });

  const dir = MAILROOT + '/' + c.domain + '/' + c.mailbox + '/new';
  const name = Math.floor(Date.now() / 1000) + '.M' + process.hrtime.bigint() % 1000000n +
    'P' + process.pid + '.selfmail';
  const tmp = '/tmp/' + name;
  try {
    fs.writeFileSync(tmp, raw);
    await sh('sudo', ['install', '-o', 'vmail', '-g', 'vmail', '-m', '600', tmp, dir + '/' + name]);
    fs.unlinkSync(tmp);
    console.log('inbound: stored ' + name + ' (' + raw.length + ' bytes)');
    res.json({ ok: true, stored: name, bytes: raw.length });
  } catch (e) {
    console.error('inbound failed: ' + e.message);
    res.status(500).json({ error: e.message });
  }
});

app.get('/inbound/:secret/ping', (req, res) => {
  if (!INBOUND_SECRET || req.params.secret !== INBOUND_SECRET) {
    return res.status(403).json({ error: 'forbidden' });
  }
  res.json({ ok: true, ready: true });
});

// ---------------------------------------------------------------------
// Everything below requires auth.
// ---------------------------------------------------------------------
app.use(express.json({ limit: '25mb' }));

app.use(function (req, res, next) {
  const parts = (req.headers.authorization || '').split(' ');
  if (parts[0] === 'Basic' && parts[1]) {
    const dec = Buffer.from(parts[1], 'base64').toString();
    const i = dec.indexOf(':');
    if (i !== -1 && checkAuth(dec.slice(0, i), dec.slice(i + 1))) return next();
  }
  res.set('WWW-Authenticate', 'Basic realm="selfmail"').status(401).send('authentication required');
});

app.use(express.static(path.join(APP_DIR, 'public')));

// Postfix queries the OpenDKIM milter about a new connection *before* it emits
// the 220 banner, and waits milter_connect_timeout (default 30s) for an answer.
// A milter that is listening but not replying therefore looks exactly like a
// dead server, and nodemailer's own greetingTimeout is also 30s - so the two
// expire together and the UI reports the useless "Greeting never received".
// Give up in a few seconds instead, and let the caller fall back to sendmail.
const transport = nodemailer.createTransport({
  host: '127.0.0.1', port: 25, secure: false, ignoreTLS: true,
  connectionTimeout: 8000, greetingTimeout: 8000, socketTimeout: 45000,
});

// Submitting through the sendmail binary goes postdrop -> pickup -> cleanup and
// never touches smtpd, so it still works while smtpd is stalled on the milter.
// postdrop is setgid, so no sudo entry is needed for this.
function sendmailPath() {
  const cands = ['/usr/sbin/sendmail', '/usr/lib/sendmail', '/usr/bin/sendmail'];
  for (const p of cands) {
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch (e) { /* next */ }
  }
  return '';
}

// Only transport-level failures may be retried. A 5xx from Postfix, a rejected
// recipient or a malformed address is a real answer and must be reported as-is.
function mtaUnreachable(e) {
  const code = e && e.code;
  if (['ECONNECTION', 'ETIMEDOUT', 'ESOCKET', 'ECONNREFUSED', 'EDNS'].indexOf(code) !== -1) return true;
  return /greeting never received|connection timeout|socket close/i.test((e && e.message) || '');
}

// Connects to the local MTA and waits for the greeting, so the three failures
// that are indistinguishable in the UI can be told apart: nothing listening,
// something listening that is not Postfix, and Postfix accepting the connection
// but withholding the banner.
function probeSmtp(timeoutMs) {
  return new Promise(function (resolve) {
    const started = Date.now();
    let done = false, buf = '';
    const s = net.createConnection({ host: '127.0.0.1', port: 25 });
    const finish = function (r) {
      if (done) return;
      done = true;
      try { s.destroy(); } catch (e) { /* already gone */ }
      r.ms = Date.now() - started;
      resolve(r);
    };
    s.setTimeout(timeoutMs || 8000);
    s.on('data', function (d) {
      buf += d.toString('latin1');
      if (buf.indexOf(String.fromCharCode(10)) === -1) return;
      const line = buf.split(String.fromCharCode(10))[0].trim();
      const ok = /^220[ -]/.test(line);
      finish({ ok: ok, banner: line, code: ok ? '' : 'NOTSMTP' });
    });
    s.on('timeout', function () {
      finish({ ok: false, banner: buf.trim(), code: 'NOGREETING' });
    });
    s.on('error', function (e) {
      finish({ ok: false, banner: '', code: e.code || 'ERROR', detail: e.message });
    });
  });
}

function explainProbe(p) {
  if (p.ok) return '';
  if (p.code === 'NOGREETING') {
    return 'Postfix accepted the connection on 127.0.0.1:25 but sent no greeting within ' +
      Math.round(p.ms / 1000) + 's. smtpd asks the OpenDKIM milter about every connection ' +
      'before it greets, so a milter that is listening but not answering stalls it here. ' +
      'Check: systemctl status opendkim - then run sudo ./update.sh, which caps that wait.';
  }
  if (p.code === 'ECONNREFUSED') {
    return 'Nothing is listening on 127.0.0.1:25, so Postfix is not running. ' +
      'Check: sudo postfix status  and  sudo ss -lntp | grep :25';
  }
  if (p.code === 'NOTSMTP') {
    return 'Port 25 answered with "' + p.banner.slice(0, 120) + '", which is not an SMTP greeting. ' +
      'Something other than Postfix owns the port. Check: sudo ss -lntp | grep :25';
  }
  return 'Could not reach 127.0.0.1:25 (' + (p.code || 'unknown') + '). ' + (p.detail || '');
}

const readSent = () => {
  try { return JSON.parse(fs.readFileSync(SENT_LOG, 'utf8')); } catch (e) { return []; }
};

// --- settings ---------------------------------------------------------
app.get('/api/settings', (req, res) => res.json(loadCfg()));

app.post('/api/settings', (req, res) => {
  const next = loadCfg();
  Object.keys(DEFAULTS).forEach(function (k) {
    if (typeof req.body[k] === 'string') next[k] = req.body[k].trim();
  });
  saveCfg(next);
  res.json(next);
});

// --- DNS records ------------------------------------------------------
function dkimPublic(c) {
  const f = '/etc/opendkim/keys/' + c.domain + '/' + c.selector + '.txt';
  try {
    const raw = fs.readFileSync(f, 'utf8');
    const parts = raw.match(/"([^"]*)"/g) || [];
    return parts.map(function (s) { return s.slice(1, -1); }).join('');
  } catch (e) { return ''; }
}

function buildRecords(c) {
  const recs = [];
  const zoneHint = 'Name is relative to your zone; your DNS host may append the domain automatically.';

  recs.push({
    key: 'a', type: 'A', name: c.mxhost, content: c.publicIp,
    note: 'This server. Must be unproxied / "DNS only" on Cloudflare, or SPF breaks. ' + zoneHint,
  });

  if (c.mode === 'relay') {
    recs.push({
      key: 'mx1', type: 'MX', name: c.domain, content: 'mx1.forwardemail.net', priority: 10,
      note: 'Relay takes delivery on port 25 and forwards to your webhook.',
    });
    recs.push({
      key: 'mx2', type: 'MX', name: c.domain, content: 'mx2.forwardemail.net', priority: 20,
      note: 'Backup relay host.',
    });
    recs.push({
      key: 'hook', type: 'TXT', name: c.domain,
      content: 'forward-email=' + (c.webhookUrl || 'https://YOUR-PUBLIC-URL/inbound/SECRET'),
      note: 'Tells the relay where to deliver. This coexists with the SPF TXT record below - do not merge them.',
    });
  } else {
    recs.push({
      key: 'mx1', type: 'MX', name: c.domain, content: c.mxhost, priority: 10,
      note: 'Mail is delivered straight to this server on port 25.',
    });
  }

  recs.push({
    key: 'spf', type: 'TXT', name: c.domain,
    content: 'v=spf1 ip4:' + c.publicIp + ' -all',
    note: 'Authorises this server to send as @' + c.domain + '.',
  });
  recs.push({
    key: 'dkim', type: 'TXT', name: c.selector + '._domainkey.' + c.domain,
    content: dkimPublic(c) || '(DKIM key not generated yet)',
    note: 'Public half of the DKIM signing key. Paste as one line.',
  });
  let dmarc = 'v=DMARC1; p=' + (c.dmarcPolicy || 'none');
  if (c.dmarcRua) dmarc += '; rua=mailto:' + c.dmarcRua;
  recs.push({
    key: 'dmarc', type: 'TXT', name: '_dmarc.' + c.domain, content: dmarc,
    note: c.dmarcRua
      ? 'Reports only arrive if the destination domain authorises you.'
      : 'No report address set.',
  });
  return recs;
}

app.get('/api/dns-records', (req, res) => res.json(buildRecords(loadCfg())));

// --- DNS check --------------------------------------------------------
// Resolves each expected record and reports pass/fail with what was found,
// so a wrong or missing record is obvious rather than a generic failure.
app.get('/api/dns-check', async (req, res) => {
  const c = loadCfg();
  const recs = buildRecords(c);
  const out = [];
  const R = pubdns;

  for (const r of recs) {
    const row = { key: r.key, type: r.type, name: r.name, expected: r.content, ok: false, found: '', detail: '' };
    try {
      if (r.type === 'A') {
        const v = await R.resolve4(r.name);
        row.found = v.join(', ');
        row.ok = v.indexOf(r.content) !== -1;
        if (!row.ok && v.length) row.detail = 'Resolves elsewhere - if this is Cloudflare, switch the record to "DNS only".';
      } else if (r.type === 'MX') {
        const v = await R.resolveMx(r.name);
        row.found = v.map(function (x) { return x.priority + ' ' + x.exchange; }).join(', ');
        row.ok = v.some(function (x) {
          return x.exchange.replace(/\.$/, '').toLowerCase() === r.content.toLowerCase();
        });
      } else {
        const v = await R.resolveTxt(r.name);
        const joined = v.map(function (x) { return x.join(''); });
        row.found = joined.join(' | ');
        if (r.key === 'spf') {
          row.ok = joined.some(function (x) { return x.trim() === r.content; });
          if (!row.ok && joined.some(function (x) { return x.indexOf('v=spf1') === 0; })) {
            row.detail = 'An SPF record exists but does not match exactly.';
          }
        } else if (r.key === 'dkim') {
          const want = (r.content.match(/p=([A-Za-z0-9+/=]+)/) || [])[1];
          row.ok = !!want && joined.some(function (x) { return x.indexOf(want) !== -1; });
          if (!row.ok && joined.length) row.detail = 'A DKIM record exists but the key does not match the one on this server.';
        } else if (r.key === 'hook') {
          row.ok = joined.some(function (x) { return x.trim() === r.content; });
        } else {
          row.ok = joined.some(function (x) { return x.indexOf('v=DMARC1') === 0; });
        }
      }
    } catch (e) {
      row.detail = e.code === 'ENOTFOUND' || e.code === 'ENODATA' ? 'No such record found.' : String(e.code || e.message);
    }
    out.push(row);
  }

  const okCount = out.filter(function (x) { return x.ok; }).length;
  res.json({ records: out, ok: okCount, total: out.length, allGood: okCount === out.length });
});

// --- send -------------------------------------------------------------
app.post('/api/send', async (req, res) => {
  const c = loadCfg();
  const b = req.body || {};
  if (!b.from || !b.to || !b.subject) {
    return res.status(400).json({ error: 'from, to and subject are required' });
  }
  if (String(b.from).split('@')[1] !== c.domain) {
    return res.status(400).json({ error: 'From must be @' + c.domain + ' or DKIM will not sign it' });
  }
  const rcpts = String(b.to).split(',').map(function (s) { return s.trim(); }).filter(Boolean);

  // Always include a plain-text alternative: HTML-only bodies score poorly.
  let textPart = b.text;
  if (!textPart && b.html) {
    textPart = String(b.html)
      .replace(new RegExp('<br[^>]*>', 'gi'), NL)
      .replace(new RegExp('</(p|div|h[1-6]|li|tr)>', 'gi'), NL)
      .replace(new RegExp('<[^>]+>', 'g'), '')
      .replace(new RegExp('&nbsp;', 'g'), ' ')
      .replace(new RegExp('&amp;', 'g'), '&')
      .replace(new RegExp(NL + '{3,}', 'g'), NL + NL)
      .trim();
  }

  const msg = {
    from: c.fromName ? '"' + c.fromName + '" <' + b.from + '>' : b.from,
    to: rcpts.join(', '),
    subject: b.subject,
    replyTo: b.replyTo || undefined,
    text: textPart || undefined,
    html: b.html || undefined,
    envelope: { from: b.from, to: rcpts },
    inReplyTo: b.inReplyTo || undefined,
    references: b.references || b.inReplyTo || undefined,
    textEncoding: 'quoted-printable',
  };

  const finish = function (rec) {
    const all = readSent(); all.unshift(rec);
    fs.writeFileSync(SENT_LOG, JSON.stringify(all.slice(0, 200), null, 2));
    res.status(rec.ok ? 200 : 500).json(rec);
  };
  const base = { ts: new Date().toISOString(), from: b.from, to: b.to, subject: b.subject };

  let smtpErr;
  try {
    const info = await transport.sendMail(msg);
    return finish(Object.assign({}, base, { response: info.response, via: 'smtp', ok: true }));
  } catch (e) {
    if (!mtaUnreachable(e)) {
      return finish(Object.assign({}, base, { error: e.message, via: 'smtp', ok: false }));
    }
    smtpErr = e;
    console.error('send: smtpd unreachable (' + e.message + '), trying sendmail');
  }

  // smtpd did not answer. Hand the message to the sendmail binary instead: it
  // writes to the maildrop queue, so the mail is accepted and delivered as soon
  // as the queue drains, rather than being lost to a stalled smtpd.
  const bin = sendmailPath();
  if (bin) {
    try {
      const alt = nodemailer.createTransport({ sendmail: true, path: bin, newline: 'unix' });
      const info = await alt.sendMail(msg);
      console.log('send: queued via ' + bin + ' (smtpd was unreachable)');
      return finish(Object.assign({}, base, {
        response: 'queued locally via ' + bin + ' - smtpd did not answer, see Status',
        via: 'sendmail', messageId: info.messageId, ok: true,
      }));
    } catch (e2) {
      console.error('send: sendmail fallback failed: ' + e2.message);
    }
  }

  const probe = await probeSmtp(9000);
  finish(Object.assign({}, base, {
    error: smtpErr.message, diagnosis: explainProbe(probe), via: 'smtp', ok: false,
  }));
});

app.get('/api/sent', (req, res) => res.json(readSent()));

// --- inbox ------------------------------------------------------------
function parseHeaders(raw) {
  raw = String(raw).split(String.fromCharCode(13,10)).join(String.fromCharCode(10));
  const split = raw.indexOf(NL + NL);
  const head = (split === -1 ? raw : raw.slice(0, split)).replace(/\n[ \t]+/g, ' ');
  const body = split === -1 ? '' : raw.slice(split + 2);
  const h = {};
  head.split(NL).forEach(function (line) {
    const i = line.indexOf(':');
    if (i > 0) {
      const k = line.slice(0, i).trim().toLowerCase();
      if (!h[k]) h[k] = line.slice(i + 1).trim();
    }
  });
  return { h: h, body: body };
}

function decodeWords(s) {
  if (!s) return '';
  return String(s).replace(/=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g, function (_, cs, enc, txt) {
    try {
      if (enc.toUpperCase() === 'B') return Buffer.from(txt, 'base64').toString('utf8');
      return Buffer.from(txt.replace(/_/g, ' ').replace(/=([0-9A-Fa-f]{2})/g, function (m, hx) {
        return String.fromCharCode(parseInt(hx, 16));
      }), 'binary').toString('utf8');
    } catch (e) { return txt; }
  });
}

function textPartOf(raw) {
  raw = String(raw).split(String.fromCharCode(13,10)).join(String.fromCharCode(10));
  const p = parseHeaders(raw);
  const ct = p.h['content-type'] || '';
  const cte = (p.h['content-transfer-encoding'] || '').toLowerCase();
  let body = p.body;
  const m = /boundary="?([^";\s]+)"?/i.exec(ct);
  if (m) {
    const parts = body.split('--' + m[1]);
    for (let i = 0; i < parts.length; i++) {
      if (/content-type:\s*text\/plain/i.test(parts[i])) return textPartOf(parts[i].replace(/^\r?\n/, ''));
    }
    for (let i = 0; i < parts.length; i++) {
      if (/content-type:\s*text\/html/i.test(parts[i])) return textPartOf(parts[i].replace(/^\r?\n/, ''));
    }
  }
  if (cte === 'base64') { try { body = Buffer.from(body, 'base64').toString('utf8'); } catch (e) {} }
  else if (cte === 'quoted-printable') {
    body = body.replace(/=\r?\n/g, '').replace(/=([0-9A-Fa-f]{2})/g, function (m2, hx) {
      return String.fromCharCode(parseInt(hx, 16));
    });
  }
  return body;
}

// Extract a text/html part if the message has one, so the reader can render
// mail the way the sender intended rather than as flattened plain text.
function htmlPartOf(raw) {
  raw = String(raw).split(String.fromCharCode(13, 10)).join(String.fromCharCode(10));
  const p = parseHeaders(raw);
  const ct = p.h['content-type'] || '';
  const cte = (p.h['content-transfer-encoding'] || '').toLowerCase();
  const m = /boundary="?([^";\s]+)"?/i.exec(ct);
  if (m) {
    const parts = raw.split('--' + m[1]);
    for (let i = 0; i < parts.length; i++) {
      if (/content-type:\s*text\/html/i.test(parts[i])) return htmlPartOf(parts[i].replace(/^\r?\n/, ''));
    }
    return '';
  }
  if (!/text\/html/i.test(ct)) return '';
  let body = p.body;
  if (cte === 'base64') { try { body = Buffer.from(body, 'base64').toString('utf8'); } catch (e) {} }
  else if (cte === 'quoted-printable') {
    body = body.replace(/=\r?\n/g, '').replace(/=([0-9A-Fa-f]{2})/g, function (mm, hx) {
      return String.fromCharCode(parseInt(hx, 16));
    });
  }
  return body;
}

const sudoRead = (f) => new Promise(function (resolve) {
  execFile('sudo', ['cat', f], { maxBuffer: 8e6, timeout: 15000 }, function (e, so) { resolve(so || ''); });
});

function boxDir(c) { return MAILROOT + '/' + c.domain + '/' + c.mailbox; }

app.get('/api/inbox', async (req, res) => {
  const c = loadCfg();
  const box = boxDir(c);
  const out = await sh('sudo', ['find', box + '/new', box + '/cur', '-type', 'f', '-printf', '%T@\\t%p\\n']);
  const files = out.split(NL).filter(Boolean).map(function (l) {
    const a = l.split('\t');
    return { t: parseFloat(a[0]), f: a[1] };
  }).filter(function (x) { return x.f; })
    .sort(function (a, b) { return b.t - a.t; })
    .slice(0, 80);

  const msgs = [];
  for (const it of files) {
    const raw = await sudoRead(it.f);
    const p = parseHeaders(raw.slice(0, 8000));
    let snippet = '';
    try {
      snippet = textPartOf(raw).replace(/\s+/g, ' ').trim().slice(0, 140);
    } catch (e) { /* unparseable body */ }
    msgs.push({
      id: Buffer.from(it.f).toString('base64'),
      from: decodeWords(p.h.from || ''),
      to: decodeWords(p.h.to || ''),
      subject: decodeWords(p.h.subject || '(no subject)'),
      date: p.h.date || new Date(it.t * 1000).toUTCString(),
      ts: (function () {
        const d = Date.parse(p.h.date || '');
        return isNaN(d) ? it.t * 1000 : d;
      })(),
      unread: it.f.indexOf('/new/') !== -1,
      snippet: snippet,
    });
  }
  msgs.sort(function (a, b) { return b.ts - a.ts; });
  res.json(msgs);
});

app.get('/api/inbox/msg', async (req, res) => {
  let f;
  try { f = Buffer.from(String(req.query.id || ''), 'base64').toString('utf8'); }
  catch (e) { return res.status(400).json({ error: 'bad id' }); }
  if (f.indexOf(MAILROOT) !== 0 || f.indexOf('..') !== -1) return res.status(400).json({ error: 'bad path' });
  const raw = await sudoRead(f);
  if (!raw) return res.status(404).json({ error: 'not found' });
  const p = parseHeaders(raw);
  res.json({
    from: decodeWords(p.h.from || ''), to: decodeWords(p.h.to || ''),
    subject: decodeWords(p.h.subject || '(no subject)'), date: p.h.date || '',
    authResults: p.h['authentication-results'] || '',
    dkim: p.h['dkim-signature'] ? 'present' : 'none',
    messageId: p.h['message-id'] || '',
    references: p.h['references'] || '',
    body: textPartOf(raw).slice(0, 200000),
    html: htmlPartOf(raw).slice(0, 400000),
  });
});

// --- delete ------------------------------------------------------------
// The id is a base64 path, so validate it stays inside the mail root and
// contains no traversal before handing it to rm.
app.post('/api/inbox/delete', async (req, res) => {
  let f;
  try { f = Buffer.from(String((req.body && req.body.id) || ''), 'base64').toString('utf8'); }
  catch (e) { return res.status(400).json({ error: 'bad id' }); }
  if (!f || f.indexOf(MAILROOT + '/') !== 0 || f.indexOf('..') !== -1 || f.indexOf(String.fromCharCode(0)) !== -1) {
    return res.status(400).json({ error: 'bad path' });
  }
  const out = await sh('sudo', ['rm', '-f', '--', f]);
  const gone = await sh('sudo', ['test', '-e', f]);
  console.log('deleted ' + f);
  res.json({ ok: true, deleted: f.split('/').pop(), detail: (out || '').trim() });
});

app.get('/api/addresses', async (req, res) => {
  const c = loadCfg();
  const domRaw = (await sh('sudo', ['postconf', '-h', 'virtual_mailbox_domains'])).trim();
  const domains = domRaw.split(',').map(function (x) { return x.trim(); }).filter(Boolean);
  const boxRaw = await sh('sudo', ['postmap', '-s', 'hash:/etc/postfix/vmailbox']);
  const mailboxes = boxRaw.split(NL).map(function (l) { return l.split(/\s+/)[0]; })
    .filter(function (x) { return x && x.indexOf('@') !== -1; });
  res.json(domains.map(function (d) {
    return {
      domain: d,
      addresses: mailboxes.filter(function (m) { return m.split('@')[1] === d; }),
      catchAll: true,
      mode: c.mode,
    };
  }));
});

// --- status -----------------------------------------------------------
app.get('/api/status', async (req, res) => {
  const c = loadCfg();
  const out = { cfg: c };
  out.currentIp = (await sh('curl', ['-4', '-s', '--max-time', '8', 'https://api.ipify.org'])).trim();
  out.ipMatchesConfig = out.currentIp === c.publicIp;
  out.queue = (await sh('mailq', [])).trim().slice(-4000);
  const unit = (await sh('systemctl', ['is-active', 'postfix'])).trim();
  if (/mail system is down|Queue report unavailable|No such file or directory/i.test(out.queue)) {
    out.postfix = 'down';
    out.postfixDetail = 'Postfix is not actually running. Most often something else already owns port 25 - check: sudo ss -lntp | grep :25';
  } else {
    out.postfix = unit;
  }
  out.opendkim = (await sh('systemctl', ['is-active', 'opendkim'])).trim();

  // `postfix status` only says the master is alive. What actually matters for
  // sending is whether smtpd greets, which is a different question - it is the
  // milter handshake, not the master, that goes silent.
  const probe = await probeSmtp(9000);
  out.smtp = {
    ok: probe.ok,
    banner: probe.banner,
    ms: probe.ms,
    detail: probe.ok ? '' : explainProbe(probe),
  };
  res.json(out);
});

app.get('/api/log', async (req, res) => {
  let t = await sh('sudo', ['tail', '-n', '200', '/var/log/mail.log']);
  if (!t.trim()) t = await sh('sudo', ['tail', '-n', '200', '/var/log/maillog']);
  if (!t.trim()) t = await sh('journalctl', ['-u', 'postfix@-', '-u', 'postfix', '-n', '200', '--no-pager']);
  res.type('text/plain').send(t || '(no mail log readable)');
});

app.listen(PORT, '0.0.0.0', function () {
  console.log('selfmail listening on :' + PORT);
});
