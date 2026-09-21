'use strict';
// WorkBuddy relay for OpenWrt - ucode streaming HTTP server.
// Serves an OpenAI-compatible /v1/chat/completions by proxying WorkBuddy,
// passing SSE chunks through unmodified so clients can stream.

import * as uloop from 'uloop';
import * as fs from 'fs';
import * as socket from 'socket';

// `fs.popen()` accepts an argument *array*, which is executed directly via
// execvp() with no shell involved. Always prefer the array form: it removes
// any need for quoting and makes command injection structurally impossible.

// ---------------------------------------------------------------- config

const CFG = {
	host:     getenv('WORKBUDDY_HOST') || '0.0.0.0',
	port:     +(getenv('WORKBUDDY_PORT') || 8789),
	token:    getenv('WORKBUDDY_TOKEN') || '',
	endpoint: getenv('WORKBUDDY_ENDPOINT') || 'https://www.workbuddy.ai',
	cver:     getenv('WORKBUDDY_CLIENT_VERSION') || '5.5.2',
	freeOnly: getenv('WORKBUDDY_FREE_ONLY') == '1',
	share:    getenv('WORKBUDDY_SHARE_TOKEN') || '',
	expose:   getenv('WORKBUDDY_EXPOSE_MODELS') || '',
	debug:    getenv('WORKBUDDY_DEBUG') == '1',
};

function log(...a) {
	if (CFG.debug) fprintf(stderr, '[workbuddy] ' + join(' ', a) + '\n');
}

// ucode exposes wall-clock seconds as clock(); 1 = CLOCK_REALTIME.
function now() { return clock(1); }

// ------------------------------------------------------------ model table
// Fallback free set, used only when the remote catalogue cannot be fetched.
// Mirrors the free models the DSH plugin resolves via /v3/config.
const FREE_FALLBACK = [
	{ id: 'deepseek-v4.1-flash', name: 'Deepseek-V4.1-Flash · Free now', contextWindow: 128000, maxTokens: 8192 },
	{ id: 'hy4-preview-f',       name: 'Hy4 preview · Free now',        contextWindow: 256000, maxTokens: 8192 },
	{ id: 'hy3',                 name: 'Hy3 · Free now',                contextWindow: 128000, maxTokens: 8192 },
];

let cache = { at: 0, list: null, source: 'none', all: 0, free: 0 };

// creditOf: 0 means the model is free right now; anything else is paid.
// An absent/empty value is *unrated* and must not be treated as free.
function creditOf(credits) {
	if (credits == null || credits === '') return null;
	const v = +credits;
	return isNaN(v) ? null : v;
}

function isFree(m) {
	return creditOf(m.credits) === 0;
}

// ------------------------------------------------------------ http client
// curl is present in every OpenWrt image that ships LuCI; using it avoids
// a TLS implementation and keeps this script free of C dependencies.
//
// popen() is given an argument array, so no shell quoting is involved.

function curl(args) {
	const argv = [ 'curl', '-sS', '--max-time', '120', '-i' ];
	for (let i = 0; i < length(args); i++) push(argv, args[i]);

	let p;
	try {
		p = fs.popen(argv, 'r');
	} catch (e) {
		log('popen failed: ' + e);
		return null;
	}
	if (!p) return null;

	let buf = '';
	for (let line = p.read('line'); line != null && length(line); line = p.read('line'))
		buf += line;
	p.close();
	return buf;
}

// Split a raw "HTTP/1.1 200 OK\r\n...\r\n\r\nbody" blob.
function splitResponse(raw) {
	if (!raw) return null;
	const sep = index(raw, '\r\n\r\n');
	const head = (sep >= 0) ? substr(raw, 0, sep) : raw;
	const body = (sep >= 0) ? substr(raw, sep + 4) : '';
	const lines = split(head, '\r\n');

	let code = 0;
	const sm = match(lines[0], /^HTTP\/[\d.]+\s+(\d+)/);
	if (sm) code = +sm[1];

	const headers = {};
	for (let i = 1; i < length(lines); i++) {
		const c = index(lines[i], ':');
		if (c > 0) headers[lc(trim(substr(lines[i], 0, c)))] = trim(substr(lines[i], c + 1));
	}
	return { code, headers, body };
}

function lc(s) {
	return replace(s, /[A-Z]/g, (c) => chr(ord(c) + 32));
}

function jsonParse(s) {
	try {
		return json(s);
	} catch (e) {
		return null;
	}
}

// ------------------------------------------------------- workbuddy backend

// Headers for the plugin endpoints used here. All of them authenticate either
// by the one-time state or purely by User-Agent, so no bearer token is sent:
// the exact UA string matters, because upstream answers 400 code12403 for
// anything that does not look like a WorkBuddy client.
function wbHeaders() {
	return [
		'-H', 'Content-Type: application/json',
		'-H', 'Accept: application/json',
		'-H', 'User-Agent: WorkBuddy/' + CFG.cver,
		'-H', 'X-No-Authorization: true',
	];
}

// Fetch the catalogue and annotate each entry with its rate.
function fetchModels(force) {
	const ts = now();
	if (!force && cache.list && ts - cache.at < 21600) return cache;

	const r = splitResponse(curl(wbHeaders().concat([
		CFG.endpoint + '/v3/config',
	])));

	let list = null, source = 'fallback';
	if (r && r.code == 200 && r.body) {
		const cfg = jsonParse(r.body);
		const models = cfg ? cfg.models : null;
		if (models && length(models)) {
			list = [];
			for (let i = 0; i < length(models); i++) {
				const m = models[i];
				const id = m.id || m.model;
				if (!id) continue;
				const credits = (m.credits != null) ? m.credits : m.credit;
				const free = creditOf(credits) === 0;
				const base = m.name || id;
				const label = (creditOf(credits) == null) ? base
					: (free ? base + ' · Free now' : base + ' · x' + credits);
				push(list, {
					id, name: label, credits,
					free,
					contextWindow: m.contextWindow || m.context_window || 128000,
					maxTokens: m.maxTokens || m.max_tokens || 8192,
				});
			}
			source = 'remote';
		}
	}

	if (!list) list = FREE_FALLBACK;

	// freeOnly trims the exposed set; an empty free subset falls back to all
	// so the relay never ends up serving zero models.
	let out = list, freeCount = 0;
	for (let i = 0; i < length(list); i++) if (list[i].free) freeCount++;

	if (CFG.freeOnly && freeCount) {
		out = [];
		for (let i = 0; i < length(list); i++) if (list[i].free) push(out, list[i]);
	}

	cache = { at: ts, list: out, source, all: length(list), free: freeCount };
	log('models: source=' + source + ' all=' + length(list) + ' free=' + freeCount + ' exposed=' + length(out));
	return cache;
}

// ------------------------------------------------------------- http output
// Sockets expose send()/recv(); there is no write() on them.

function sendRaw(conn, s) {
	let off = 0;
	while (off < length(s)) {
		let n;
		try {
			n = conn.send(substr(s, off));
		} catch (e) {
			return false;
		}
		if (!n) return false;
		off += n;
	}
	return true;
}

function sendHead(conn, code, reason, headers) {
	let s = 'HTTP/1.1 ' + code + ' ' + reason + '\r\n';
	s += 'Access-Control-Allow-Origin: *\r\n';
	s += 'Access-Control-Allow-Headers: *\r\n';
	s += 'Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n';
	for (const k in headers) s += k + ': ' + headers[k] + '\r\n';
	s += '\r\n';
	return sendRaw(conn, s);
}

function sendJson(conn, code, reason, obj) {
	const body = sprintf('%J', obj);
	sendHead(conn, code, reason, [
		'Content-Type: application/json',
		'Content-Length: ' + length(body),
		'Connection: close',
	]);
	sendRaw(conn, body);
}

// ------------------------------------------------------------- request I/O

// Reads until the headers are complete, then until Content-Length is satisfied.
function readRequest(conn) {
	let buf = '';
	for (let i = 0; i < 4096; i++) {
		let chunk;
		try {
			chunk = conn.recv(4096);
		} catch (e) {
			break;
		}
		if (chunk == null || !length(chunk)) break;
		buf += chunk;

		const sep = index(buf, '\r\n\r\n');
		if (sep >= 0) {
			const h = splitResponse(buf);
			const want = (h && h.headers['content-length']) ? +h.headers['content-length'] : 0;
			if (length(h.body) >= want) break;
		}
	}
	return buf;
}

function parseRequest(raw) {
	const sep = index(raw, '\r\n\r\n');
	if (sep < 0) return null;
	const head = split(raw, '\r\n');
	const m = match(head[0], /^(\w+)\s+(\S+)/);
	if (!m) return null;

	const headers = {};
	for (let i = 1; i < length(head); i++) {
		const c = index(head[i], ':');
		if (c > 0) headers[lc(substr(head[i], 0, c))] = trim(substr(head[i], c + 1));
	}

	const url = m[2];
	const q = index(url, '?');
	return {
		method: m[1],
		path: (q >= 0) ? substr(url, 0, q) : url,
		query: (q >= 0) ? substr(url, q + 1) : '',
		headers,
		body: substr(raw, sep + 4),
	};
}

// -------------------------------------------------------------- auth check
// When share_token is set, every relay request must present it. The LuCI
// page and the token-polling endpoints are always local-trust.

function authorized(req, path) {
	if (index(path, '/v1/') != 0 && index(path, '/v1') != 0) return true;
	if (!length(CFG.share)) return true;
	const h = req.headers['authorization'] || '';
	const m = match(h, /^Bearer\s+(.+)$/i);
	const got = m ? trim(m[1]) : '';
	return got == CFG.share || got == CFG.token;
}

// ------------------------------------------------------------------ routes

function handleModels(conn, force) {
	const c = fetchModels(force);
	const data = [];
	for (let i = 0; i < length(c.list); i++)
		push(data, { id: c.list[i].id, object: 'model', owned_by: 'workbuddy' });
	sendJson(conn, 200, 'OK', { object: 'list', data });
}

function handleStatus(conn) {
	const c = fetchModels(false);
	sendJson(conn, 200, 'OK', {
		ok: true,
		hasToken: length(CFG.token) > 0,
		freeOnly: CFG.freeOnly,
		source: c.source,
		modelCount: length(c.list),
		allCount: c.all,
		freeCount: c.free,
		port: CFG.port,
	});
}

// Streams the upstream response straight through, preserving chunk framing.
function handleChat(conn, req) {
	if (!length(CFG.token))
		return sendJson(conn, 401, 'Unauthorized', { error: { message: 'no token configured', type: 'auth_error' } });

	const tmp = '/tmp/workbuddy-req.json';
	fs.writefile(tmp, req.body);

	// -N disables curl's internal buffering: essential for SSE passthrough.
	const p = fs.popen([ 'curl', '-sS', '-N', '--max-time', '300',
		'-X', 'POST',
		'-H', 'Content-Type: application/json',
		'-H', 'Accept: text/event-stream',
		'-H', 'User-Agent: WorkBuddy/' + CFG.cver,
		'-H', 'Authorization: Bearer ' + CFG.token,
		'--data-binary', '@' + tmp,
		CFG.endpoint + '/v1/chat/completions' ], 'r');

	if (!p) return sendJson(conn, 502, 'Bad Gateway', { error: { message: 'cannot spawn curl' } });

	// Upstream is always SSE; announce it and stream without buffering.
	// No Content-Length and no chunked framing: closing the socket marks EOF,
	// and HTTP/1.1 clients accept that for an event stream.
	sendHead(conn, 200, 'OK', [
		'Content-Type: text/event-stream; charset=utf-8',
		'Cache-Control: no-cache',
		'X-Accel-Buffering: no',
		'Connection: close',
	]);

	for (let line = p.read('line'); line != null; line = p.read('line'))
		sendRaw(conn, line);

	p.close();
}

// -------------------------------------------------------------- login flow
// Token acquisition mirrors the DSH plugin: ask WorkBuddy for a state,
// surface the authUrl, then poll for the token once the user logs in.

let pending = null;   // { state, authUrl, at }

function handleLoginStart(conn) {
	const r = splitResponse(curl([
		'-X', 'POST',
		'-H', 'Content-Type: application/json',
		'-H', 'X-No-Authorization: true',
		'-H', 'User-Agent: WorkBuddy/' + CFG.cver,
		CFG.endpoint + '/v2/plugin/auth/state?platform=CLI',
	]));

	if (!r || r.code != 200) {
		const msg = (r && r.body) ? r.body : 'request failed';
		return sendJson(conn, 502, 'Bad Gateway', { error: { message: msg } });
	}

	const j = jsonParse(r.body);
	if (!j || !j.state) return sendJson(conn, 502, 'Bad Gateway', { error: { message: 'no state returned' } });

	pending = { state: j.state, authUrl: j.authUrl || '', at: now() };
	sendJson(conn, 200, 'OK', { state: j.state, authUrl: j.authUrl || '', expiresIn: 300 });
}

function handleLoginPoll(conn, req) {
	if (!pending) return sendJson(conn, 400, 'Bad Request', { error: { message: 'no login in progress' } });

	const m = match(req.query, /(?:^|&)state=([^&]+)/);
	const state = m ? m[1] : pending.state;

	// The token endpoint authenticates by state alone; sending a stale bearer
	// token is at best useless and at worst rejected.
	const r = splitResponse(curl(wbHeaders().concat([
		CFG.endpoint + '/v2/plugin/auth/token?state=' + state,
	])));

	if (!r) return sendJson(conn, 502, 'Bad Gateway', { error: { message: 'request failed' } });

	const j = jsonParse(r.body);
	if (!j) return sendJson(conn, 502, 'Bad Gateway', { error: { message: 'bad response' } });

	// 11217 = still waiting for the user to finish logging in.
	if (j.code == 11217) return sendJson(conn, 200, 'OK', { status: 'waiting' });

	const t = j.data ? (j.data.accessToken || j.data.token) : (j.accessToken || j.token);
	if (!t) {
		const msg = j.msg || j.message || ('unexpected response, code ' + (j.code || 0));
		return sendJson(conn, 200, 'OK', { status: 'failed', message: msg });
	}

	// Persist through uci so the token survives a restart.
	fs.popen([ 'uci', 'set', 'workbuddy.main.access_token=' + t ], 'r');
	fs.popen([ 'uci', 'commit', 'workbuddy' ], 'r');

	CFG.token = t;
	pending = null;
	sendJson(conn, 200, 'OK', { status: 'ok', tokenLength: length(t) });
}

// ------------------------------------------------------------------ router

function route(conn, req) {
	const p = req.path;

	if (req.method == 'OPTIONS') {
		sendHead(conn, 204, 'No Content', [ 'Connection: close' ]);
		return;
	}

	if (p == '/v1/models' || p == '/models')      return handleModels(conn, false);
	if (p == '/models/refresh')                   return handleModels(conn, true);
	if (p == '/status')                           return handleStatus(conn);
	if (p == '/v1/chat/completions' ||
	    p == '/chat/completions')                 return handleChat(conn, req);
	if (p == '/login/start')                      return handleLoginStart(conn);
	if (p == '/login/poll')                       return handleLoginPoll(conn, req);

	sendJson(conn, 404, 'Not Found', { error: { message: 'no route ' + p } });
}

// ------------------------------------------------------------- server loop

uloop.init();

// socket.listen() wraps create+bind+listen (+ SO_REUSEADDR), which is exactly
// what is needed here; fs.open() only ever opens ordinary files.
let server = null;
try {
	server = socket.listen(CFG.host, CFG.port, null, 64, true);
} catch (e) {
	fprintf(stderr, '[workbuddy] cannot bind ' + CFG.host + ':' + CFG.port + ': ' + e + '\n');
	exit(1);
}

if (!server) {
	fprintf(stderr, '[workbuddy] cannot bind ' + CFG.host + ':' + CFG.port + ': ' + socket.error() + '\n');
	exit(1);
}

log('listening on ' + CFG.host + ':' + CFG.port);

uloop.handle(server, () => {
	let conn;
	try {
		conn = server.accept();
	} catch (e) {
		log('accept failed: ' + e);
		return;
	}
	if (!conn) return;

	try {
		const raw = readRequest(conn);
		const req = parseRequest(raw);

		if (!req)
			conn.close();
		else {
			if (!authorized(req, req.path))
				sendJson(conn, 401, 'Unauthorized', { error: { message: 'bad share token' } });
			else
				route(conn, req);

			conn.close();
		}
	} catch (e) {
		log('request failed: ' + e);
		try { conn.close(); } catch (e2) {}
	}
}, uloop.ULOOP_READ);

uloop.run();
