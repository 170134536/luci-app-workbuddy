#!/usr/bin/ucode
// ============================================================
// workbuddy.uc — WorkBuddy 免费模型 OpenAI 兼容代理（OpenWrt 原生实现）
//
// 在路由器上监听一个 HTTP 端口，把 WorkBuddy 的三条硬性要求适配成
// 标准 OpenAI 接口，供局域网设备（DSH / OpenAI 客户端）使用：
//   1. 只接受流式（非流式请求由本代理收集 SSE 后合并）
//   2. 首条消息必须是 system prompt（不是则自动插入）
//   3. 鉴权用 WorkBuddy 账号的 accessToken
//
// 架构说明：ucode 的 socket 模块没有 TLS 能力，因此上游 HTTPS 请求
// 统一交给 curl 子进程完成（fs.popen + uloop.handle 流式读取），
// 本进程只负责 HTTP 服务端与流式转发。
//
// 用法: ucode /usr/share/ucode/workbuddy.uc
// 配置: /etc/config/workbuddy (UCI)
// ============================================================

'use strict';

import { readfile, writefile, popen, access, mkdir, error, unlink } from 'fs';
import * as socket from 'socket';
import * as uloop from 'uloop';
import * as uci from 'uci';

// ---------- 日志 ----------
// 本 ucode 版本的 log 模块提供 syslog(level, fmt, ...)，没有 log.info()/log.err()。
// 这里统一输出到 stdout/stderr，由 init.d 重定向到 syslog，避免依赖具体 log API。
function logMsg(level, msg) {
	printf('[workbuddy] %s: %s\n', level, msg);
}
function logInfo(msg) { logMsg('info', msg); }
function logErr(msg) { logMsg('error', msg); }

// ---------- 常量 ----------

const LOG_TAG = 'workbuddy';
const APP_VERSION = '1.7.0';

// 产品显示名。集中在这里，改名字只需改这一处。
//
// 注意：这只是"对外可见的名字"，与内部标识符是两回事 ——
// UCI 配置节、init.d 服务名、ucode 模块名都仍叫 workbuddy，
// 因为 WorkBuddy 上游的登录流程、凭据池、已有配置文件都绑定在这些路径上。
// 改内部名需要数据迁移，且会打断正在运行的实例。
const APP_NAME = 'AI 中转服务器';

// 前向引用表：用于绕开 ucode 的函数不提升限制。
// 凡是「定义在文件靠后、但被靠前的函数调用」的函数，都挂在这里按需取用。
// 目前包含：runCurl（clientVersion 用）、spawnUpstream/tryNextCred/onUpstreamEnd
// （三者互相递归，纯排序无法解开）。
// 必须在任何使用它的函数之前声明：ucode 的顶层 let/const 同样不提升。
let F = {};

// ---------- 基础工具函数 ----------
//
// ucode 不提升函数，且按定义时的词法作用域解析标识符：
// 一个函数若调用「在文件中出现得更晚」的函数，运行时就会抛
// "access to undeclared variable <name>"。
// 因此所有被广泛复用的底层工具必须放在文件最前面，集中在这里。

// 取 sha256 十六进制（小写）。
// 注意：sha256 不是全局函数，必须 require('digest')；
// 直接调用 digest() 会报 "left-hand side is not a function"。
function sha256Hex(s) {
	let d = require('digest');
	return '' + d.sha256('' + s);
}

// 恒定时间比较，降低时序侧信道影响
function secureEq(a, b) {
	if (type(a) !== 'string' || type(b) !== 'string') return false;
	if (length(a) !== length(b)) return false;
	let diff = 0;
	for (let i = 0; i < length(a); i++)
		diff |= (ord(substr(a, i, 1)) ^ ord(substr(b, i, 1)));
	return diff === 0;
}

// 宽松布尔判断：前端与 rpcd 传来的可能是 1/0、"true"/"false"、
// 真布尔或 "on"/"yes"，统一归一。
function truthy(v) {
	return (v === true || v === 1 || v === '1' || v === 'true' ||
		v === 'on' || v === 'yes');
}

// 读系统熵；失败时用时间戳兜底（仍可用，只是熵弱一些）。
// open()/writefile() 在某些调用上下文里不是全局函数，必须走 fs 模块。
let keySeq = 0;

function readRandom(n) {
	try {
		let fs = require('fs');
		if (fs && type(fs.open) === 'function') {
			let f = fs.open('/dev/urandom', 'r');
			if (f) {
				let b = f.read(n);
				f.close();
				if (b && length(b) > 0) return b;
			}
		}
	} catch (e) {
		// 忽略，走兜底
	}
	return '' + time() + '.' + keySeq;
}

// 生成 wb-<8>-<4>-<4>-<4>-<12> 形式的密钥。
// 熵来源：时间戳 + 进程内自增计数 + /dev/urandom，再经 sha256 混合。
// rand()/getpid() 在这个 ucode 构建里不可用，不要使用。
function genApiKey() {
	keySeq++;
	let seed = '' + time() + '|' + keySeq + '|' + readRandom(32);
	let h = sha256Hex(seed);
	return 'wb-' + substr(h, 0, 8) + '-' + substr(h, 8, 4) + '-' +
		substr(h, 12, 4) + '-' + substr(h, 16, 4) + '-' + substr(h, 20, 12);
}

// 原子写 JSON：先写临时文件再 rename，避免掉电/中断留下半截文件。
// 权限 600，因为文件里有密钥与令牌。
// 注意：ucode 字符串没有 .replace()/.match() 方法，路径用 fs.dirname()。
function writeJsonFile(path, obj) {
	try {
		let fs = require('fs');
		let dir = fs.dirname(path);
		if (dir && dir !== '' && !fs.access(dir, 'f')) fs.mkdir(dir, 448);  // 0700

		let tmp = path + '.tmp';
		fs.writefile(tmp, sprintf('%.J\n', obj));
		fs.rename(tmp, path);
		try { fs.chmod(path, 384); } catch (e) { }  // 0600
		return true;
	} catch (e) {
		logErr('writeJsonFile failed for ' + path + ': ' + e);
		return false;
	}
}

function readJsonFile(path) {
	try {
		let fs = require('fs');
		if (!fs.access(path, 'f')) return null;
		let raw = fs.readfile(path);
		if (!raw) return null;
		return json(raw);
	} catch (e) {
		return null;
	}
}

const FREE_MODELS = ['deepseek-v4.1-flash', 'hy4-preview-f', 'hy3'];
const LOGIN_POLL_MS = 1000;
const LOGIN_TIMEOUT_MS = 300000;
const CODE_LOGIN_ING = 11217;

// ---------- JWT / 凭据检查 ----------
//
// WorkBuddy 的 accessToken 是标准 JWT（三段点分）。第二段 payload 里有：
//   exp                过期时间（Unix 秒）—— 用来做过期提示与自动跳过
//   preferred_username 账号名 —— 用来给凭据起可读名字
//   sub                账号唯一 ID —— 用来识别同一账号的重复凭据
//
// ucode 既没有 base64 模块，也没有全局 b64dec/popen，所以这里自己实现
// base64url 解码。只需要「解码」，不需要编码。

const B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

// 建一个字符 -> 6bit 值的查找表（只建一次）
let b64Table = null;

function b64Index(ch) {
	if (b64Table === null) {
		b64Table = {};
		for (let i = 0; i < length(B64_CHARS); i++)
			b64Table[substr(B64_CHARS, i, 1)] = i;
	}
	if (type(b64Table[ch]) === 'int') return b64Table[ch];
	return -1;
}

// base64url 解码为字符串。忽略 padding 与非法字符。
// 只用于解析 JWT 头部与 payload（都是 UTF-8 JSON），够用即可。
function b64UrlDecode(s) {
	if (type(s) !== 'string') return '';
	let out = '';
	let buf = 0;
	let bits = 0;

	for (let i = 0; i < length(s); i++) {
		let ch = substr(s, i, 1);
		if (ch === '=') break;            // padding 之后不再有数据
		if (ch === '-') ch = '+';         // base64url 还原
		if (ch === '_') ch = '/';
		let v = b64Index(ch);
		if (v < 0) continue;              // 跳过换行等杂字符

		buf = (buf << 6) | v;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			let byte = (buf >> bits) & 0xff;
			out += chr(byte);
		}
	}
	return out;
}

// 解析 JWT，返回 { exp, iat, username, sub } 或 null。
// 完全不验签：这里的用途只是读过期时间与账号名，不做安全判断。
function parseJwt(token) {
	if (type(token) !== 'string' || length(token) === 0) return null;

	// 按点号切三段
	let parts = [];
	let cur = '';
	for (let i = 0; i < length(token); i++) {
		let ch = substr(token, i, 1);
		if (ch === '.') {
			push(parts, cur);
			cur = '';
		} else {
			cur += ch;
		}
	}
	push(parts, cur);
	if (length(parts) < 2) return null;

	let payload;
	try {
		payload = json(b64UrlDecode(parts[1]));
	} catch (e) {
		return null;
	}
	if (type(payload) !== 'object' || payload === null) return null;

	let out = {};
	out.exp = (type(payload.exp) === 'int') ? payload.exp : 0;
	out.iat = (type(payload.iat) === 'int') ? payload.iat : 0;
	out.username = '' + (payload.preferred_username || payload.email || '');
	out.sub = '' + (payload.sub || '');
	return out;
}

// 凭据状态：'ok' | 'expiring'（7 天内过期）| 'expired' | 'unknown'
function credStatus(token, now) {
	let j = parseJwt(token);
	if (j === null || !j.exp) return 'unknown';
	if (j.exp <= now) return 'expired';
	if (j.exp - now < 7 * 86400) return 'expiring';
	return 'ok';
}

// 凭据池文件：单个 JSON 保存多条凭据
// 注意：ucode 没有 opendir/readdir，无法遍历目录，因此池必须放在一个文件里。
const TOKEN_POOL_FILE = '/etc/workbuddy/pool.json';
// API 密钥文件：由 LuCI 通过 rpcd 维护
const APIKEY_FILE = '/etc/workbuddy/apikeys.json';
// WorkBuddy 自身上游在模型列表里的供应商前缀。
// 所有来源统一带前缀，客户端可据此选择走哪个上游。
const WB_PREFIX = 'workbuddy';
// 凭据冷却时长（秒）：被限流/拒绝后暂不使用
const COOL_MS = 60;
// 单个请求最多尝试的凭据数
const MAX_TRY = 3;

// ---------- 管理页会话 ----------
//
// 设计取舍（对照 edgetunnel 的实现做了三处修正）：
//   1. edgetunnel 的 Cookie = MD5(UA + 秘钥 + 密码)，绑定 User-Agent。
//      UA 完全由客户端控制，安全增益约等于零，副作用却是换浏览器/UA 升级
//      就掉线。这里不参与派生。
//   2. edgetunnel 用无盐 MD5，Cookie 值恒定、不随会话或时间变化，也无法撤销。
//      这里改为 sha256 派生，且 Cookie 值内嵌过期时间戳并参与签名，
//      服务端真正校验过期，改密码即全量失效。
//   3. 这里不设 Secure 属性：管理页通过 http 访问路由器，带 Secure 的
//      Cookie 不会被浏览器回传，会导致“密码正确但一直登录不上”且毫无提示。
const ADMIN_COOKIE = 'wb_admin';
const ADMIN_TTL = 86400;        // 会话有效期（秒）
const ADMIN_MAX_FAIL = 8;       // 同一 IP 连续失败上限
const ADMIN_LOCK_SEC = 300;     // 触发上限后的锁定时长（秒）
// 管理员密码专属盐；密码本身由 LuCI 写入 UCI
const ADMIN_SALT = 'luci-app-workbuddy/admin/v1';

// 客户端版本探测源（按顺序尝试，任一成功即用）。
// 说明：WorkBuddy 官方没有公开的版本清单接口 —— /v3/config 里只有插件市场的
// versionUrl，与客户端 UA 无关；download.codebuddy.cn/version.json 是 CodeBuddy
// 的清单（4 段式版本、无 windows-x64），不能直接当 WorkBuddy 版本用。
// 因此这里采用「多源探测 + 自校准」：探测源给出候选，同时记录上游实际接受过的
// 最高版本，避免把版本号写死在某一次发布上。
const VERSION_SOURCES = [
	'https://www.workbuddy.ai/api/version',
	'https://www.workbuddy.ai/version.json',
];
const VERSION_FILE = '/etc/workbuddy/version.json';
const VERSION_TTL = 21600;      // 版本缓存 6 小时
const VERSION_FLOOR = '5.5.2';  // 已知可用下限，探测全失败时回退到这里

// ---------- 配置读取 ----------

function rtrim(s, ch) {
	while (length(s) > 0 && substr(s, length(s) - 1) === ch)
		s = substr(s, 0, length(s) - 1);
	return s;
}

function loadConfig() {
	let cfg = {
		enabled: '1',
		port: 8789,
		host: '0.0.0.0',
		endpoint: 'https://www.workbuddy.ai',
		share_token: '',
		client_version: '5.5.2',
		auto_client_version: '1',
		admin_password: '',
		token_file: '/etc/workbuddy/token.json',
		only_free_models: '1',
		wan_access: '0',
		wan_port: '',
		debug: '0',
	};

	let ctx = uci.cursor();
	let all = ctx.get_all('workbuddy') || {};
	let main = all.main || {};

	for (let k in main) {
		if (main[k] === '' || main[k] === null) continue;
		cfg[k] = main[k];
	}

	cfg.port = +cfg.port || 8789;
	cfg.endpoint = rtrim('' + cfg.endpoint, '/');
	cfg.enabled = (('' + cfg.enabled) !== '0');
	cfg.onlyFree = (('' + cfg.only_free_models) !== '0');
	cfg.autoVersion = (('' + cfg.auto_client_version) !== '0');
	// 公网访问默认关闭。只有显式写 '1' 才算开，避免历史配置缺项被误判成开。
	cfg.wanAccess = (('' + cfg.wan_access) === '1');
	// 外部端口（公网侧监听端口）。合法 1–65535 才采用，否则回退到内部端口。
	// 这样即使 UCI 里写了个脏值也不会把防火墙规则写坏。
	{
		let wp = +cfg.wan_port;
		cfg.wanPort = (wp >= 1 && wp <= 65535) ? wp : cfg.port;
	}
	cfg.adminPass = '' + (cfg.admin_password || '');

	return cfg;
}

// ---------- token 管理（兼容单文件旧格式） ----------

function tokenPath(cfg) {
	return cfg.token_file || '/etc/workbuddy/token.json';
}

// readJsonFile / writeJsonFile 定义在文件顶部的「基础工具函数」区，
// 那里是唯一允许放置底层工具的位置（ucode 不提升函数）。

function getToken(cfg) {
	let j = readJsonFile(tokenPath(cfg));
	if (!j) return null;
	let t = j.accessToken;
	if (type(t) !== 'string' || length(t) === 0) return null;
	return t;
}

function saveToken(cfg, accessToken, refreshToken) {
	let payload = {
		accessToken: accessToken,
		syncedAt: time(),
	};
	if (refreshToken) payload.refreshToken = refreshToken;

	if (!writeJsonFile(tokenPath(cfg), payload)) {
		logErr('token save failed');
		return false;
	}
	logInfo('token saved to ' + tokenPath(cfg));
	return true;
}

// ---------- 凭据池（多账号轮询） ----------
//
// 凭据来源有两处，合并成一个池：
//   1. TOKEN_POOL_FILE  —— { credentials: [{id,name,accessToken,syncedAt}] }
//   2. token_file       —— 旧版单凭据文件，保持兼容
//
// 池中每个条目记录冷却截止时间，被上游限流后自动跳过，
// 冷却结束自动恢复，无需人工干预。
//
// 注意：ucode 没有 opendir/readdir，所以池必须集中在单个 JSON 文件里，
// 不能像常见做法那样一条凭据一个文件。

let credState = {};   // id -> { coolUntil: <ts>, fails: <n>, lastErr: <str> }
let credCursor = 0;   // 轮询游标

// 读池文件的原始条目（含禁用项，不去重），供管理页展示与编辑。
function readPoolRaw() {
	let j = readJsonFile(TOKEN_POOL_FILE);
	if (!j || type(j.credentials) !== 'array') return [];
	let out = [];
	for (let c in j.credentials) {
		if (type(c) !== 'object' || c === null) continue;
		if (type(c.accessToken) !== 'string' || length(c.accessToken) === 0) continue;
		push(out, c);
	}
	return out;
}

function savePoolRaw(list) {
	return writeJsonFile(TOKEN_POOL_FILE, { credentials: list });
}

function findPoolById(id) {
	for (let c in readPoolRaw())
		if (('' + (c.id || '')) === ('' + id)) return c;
	return null;
}

// 新增一条凭据。返回 { ok, id } 或 { ok:false, error, dup }。
//
// 去重分两层：
//   1) token 完全相同 -> 重复
//   2) 同一账号（JWT 的 sub 相同）-> 也视为重复
// 第 2 条是有意的：同一账号存多份没有任何负载均衡收益，
// 反而会让人误以为"已经配了多个账号"。
//
// 注意：去重必须同时覆盖 pool.json 和 token.json 两处存储。
// 只查 pool.json 会漏掉"网页登录凭据"——而那恰恰是用户最容易
// 复制过来重复添加的一条。
function addPoolCred(name, token, cfg) {
	token = trim('' + (token || ''));
	if (length(token) < 20)
		return { ok: false, error: '凭据内容过短，请粘贴完整的 access token' };

	// 去掉可能粘进来的 "Bearer " 前缀与首尾引号
	token = replace(token, 'Bearer ', '');
	token = replace(token, 'bearer ', '');
	token = trim(token);
	if (substr(token, 0, 1) === '"' && substr(token, length(token) - 1) === '"')
		token = substr(token, 1, length(token) - 2);
	token = trim(token);

	// 候选集合：池文件条目 + 网页登录凭据
	// 注意：ucode 的数组没有 .push() 方法，必须用全局 push(a, v)
	let candidates = [];
	for (let c in readPoolRaw()) {
		push(candidates, {
			id: '' + (c.id || ''),
			name: '' + (c.name || ''),
			token: '' + (c.accessToken || ''),
		});
	}
	if (cfg) {
		let lt = getToken(cfg);
		if (lt && length(lt) > 0)
			push(candidates, { id: 'default', name: '网页登录凭据', token: lt });
	}

	let info = parseJwt(token);
	let sub = info ? info.sub : '';

	// 必须是一个能解析出 payload 的 JWT。
	//
	// 这里刻意严格：WorkBuddy 的 access token 一定是三段点分的 JWT，
	// payload 里带 exp。放行解析失败的字符串只会让用户以为加成功了，
	// 实际轮询时才失败，反而更难排查。所以解析不出来就直接拒绝。
	if (info === null) {
		return {
			ok: false,
			error: '这不是有效的 access token：应为三段点分的 JWT，且能解析出 payload',
		};
	}
	if (info.exp && info.exp <= time()) {
		return { ok: false, expired: true, error: '该凭据已过期，请重新登录获取新的 token' };
	}

	for (let c in candidates) {
		if (c.token === token) {
			return {
				ok: false, dup: true,
				error: '该凭据已存在（内容完全相同）',
				existingId: c.id, existingName: c.name,
			};
		}
		if (length(sub) > 0) {
			let ci = parseJwt(c.token);
			if (ci && length(ci.sub) > 0 && ci.sub === sub) {
				return {
					ok: false, dup: true,
					error: '该账号已在池中（同一账号无需重复添加）',
					existingId: c.id, existingName: c.name,
				};
			}
		}
	}

	let list = readPoolRaw();

	// id 用时间戳；同秒内连续添加会撞号，补 -N 保证唯一
	let base = 'c' + time();
	let id = base;
	let n = 1;
	let taken = {};
	for (let c in list) taken['' + (c.id || '')] = true;
	while (taken[id]) { id = base + '-' + n; n++; }

	let nm = trim('' + (name || ''));
	if (length(nm) === 0)
		nm = (info && length(info.username) > 0) ? info.username : ('凭据 ' + (length(list) + 1));

	push(list, {
		id: id,
		name: nm,
		accessToken: token,
		enabled: true,
		syncedAt: time(),
	});
	if (!savePoolRaw(list))
		return { ok: false, error: '写入凭据池失败' };

	logInfo('pool credential added: ' + id + ' (' + nm + ')');
	return { ok: true, id: id, name: nm };
}

function deletePoolCred(id) {
	let list = readPoolRaw();
	let next = [];
	let hit = false;
	for (let c in list) {
		if (('' + (c.id || '')) === ('' + id)) { hit = true; continue; }
		push(next, c);
	}
	if (!hit) return false;
	// 一并清掉它的冷却状态
	delete credState[id];
	return savePoolRaw(next);
}

function togglePoolCred(id, enabled) {
	let list = readPoolRaw();
	let hit = false;
	for (let c in list) {
		if (('' + (c.id || '')) === ('' + id)) { c.enabled = enabled ? true : false; hit = true; }
	}
	if (!hit) return false;
	return savePoolRaw(list);
}

function loadPool(cfg) {
	let pool = [];
	let seen = {};
	let seenSub = {};
	let now = time();

	// 同一个账号只保留第一条：跨 pool.json 与 token.json 去重。
	// 已有去重只按 token 全文比较，但同一账号的 token 会随刷新而变
	// （jti/iat 不同），所以还要按 JWT 的 sub 再判一次。
	function take(id, name, t, source, syncedAt) {
		if (type(t) !== 'string' || length(t) === 0) return false;
		if (seen[t]) return false;

		// 已过期的凭据直接跳过，避免轮询把请求浪费在死 token 上。
		// 状态仍会在管理页显示，用户能看到并更换。
		if (credStatus(t, now) === 'expired') return false;

		let info = parseJwt(t);
		let sub = (info && length(info.sub) > 0) ? info.sub : '';
		if (length(sub) > 0) {
			if (seenSub[sub]) return false;
			seenSub[sub] = true;
		}

		seen[t] = true;
		push(pool, { id: id, name: name, token: t, source: source, syncedAt: syncedAt || 0 });
		return true;
	}

	// 1) 主池文件
	let j = readJsonFile(TOKEN_POOL_FILE);
	let creds = (j && type(j.credentials) === 'array') ? j.credentials : [];
	for (let c in creds) {
		if (type(c) !== 'object' || c === null) continue;
		if (c.enabled === false) continue;
		take('' + (c.id || ('cred' + (length(pool) + 1))), '' + (c.name || ''),
			c.accessToken, 'pool', c.syncedAt);
	}

	// 2) 旧版单文件凭据（兼容）
	let legacy = getToken(cfg);
	if (legacy) {
		let lj = readJsonFile(tokenPath(cfg)) || {};
		take('default', '默认凭据', legacy, 'legacy', lj.syncedAt);
	}

	return pool;
}

// 仅取当前可用的凭据（跳过冷却中的），按轮询顺序返回
function usablePool(cfg) {
	let pool = loadPool(cfg);
	let now = time();
	let ok = [];
	for (let c in pool) {
		let st = credState[c.id];
		if (st && st.coolUntil > now) continue;
		push(ok, c);
	}

	// 全部冷却中：退回冷却最早结束的那个，避免完全不可用
	if (length(ok) === 0 && length(pool) > 0) {
		let best = pool[0];
		for (let c in pool) {
			let a = credState[c.id] ? credState[c.id].coolUntil : 0;
			let b = credState[best.id] ? credState[best.id].coolUntil : 0;
			if (a < b) best = c;
		}
		push(ok, best);
	}

	// 从游标处轮转，实现轮流使用
	if (length(ok) > 1) {
		let n = length(ok);
		let start = credCursor % n;
		let rotated = [];
		for (let i = 0; i < n; i++)
			push(rotated, ok[(start + i) % n]);
		credCursor = (credCursor + 1) % n;
		ok = rotated;
	}

	return ok;
}

// 标记凭据异常并进入冷却
function markCredFail(cfg, id, reason) {
	let now = time();
	let st = credState[id] || { coolUntil: 0, fails: 0, lastErr: '' };
	st.fails = (st.fails || 0) + 1;
	// 连续失败则指数退避，上限 10 分钟
	let cool = COOL_MS;
	for (let i = 1; i < st.fails && cool < 600; i++) cool *= 2;
	st.coolUntil = now + cool;
	st.lastErr = '' + reason;
	credState[id] = st;
	logErr(sprintf('credential %s cooling down %ds: %s', id, cool, reason));
}

function markCredOk(id) {
	if (!credState[id]) return;
	credState[id].fails = 0;
	credState[id].coolUntil = 0;
	credState[id].lastErr = '';
}

// 取一个当前可用的凭据 token 字符串（供模型列表等非重试场景使用）
function pickToken(cfg) {
	let pool = usablePool(cfg);
	if (length(pool) === 0) return null;
	return pool[0].token;
}

// ---------- API 密钥 ----------
//
// 与上游凭据是两层不同的东西：
//   上游凭据 = WorkBuddy 账号 token（我们调用上游用）
//   API 密钥 = 我们发给客户端用（客户端调用本代理用）

function loadApiKeys() {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') return [];
	let out = [];
	for (let k in j.keys) {
		if (type(k) !== 'object' || k === null) continue;
		if (type(k.key) !== 'string' || length(k.key) === 0) continue;
		if (k.enabled === false) continue;
		push(out, { id: '' + (k.id || ''), name: '' + (k.name || ''), key: k.key });
	}
	return out;
}

// 只要密钥文件里定义过任何一条密钥就算“已配置鉴权”，
// 不论它当前是启用还是禁用。
// 注意：这里刻意不看 enabled —— 否则禁用掉最后一条密钥会让
// authRequired 变成 false，整个代理直接对公网敞开，这是危险的默认行为。
function apiKeysDefined() {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') return 0;
	let n = 0;
	for (let k in j.keys) {
		if (type(k) !== 'object' || k === null) continue;
		if (type(k.key) !== 'string' || length(k.key) === 0) continue;
		n++;
	}
	return n;
}

function hasApiKeys() {
	return apiKeysDefined() > 0;
}

// 列出全部密钥（含禁用项与明文值），供管理页随时查看/复制。
// 明文本来就必须存在 apikeys.json 里才能做校验，所以"只显示一次"只是
// 界面上的选择，不是存储限制 —— 这里把完整值提供给已登录的管理页。
function listApiKeysFull() {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') return [];
	let out = [];
	for (let k in j.keys) {
		if (type(k) !== 'object' || k === null) continue;
		if (type(k.key) !== 'string' || length(k.key) === 0) continue;
		push(out, {
			id: '' + (k.id || ''),
			name: '' + (k.name || ''),
			key: k.key,
			enabled: (k.enabled !== false),
			createdAt: +k.createdAt || 0,
		});
	}
	return out;
}

// 生成一条新密钥并落盘，返回该密钥对象。
// genApiKey()/readRandom() 定义在文件顶部基础工具区。

function saveApiKeysFile(j) {
	if (!writeJsonFile(APIKEY_FILE, j)) {
		logErr('apikey save failed');
		return false;
	}
	return true;
}

function addApiKey(name) {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') j = { keys: [] };

	let nm = trim('' + (name || ''));
	if (length(nm) === 0) nm = '未命名';

	// id 用时间戳；同一秒内连续创建会撞号，因此补 -N 后缀保证唯一
	let base = 'k' + time();
	let id = base;
	let n = 1;
	let taken = {};
	for (let k in j.keys) if (type(k) === 'object' && k !== null) taken['' + (k.id || '')] = true;
	while (taken[id]) {
		id = base + '-' + n;
		n++;
	}

	let entry = {
		id: id,
		name: nm,
		key: genApiKey(),
		enabled: true,
		createdAt: time(),
	};
	push(j.keys, entry);
	if (!saveApiKeysFile(j)) return null;
	logInfo('api key added: ' + id + ' (' + nm + ')');
	return entry;
}

function deleteApiKey(id) {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') return false;
	let out = [];
	let hit = false;
	for (let k in j.keys) {
		if (type(k) === 'object' && k !== null && ('' + (k.id || '')) === ('' + id)) {
			hit = true;
			continue;
		}
		push(out, k);
	}
	if (!hit) return false;
	j.keys = out;
	return saveApiKeysFile(j);
}

function toggleApiKey(id, enabled) {
	let j = readJsonFile(APIKEY_FILE);
	if (!j || type(j.keys) !== 'array') return false;
	let hit = false;
	for (let k in j.keys) {
		if (type(k) === 'object' && k !== null && ('' + (k.id || '')) === ('' + id)) {
			k.enabled = enabled ? true : false;
			hit = true;
		}
	}
	if (!hit) return false;
	return saveApiKeysFile(j);
}

// ---------- 自定义上游（多 API 地址 + 多 Key 轮询） ----------
//
// 背景：WorkBuddy 本身是一个上游（走登录凭据池）。本模块让用户再挂若干个
// 第三方 OpenAI 兼容上游（例如日日新 sensenova、点点 askdiandian），
// 每个上游配多条 Key，效果对齐 dsh-free-models-hub 的 keypools：
//
//   "targets": { "sensenova": "https://token.sensenova.cn/v1", ... }
//   "keyPools": { "sensenova": ["sk-a", "sk-b"], ... }
//
// 模型列表里所有来源都带供应商前缀，客户端一眼能看出模型来自哪：
//     workbuddy/deepseek-v4.1-flash      ← 本机 WorkBuddy 自身
//     sensenova/deepseek-v4-flash        ← 自定义上游
//     askdiandian/dots3-note-prev        ← 自定义上游
//
// 存储：/etc/workbuddy/upstreams.json（与 apikeys.json 并列，权限 0600）
//
// 为什么不复用凭据池：凭据池是"WorkBuddy 账号 token"，轮询的是账号；
// 上游池轮询的是不同厂商的 key，冷却与失败语义都不同，混在一起会互相污染。
const UPSTREAM_FILE = '/etc/workbuddy/upstreams.json';
// 自定义上游 Key 的冷却时长（秒）
const UP_COOL_SEC = 60;

// 上游池轮询游标：按上游分别记录，避免多上游互相打乱节奏
let upCursor = {};

// 日志与页面里都不应出现完整 Key，只留头尾便于辨认。
// 必须定义在所有调用点之前 —— ucode 函数不提升（踩坑记录 #12）。
function maskKey(k) {
	let s = '' + (k || '');
	if (length(s) <= 10) return '***';
	return substr(s, 0, 6) + '…' + substr(s, length(s) - 4, 4);
}

// 读取上游配置。返回数组，每条形如：
//   { id, name, prefix, baseUrl, keys: [...], enabled, createdAt }
function loadUpstreams() {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') return [];
	let out = [];
	for (let u in j.upstreams) {
		if (type(u) !== 'object' || u === null) continue;

		let id = '' + (u.id || '');
		let prefix = '' + (u.prefix || '');
		let baseUrl = '' + (u.baseUrl || '');
		if (length(id) === 0 || length(prefix) === 0 || length(baseUrl) === 0) continue;

		// Key 统一清洗成字符串数组，过滤空值与重复
		let keys = [];
		let seen = {};
		if (type(u.keys) === 'array') {
			for (let k in u.keys) {
				if (type(k) !== 'string') continue;
				let t = trim(k);
				if (length(t) === 0) continue;
				if (seen[t]) continue;
				seen[t] = true;
				push(keys, t);
			}
		}

		push(out, {
			id: id,
			name: '' + (u.name || prefix),
			prefix: prefix,
			baseUrl: baseUrl,
			keys: keys,
			enabled: (u.enabled !== false),
			createdAt: +u.createdAt || 0,
		});
	}
	return out;
}

// 上游健康状态：仅存内存，重启即清（冷却本来就不该跨重启持久化）
let upState = {};

function saveUpstreamsFile(j) {
	if (!writeJsonFile(UPSTREAM_FILE, j)) {
		logErr('upstream save failed');
		return false;
	}
	return true;
}

// 校验上游地址：只允许 http/https，且必须以 /v1 之类路径结尾。
// 返回规范化后的地址（去掉结尾多余的 /v1/ 重复斜杠），非法返回 null。
function normalizeBaseUrl(raw) {
	let u = trim('' + (raw || ''));
	if (length(u) === 0) return null;
	if (length(u) > 512) return null;

	let low = lc(u);
	if (substr(low, 0, 7) !== 'http://' && substr(low, 0, 8) !== 'https://') return null;

	// 去掉结尾斜杠，避免拼出 //v1/chat/completions
	while (length(u) > 0 && substr(u, length(u) - 1, 1) === '/')
		u = substr(u, 0, length(u) - 1);

	if (length(u) < 12) return null;
	return u;
}

// 规范化供应商前缀：小写字母数字与 - _，长度 2-32。
// 前缀会出现在模型名里，因此必须限制字符集，否则会破坏 "前缀/模型" 的切分。
function normalizePrefix(raw) {
	let p = lc(trim('' + (raw || '')));
	if (length(p) < 2 || length(p) > 32) return null;
	for (let i = 0; i < length(p); i++) {
		let ch = substr(p, i, 1);
		let ok = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch === '-' || ch === '_';
		if (!ok) return null;
	}
	// 不能含斜杠（切分符），上面字符集已排除
	return p;
}

// 取当前可用的 Key（跳过冷却中的），按轮询顺序返回。
// 逻辑与凭据池的 usablePool 保持一致，便于维护者对照理解。
function usableUpKeys(up) {
	let now = time();
	let ok = [];
	for (let k in up.keys) {
		let st = upState[up.id + '|' + k];
		if (st && st.coolUntil > now) continue;
		push(ok, k);
	}

	// 全部冷却中：退回冷却最早结束的那条，避免完全不可用
	if (length(ok) === 0 && length(up.keys) > 0) {
		let best = up.keys[0];
		let bestUntil = upState[up.id + '|' + best] ? upState[up.id + '|' + best].coolUntil : 0;
		for (let k in up.keys) {
			let st = upState[up.id + '|' + k];
			let cu = st ? st.coolUntil : 0;
			if (cu < bestUntil) {
				best = k;
				bestUntil = cu;
			}
		}
		push(ok, best);
	}

	// 从游标处轮转
	if (length(ok) > 1) {
		let n = length(ok);
		let start = (upCursor[up.id] || 0) % n;
		let rotated = [];
		for (let i = 0; i < n; i++)
			push(rotated, ok[(start + i) % n]);
		upCursor[up.id] = (start + 1) % n;
		ok = rotated;
	}

	return ok;
}

function markUpKeyFail(up, key, reason) {
	let now = time();
	let id = up.id + '|' + key;
	let st = upState[id] || { coolUntil: 0, fails: 0, lastErr: '' };
	st.fails = (st.fails || 0) + 1;
	// 连续失败指数退避，上限 10 分钟（与凭据池一致）
	let cool = UP_COOL_SEC;
	for (let i = 1; i < st.fails && cool < 600; i++) cool *= 2;
	st.coolUntil = now + cool;
	st.lastErr = '' + reason;
	upState[id] = st;
	logErr(sprintf('upstream %s key %s cooling %ds: %s',
		up.prefix, maskKey(key), cool, reason));
}

function markUpKeyOk(up, key) {
	let id = up.id + '|' + key;
	if (!upState[id]) return;
	upState[id].fails = 0;
	upState[id].coolUntil = 0;
	upState[id].lastErr = '';
}

// 按前缀查找已启用的自定义上游
function findUpstreamByPrefix(prefix) {
	let list = loadUpstreams();
	for (let u in list) {
		if (u.enabled && u.prefix === prefix) return u;
	}
	return null;
}

// 拉取某个自定义上游的模型列表。
// 返回 [{ id }]；失败返回空数组（不让一个挂掉的上游拖垮整个 /v1/models）。
//
// 注意：这里不能调用 shquote() —— 它定义在本文件靠后的位置（约第 1682 行），
// 而 ucode 函数不提升，此处调用会抛
// "Reference error: access to undeclared variable"（踩坑记录 #12）。
// 因此就近定义一个等价的私有引号函数。
function q(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function fetchUpstreamModels(up) {
	let keys = usableUpKeys(up);
	if (length(keys) === 0) return [];

	let key = keys[0];
	let cmd = join(' ', [
		'curl', '-sS', '-m', '12', '-4',
		'-H', q('Authorization: Bearer ' + key),
		q(up.baseUrl + '/models'),
	]);

	let body = '';
	try {
		let p = popen(cmd, 'r');
		if (p) body = p.read('all') || '';
	} catch (e) {
		markUpKeyFail(up, key, 'models fetch failed: ' + e);
		return [];
	}

	let j = null;
	try { j = json(body); } catch (e) { j = null; }
	if (!j || type(j.data) !== 'array') {
		// 401/403 说明 Key 有问题；其它情况（限流/网络）也给冷却
		let why = 'models returned non-list';
		if (index(body, 'Authorization') >= 0 || index(body, 'invalid') >= 0)
			why = 'models auth failed';
		markUpKeyFail(up, key, why);
		return [];
	}

	markUpKeyOk(up, key);

	let out = [];
	for (let m in j.data) {
		if (type(m) !== 'object' || m === null) continue;
		let mid = '' + (m.id || '');
		if (length(mid) === 0) continue;
		push(out, { id: mid });
	}
	return out;
}

// 把 "供应商/模型" 切分为 { prefix, model }。
// 无斜杠返回 null（表示走 WorkBuddy 自身上游）。
//
// 注意：这里刻意不用 match()。实测 ucode 的 match() 只接受正则字面量
// /.../，传字符串模式即使能匹配也返回 null（踩坑记录 #10）。
// index+substr 更直观，也没有这个陷阱。
function splitModelRef(model) {
	let m = '' + (model || '');
	let p = index(m, '/');
	if (p <= 0) return null;
	let prefix = lc(substr(m, 0, p));
	let rest = substr(m, p + 1);
	if (length(rest) === 0) return null;
	return { prefix: prefix, model: rest };
}

function addUpstream(name, prefix, baseUrl, keysText) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') j = { upstreams: [] };

	let nm = trim('' + (name || ''));
	let pf = normalizePrefix(prefix);
	let url = normalizeBaseUrl(baseUrl);

	if (pf === null) return { ok: false, error: '前缀非法：只能用小写字母/数字/-/_，长度 2-32' };
	if (url === null) return { ok: false, error: 'API 地址非法：必须是 http:// 或 https:// 开头' };

	// 前缀不能与已有上游重复，否则路由会有歧义
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && lc('' + (u.prefix || '')) === pf)
			return { ok: false, error: '前缀「' + pf + '」已被占用' };
	}

	// Key 按行拆分（与 dsh-free-models-hub 的粘贴方式一致）。
	// 注意：ucode 的签名是 split(subject, separator)，与 JS 的 str.split(sep)
	// 方向相反。写成 split('\n', text) 会按字面字符 'n' 切分并返回单元素数组，
	// 表现为"粘了一堆 Key 却提示至少需要一条"（踩坑记录 #13）。
	let keys = [];
	let seen = {};
	let lines = split('' + (keysText || ''), '\n');
	for (let ln in lines) {
		let t = trim(ln);
		if (length(t) === 0) continue;
		if (seen[t]) continue;
		seen[t] = true;
		push(keys, t);
	}
	if (length(keys) === 0) return { ok: false, error: '至少需要一条 Key' };

	let base = 'u' + time();
	let id = base;
	let n = 1;
	let taken = {};
	for (let u in j.upstreams) if (type(u) === 'object' && u !== null) taken['' + (u.id || '')] = true;
	while (taken[id]) { id = base + '-' + n; n++; }

	let entry = {
		id: id,
		name: (length(nm) > 0 ? nm : pf),
		prefix: pf,
		baseUrl: url,
		keys: keys,
		enabled: true,
		createdAt: time(),
	};
	push(j.upstreams, entry);
	if (!saveUpstreamsFile(j)) return { ok: false, error: '写入失败' };
	logInfo(sprintf('upstream added: %s -> %s (%d keys)', pf, url, length(keys)));
	return { ok: true, upstream: entry };
}

function deleteUpstream(id) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') return false;
	let out = [];
	let hit = false;
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && ('' + (u.id || '')) === ('' + id)) {
			hit = true;
			continue;
		}
		push(out, u);
	}
	if (!hit) return false;
	j.upstreams = out;
	// 顺手清掉该上游的内存态，避免删除后残留冷却记录。
	// 注意：ucode 不支持 `delete obj[key]`（会报
	// "left-hand side expression is not an object"），
	// 因此改用"重建表"的方式剔除，踩坑记录 #11。
	let keep = {};
	let pfx = '' + id + '|';
	for (let k in upState) {
		if (substr(k, 0, length(pfx)) !== pfx) keep[k] = upState[k];
	}
	upState = keep;
	return saveUpstreamsFile(j);
}

function toggleUpstream(id, enabled) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') return false;
	let hit = false;
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && ('' + (u.id || '')) === ('' + id)) {
			u.enabled = enabled ? true : false;
			hit = true;
		}
	}
	if (!hit) return false;
	return saveUpstreamsFile(j);
}

// 替换某个上游的 Key 组（管理页"编辑 Key"用）
function setUpstreamKeys(id, keysText) {
	let j = readJsonFile(UPSTREAM_FILE);
	if (!j || type(j.upstreams) !== 'array') return { ok: false, error: '无上游配置' };

	let keys = [];
	let seen = {};
	// split(subject, separator) —— 顺序不能反，见 addUpstream 的说明
	let lines = split('' + (keysText || ''), '\n');
	for (let ln in lines) {
		let t = trim(ln);
		if (length(t) === 0) continue;
		if (seen[t]) continue;
		seen[t] = true;
		push(keys, t);
	}
	if (length(keys) === 0) return { ok: false, error: '至少需要一条 Key' };

	let hit = false;
	for (let u in j.upstreams) {
		if (type(u) === 'object' && u !== null && ('' + (u.id || '')) === ('' + id)) {
			u.keys = keys;
			hit = true;
		}
	}
	if (!hit) return { ok: false, error: '上游不存在' };
	if (!saveUpstreamsFile(j)) return { ok: false, error: '写入失败' };
	return { ok: true, count: length(keys) };
}

// 上游状态汇总（给管理页用，不含 Key 明文）
function upstreamStatus() {
	let list = loadUpstreams();
	let now = time();
	let out = [];
	for (let u in list) {
		let keys = [];
		let usable = 0;
		for (let k in u.keys) {
			let st = upState[u.id + '|' + k];
			let cool = (st && st.coolUntil > now) ? (st.coolUntil - now) : 0;
			if (cool === 0) usable++;
			push(keys, {
				masked: maskKey(k),
				cooling: cool,
				fails: st ? (st.fails || 0) : 0,
				lastErr: st ? (st.lastErr || '') : '',
			});
		}
		push(out, {
			id: u.id,
			name: u.name,
			prefix: u.prefix,
			baseUrl: u.baseUrl,
			enabled: u.enabled,
			keyCount: length(u.keys),
			keyUsable: usable,
			keys: keys,
		});
	}
	return out;
}

// ---------- 公网访问（WAN 防火墙规则） ----------
//
// 默认关闭。打开时由本模块**自动**在 UCI firewall 里建/改一条 redirect，
// 把 WAN 的端口转到本机监听的端口；关闭时把这条规则删掉。
//
// 为什么用 UCI 而不是直接写 nft：
//   1. fw4 会在 reload 时重建整张 nftables 表，手写的 nft 规则会被冲掉；
//      写进 UCI 才能被 fw4 持久地重新生成。
//   2. 规则对用户可见、可审计 —— 在「网络 → 防火墙 → 端口转发」里能看到，
//      用户想手动关掉也有地方关。
//   3. reload 由 fw4 自己保证原子性，比我们插规则安全。
//
// 安全设计：
//   - 必须已设置管理密码才允许开启。没密码就开放公网 = 任何人可登录。
//   - 规则名固定 workbuddy_wan，关闭时整节删除，不留残影。
const FW_SECTION = 'workbuddy_wan';

// 执行一条 shell 命令，返回 { code, out }。
// 注意不能用 runCurl —— 那个是 curl 专用封装（签名是 (cfg, args)）。
// 这里要的是通用 shell，所以直接用 popen，并用 `; echo RC=$?` 取回退出码，
// 因为 popen 只给 stdout，拿不到 exit status。
function shRun(cmd) {
	let buf = '';
	try {
		let proc = popen('{ ' + cmd + ' ; } 2>&1; echo "RC=$?"', 'r');
		if (!proc) return { code: -1, out: '' };
		let chunk;
		while ((chunk = proc.read(16384)) !== null && length(chunk) > 0)
			buf += chunk;
		proc.close();
	} catch (e) {
		return { code: -1, out: '' + e };
	}
	let code = -1;
	let m = match(buf, /RC=(-?[0-9]+)\s*$/);
	if (m) {
		code = +m[1];
		buf = replace(buf, /\s*RC=-?[0-9]+\s*$/, '');
	}
	return { code: code, out: trim(buf) };
}

function fwRedirectExists() {
	let r = shRun('uci -q get firewall.' + FW_SECTION + '.target');
	return (index('' + r.out, 'DNAT') >= 0);
}

// 开关的实际落地。返回 { ok, error }
//
// 外部端口（src_dport）与内部端口（dest_port）可以不同：
//   外网 -> WAN:wanPort -> 本机:port
// 这样能把外部端口换成不显眼的端口（如 18789）降低被扫描概率，
// 同时内部监听端口保持不变。
function applyWanAccess(cfg, on) {
	if (on && !cfg.adminPass) {
		return { ok: false, error: '未设置管理密码，拒绝开放公网' };
	}

	let iport = cfg.port || 8789;             // 内部监听端口
	let eport = cfg.wanPort || iport;         // 外部暴露端口

	let cmd;

	if (on) {
		cmd = 'uci -q delete firewall.' + FW_SECTION + ' >/dev/null 2>&1; ' +
			'uci set firewall.' + FW_SECTION + '=redirect && ' +
			'uci set firewall.' + FW_SECTION + '.name=workbuddy_wan && ' +
			'uci set firewall.' + FW_SECTION + '.target=DNAT && ' +
			'uci set firewall.' + FW_SECTION + '.src=wan && ' +
			'uci set firewall.' + FW_SECTION + '.proto=tcp && ' +
			'uci set firewall.' + FW_SECTION + '.src_dport=' + eport + ' && ' +
			'uci set firewall.' + FW_SECTION + '.dest_port=' + iport + ' && ' +
			'uci commit firewall';
	} else {
		cmd = 'uci -q delete firewall.' + FW_SECTION + ' >/dev/null 2>&1; uci commit firewall';
	}

	let rc = shRun(cmd);
	if (rc.code !== 0) {
		return { ok: false, error: '写防火墙配置失败: ' + rc.out };
	}

	let rl = shRun('/etc/init.d/firewall reload >/dev/null 2>&1');
	if (rl.code !== 0) {
		return { ok: false, error: '防火墙 reload 失败' };
	}

	return { ok: true };
}

// 读当前实际生效状态。
// 短路优化：UCI 里没有规则时直接判定未生效，省掉一次 nft 子进程。
// nft 侧按**外部端口**匹配（redirect 规则匹配的是入站 dport），
// 并加 [^0-9] 边界避免 18789 误配到 187890。
function wanAccessStatus(cfg) {
	let uciOn = fwRedirectExists();
	if (!uciOn) {
		return { config: (cfg.wanAccess === true), uci: false, active: false };
	}
	let eport = cfg.wanPort || cfg.port || 8789;
	let r = shRun('nft list ruleset 2>/dev/null | grep -cE "dport ' + eport + '([^0-9]|$)"');
	let nftOn = (r.out !== '' && +r.out > 0);
	return { config: (cfg.wanAccess === true), uci: true, active: nftOn };
}

function hexdec(h) {
	let v = 0;
	for (let i = 0; i < length(h); i++) {
		let c = lc(substr(h, i, 1));
		let d;
		if (c >= '0' && c <= '9') d = ord(c) - 48;
		else if (c >= 'a' && c <= 'f') d = ord(c) - 87;
		else return -1;
		v = v * 16 + d;
	}
	return v;
}

// ucode 没有 decodeURIComponent，这里实现最小可用的百分号解码
function urlDecode(s) {
	if (index(s, '%') < 0 && index(s, '+') < 0) return s;
	let out = '';
	let i = 0;
	let n = length(s);
	while (i < n) {
		let ch = substr(s, i, 1);
		if (ch === '+') {
			out += ' ';
			i++;
			continue;
		}
		if (ch === '%' && i + 2 < n) {
			let hex = substr(s, i + 1, 2);
			let m = match(hex, /^([0-9a-fA-F]{2})$/);
			if (m) {
				out += chr(hexdec(m[1]));
				i += 3;
				continue;
			}
		}
		out += ch;
		i++;
	}
	return out;
}

// 恒定时间比较与 sha256Hex 定义在文件顶部「基础工具函数」区。
// 那里是唯一允许放置这类底层工具的位置：ucode 不提升函数，
// 放在这里会被后面定义的同名函数覆盖，也容易漏改。

// ---------- 哈希与会话 ----------

// 管理页会话签名：把过期时间戳一起签进去，服务端能真正判断过期，
// 而不是只依赖浏览器端的 Max-Age。
function adminToken(cfg) {
	let exp = time() + ADMIN_TTL;
	let sig = substr(sha256Hex(ADMIN_SALT + '|' + cfg.adminPass + '|' + exp), 0, 32);
	return '' + exp + '.' + sig;
}

function adminTokenValid(cfg, tok) {
	if (type(tok) !== 'string' || length(tok) === 0) return false;
	let m = match(tok, /^([0-9]+)\.([0-9a-f]{32})$/);
	if (!m) return false;
	let exp = +m[1];
	if (!exp || exp < time()) return false;
	let want = substr(sha256Hex(ADMIN_SALT + '|' + cfg.adminPass + '|' + exp), 0, 32);
	return secureEq(want, m[2]);
}

function adminEnabled(cfg) {
	return length('' + (cfg.adminPass || '')) > 0;
}

// 解析 Cookie 头为对象
function parseCookies(headers) {
	let out = {};
	let raw = headers['cookie'] || '';
	if (length(raw) === 0) return out;
	for (let part in split(raw, ';')) {
		let p = trim(part);
		let eq = index(p, '=');
		if (eq <= 0) continue;
		out[trim(substr(p, 0, eq))] = trim(substr(p, eq + 1));
	}
	return out;
}

function adminAuthed(cfg, headers) {
	if (!adminEnabled(cfg)) return false;
	return adminTokenValid(cfg, parseCookies(headers)[ADMIN_COOKIE]);
}

// 登录失败限速：同一 IP 连续失败达到上限后锁定一段时间
let adminFails = {};

function adminLocked(ip) {
	let st = adminFails[ip];
	if (!st) return 0;
	if (st.until > time()) return st.until - time();
	return 0;
}

function adminNoteFail(ip) {
	let st = adminFails[ip] || { n: 0, until: 0 };
	// 距上次失败超过锁定窗口就重新计数，避免历史失败永久累积
	if (st.until && st.until < time()) st.n = 0;
	st.n++;
	if (st.n >= ADMIN_MAX_FAIL) {
		st.until = time() + ADMIN_LOCK_SEC;
		st.n = 0;
	}
	adminFails[ip] = st;
}

function adminNoteOk(ip) {
	delete adminFails[ip];
}

// ---------- 客户端版本 ----------

let versionCache = null;

function readVersionFile() {
	let j = readJsonFile(VERSION_FILE);
	if (!j || type(j) !== 'object') return null;
	if (type(j.version) !== 'string' || length(j.version) === 0) return null;
	return { version: j.version, at: +j.at || 0, source: '' + (j.source || '') };
}

function saveVersionFile(ver, source) {
	writeJsonFile(VERSION_FILE, { version: ver, at: time(), source: source });
}

// 从任意响应体里提取形如 x.y.z 的版本号
function extractVersion(raw) {
	if (type(raw) !== 'string' || length(raw) === 0) return null;
	let m = match(raw, /([0-9]+\.[0-9]+\.[0-9]+)/);
	if (!m) return null;
	return m[1];
}

// 版本号比较：a > b 返回 1，相等 0，小于 -1
function verCmp(a, b) {
	let pa = split('' + a, '.');
	let pb = split('' + b, '.');
	let n = (length(pa) > length(pb)) ? length(pa) : length(pb);
	for (let i = 0; i < n; i++) {
		let x = +((pa[i] !== null && pa[i] !== '') ? pa[i] : 0) || 0;
		let y = +((pb[i] !== null && pb[i] !== '') ? pb[i] : 0) || 0;
		if (x > y) return 1;
		if (x < y) return -1;
	}
	return 0;
}

// 取得当前应使用的客户端版本。
//
// 现实约束（已实测）：WorkBuddy 没有公开的客户端版本清单接口。
//   - /v3/config 里只有插件市场的 versionUrl，与客户端 UA 无关
//   - /v3/version、/api/version 等一律 404
//   - download.codebuddy.cn/version.json 是 CodeBuddy 的清单（4 段式、无 windows-x64）
//   - 上游不校验版本：UA 从 1.0.0 到 9.9.9 都返回 200
// 因此这里做「多源探测 + 自校准」：探测源若将来可用就自动采用；探测不到时
// 沿用自校准记录（上游接受过的最高版本）、配置值，最后才回退内置下限。
function clientVersion(cfg) {
	if (!cfg.autoVersion) return '' + (cfg.client_version || VERSION_FLOOR);

	if (versionCache === null) versionCache = readVersionFile();
	let cached = versionCache;

	// 缓存仍新鲜：直接复用，避免每次请求都外呼
	if (cached && (time() - cached.at) < VERSION_TTL && length(cached.version) > 0)
		return cached.version;

	// 逐个探测源尝试。
	// 注意：runCurl() 声明在文件后面，ucode 不提升函数且按定义时的词法作用域
	// 解析标识符，这里直接调用会报 "access to undeclared variable runCurl"。
	// 因此通过前向引用表 F 调用（与 spawnUpstream 等同一套做法）。
	for (let url in VERSION_SOURCES) {
		let out = F.runCurl(cfg, ['-sS', '-m', '8', '-L', url]);
		if (out === null || length(out) === 0) continue;
		let v = extractVersion(out);
		if (v !== null) {
			versionCache = { version: v, at: time(), source: 'probe' };
			saveVersionFile(v, 'probe');
			logInfo('client version probed: ' + v + ' from ' + url);
			return v;
		}
	}

	// 探测全部失败：沿用已有记录，否则用配置值/下限，并刷新时间戳避免
	// 每个请求都重复外呼（负缓存）。
	let fallback = (cached && length(cached.version) > 0)
		? cached.version
		: ('' + (cfg.client_version || VERSION_FLOOR));
	versionCache = { version: fallback, at: time(), source: 'fallback' };
	saveVersionFile(fallback, 'fallback');
	return fallback;
}

// 记录上游实际接受过的版本，作为自校准结果。
// 只在版本号确实更高时更新，避免把版本号写退回去。
function noteAcceptedVersion(cfg, used) {
	if (!cfg.autoVersion) return;
	let v = '' + (used || cfg.client_version || VERSION_FLOOR);
	if (!versionCache) versionCache = readVersionFile();
	if (!versionCache || verCmp(v, versionCache.version || '0') > 0) {
		versionCache = { version: v, at: time(), source: 'accepted' };
		saveVersionFile(v, 'accepted');
	}
}

// 返回命中的密钥对象，未命中返回 null
function matchApiKey(cfg, headers, query) {
	let keys = loadApiKeys();

	// 提取客户端提交的密钥
	let auth = headers['authorization'] || '';
	let bearer = trim(replace(auth, /^Bearer\s+/i, ''));
	let xkey = trim(headers['x-api-key'] || '');
	let qkey = '';
	if (query) {
		let m = match(query, /(^|&)key=([^&]*)/);
		if (m) qkey = urlDecode(m[2]);
	}

	let supplied = [bearer, xkey, qkey];
	for (let s in supplied) {
		if (length(s) === 0) continue;
		for (let k in keys)
			if (secureEq(s, k.key)) return k;
		// 兼容旧版单一 share_token
		if (cfg.share_token && secureEq(s, cfg.share_token))
			return { id: 'legacy', name: 'share_token' };
	}
	return null;
}

// 是否需要鉴权：配置了任意密钥就强制校验
function authRequired(cfg) {
	return hasApiKeys() || length('' + (cfg.share_token || '')) > 0;
}

// ---------- HTTP 工具 ----------

function httpStatusText(code) {
	let map = {
		'200': 'OK', '302': 'Found', '400': 'Bad Request', '401': 'Unauthorized',
		'404': 'Not Found', '405': 'Method Not Allowed', '429': 'Too Many Requests',
		'500': 'Internal Server Error', '502': 'Bad Gateway',
	};
	return map[code] || 'Unknown';
}

// truthy() 定义在文件顶部基础工具区。

function closeConn(conn) {
	if (conn.closed) return;
	conn.closed = true;
	try {
		if (conn.handle) conn.handle.cancel();
	} catch (e) { }
	try {
		if (conn.procHandle) conn.procHandle.cancel();
	} catch (e) { }
	try {
		if (conn.proc) conn.proc.close();
	} catch (e) { }
	try {
		if (conn.tmpFile) unlink(conn.tmpFile);
	} catch (e) { }
	try {
		conn.sock.close();
	} catch (e) { }
}

function jsonResponse(conn, status, obj, extraHeaders) {
	if (conn.closed) return;
	let body = sprintf('%.J', obj);
	let extra = '';
	if (extraHeaders) {
		for (let k in extraHeaders)
			extra += k + ': ' + extraHeaders[k] + '\r\n';
	}
	let head = sprintf(
		'HTTP/1.1 %d %s\r\n' +
		'Content-Type: application/json\r\n' +
		'Content-Length: %d\r\n' +
		'Connection: close\r\n' +
		'Access-Control-Allow-Origin: *\r\n' +
		'Access-Control-Allow-Headers: *\r\n' +
		'%s' +
		'\r\n',
		status, httpStatusText(status), length(body), extra
	);
	conn.sock.send(head + body);
	closeConn(conn);
}

// 通用响应：可自定义 content-type 与附加响应头
// 注意：必须定义在 textResponse() 之前 —— ucode 不提升函数，
// 顺序颠倒会在运行时抛 "access to undeclared variable rawResponse"。
function rawResponse(conn, status, ctype, body, extraHeaders) {
	if (conn.closed) return;
	body = '' + (body || '');
	let extra = '';
	if (extraHeaders) {
		for (let k in extraHeaders)
			extra += k + ': ' + extraHeaders[k] + '\r\n';
	}
	let head = sprintf(
		'HTTP/1.1 %d %s\r\n' +
		'Content-Type: %s\r\n' +
		'Content-Length: %d\r\n' +
		'Connection: close\r\n' +
		'Cache-Control: no-store\r\n' +
		'X-Content-Type-Options: nosniff\r\n' +
		'%s' +
		'\r\n',
		status, httpStatusText(status), ctype, length(body), extra
	);
	conn.sock.send(head + body);
	closeConn(conn);
}

// 发送 HTML 响应（管理页用）
function textResponse(conn, status, title, body) {
	rawResponse(conn, status, 'text/html; charset=utf-8', body, null);
}

function sseHeaders(conn) {
	if (conn.closed || conn.headersSent) return;
	let head =
		'HTTP/1.1 200 OK\r\n' +
		'Content-Type: text/event-stream\r\n' +
		'Cache-Control: no-cache\r\n' +
		'Connection: close\r\n' +
		'Access-Control-Allow-Origin: *\r\n' +
		'\r\n';
	conn.sock.send(head);
	conn.headersSent = true;
}

// ---------- 请求体适配 ----------

// 模型列表缓存。必须声明在 freeModelIds() 之前：
// ucode 在编译函数时按当时的词法作用域解析标识符，声明在后面会报
// "access to undeclared variable"。
let modelCache = { at: 0, list: null };

// 返回当前已知的免费模型 ID 集合。
// 优先用已缓存的模型列表（开启 onlyFree 时缓存里只有免费模型），
// 缓存未就绪时回退到内置 FREE_MODELS 常量。
function freeModelIds() {
	if (modelCache.list && type(modelCache.list) === 'array' && length(modelCache.list) > 0) {
		let ids = [];
		for (let m in modelCache.list)
			if (type(m) === 'object' && m !== null && type(m.id) === 'string')
				push(ids, m.id);
		if (length(ids) > 0) return ids;
	}
	return FREE_MODELS;
}

function adaptBody(raw, cfg) {
	let body;
	try {
		body = json(raw);
	} catch (e) {
		return null;
	}
	if (type(body) !== 'object' || body === null) return null;

	let wantNonStream = (body.stream === false);
	// WorkBuddy 上游始终返回 SSE，客户端要非流式时由本代理合并后再回。
	// 但自定义上游（sensenova / askdiandian 等）会遵守 stream 字段，
	// 因此这里先统一置 true，等确定路由目标后再为自定义上游还原。
	body.stream = true;

	let messages = body.messages;
	if (type(messages) !== 'array' || length(messages) === 0 || messages[0].role !== 'system') {
		let sys = { role: 'system', content: 'You are a helpful assistant.' };
		let newMsgs = [sys];
		if (type(messages) === 'array') {
			for (let m in messages) push(newMsgs, m);
		}
		body.messages = newMsgs;
	}

	// 自定义上游路由：模型名形如 "sensenova/deepseek-v4-flash" 时，
	// 记下目标上游并把模型名还原成上游认得的裸名。
	//
	// 必须在下面的 onlyFree 检查之前处理：自定义上游的模型不在 WorkBuddy
	// 免费集合里，若先走 onlyFree 会被替换成 WorkBuddy 的默认模型，
	// 导致"选了日日新的模型却拿到 WorkBuddy 的回复"。
	//
	// 不能直接改 body.model：还要用它在上游请求里传裸模型名，
	// 因此把结果通过 body 的私有字段透出给 dispatch。
	body.__upstream = null;
	let upstreamId = null;
	if (type(body.model) === 'string') {
		let ref = splitModelRef(body.model);
		if (ref !== null) {
			if (ref.prefix === WB_PREFIX) {
				// workbuddy/xxx -> 走本机凭据池，去掉前缀即可
				body.model = ref.model;
			} else {
				let up = findUpstreamByPrefix(ref.prefix);
				if (up === null) {
					return { text: '', wantNonStream: wantNonStream,
						error: 'unknown upstream prefix: ' + ref.prefix };
				}
				upstreamId = up.id;
				body.model = ref.model;
			}
		}
	}

	// 免费模型保护：onlyFree 开启时，若请求的模型不在免费集合中，
	// 自动替换为默认免费模型，从源头杜绝收费。
	//
	// 注意：自定义上游的模型不受此限制 —— 它们本来就不是 WorkBuddy 的模型，
	// 用 WorkBuddy 的免费清单去校验必然"不通过"，会把请求错误地改写成
	// WorkBuddy 的默认模型，表现为"选了日日新却收到 WorkBuddy 的回复"。
	// 判据是 upstreamId（局部变量），不是 body.__upstream。
	if (cfg && cfg.onlyFree && upstreamId === null) {
		let ids = freeModelIds();
		let requested = body.model;
		let found = false;
		if (type(requested) === 'string' && length(requested) > 0) {
			for (let id in ids)
				if (id === requested) { found = true; break; }
		}
		if (!found) {
			logInfo(sprintf('only_free: model "%s" not free -> fallback "%s"', '' + (requested || '(none)'), ids[0]));
			body.model = ids[0];
		}
	}

	// 自定义上游遵守 stream 字段，非流式请求就让它直接返回完整 JSON，
	// 比"强制流式再本地合并"少一次拼接，语义也更准确。
	if (upstreamId !== null && wantNonStream) body.stream = false;

	return { text: sprintf('%.J', body), wantNonStream: wantNonStream, upstreamId: upstreamId };
}

// 把 SSE 流合并成单个 chat.completion 对象（非流式请求用）
function mergeChunks(sse) {
	let out = {
		id: '', object: 'chat.completion', created: 0, model: '',
		choices: [{ index: 0, message: { role: 'assistant', content: '' }, finish_reason: null }],
		usage: {},
	};
	for (let line in split(sse, '\n')) {
		if (substr(line, 0, 6) !== 'data: ') continue;
		let data = trim(substr(line, 6));
		if (data === '[DONE]' || data === '') continue;
		let chunk;
		try {
			chunk = json(data);
		} catch (e) {
			continue;
		}
		if (!out.id && chunk.id) out.id = chunk.id;
		if (!out.created && chunk.created) out.created = chunk.created;
		if (chunk.model) out.model = chunk.model;
		if (type(chunk.choices) === 'array' && length(chunk.choices) > 0) {
			let c = chunk.choices[0];
			if (c.delta) {
				if (c.delta.content) out.choices[0].message.content += c.delta.content;
				if (c.delta.reasoning_content)
					out.choices[0].message.reasoning_content =
						(out.choices[0].message.reasoning_content || '') + c.delta.reasoning_content;
			}
			if (c.finish_reason) out.choices[0].finish_reason = c.finish_reason;
		}
		if (chunk.usage) out.usage = chunk.usage;
	}
	return out;
}

// ---------- 鉴权 ----------
// 实际校验在 matchApiKey()，这里只判断是否需要鉴权。
// 单参数保留是为了兼容可能的旧调用点。

function authorized(cfg, headers) {
	return matchApiKey(cfg, headers, null) !== null;
}

// ---------- 模型列表 ----------

function fallbackModels() {
	let out = [];
	for (let id in FREE_MODELS)
		push(out, { id: id, name: id + ' · Free now' });
	return out;
}

function rateLabel(credits) {
	let raw = (credits === null) ? '' : ('' + credits);
	if (length(trim(raw)) === 0) return '';
	// 注意：ucode 的 PCRE 实现不支持 (?:...) 非捕获组，这里用普通捕获组。
	let m = match(raw, /x?\s*([0-9]+(\.[0-9]+)?)/);
	if (m) {
		let n = +m[1];
		if (n === 0) return 'Free now';
	}
	return trim(replace(raw, /\s*credits\s*$/i, ''));
}

// 判断 credits 是否显式为零（真正的免费模型）。
// 无 credits 字段的模型视为非免费，避免误放行收费模型。
function isFreeCredits(raw) {
	let s = (raw === null) ? '' : ('' + raw);
	if (length(trim(s)) === 0) return false;
	let m = match(s, /x?\s*([0-9]+(\.[0-9]+)?)/);
	if (m) return (+m[1] === 0);
	return false;
}

function modelsFromConfig(conf, freeOnly) {
	let out = [];
	let models = (type(conf) === 'object' && conf !== null && type(conf.models) === 'array') ? conf.models : [];
	for (let m in models) {
		if (type(m) !== 'object' || m === null) continue;
		if (type(m.id) !== 'string' || length(m.id) === 0) continue;
		// 只保留免费模型：避免出现收费
		if (freeOnly && !isFreeCredits(m.credits)) continue;
		let base = m.name || m.id;
		let label = rateLabel(m.credits);
		let entry = { id: m.id, name: (length(label) > 0) ? (base + ' · ' + label) : base };
		if (type(m.maxInputTokens) === 'int') entry.contextWindow = m.maxInputTokens;
		if (type(m.maxOutputTokens) === 'int') entry.maxTokens = m.maxOutputTokens;
		push(out, entry);
	}
	return out;
}

// ---------- curl 执行 ----------
// 注意：这些函数必须定义在 fetchModelsSync / 登录流程之前（ucode 无函数提升）。

// 单引号 shell 转义：' -> '\''
// 本版本 ucode 的 popen() 不支持数组参数形式（数组会返回 null + "Invalid argument"），
// 只能传命令字符串，因此所有外部数据必须经过本函数转义后再拼入命令行。
function shquote(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

// 执行 curl（字符串形式）并返回 stdout；失败返回 null
function runCurlStr(cmdline) {
	let buf = '';
	try {
		let proc = popen(cmdline, 'r');
		if (!proc) {
			logErr('popen failed: ' + error());
			return null;
		}
		let chunk;
		while ((chunk = proc.read(16384)) !== null && length(chunk) > 0)
			buf += chunk;
		proc.close();
	} catch (e) {
		logErr('curl failed: ' + e);
		return null;
	}
	return buf;
}

// 通用 curl 调用：args 为字符串数组（会自动转义拼接）
function runCurl(cfg, args) {
	let parts = ['curl'];
	for (let a in args) push(parts, shquote(a));
	return runCurlStr(join(' ', parts));
}

// 同步获取模型列表（用 curl，带超时；失败回退内置）
function fetchModelsSync(cfg, token) {
	if (!token) return null;
	let url = cfg.endpoint + '/v3/config';
	let out = runCurl(cfg, [
		'-sS', '-m', '10',
		'-H', 'Authorization: Bearer ' + token,
		'-H', 'Content-Type: application/json',
		'-H', 'User-Agent: WorkBuddy/' + clientVersion(cfg),
		url,
	]);
	if (out === null) return null;
	let j;
	try {
		j = json(out);
	} catch (e) {
		return null;
	}
	if (type(j) !== 'object' || j === null) return null;
	let list = modelsFromConfig(j.data || j, cfg.onlyFree);
	if (length(list) === 0) return null;
	return list;
}

function availableModels(cfg) {
	let now = time();
	if (modelCache.list && (now - modelCache.at) < 21600) return modelCache.list;

	let token = pickToken(cfg);
	let list = fetchModelsSync(cfg, token);
	if (list && length(list) > 0) {
		modelCache = { at: now, list: list };
		return list;
	}
	list = fallbackModels();
	modelCache = { at: now, list: list };
	return list;
}

// ---------- 登录流程 ----------

let login = { running: false, state: '', timer: null, startedAt: 0, lastError: '', ok: false, authUrl: '' };

function noAuthHeaders() {
	return [
		'-H', 'Content-Type: application/json',
		'-H', 'X-No-Authorization: true',
		'-H', 'X-No-Enterprise-Id: true',
		'-H', 'X-No-Department-Info: true',
	];
}

function pickField(obj, keys) {
	if (type(obj) !== 'object' || obj === null) return null;
	for (let k in keys) {
		let v = obj[k];
		if (type(v) === 'string' && length(v) > 0) return v;
	}
	return null;
}

function pollOnce(cfg, state) {
	let args = ['-sS', '-m', '10'];
	let nh = noAuthHeaders();
	for (let h in nh) push(args, h);
	push(args, cfg.endpoint + '/v2/plugin/auth/token?state=' + state);

	let out = runCurl(cfg, args);
	if (out === null) return 'retry';

	let j;
	try {
		j = json(out);
	} catch (e) {
		return 'retry';
	}
	if (type(j) !== 'object' || j === null) return 'retry';

	if (j.code === 0 && j.data) {
		let data = j.data.data || j.data;
		let accessToken = pickField(data, ['access_token', 'accessToken', 'token']);
		if (accessToken) {
			saveToken(cfg, accessToken, pickField(data, ['refresh_token', 'refreshToken']));
			return 'ok';
		}
		return 'retry';
	}
	return (j.code === CODE_LOGIN_ING) ? 'retry' : 'failed';
}

function schedulePoll(cfg, state) {
	login.timer = uloop.timer(LOGIN_POLL_MS, () => {
		if (!login.running) return;
		let r = pollOnce(cfg, state);
		if (r === 'ok') {
			login.running = false;
			login.ok = true;
			login.lastError = '登录成功，token 已保存';
			return;
		}
		if (r === 'failed') {
			login.running = false;
			login.lastError = '登录失败（WorkBuddy 拒绝了本次授权）';
			return;
		}
		if (time() - login.startedAt > (LOGIN_TIMEOUT_MS / 1000)) {
			login.running = false;
			login.lastError = '登录超时（300 秒内未完成）';
			return;
		}
		schedulePoll(cfg, state);
	});
}

function startWebLogin(cfg) {
	if (login.running) return { ok: true, alreadyRunning: true, authUrl: login.authUrl };

	login.running = true;
	login.lastError = '';
	login.ok = false;

	let args = ['-sS', '-m', '15', '-X', 'POST'];
	let nh = noAuthHeaders();
	for (let h in nh) push(args, h);
	push(args, '--data', '{}');
	push(args, cfg.endpoint + '/v2/plugin/auth/state?platform=CLI');

	let out = runCurl(cfg, args);
	if (out === null) {
		login.running = false;
		login.lastError = 'auth/state 请求失败（无法连接 WorkBuddy）';
		return { ok: false, error: login.lastError };
	}

	let j;
	try {
		j = json(out);
	} catch (e) {
		login.running = false;
		login.lastError = 'auth/state 返回非 JSON';
		return { ok: false, error: login.lastError };
	}

	let data = (type(j) === 'object' && j !== null) ? j.data : null;
	if (type(data) !== 'object' || data === null || !data.authUrl) {
		login.running = false;
		login.lastError = 'auth/state 未返回 authUrl';
		return { ok: false, error: login.lastError };
	}

	login.state = data.state || '';
	login.authUrl = data.authUrl;
	login.startedAt = time();
	login.lastError = '请在浏览器打开登录链接完成 WorkBuddy 授权（300 秒内）';
	logInfo('login url: ' + data.authUrl);

	schedulePoll(cfg, login.state);
	return { ok: true, alreadyRunning: false, authUrl: data.authUrl };
}

// ---------- 连接处理 ----------

let cfg = loadConfig();
let connections = [];

function parseHead(head) {
	let lines = split(head, '\r\n');
	let first = lines[0] || '';
	let m = match(first, /^(\S+)\s+(\S+)/);
	let method = m ? m[1] : 'GET';
	let path = m ? m[2] : '/';
	let headers = {};
	for (let i = 1; i < length(lines); i++) {
		let ln = lines[i];
		let idx = index(ln, ':');
		if (idx <= 0) continue;
		let k = lc(trim(substr(ln, 0, idx)));
		let v = trim(substr(ln, idx + 1));
		headers[k] = v;
	}
	return { method: method, path: path, headers: headers };
}

// ---------- 聊天转发（核心） ----------
// 顺序：onUpstreamEnd（被 handleChat 引用）→ handleChat → dispatch（引用 handleChat）

// ---------- 前向引用表 ----------
// ucode 的函数声明不提升，被引用的函数必须先定义。
// 但聊天转发链存在真实的循环依赖：
//     spawnUpstream → tryNextCred → spawnUpstream（换凭据重试）
//     spawnUpstream → onUpstreamEnd → tryNextCred
// 纯靠排序无法解开，因此把这三个函数挂到一个表上，
// 相互调用走属性查找（运行时解析），绕开声明顺序限制。
//
// 注意：这个表必须在文件最前面声明（见顶部 F 的定义处），不能放在这里 ——
// clientVersion() 也要通过它调用 runCurl()，而 clientVersion 在本行之前。

function spawnUpstream(conn) {
	if (conn.closed) return;

	let cred = conn.pool[conn.tries];
	conn.tries++;
	conn.credId = cred.id;
	conn.sseBuf = '';
	conn.headersSent = false;

	logInfo(sprintf('chat via credential %s (attempt %d/%d)',
		cred.id, conn.tries, conn.tryLimit));

	// 带上客户端版本：上游目前不校验版本，但统一的 UA 更贴近真实客户端，
	// 也便于日后上游若启用版本门禁时不必再改代码。
	let ua = clientVersion(cfg);
	conn.usedVersion = ua;

	let cmdline = join(' ', [
		'curl', '-sS', '-N', '-X', 'POST',
		'--connect-timeout', '5',
		shquote('-H'), shquote('Content-Type: application/json'),
		shquote('-H'), shquote('Authorization: Bearer ' + cred.token),
		shquote('-H'), shquote('Accept: text/event-stream'),
		shquote('-H'), shquote('User-Agent: WorkBuddy/' + ua),
		shquote('--data-binary'), shquote('@' + conn.tmpFile),
		shquote(cfg.endpoint + '/v2/chat/completions'),
	]);

	let proc;
	try {
		proc = popen(cmdline, 'r');
	} catch (e) {
		F.tryNextCred(conn, 'curl spawn failed: ' + e);
		return;
	}
	if (!proc) {
		F.tryNextCred(conn, 'curl spawn failed: ' + error());
		return;
	}

	conn.proc = proc;

	conn.procHandle = uloop.handle(proc, () => {
		let chunk;
		try {
			chunk = proc.read(16384);
		} catch (e) {
			F.tryNextCred(conn, 'read failed: ' + e);
			return;
		}
		if (chunk === null || length(chunk) === 0) {
			F.onUpstreamEnd(conn);
			return;
		}

		if (conn.wantNonStream) {
			conn.sseBuf += chunk;
			return;
		}

		// 流式转发；首个数据块先判断是否为错误响应
		if (!conn.headersSent) {
			let t = trim(chunk);
			let c = substr(t, 0, 1);
			// 以 { 开头且没有 SSE 帧，或以 < 开头（网关 HTML 错误页）：
			// 都可能是错误体，先攒着，等结束时判断是否要换凭据
			if ((c === '{' || c === '<') && index(chunk, 'data:') < 0) {
				conn.sseBuf += chunk;
				return;
			}
			sseHeaders(conn);
		}
		try {
			conn.sock.send(chunk);
		} catch (e) {
			closeConn(conn);
		}
	}, uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
}

// 结束当前凭据的尝试：释放进程与句柄，决定重试还是收尾
function tryNextCred(conn, reason) {
	if (conn.closed) return;

	try { if (conn.procHandle) conn.procHandle.cancel(); } catch (e) { }
	try { if (conn.proc) conn.proc.close(); } catch (e) { }
	conn.procHandle = null;
	conn.proc = null;

	if (reason) markCredFail(cfg, conn.credId, reason);

	if (conn.headersSent) {
		// 已经开始向客户端推流，无法回退重试
		closeConn(conn);
		return;
	}

	if (conn.tries < conn.tryLimit) {
		F.spawnUpstream(conn);
		return;
	}

	jsonResponse(conn, 502, {
		error: {
			message: '所有可用凭据均失败：' + (reason || '上游无响应'),
			tried: conn.tries,
		},
	});
}

// ---------- 自定义上游转发 ----------
//
// 与 spawnUpstream 的区别有三处，因此单独实现而不是复用：
//   1. Key 来自上游自己的 Key 组（轮询），不是 WorkBuddy 凭据池
//   2. 目标是 {baseUrl}/chat/completions，不是 {endpoint}/v2/chat/completions
//   3. 失败时换的是同一个上游的下一条 Key，而不是换账号
function spawnUpstreamDirect(conn) {
	if (conn.closed) return;

	let up = conn.upstream;
	if (conn.upTry >= length(conn.upKeys)) {
		jsonResponse(conn, 502, {
			error: { message: '上游 ' + up.prefix + ' 的所有 Key 均失败' },
		});
		return;
	}

	let key = conn.upKeys[conn.upTry];
	conn.upTry++;
	conn.sseBuf = '';
	conn.headersSent = false;

	logInfo(sprintf('chat via upstream %s key %s (attempt %d/%d)',
		up.prefix, maskKey(key), conn.upTry, length(conn.upKeys)));

	// Accept 头必须跟着 body 的 stream 字段走。
	// 自定义上游（sensenova 等）看到 Accept: text/event-stream 就会返回 SSE，
	// 即使 body 里 stream:false —— 客户端要非流式时会收到一堆 SSE 帧，
	// 表现为"请求了非流式却拿到流"。踩坑记录 #14。
	let accept = conn.wantNonStream ? 'application/json' : 'text/event-stream';

	let cmdline = join(' ', [
		'curl', '-sS', '-N', '-X', 'POST',
		'--connect-timeout', '8',
		'-4',
		q('-H'), q('Content-Type: application/json'),
		q('-H'), q('Authorization: Bearer ' + key),
		q('-H'), q('Accept: ' + accept),
		q('-H'), q('User-Agent: ai-gateway/' + APP_VERSION),
		q('--data-binary'), q('@' + conn.tmpFile),
		q(up.baseUrl + '/chat/completions'),
	]);

	let proc;
	try {
		proc = popen(cmdline, 'r');
	} catch (e) {
		F.tryNextUpKey(conn, 'curl spawn failed: ' + e);
		return;
	}
	if (!proc) {
		F.tryNextUpKey(conn, 'curl spawn failed: ' + error());
		return;
	}

	conn.proc = proc;
	conn.upKeyInUse = key;

	conn.procHandle = uloop.handle(proc, () => {
		let chunk;
		try {
			chunk = proc.read(16384);
		} catch (e) {
			F.tryNextUpKey(conn, 'read failed: ' + e);
			return;
		}
		if (chunk === null || length(chunk) === 0) {
			F.onUpstreamDirectEnd(conn);
			return;
		}

		if (conn.wantNonStream) {
			conn.sseBuf += chunk;
			return;
		}

		// 与 WorkBuddy 通道相同的判断：首块可能是错误体，先攒着
		if (!conn.headersSent) {
			let t = trim(chunk);
			let c = substr(t, 0, 1);
			if ((c === '{' || c === '<') && index(chunk, 'data:') < 0) {
				conn.sseBuf += chunk;
				return;
			}
			sseHeaders(conn);
		}
		try {
			conn.sock.send(chunk);
		} catch (e) {
			closeConn(conn);
		}
	}, uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
}

// 换下一条 Key 重试
function tryNextUpKey(conn, reason) {
	if (conn.closed) return;

	try { if (conn.procHandle) conn.procHandle.cancel(); } catch (e) { }
	try { if (conn.proc) conn.proc.close(); } catch (e) { }
	conn.procHandle = null;
	conn.proc = null;

	if (reason && conn.upKeyInUse)
		markUpKeyFail(conn.upstream, conn.upKeyInUse, reason);

	if (conn.headersSent) {
		closeConn(conn);
		return;
	}

	F.spawnUpstreamDirect(conn);
}

// 自定义上游正常结束：收尾并在必要时做非流式合并
function onUpstreamDirectEnd(conn) {
	if (conn.closed) return;

	try { if (conn.procHandle) conn.procHandle.cancel(); } catch (e) { }
	try { if (conn.proc) conn.proc.close(); } catch (e) { }
	conn.procHandle = null;
	conn.proc = null;

	// 未推流就结束：要么是错误体，要么是空响应
	if (!conn.headersSent) {
		let raw = conn.sseBuf;
		// 通过 F 表调用：upstreamLooksFailed 定义在本文件更靠后的位置，
		// ucode 函数不提升，直接调用会抛未声明变量错误（同 spawnUpstream 的循环依赖处理）。
		let fail = F.upstreamLooksFailed(raw);
		if (fail) {
			tryNextUpKey(conn, fail);
			return;
		}
		if (conn.wantNonStream) {
			// 上游遵守了 stream:false，直接回完整 JSON；
			// 若它仍然返回 SSE（少数上游无视 stream 字段），再本地合并。
			let t = trim(raw);
			if (substr(t, 0, 1) === '{' && index(t, 'data:') < 0) {
				rawResponse(conn, 200, 'application/json', raw, null);
				return;
			}
			let merged = mergeChunks(raw);
			jsonResponse(conn, 200, merged);
			return;
		}
		// 流式但上游没给 SSE：直接透传原始内容
		sseHeaders(conn);
		try { conn.sock.send(raw); } catch (e) { }
		closeConn(conn);
		return;
	}

	if (conn.wantNonStream) {
		let merged = mergeChunks(conn.sseBuf);
		jsonResponse(conn, 200, merged);
		return;
	}
	closeConn(conn);
}

// 判断上游返回体是否代表“这个凭据不可用”（限流/被封/额度耗尽/鉴权失败）。
// 上游失败时并不总是返回 JSON：
//   - APISIX/openresty 网关会直接吐 HTML 错误页（如 401 Authorization Required）
//   - 也可能返回 {"error":...} JSON
//   - 也可能返回 SSE 形式的错误事件
//   - 也可能成功但其实没有任何内容
// 只要在未向客户端推流前拿到的不是“能识别出内容”的响应，就视为该凭据失败。
function upstreamLooksFailed(raw) {
	let t = trim(raw || '');
	if (length(t) === 0) return '上游返回空响应';

	let c = substr(t, 0, 1);
	let head = substr(lc(t), 0, 400);

	// HTML 错误页（网关 401/403/429/502 等）
	if (c === '<') {
		let m = match(t, /([0-9]{3})[ ]*([A-Za-z][A-Za-z ]{0,30})/);
		if (m) return '上游返回 HTML 错误页：' + m[1] + ' ' + trim(m[2]);
		return '上游返回 HTML 错误页';
	}

	// JSON 错误体
	if (c === '{') {
		let j = null;
		try { j = json(t); } catch (e) { j = null; }
		if (j && type(j) === 'object') {
			// 明确的错误字段
			if (j.error) {
				let msg = j.error;
				if (type(msg) === 'object' && msg.message) msg = msg.message;
				return '上游错误：' + ('' + msg);
			}
			// 注意：ucode 没有 undefined，判断字段是否存在要用 type()
			let hasCode = (type(j.code) === 'int' || type(j.code) === 'string');
			let code = hasCode ? ('' + j.code) : '';
			if (j.message && hasCode && code !== '0' && code !== '200')
				return '上游错误：' + ('' + j.message);
			if (hasCode && code !== '0' && code !== '200')
				return '上游错误码：' + code;
			// 合法的 chat.completion
			if (j.choices || j.object === 'chat.completion' || j.id) return null;
		}
		// 解析不了或结构不认识，交给后续处理
		return null;
	}

	// SSE：只要包含 data: 就算正常流
	if (index(t, 'data:') >= 0) return null;

	// 既不是 JSON、不是 HTML、也没有 SSE 帧 —— 无法识别，视为失败
	if (index(head, 'rate limit') >= 0 || index(head, 'too many request') >= 0)
		return '上游限流：' + substr(t, 0, 120);

	return '上游返回无法识别的响应：' + substr(t, 0, 120);
}

function onUpstreamEnd(conn) {
	if (conn.closed) return;

	// 未向客户端推送任何内容时，先判断上游是否其实失败了：
	// 失败则换下一个凭据重试，并让该凭据进入冷却。
	if (!conn.headersSent) {
		let reason = upstreamLooksFailed(conn.sseBuf);
		if (reason !== null) {
			F.tryNextCred(conn, reason);
			return;
		}
	}

	// 到这里说明上游确实产出了内容，当前凭据可用
	markCredOk(conn.credId);
	// 顺带把这次实际用成功、且上游接受的版本记下来，作为自校准依据
	if (conn.usedVersion) noteAcceptedVersion(cfg, conn.usedVersion);

	if (conn.wantNonStream) {
		jsonResponse(conn, 200, mergeChunks(conn.sseBuf));
		return;
	}
	if (!conn.headersSent)
		sseHeaders(conn);
	closeConn(conn);
}

function handleChat(conn, bodyRaw) {
	let pool = usablePool(cfg);
	if (length(pool) === 0) {
		let started = startWebLogin(cfg);
		jsonResponse(conn, 502, {
			error: {
				message: 'WorkBuddy access token 缺失：' +
					(started.ok ? ('已生成登录链接（' + login.lastError + '），登录后自动生效') : login.lastError),
				login: started,
			},
		});
		return;
	}

	let adapted = adaptBody(bodyRaw, cfg);
	if (!adapted) {
		jsonResponse(conn, 400, { error: { message: 'invalid JSON body' } });
		return;
	}
	if (adapted.error) {
		jsonResponse(conn, 400, { error: { message: adapted.error, type: 'invalid_request_error' } });
		return;
	}

	// body 走临时文件，避免 JSON 内容进入命令行被 shell 解释
	// （getpid() 在本 ucode 版本不可用，用时间戳+时钟纳秒生成唯一名）
	let tmp = sprintf('/tmp/wb-req-%d-%d.json', time(), clock()[1]);
	try {
		writefile(tmp, adapted.text);
	} catch (e) {
		jsonResponse(conn, 502, { error: { message: 'temp file write failed: ' + e } });
		return;
	}

	conn.tmpFile = tmp;
	conn.wantNonStream = adapted.wantNonStream;
	conn.sseBuf = '';
	conn.tries = 0;

	// 自定义上游：不走凭据池，改用该上游自己的 Key 轮询
	if (adapted.upstreamId) {
		let up = null;
		let all = loadUpstreams();
		for (let u in all) if (u.id === adapted.upstreamId) { up = u; break; }
		if (up === null) {
			jsonResponse(conn, 404, { error: { message: 'upstream not found' } });
			return;
		}
		let keys = usableUpKeys(up);
		if (length(keys) === 0) {
			jsonResponse(conn, 503, { error: { message: 'upstream has no usable key' } });
			return;
		}
		conn.upstream = up;
		conn.upKeys = keys;
		conn.upTry = 0;
		F.spawnUpstreamDirect(conn);
		return;
	}

	conn.tryLimit = (length(pool) < MAX_TRY) ? length(pool) : MAX_TRY;
	conn.pool = pool;

	F.spawnUpstream(conn);
}

// 挂到前向引用表上：这些函数定义在管理页代码之后，
// 但从 dispatch() 的凭据管理接口里要调用它们。
// 必须在 dispatch() 之前执行，因为请求处理会用到它们。
F.spawnUpstream = spawnUpstream;
F.tryNextCred = tryNextCred;
F.onUpstreamEnd = onUpstreamEnd;
F.runCurl = runCurl;
F.startWebLogin = startWebLogin;
// 自定义上游转发链：spawnUpstreamDirect → tryNextUpKey → spawnUpstreamDirect
F.spawnUpstreamDirect = spawnUpstreamDirect;
F.tryNextUpKey = tryNextUpKey;
F.onUpstreamDirectEnd = onUpstreamDirectEnd;
F.upstreamLooksFailed = upstreamLooksFailed;

// ---------- 管理页 ----------
//
// 独立的单页管理界面，直接由本服务提供，不依赖 LuCI：
//   GET  /admin           登录页或管理页
//   POST /admin/login     校验密码，下发会话 Cookie
//   GET  /admin/logout    清除会话
//   GET  /admin/api/state 管理页所需的全部数据
//   POST /admin/api/*     管理操作
//
// 页面全部内联，不引用任何 CDN：路由器可能没有稳定外网，也没有构建步骤。

function htmlEscape(s) {
	let out = '';
	let str = '' + s;
	for (let i = 0; i < length(str); i++) {
		let c = substr(str, i, 1);
		if (c === '&') out += '&amp;';
		else if (c === '<') out += '&lt;';
		else if (c === '>') out += '&gt;';
		else if (c === '"') out += '&quot;';
		else if (c === "'") out += '&#39;';
		else out += c;
	}
	return out;
}

// 管理页的 CSS。深色主题，响应式，无外部依赖。
function adminCss() {
	return `
:root{
  --bg:#0f1115; --panel:#171a21; --panel2:#1e222b; --line:#2a2f3a;
  --fg:#e6e9ef; --dim:#9aa4b2; --accent:#4c8dff; --accent2:#3a6fd8;
  --ok:#35c26b; --warn:#e0a83a; --err:#e5544b;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:14px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans CJK SC","Microsoft YaHei",sans-serif}
a{color:var(--accent);text-decoration:none}
.wrap{max-width:1080px;margin:0 auto;padding:20px}
header{display:flex;align-items:center;gap:12px;padding:16px 20px;
  background:var(--panel);border-bottom:1px solid var(--line);flex-wrap:wrap}
header h1{font-size:17px;margin:0;font-weight:600;letter-spacing:.3px}
header .sp{flex:1}
.badge{font-size:12px;padding:2px 9px;border-radius:99px;border:1px solid var(--line);
  background:var(--panel2);color:var(--dim)}
.badge.ok{color:var(--ok);border-color:#1e4a30}
.badge.err{color:var(--err);border-color:#4a201e}
.badge.warn{color:var(--warn);border-color:#4a3d1e}
.card{background:var(--panel);border:1px solid var(--line);border-radius:10px;
  padding:18px;margin-bottom:16px}
.card h2{font-size:14px;margin:0 0 4px;font-weight:600}
.card .desc{color:var(--dim);font-size:12.5px;margin:0 0 14px}
label{display:block;font-size:12.5px;color:var(--dim);margin-bottom:5px}
input[type=text],input[type=password],input[type=number],select,textarea{
  width:100%;padding:9px 11px;background:var(--bg);color:var(--fg);
  border:1px solid var(--line);border-radius:7px;font-size:13.5px;font-family:inherit}
input:focus,select:focus,textarea:focus{outline:none;border-color:var(--accent)}
textarea{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px;resize:vertical}
.row{display:flex;gap:12px;flex-wrap:wrap}
.row>div{flex:1;min-width:190px}
.field{margin-bottom:14px}
button{cursor:pointer;border:1px solid var(--line);background:var(--panel2);color:var(--fg);
  padding:8px 15px;border-radius:7px;font-size:13px;font-family:inherit;transition:.15s}
button:hover{border-color:var(--accent)}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:500}
button.primary:hover{background:var(--accent2)}
button.danger{color:var(--err);border-color:#4a201e}
button.danger:hover{background:#2a1614}
button:disabled{opacity:.5;cursor:not-allowed}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:9px 8px;border-bottom:1px solid var(--line)}
th{color:var(--dim);font-weight:500;font-size:12px}
tr:last-child td{border-bottom:none}
code,.mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px}
.kv{display:flex;justify-content:space-between;padding:7px 0;border-bottom:1px solid var(--line)}
.kv:last-child{border-bottom:none}
.kv .k{color:var(--dim)}
.toast{position:fixed;right:18px;bottom:18px;z-index:99;display:flex;flex-direction:column;gap:8px}
.toast div{padding:11px 15px;border-radius:8px;background:var(--panel2);
  border:1px solid var(--line);box-shadow:0 6px 22px rgba(0,0,0,.45);font-size:13px;
  animation:sl .2s ease}
.toast div.ok{border-color:#1e4a30;color:#9fe8bd}
.toast div.err{border-color:#4a201e;color:#ffb3ae}
@keyframes sl{from{transform:translateX(14px);opacity:0}to{transform:none;opacity:1}}
.login{max-width:370px;margin:11vh auto;padding:0 20px}
.login .card{padding:26px}
.login h1{font-size:19px;margin:0 0 6px;font-weight:600}
.login p.sub{color:var(--dim);font-size:13px;margin:0 0 20px}
.keybox{background:var(--bg);border:1px solid var(--line);border-radius:7px;
  padding:9px 11px;display:flex;align-items:center;gap:9px}
.keybox code{flex:1;overflow-x:auto;white-space:nowrap;color:#9fe8bd}
.tabs{display:flex;gap:4px;margin-bottom:16px;flex-wrap:wrap}
.tabs button{border-radius:7px}
.tabs button.on{background:var(--accent);border-color:var(--accent);color:#fff}
.hide{display:none!important}
.hint{color:var(--dim);font-size:12px;margin-top:7px}
.sw{position:relative;display:inline-block;width:38px;height:21px;vertical-align:middle}
.sw input{opacity:0;width:0;height:0}
.sw span{position:absolute;inset:0;background:#39404d;border-radius:99px;transition:.2s}
.sw span:before{content:"";position:absolute;width:15px;height:15px;left:3px;top:3px;
  background:#fff;border-radius:50%;transition:.2s}
.sw input:checked+span{background:var(--ok)}
.sw input:checked+span:before{transform:translateX(17px)}
/* 自定义上游卡片：地址/前缀/Key 都要能一眼看清，所以用卡片式而非表格 */
.upcard{background:var(--bg);border:1px solid var(--line);border-radius:9px;
  padding:13px 15px;margin-bottom:11px}
/* 内置服务器（WorkBuddy 自身）用左侧色条区分，且不可删除 */
.upcard.builtin{border-left:3px solid var(--accent)}
/* 弹层：改 Key 时粘贴多行内容，必须给足空间 */
.modal-mask{position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:99;
  display:flex;align-items:center;justify-content:center;padding:20px}
.modal-mask .modal{background:var(--card);border:1px solid var(--line);
  border-radius:11px;padding:19px 21px;width:100%;max-width:560px;
  max-height:86vh;overflow-y:auto}
.modal-mask h3{margin:0 0 12px;font-size:15px}
.modal-mask textarea{width:100%;box-sizing:border-box;font-family:ui-monospace,Menlo,monospace}
.modal-foot{display:flex;gap:9px;justify-content:flex-end;margin-top:15px}
.uphead{margin-bottom:9px;font-size:14px}
.uprow{display:flex;gap:9px;align-items:flex-start;margin:5px 0;font-size:13px}
.uprow .lbl{color:var(--dim);min-width:66px;flex:0 0 66px}
/* 公网访问的风险提示框：只在开关打开时显示，用暖色区别于普通 hint */
.warnbox{background:#2a2113;border:1px solid #5a4520;border-radius:8px;
  padding:11px 14px;margin:11px 0;font-size:13px;color:#f0d9a8}
.warnbox strong{color:#ffd479}
.warnbox ul{margin:7px 0 0;padding-left:19px}
.warnbox li{margin:3px 0}
.uprow code{background:#1b2029;border:1px solid var(--line);border-radius:5px;
  padding:2px 7px;color:#9fe8bd;word-break:break-all}
.uprow .badge{margin-right:4px}

/* 添加凭据：两种方式并排，窄屏自动堆叠 */
.addbox{display:flex;gap:18px;flex-wrap:wrap;margin-top:6px}
.addcol{flex:1 1 300px;min-width:0;background:var(--bg);border:1px solid var(--line);
  border-radius:9px;padding:14px}
.addcol h3{margin:0 0 6px;font-size:14px;font-weight:600}
.addcol .field{margin-top:10px}
.loginbox{margin-top:12px;padding-top:12px;border-top:1px dashed var(--line)}
.linkbtn{display:inline-block;color:var(--accent);text-decoration:none;font-size:13px;
  padding:6px 0;word-break:break-all}
.linkbtn:hover{text-decoration:underline}
textarea{width:100%;background:var(--bg);border:1px solid var(--line);border-radius:7px;
  color:var(--fg);padding:9px 11px;font-family:monospace;font-size:12px;resize:vertical}
textarea:focus{outline:none;border-color:var(--accent)}
button:disabled{opacity:.5;cursor:not-allowed}
.badge.err{color:var(--err)}

@media(max-width:640px){
  .wrap{padding:12px} .card{padding:14px} header{padding:12px}
  th:nth-child(3),td:nth-child(3){display:none}
  .addcol{flex:1 1 100%}
}
`;
}

// 登录页
function adminLoginPage(msg) {
	return `<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${APP_NAME} · 管理登录</title>
<style>${adminCss()}</style>
</head><body>
<div class="login">
  <div class="card">
    <h1>${APP_NAME}</h1>
    <p class="sub">请输入管理员密码</p>
    ${msg ? `<div class="badge err" style="display:block;padding:8px 11px;margin-bottom:14px">${htmlEscape(msg)}</div>` : ''}
    <form method="POST" action="/admin/login" id="f">
      <div class="field">
        <label for="pw">管理员密码</label>
        <input type="password" id="pw" name="password" autocomplete="current-password" autofocus>
      </div>
      <button class="primary" style="width:100%" id="btn" type="submit">登录</button>
    </form>
    <p class="hint">密码在「LuCI → 服务 → AI 中转服务器 → 管理页密码」中设置。</p>
  </div>
</div>
<script>
document.getElementById('f').addEventListener('submit',function(){
  var b=document.getElementById('btn'); b.disabled=true; b.textContent='登录中…';
});
</script>
</body></html>`;
}

// 管理页主体
function adminAppPage() {
	return `<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${APP_NAME} · 管理</title>
<style>${adminCss()}</style>
</head><body>
<header>
  <h1>${APP_NAME}</h1>
  <span class="badge" id="bVer">—</span>
  <span class="sp"></span>
  <button onclick="load()">刷新</button>
  <button class="danger" onclick="logout()">退出</button>
</header>
<div class="wrap">

  <div class="tabs">
    <button class="on" data-t="ov" onclick="tab('ov')">概览</button>
    <button data-t="keys" onclick="tab('keys')">API 密钥</button>
    <button data-t="ups" onclick="tab('ups')">服务器管理</button>
    <button data-t="creds" onclick="tab('creds')">凭据池</button>
    <button data-t="cfg" onclick="tab('cfg')">设置</button>
  </div>

  <div id="t-ov">
    <div class="card">
      <h2>运行状态</h2>
      <p class="desc">服务当前状态与生效范围</p>
      <div id="ovBody">加载中…</div>
    </div>
    <div class="card">
      <h2>可用模型</h2>
      <p class="desc" id="mDesc"></p>
      <div id="mBody">加载中…</div>
    </div>
  </div>

  <div id="t-keys" class="hide">
    <div class="card">
      <h2>API 密钥</h2>
      <p class="desc">密钥可随时查看与复制；吊销后立即失效。请求时通过
        <code>Authorization: Bearer &lt;密钥&gt;</code> 或 <code>X-API-Key</code> 头提交。</p>
      <div class="field">
        <label for="nkName">新建密钥名称</label>
        <div class="row">
          <div><input type="text" id="nkName" placeholder="例如：家里电脑"></div>
          <div style="flex:0"><button class="primary" onclick="addKey()">生成密钥</button></div>
        </div>
      </div>
      <div id="keysBody">加载中…</div>
    </div>
  </div>

  <div id="t-ups" class="hide">
    <div class="card">
      <h2>服务器列表</h2>
      <p class="desc">每台服务器 = 一个 API 地址 + 一组 Key。组内 Key 自动轮询做负载均衡，
        失效的 Key 进入冷却并被跳过。模型以 <code>前缀/模型名</code> 形式出现在
        <code>/v1/models</code>，客户端据此选择走哪台服务器。</p>
      <div id="upBody">加载中…</div>
    </div>

    <div class="card">
      <h2>添加服务器</h2>
      <p class="desc">填一个 API 地址 + 一批 Key 即可接入。Key 每行一条，支持一次粘贴多条，
        服务端会自动去重；某条 Key 失效会被自动跳过并进入冷却。</p>

      <div class="field">
        <label for="upName">服务器名称</label>
        <input type="text" id="upName" placeholder="例如：日日新">
      </div>

      <div class="field">
        <label for="upPrefix">模型前缀</label>
        <input type="text" id="upPrefix" placeholder="例如：sensenova">
        <p class="hint">只能用小写字母、数字、<code>-</code>、<code>_</code>，长度 2–32。
          客户端里模型名会写成 <code>前缀/模型名</code>，用前缀区分不同服务器。</p>
      </div>

      <div class="field">
        <label for="upUrl">服务器 API 地址</label>
        <input type="text" id="upUrl" placeholder="https://token.sensenova.cn/v1">
        <p class="hint">填到 <code>/v1</code> 为止，本服务会自动拼接
          <code>/chat/completions</code> 与 <code>/models</code>。</p>
      </div>

      <div class="field">
        <label for="upKeys">API Key 密钥（每行一条，可批量粘贴）</label>
        <textarea id="upKeys" rows="5" placeholder="sk-xxxxxxxx&#10;sk-yyyyyyyy&#10;sk-zzzzzzzz"></textarea>
        <p class="hint">所有 Key 组成一个池子，请求时轮流使用，实现负载均衡。</p>
      </div>

      <button class="primary" onclick="addUpstreamUI()">添加服务器</button>
    </div>
  </div>

  <div id="t-creds" class="hide">
    <div class="card">
      <h2>凭据池</h2>
      <p class="desc">多个账号轮询使用，某个账号被限流时自动冷却并切换到其他账号。
        同一账号只会保留一条，重复添加会被自动拦截。</p>
      <div id="credsBody">加载中…</div>
    </div>

    <div class="card">
      <h2>添加凭据</h2>
      <p class="desc">两种方式：登录 WorkBuddy 账号自动获取，或手动粘贴已有 access token。</p>

      <div class="addbox">
        <div class="addcol">
          <h3>方式一 · 登录账号获取</h3>
          <p class="hint">点击后在浏览器打开授权链接，登录完成后凭据会自动加入池中。</p>
          <button class="primary" id="btnLogin" onclick="startLogin()">登录并添加账号</button>

          <div id="loginBox" class="hide loginbox">
            <div class="row" style="gap:8px;align-items:center">
              <div style="flex:1;min-width:0">
                <a id="loginLink" href="#" target="_blank" rel="noopener noreferrer"
                   class="linkbtn">打开授权链接</a>
              </div>
              <div style="flex:0"><button onclick="copyText(document.getElementById('loginUrl').value)">复制链接</button></div>
            </div>
            <input type="text" id="loginUrl" readonly style="margin-top:8px;font-size:12px">
            <p class="hint" id="loginHint">等待授权中…</p>
          </div>
        </div>

        <div class="addcol">
          <h3>方式二 · 手动添加 token</h3>
          <p class="hint">粘贴 access token（JWT 串）。可直接粘贴 <code>Bearer xxx</code>，会自动去掉前缀。</p>
          <div class="field">
            <label for="ncName">名称（留空则用账号名）</label>
            <input type="text" id="ncName" placeholder="例如：备用账号">
          </div>
          <div class="field">
            <label for="ncToken">Access Token</label>
            <textarea id="ncToken" rows="3" placeholder="eyJhbGciOiJS..."></textarea>
          </div>
          <button class="primary" onclick="addCred()">添加到凭据池</button>
        </div>
      </div>
    </div>
  </div>

  <div id="t-cfg" class="hide">
    <div class="card">
      <h2>服务设置</h2>
      <p class="desc">修改后立即生效，写入路由器配置。</p>
      <div class="field">
        <label class="row" style="align-items:center;gap:9px;cursor:pointer">
          <span class="sw"><input type="checkbox" id="cFree"><span></span></span>
          <span>仅使用免费模型（避免产生费用）</span>
        </label>
        <p class="hint">开启后，请求收费模型会被自动替换为免费模型。</p>
      </div>
      <div class="field">
        <label class="row" style="align-items:center;gap:9px;cursor:pointer">
          <span class="sw"><input type="checkbox" id="cAutoVer"><span></span></span>
          <span>自动获取客户端版本</span>
        </label>
        <p class="hint">关闭后可手动指定版本号。</p>
      </div>
      <div class="field" id="verWrap">
        <label for="cVer">客户端版本</label>
        <input type="text" id="cVer" placeholder="5.5.2">
      </div>
      <button class="primary" onclick="saveCfg()">保存设置</button>
    </div>

    <div class="card">
      <h2>公网访问</h2>
      <p class="desc">默认只允许局域网访问。打开后，外网可直连本服务。</p>

      <div class="field">
        <label class="row" style="align-items:center;gap:9px;cursor:pointer">
          <span class="sw"><input type="checkbox" id="cWan"><span></span></span>
          <span>允许公网调用管理页与 API</span>
        </label>
        <p class="hint" id="wanState">检测中…</p>
      </div>

      <div class="field">
        <label for="cWanPort">公网端口（外部访问端口）</label>
        <input type="number" id="cWanPort" min="1" max="65535" placeholder="留空跟随内部端口">
        <p class="hint">外网用这个端口访问，转发到本机内部端口
          <code id="wanInnerPort">—</code>。改个不显眼的端口（如 <code>18789</code>）
          能降低被扫描概率。留空则内外端口一致。</p>
      </div>

      <div class="warnbox" id="wanWarn">
        <strong>开放公网意味着：</strong>
        <ul>
          <li>任何人都能访问 <code>http://&lt;你的公网IP&gt;:<span id="wanWarnPort">8789</span>/admin</code> 的登录界面</li>
          <li>API 仍受 API 密钥保护，管理页仍受管理员密码保护 —— 但请确认两者都足够强</li>
          <li>建议同时确认路由器本身没有被运营商封禁该端口</li>
        </ul>
      </div>

      <p class="hint">本开关会自动在「网络 → 防火墙 → 端口转发」中创建/移除规则
        <code>workbuddy_wan</code>，无需手工配置。关闭后规则会被立即删除。</p>
      <button class="primary" onclick="saveWan()">保存公网设置</button>
    </div>
  </div>

</div>
<div class="toast" id="toast"></div>
<div class="modal-mask hide" id="modal">
  <div class="modal">
    <h3 id="modalTitle"></h3>
    <div id="modalBody"></div>
  </div>
</div>
<script>
var S = null;

function toast(msg, kind) {
  var d = document.createElement('div');
  d.className = kind || '';
  d.textContent = msg;
  document.getElementById('toast').appendChild(d);
  setTimeout(function(){ d.remove(); }, 3200);
}

function api(path, body) {
  var opt = { method: body ? 'POST' : 'GET', headers: {}, credentials: 'same-origin' };
  if (body) {
    opt.headers['Content-Type'] = 'application/json';
    opt.body = JSON.stringify(body);
  }
  return fetch('/admin/api/' + path, opt).then(function(r) {
    if (r.status === 401) { location.href = '/admin'; throw new Error('会话已过期'); }
    return r.json();
  });
}

function tab(name) {
  var names = ['ov','keys','ups','creds','cfg'];
  for (var i = 0; i < names.length; i++) {
    document.getElementById('t-' + names[i]).className = (names[i] === name) ? '' : 'hide';
  }
  var btns = document.querySelectorAll('.tabs button');
  for (var j = 0; j < btns.length; j++) {
    btns[j].className = (btns[j].getAttribute('data-t') === name) ? 'on' : '';
  }
}

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function(c) {
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
  });
}

function load() {
  api('state').then(function(d) {
    S = d;
    document.getElementById('bVer').textContent = 'v' + d.version;
    renderOv(d); renderModels(d); renderKeys(d); renderCreds(d); renderUpstreams(d); renderCfg(d); renderWan(d);

    // 如果服务端还有一个登录流程在等授权（比如页面被刷新过），
    // 就恢复显示并接着轮询，不要让它变成"看不见的后台任务"。
    if (d.login && d.login.running) {
      document.getElementById('btnLogin').disabled = true;
      document.getElementById('loginBox').className = 'loginbox';
      document.getElementById('loginUrl').value = d.login.authUrl || '';
      document.getElementById('loginLink').href = d.login.authUrl || '#';
      document.getElementById('loginHint').textContent =
        '已有登录流程在进行中，等待授权… 剩余 ' + d.login.remain + ' 秒';
      if (!loginTimer) pollLogin();
    }
  }).catch(function(e) { toast('加载失败：' + e.message, 'err'); });
}

function renderOv(d) {
  var h = '';
  function kv(k, v) { h += '<div class="kv"><span class="k">' + k + '</span><span>' + v + '</span></div>'; }
  kv('服务状态', d.enabled ? '<span class="badge ok">运行中</span>' : '<span class="badge err">已停用</span>');
  kv('监听端口', '<code>' + esc(d.host) + ':' + d.port + '</code>');
  kv('上游地址', '<code>' + esc(d.endpoint) + '</code>');
  kv('凭据数量', d.credentials);
  kv('API 密钥', d.keysActive + ' 启用 / ' + d.keysTotal + ' 总数');
  kv('模型范围', d.onlyFreeModels ? '<span class="badge ok">仅免费</span>' : '<span class="badge warn">全部模型（可能收费）</span>');
  kv('客户端版本', '<code>' + esc(d.clientVersion) + '</code>' + (d.autoVersion ? ' <span class="badge">自动</span>' : ' <span class="badge">手动</span>'));
  kv('管理页', d.adminEnabled ? '<span class="badge ok">已设密码</span>' : '<span class="badge err">未设密码</span>');
  document.getElementById('ovBody').innerHTML = h;
}

// 可用模型面板。
// 说明：这个函数曾经缺失，导致 #mBody 永远停在「加载中…」——
// 服务端 state 一直在正常返回 models 数组，只是前端没人渲染它。
function renderModels(d) {
  var box = document.getElementById('mBody');
  var desc = document.getElementById('mDesc');
  var list = (d && d.models) || [];

  if (desc) {
    desc.textContent = d && d.onlyFreeModels
      ? '当前仅允许免费额度模型（x0.00 积分）。请求收费模型会被自动替换。'
      : '当前允许全部模型，包含计费模型。';
  }

  if (!list.length) {
    box.innerHTML =
      '<p class="hint">上游没有返回可用模型。可能是凭据失效或网络不通，' +
      '可到「凭据池」点「测试」确认。</p>';
    return;
  }

  // 免费模型集合：与后端 FREE_MODELS 保持一致，用于打标
  var FREE = ['deepseek-v4.1-flash', 'hy4-preview-f', 'hy3'];

  var h = '<table><thead><tr><th>模型 ID</th><th>名称</th><th>计费</th><th></th></tr></thead><tbody>';
  for (var i = 0; i < list.length; i++) {
    var m = list[i];
    var id = m && m.id ? String(m.id) : '';
    var nm = m && m.name ? String(m.name) : '';
    var isFree = FREE.indexOf(id) >= 0;
    h += '<tr><td><code>' + esc(id) + '</code></td>' +
         '<td>' + (nm ? esc(nm) : '<span style="opacity:.5">—</span>') + '</td>' +
         '<td>' + (isFree
            ? '<span class="badge ok">免费</span>'
            : '<span class="badge warn">计费</span>') + '</td>' +
         '<td style="white-space:nowrap">' +
         '<button onclick="copyText(\\'' + esc(id) + '\\')">复制 ID</button>' +
         '</td></tr>';
  }
  h += '</tbody></table>';

  if (d && d.onlyFreeModels) {
    h += '<p class="hint" style="margin-top:10px">共 ' + list.length +
         ' 个可用模型。已开启「仅免费模型」，计费模型不会出现在 ' +
         '<code>/v1/models</code> 响应中。</p>';
  } else {
    h += '<p class="hint" style="margin-top:10px">共 ' + list.length +
         ' 个模型。<span class="badge warn">注意</span> 未开启「仅免费模型」，' +
         '调用计费模型会产生费用。</p>';
  }

  box.innerHTML = h;
}

function renderKeys(d) {
  if (!d.keys || !d.keys.length) {
    document.getElementById('keysBody').innerHTML =
      '<p class="hint">还没有密钥。未设置密钥时，代理对所有请求开放鉴权检查。</p>';
    return;
  }
  var h = '<table><thead><tr><th>名称</th><th>密钥</th><th>状态</th><th></th></tr></thead><tbody>';
  for (var i = 0; i < d.keys.length; i++) {
    var k = d.keys[i];
    h += '<tr><td>' + esc(k.name) + '</td>' +
         '<td><div class="keybox"><code>' + esc(k.key) + '</code>' +
         '<button onclick="copyKey(this,\\'' + esc(k.key) + '\\')">复制</button></div></td>' +
         '<td>' + (k.enabled ? '<span class="badge ok">启用</span>' : '<span class="badge">禁用</span>') + '</td>' +
         '<td style="white-space:nowrap">' +
         '<button onclick="toggleKey(\\'' + esc(k.id) + '\\',' + (k.enabled ? 'false' : 'true') + ')">' +
         (k.enabled ? '禁用' : '启用') + '</button> ' +
         '<button class="danger" onclick="delKey(\\'' + esc(k.id) + '\\',\\'' + esc(k.name) + '\\')">吊销</button>' +
         '</td></tr>';
  }
  h += '</tbody></table>';
  document.getElementById('keysBody').innerHTML = h;
}

// 服务器列表。每台服务器一张卡：地址、前缀、Key 数、可用数。
// 模型名前缀是路由依据，所以必须显眼展示，用户才知道客户端该填什么。
//
// 第一张卡固定是内置的 WorkBuddy 服务器（走凭据池，不是 Key 池）。
// 它不能被删除，所以不渲染删除按钮 —— 删掉它免费模型与凭据池就没入口了。
function renderUpstreams(d) {
  var box = document.getElementById('upBody');
  if (!box) return;
  var list = d.upstreams || [];
  var wb = d.wbPrefix || 'workbuddy';
  var creds = (d.credentials != null ? d.credentials : 0);

  var h = '';

  // ---- 内置服务器：WorkBuddy 自身 ----
  h += '<div class="upcard builtin">';
  h += '<div class="uphead"><strong>WorkBuddy</strong> ';
  h += '<span class="badge ok">内置</span> ';
  h += (d.hasToken ? '<span class="badge ok">已登录</span>' : '<span class="badge err">未登录</span>');
  h += '<span class="badge">' + creds + ' 个账号</span>';
  h += '</div>';
  h += '<div class="uprow"><span class="lbl">模型前缀</span><code>' + esc(wb) + '/</code></div>';
  h += '<div class="uprow"><span class="lbl">服务器</span><code>' + esc(d.endpoint || '—') + '</code></div>';
  h += '<div class="uprow"><span class="lbl">Key 池</span><span class="badge">账号凭据池（见「凭据池」页）</span></div>';
  h += '<div class="uprow"><span class="lbl">操作</span><span style="white-space:nowrap">';
  h += '<button onclick="tab(\\'creds\\')">管理账号</button>';
  h += '</span></div>';
  h += '</div>';

  // ---- 自定义服务器 ----
  if (!list.length) {
    h += '<p class="hint">还没有自定义服务器。用下面的表单添加：' +
      '填一个 API 地址 + 一批 Key，即可与本机的 WorkBuddy 一起对外提供模型。</p>';
  }

  for (var i = 0; i < list.length; i++) {
    var u = list[i];

    h += '<div class="upcard">';
    h += '<div class="uphead"><strong>' + esc(u.name) + '</strong> ';
    h += u.enabled ? '<span class="badge ok">启用</span>' : '<span class="badge">已停用</span>';
    h += '<span class="badge">' + u.keyUsable + '/' + u.keyCount + ' Key 可用</span>';
    h += '</div>';

    // 前缀 + 地址：这两个是用户配置客户端时要抄的
    h += '<div class="uprow"><span class="lbl">模型前缀</span><code>' + esc(u.prefix) + '/</code></div>';
    h += '<div class="uprow"><span class="lbl">服务器</span><code>' + esc(u.baseUrl) + '</code></div>';

    // Key 明细（掩码）
    if (u.keys && u.keys.length) {
      h += '<div class="uprow"><span class="lbl">Key 池</span><span>';
      for (var j = 0; j < u.keys.length; j++) {
        var k = u.keys[j];
        if (k.cooling > 0) {
          h += '<span class="badge warn" title="' + esc(k.lastErr || '') + '">' +
               esc(k.masked) + ' 冷却 ' + k.cooling + 's</span> ';
        } else {
          h += '<span class="badge ok">' + esc(k.masked) + '</span> ';
        }
      }
      h += '</span></div>';
    }

    h += '<div class="uprow"><span class="lbl">操作</span><span style="white-space:nowrap">';
    h += '<button onclick="testUp(\\'' + esc(u.id) + '\\')">测试</button> ';
    h += '<button onclick="editUpKeys(\\'' + esc(u.id) + '\\')">改 Key</button> ';
    h += '<button onclick="toggleUp(\\'' + esc(u.id) + '\\',' + (u.enabled ? 'false' : 'true') + ')">' +
         (u.enabled ? '停用' : '启用') + '</button> ';
    h += '<button class="danger" onclick="delUp(\\'' + esc(u.id) + '\\',\\'' + esc(u.name) + '\\')">删除</button>';
    h += '</span></div>';

    h += '</div>';
  }

  h += '<p class="hint">客户端里模型名写成 <code>前缀/模型名</code>。' +
       '本机 WorkBuddy 的前缀固定为 <code>' + esc(wb) + '/</code>，' +
       '其余用各自服务器配置的前缀。</p>';

  box.innerHTML = h;
}

// 测试上游：拉一次 /models，把结果直接告诉用户
function testUp(id) {
  api('POST', '/admin/api/upstreams/test', { id: id }).then(function (r) {
    if (r && r.ok) {
      var names = [];
      for (var i = 0; i < r.models.length && i < 6; i++) names.push(r.models[i].id);
      alert('可用 ✅\\n共 ' + r.count + ' 个模型：\\n' + names.join('\\n') +
            (r.count > 6 ? '\\n…' : ''));
    } else {
      alert('测试失败 ❌\\n' + ((r && r.error) || '拿不到模型列表，检查地址与 Key'));
    }
    refresh();
  });
}

// 改 Key：用页面内的弹层而不是 prompt()。
// prompt() 是单行输入框，粘多行 Key 会被压成一行；
// 而 Key 池的核心用法就是"一次粘一批"，所以必须用 textarea。
function editUpKeys(id) {
  var list = (S && S.upstreams) || [];
  var u = null;
  for (var i = 0; i < list.length; i++) if (list[i].id === id) u = list[i];
  if (!u) return;

  var cur = [];
  for (var j = 0; j < (u.keys || []).length; j++) cur.push(u.keys[j].masked);

  openModal('编辑 Key · ' + u.name,
    '<p class="hint" style="margin-top:0">当前 ' + cur.length + ' 条：' +
      esc(cur.join('、')) + '</p>' +
    '<p class="hint">粘贴新的 Key 列表，每行一条。<strong>会覆盖原有全部 Key。</strong>' +
      '每行的前后空格会自动去掉，重复项自动去重。</p>' +
    '<textarea id="mKeysEdit" rows="8" placeholder="sk-xxxxxxxx&#10;sk-yyyyyyyy"></textarea>' +
    '<div class="modal-foot">' +
      '<button onclick="closeModal()">取消</button>' +
      '<button class="primary" onclick="saveUpKeys(\\'' + esc(id) + '\\')">保存</button>' +
    '</div>');
}

function saveUpKeys(id) {
  var v = document.getElementById('mKeysEdit').value;
  if (!v || !v.replace(/\\s/g, '')) { alert('至少需要一条 Key'); return; }
  api('POST', '/admin/api/upstreams/keys', { id: id, keys: v }).then(function (r) {
    if (r && r.ok) { closeModal(); alert('已保存 ' + r.count + ' 条 Key ✅'); }
    else { alert('保存失败：' + ((r && r.error) || '未知错误')); }
    refresh();
  });
}

// 通用弹层：服务器 Key 编辑用
function openModal(title, innerHtml) {
  var m = document.getElementById('modal');
  document.getElementById('modalTitle').textContent = title;
  document.getElementById('modalBody').innerHTML = innerHtml;
  m.className = 'modal-mask';
}

function closeModal() {
  document.getElementById('modal').className = 'modal-mask hide';
}

function toggleUp(id, on) {
  api('POST', '/admin/api/upstreams/toggle', { id: id, enabled: on }).then(function () { refresh(); });
}

// 删除服务器。内置的 WorkBuddy 不走这里（它的卡片没有删除按钮）。
function delUp(id, name) {
  if (!confirm('确定删除服务器「' + name + '」？\\n\\n' +
      '删除后它的模型会从 /v1/models 消失，指向它的请求将返回 400。\\n' +
      '该服务器上配置的所有 Key 会一并删除。')) return;
  api('POST', '/admin/api/upstreams/delete', { id: id }).then(function (r) {
    if (r && r.ok) refresh();
    else alert('删除失败：' + ((r && r.error) || '未知错误'));
  });
}

// 注意：函数名不能叫 addUpstream —— 后端已有同名函数，重名会让其中一个
// 被静默覆盖（ucode 允许重复定义，但只有最后一个生效）。
function addUpstreamUI() {
  var name = document.getElementById('upName').value;
  var prefix = document.getElementById('upPrefix').value;
  var url = document.getElementById('upUrl').value;
  var keys = document.getElementById('upKeys').value;

  if (!prefix || !url || !keys) {
    alert('前缀、API 地址、Key 都是必填的');
    return;
  }

  api('POST', '/admin/api/upstreams/add', {
    name: name, prefix: prefix, baseUrl: url, keys: keys,
  }).then(function (r) {
    if (r && r.ok) {
      document.getElementById('upName').value = '';
      document.getElementById('upPrefix').value = '';
      document.getElementById('upUrl').value = '';
      document.getElementById('upKeys').value = '';
      alert('已添加 ✅\\n模型名前缀：' + r.prefix + '/');
    } else {
      alert('添加失败：' + ((r && r.error) || '未知错误'));
    }
    refresh();
  });
}

// 凭据过期状态 -> 徽章。这是用户最需要一眼看到的信息。
function credBadge(c) {  if (c.status === 'expired') return '<span class="badge err">已过期</span>';
  if (c.status === 'expiring') return '<span class="badge warn">' + c.expDays + ' 天后过期</span>';
  if (c.cooling) return '<span class="badge warn">冷却 ' + c.coolRemain + 's</span>';
  if (!c.enabled) return '<span class="badge">已停用</span>';
  if (c.status === 'unknown') return '<span class="badge">有效期未知</span>';
  if (c.expDays >= 0 && c.expDays <= 30) return '<span class="badge ok">' + c.expDays + ' 天后过期</span>';
  return '<span class="badge ok">正常</span>';
}

function renderCreds(d) {
  var box = document.getElementById('credsBody');
  var list = d.creds || [];

  if (!list.length) {
    box.innerHTML = '<p class="hint">池中还没有凭据。用下面的任意一种方式添加。</p>';
    return;
  }

  var h = '<table><thead><tr><th>名称</th><th>账号</th><th>状态</th><th>来源</th><th style="white-space:nowrap">操作</th></tr></thead><tbody>';
  for (var i = 0; i < list.length; i++) {
    var c = list[i];
    var account = c.username
      ? esc(c.username)
      : '<span style="opacity:.5">—</span>';

    var actions = '';
    if (c.managed) {
      actions += '<button onclick="testCred(\\'' + esc(c.id) + '\\')">测试</button> ';
      actions += '<button onclick="toggleCred(\\'' + esc(c.id) + '\\',' + (c.enabled ? 'false' : 'true') + ')">' +
                 (c.enabled ? '停用' : '启用') + '</button> ';
      actions += '<button class="danger" onclick="delCred(\\'' + esc(c.id) + '\\',\\'' + esc(c.name) + '\\')">删除</button>';
    } else {
      actions = '<span class="hint" style="font-size:12px">请用「退出登录」清除</span>';
    }

    h += '<tr><td>' + esc(c.name) + '</td>' +
         '<td>' + account + '</td>' +
         '<td>' + credBadge(c) + '</td>' +
         '<td><span class="badge">' + (c.source === 'legacy' ? '网页登录' : '手动添加') + '</span></td>' +
         '<td style="white-space:nowrap">' + actions + '</td></tr>';
  }
  h += '</tbody></table>';

  // 顶部汇总：有几个可用、几个有问题
  var usable = 0, bad = 0;
  for (var j = 0; j < list.length; j++) {
    if (list[j].status === 'expired') { bad++; continue; }
    if (!list[j].enabled) continue;
    usable++;
  }
  var sum = '<p class="hint" style="margin:0 0 10px">共 ' + list.length + ' 条，可用 ' + usable + ' 条' +
            (bad ? '，<span style="color:var(--err)">' + bad + ' 条已过期需更换</span>' : '') + '。</p>';

  box.innerHTML = sum + h;
}

// ---------- 凭据池操作 ----------

var loginTimer = null;

function addCred() {
  var name = document.getElementById('ncName').value.trim();
  var tok = document.getElementById('ncToken').value.trim();

  if (!tok) { toast('请粘贴 access token', 'err'); return; }
  // 前端先做一次明显格式校验，省一次往返
  if (tok.indexOf('.') < 0) {
    toast('这不像是一个 access token（JWT 应包含点号分段）', 'err');
    return;
  }

  api('creds/add', { name: name, token: tok }).then(function(r) {
    if (r.ok) {
      toast('已添加凭据：' + (r.name || ''), 'ok');
      document.getElementById('ncName').value = '';
      document.getElementById('ncToken').value = '';
      load();
    } else if (r.dup) {
      toast('未添加：' + r.error + (r.existingName ? '（已有：' + r.existingName + '）' : ''), 'err');
    } else if (r.expired) {
      toast('未添加：该凭据已过期，请重新登录获取新的 token', 'err');
    } else {
      toast('添加失败：' + (r.error || ''), 'err');
    }
  }).catch(function(e) { toast('添加失败：' + e.message, 'err'); });
}

function delCred(id, name) {
  if (!confirm('确定删除凭据「' + name + '」？删除后该账号将不再参与轮询。')) return;
  api('creds/delete', { id: id }).then(function(r) {
    if (r.ok) { toast('已删除', 'ok'); load(); }
    else { toast('删除失败：' + (r.error || ''), 'err'); }
  }).catch(function(e) { toast('删除失败：' + e.message, 'err'); });
}

function toggleCred(id, on) {
  api('creds/toggle', { id: id, enabled: on }).then(function(r) {
    if (r.ok) { toast(on ? '已启用' : '已停用', 'ok'); load(); }
    else { toast('操作失败：' + (r.error || ''), 'err'); }
  }).catch(function(e) { toast('操作失败：' + e.message, 'err'); });
}

function testCred(id) {
  toast('正在测试…');
  api('creds/test', { id: id }).then(function(r) {
    if (r.ok) toast('凭据可用（上游 HTTP ' + r.httpCode + '）', 'ok');
    else if (r.expired) toast('该凭据已过期，请重新登录或更换', 'err');
    else toast('测试未通过：' + (r.error || ''), 'err');
    load();
  }).catch(function(e) { toast('测试失败：' + e.message, 'err'); });
}

function startLogin() {
  var btn = document.getElementById('btnLogin');
  btn.disabled = true;

  api('creds/login/start', {}).then(function(r) {
    if (!r.ok) {
      btn.disabled = false;
      toast('无法发起登录：' + (r.error || ''), 'err');
      return;
    }
    document.getElementById('loginBox').className = 'loginbox';
    document.getElementById('loginUrl').value = r.authUrl || '';
    document.getElementById('loginLink').href = r.authUrl || '#';
    document.getElementById('loginHint').textContent =
      r.already ? '已有登录流程在进行中…' : '已生成授权链接，等待授权中…';

    // 自动打开授权页，省一次点击
    if (r.authUrl) window.open(r.authUrl, '_blank', 'noopener');

    pollLogin();
  }).catch(function(e) {
    btn.disabled = false;
    toast('无法发起登录：' + e.message, 'err');
  });
}

function pollLogin() {
  if (loginTimer) clearInterval(loginTimer);
  var n = 0;

  loginTimer = setInterval(function() {
    n++;
    api('creds/login/status').then(function(r) {
      if (r.done) {
        clearInterval(loginTimer); loginTimer = null;
        document.getElementById('btnLogin').disabled = false;
        document.getElementById('loginBox').className = 'hide';
        toast('登录成功，凭据已加入池中', 'ok');
        load();
        return;
      }
      if (!r.running) {
        clearInterval(loginTimer); loginTimer = null;
        document.getElementById('btnLogin').disabled = false;
        document.getElementById('loginHint').textContent = r.lastError || '登录流程已结束';
        return;
      }
      document.getElementById('loginHint').textContent =
        '等待授权中… 剩余 ' + r.remain + ' 秒' + (r.lastError ? '（' + r.lastError + '）' : '');
      // 最多轮询 5 分钟
      if (n > 150) {
        clearInterval(loginTimer); loginTimer = null;
        document.getElementById('btnLogin').disabled = false;
      }
    }).catch(function() {
      clearInterval(loginTimer); loginTimer = null;
      document.getElementById('btnLogin').disabled = false;
    });
  }, 2000);
}

function copyText(val) {
  if (!val) { toast('没有可复制的内容', 'err'); return; }
  function done() { toast('链接已复制', 'ok'); }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(val).then(done, function() { fallback(null, val, done); });
  } else { fallback(null, val, done); }
}

function renderCfg(d) {
  document.getElementById('cFree').checked = !!d.onlyFreeModels;
  document.getElementById('cAutoVer').checked = !!d.autoVersion;
  document.getElementById('cVer').value = d.clientVersion || '';
  document.getElementById('verWrap').className = d.autoVersion ? 'field hide' : 'field';
}

document.getElementById('cAutoVer').addEventListener('change', function() {
  document.getElementById('verWrap').className = this.checked ? 'field hide' : 'field';
});

function copyKey(btn, val) {
  function done() { toast('密钥已复制到剪贴板', 'ok'); }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(val).then(done, function() { fallback(btn, val, done); });
  } else { fallback(btn, val, done); }
}

function fallback(btn, val, done) {
  var ta = document.createElement('textarea');
  ta.value = val; ta.style.position = 'fixed'; ta.style.opacity = '0';
  document.body.appendChild(ta); ta.select();
  try { document.execCommand('copy'); done(); }
  catch (e) { toast('复制失败，请手动选择文本', 'err'); }
  ta.remove();
}

function addKey() {
  var inp = document.getElementById('nkName');
  var name = inp.value.trim();
  if (!name) { toast('请填写密钥名称', 'err'); return; }
  api('keys/add', { name: name }).then(function(r) {
    if (r.ok) { toast('已生成密钥：' + r.key, 'ok'); inp.value = ''; load(); }
    else { toast('生成失败：' + (r.error || ''), 'err'); }
  }).catch(function(e) { toast('生成失败：' + e.message, 'err'); });
}

function toggleKey(id, on) {
  api('keys/toggle', { id: id, enabled: on }).then(function(r) {
    if (r.ok) { toast(on ? '已启用' : '已禁用', 'ok'); load(); }
    else { toast('操作失败', 'err'); }
  }).catch(function(e) { toast('操作失败：' + e.message, 'err'); });
}

function delKey(id, name) {
  if (!confirm('确定吊销密钥「' + name + '」？使用该密钥的客户端将立即无法访问。')) return;
  api('keys/delete', { id: id }).then(function(r) {
    if (r.ok) { toast('已吊销', 'ok'); load(); } else { toast('吊销失败', 'err'); }
  }).catch(function(e) { toast('吊销失败：' + e.message, 'err'); });
}

function saveCfg() {
  var body = {
    only_free_models: document.getElementById('cFree').checked ? '1' : '0',
    auto_client_version: document.getElementById('cAutoVer').checked ? '1' : '0',
    client_version: document.getElementById('cVer').value.trim()
  };
  api('config/save', body).then(function(r) {
    if (r.ok) { toast('设置已保存', 'ok'); load(); }
    else { toast('保存失败：' + (r.error || ''), 'err'); }
  }).catch(function(e) { toast('保存失败：' + e.message, 'err'); });
}

// 公网访问开关 + 外部端口。
// 后端会自动写/删防火墙规则，失败时会把错误原样带回来，
// 所以这里必须把 r.ok === false 当成失败处理，不能只看 HTTP 200。
function saveWan() {
  var on = document.getElementById('cWan').checked;
  var portEl = document.getElementById('cWanPort');
  var portVal = portEl ? portEl.value.trim() : '';
  if (on) {
    if (!confirm('确定允许公网访问？\\n\\n' +
        '任何人都能打开 http://<你的公网IP>:' + (portVal || '8789') + '/admin 的登录界面。\\n' +
        '请确认管理员密码与 API 密钥都足够强。')) {
      return;
    }
  }
  api('config/save', { wan_access: on ? '1' : '0', wan_port: portVal }).then(function(r) {
    if (r.ok) {
      toast(on ? '公网访问已开启' : '公网访问已关闭', 'ok');
      load();
    } else {
      // 配置写了但规则没生效时后端回 ok:false，要把复选框还原成实际状态
      toast('未生效：' + (r.error || '未知错误'), 'err');
      load();
    }
  }).catch(function(e) { toast('保存失败：' + e.message, 'err'); });
}

function renderWan(d) {
  var cb = document.getElementById('cWan');
  var st = document.getElementById('wanState');
  var warn = document.getElementById('wanWarn');
  var portEl = document.getElementById('cWanPort');
  var innerEl = document.getElementById('wanInnerPort');
  var warnPortEl = document.getElementById('wanWarnPort');
  if (!cb) return;
  cb.checked = !!d.wanAccess;

  // 外部端口输入框：默认填当前生效的外部端口，内部端口作提示
  var wanPort = d.wanPort || d.port || 8789;
  if (portEl) portEl.value = (d.wanAccess ? wanPort : (d.wanPort || ''));
  if (innerEl) innerEl.textContent = d.port || 8789;
  if (warnPortEl) warnPortEl.textContent = wanPort;

  var w = d.wan || {};
  var txt, cls;
  if (w.active) {
    txt = '已生效：外网端口 ' + wanPort + ' → 本机 ' + (d.port || 8789) + '（规则 workbuddy_wan 已存在）';
    cls = 'ok';
  } else if (d.wanAccess && w.uci) {
    txt = '规则已写入，但尚未在防火墙中生效，正在等待 reload';
    cls = 'warn';
  } else if (d.wanAccess && !w.uci) {
    txt = '开关已开但规则缺失，请重新保存一次';
    cls = 'err';
  } else {
    txt = '仅局域网可访问（默认，安全）';
    cls = '';
  }
  st.innerHTML = '<span class="badge ' + cls + '">' + esc(txt) + '</span>';

  // 只在开着的时候显示风险提示，避免平时吓人
  if (warn) warn.className = d.wanAccess ? 'warnbox' : 'warnbox hide';
}

function logout() {
  if (!confirm('确定退出登录？')) return;
  location.href = '/admin/logout';
}

load();
</script>
</body></html>`;
}

// 解析 POST body；只接受 JSON，失败返回空对象
function parseJsonBody(body) {
	if (type(body) !== 'string' || length(body) === 0) return {};
	try {
		let j = json(body);
		if (type(j) === 'object' && j !== null) return j;
	} catch (e) {
		// 忽略
	}
	return {};
}

// 从 application/x-www-form-urlencoded 中取字段
function formField(body, field) {
	if (type(body) !== 'string') return '';
	let want = '' + field + '=';
	for (let part in split(body, '&')) {
		if (substr(part, 0, length(want)) === want)
			return urlDecode(substr(part, length(want)));
	}
	return '';
}

// 管理页总入口。所有 /admin 与 /admin/* 请求都经过这里。
function handleAdmin(conn, req, method, path, query, body) {
	// 未设置管理员密码：明确提示去 LuCI 设置，不要静默放行
	if (!adminEnabled(cfg)) {
		textResponse(conn, 200, APP_NAME + ' 管理',
			'<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">' +
			'<meta name="viewport" content="width=device-width,initial-scale=1">' +
			'<title>未设置管理员密码</title><style>' + adminCss() + '</style></head><body>' +
			'<div class="login"><div class="card"><h1>未设置管理员密码</h1>' +
			'<p class="sub">管理页需要先设置管理员密码。</p>' +
			'<p class="hint">请进入 LuCI：服务 → AI 中转服务器 → 管理页密码，设置一个密码后回到本页。</p>' +
			'</div></div></body></html>');
		return;
	}

	// 登录提交
	if (path === '/admin/login' && method === 'POST') {
		let ip = conn.ip || '?';
		let lock = adminLocked(ip);
		if (lock > 0) {
			logErr(sprintf('admin login blocked (locked %ds) from %s', lock, ip));
			textResponse(conn, 429, '登录受限',
				adminLoginPage(sprintf('尝试次数过多，请 %d 秒后重试。', lock)));
			return;
		}
		let pw = '' + formField(body, 'password');
		if (length(pw) === 0) pw = '' + (parseJsonBody(body).password || '');

		if (length(pw) > 0 && secureEq(pw, cfg.adminPass)) {
			adminNoteOk(ip);
			let tok = adminToken(cfg);
			logInfo('admin login ok from ' + ip);
			rawResponse(conn, 302, 'text/plain; charset=utf-8', '重定向中...', {
				'Location': '/admin',
				'Set-Cookie': ADMIN_COOKIE + '=' + tok +
					'; Path=/; Max-Age=' + ADMIN_TTL + '; HttpOnly; SameSite=Lax',
			});
			return;
		}

		adminNoteFail(ip);
		logErr('admin login failed from ' + ip);
		textResponse(conn, 401, '登录失败', adminLoginPage('密码错误'));
		return;
	}

	// 退出
	if (path === '/admin/logout') {
		rawResponse(conn, 302, 'text/plain; charset=utf-8', '重定向中...', {
			'Location': '/admin',
			'Set-Cookie': ADMIN_COOKIE + '=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax',
		});
		return;
	}

	// 以下均需已登录
	let authed = adminAuthed(cfg, req.headers);

	if (path === '/admin' || path === '/admin/') {
		if (!authed) {
			textResponse(conn, 200, '管理登录', adminLoginPage(''));
			return;
		}
		textResponse(conn, 200, APP_NAME + ' 管理', adminAppPage());
		return;
	}

	if (!authed) {
		jsonResponse(conn, 401, { error: { message: '未登录或会话已过期' } });
		return;
	}

	// ---- 已登录的 API ----

	if (path === '/admin/api/state' && method === 'GET') {
		let now = time();
		let creds = [];

		// 池文件里的条目（含禁用项与过期项，管理页要全部看到）
		let rawList = readPoolRaw();
		let seenSub = {};
		for (let c in rawList) {
			let t = '' + (c.accessToken || '');
			let info = parseJwt(t);
			let st = credStatus(t, now);
			let stt = credState['' + (c.id || '')] || {};
			let cool = (stt.coolUntil || 0) > now;

			if (info && length(info.sub) > 0) seenSub[info.sub] = true;

			push(creds, {
				id: '' + (c.id || ''),
				name: '' + (c.name || c.id || ''),
				source: 'pool',
				enabled: (c.enabled !== false),
				managed: true,                       // 可在管理页删除/启停
				status: st,                          // ok | expiring | expired | unknown
				exp: info ? info.exp : 0,
				expDays: (info && info.exp) ? int((info.exp - now) / 86400) : -1,
				username: info ? info.username : '',
				accountId: info ? info.sub : '',
				tail: length(t) >= 8 ? substr(t, length(t) - 8) : '',
				tokenLength: length(t),
				syncedAt: c.syncedAt || 0,
				cooling: cool,
				coolRemain: cool ? ((stt.coolUntil || 0) - now) : 0,
			});
		}

		// 网页登录凭据（token.json）。它是池的一部分，但不可删除，
		// 只能通过「退出登录」清除，所以单独标注 managed=false。
		let legacyTok = getToken(cfg);
		if (legacyTok) {
			let lj = readJsonFile(tokenPath(cfg)) || {};
			let info = parseJwt(legacyTok);
			let st = credStatus(legacyTok, now);
			let stt = credState['default'] || {};
			let cool = (stt.coolUntil || 0) > now;
			push(creds, {
				id: 'default',
				name: '网页登录凭据',
				source: 'legacy',
				enabled: true,
				managed: false,
				status: st,
				exp: info ? info.exp : 0,
				expDays: (info && info.exp) ? int((info.exp - now) / 86400) : -1,
				username: info ? info.username : '',
				accountId: info ? info.sub : '',
				tail: length(legacyTok) >= 8 ? substr(legacyTok, length(legacyTok) - 8) : '',
				tokenLength: length(legacyTok),
				syncedAt: lj.syncedAt || 0,
				cooling: cool,
				coolRemain: cool ? ((stt.coolUntil || 0) - now) : 0,
			});
		}

		let usable = loadPool(cfg);
		let usableActive = 0;
		for (let c in usable) {
			let st = credStatus(c.token, now);
			if (st !== 'expired') usableActive++;
		}

		let models = [];
		for (let m in availableModels(cfg))
			push(models, { id: m.id, name: m.name });

		// 是否正在等待某个登录流程完成
		let loginState = null;
		if (login.running && length(login.state) > 0) {
			let el = int(LOGIN_TIMEOUT_MS / 1000) - (time() - (login.startedAt || 0));
			loginState = {
				running: true,
				authUrl: '' + (login.authUrl || ''),
				state: '' + login.state,
				remain: el > 0 ? el : 0,
				lastError: '' + (login.lastError || ''),
			};
		}

		jsonResponse(conn, 200, {
			ok: true,
			version: APP_VERSION,
			enabled: cfg.enabled,
			port: cfg.port,
			host: cfg.host,
			endpoint: cfg.endpoint,
			credentials: length(creds),
			credentialsUsable: usableActive,
			creds: creds,
			login: loginState,
			keys: listApiKeysFull(),
			keysTotal: apiKeysDefined(),
			keysActive: length(loadApiKeys()),
			models: models,
			onlyFreeModels: cfg.onlyFree,
			autoVersion: cfg.autoVersion,
			wanAccess: cfg.wanAccess,
			wanPort: cfg.wanPort,
			wan: wanAccessStatus(cfg),
			clientVersion: clientVersion(cfg),
			adminEnabled: adminEnabled(cfg),
			upstreams: upstreamStatus(),
			wbPrefix: WB_PREFIX,
			// 内置服务器（WorkBuddy 自身）的状态，供服务器列表首卡展示
			hasToken: (length(loadPool(cfg)) > 0),
			endpoint: cfg.endpoint,
		});
		return;
	}

	// ---- 凭据池管理 ----

	if (path === '/admin/api/creds/add' && method === 'POST') {
		let j = parseJsonBody(body);
		let r = addPoolCred('' + (j.name || ''), '' + (j.token || ''), cfg);
		if (r.ok) {
			logInfo('admin added pool credential ' + r.id);
			jsonResponse(conn, 200, { ok: true, id: r.id, name: r.name });
		} else {
			// 重复用 409，让前端给出针对性提示
			jsonResponse(conn, r.dup ? 409 : 400, {
				ok: false, dup: !!r.dup, expired: !!r.expired, error: r.error,
				existingId: r.existingId || '', existingName: r.existingName || '',
			});
		}
		return;
	}

	if (path === '/admin/api/creds/delete' && method === 'POST') {
		let j = parseJsonBody(body);
		let id = '' + (j.id || '');
		if (id === 'default') {
			jsonResponse(conn, 400, { ok: false, error: '网页登录凭据请用「退出登录」清除' });
			return;
		}
		let ok = deletePoolCred(id);
		logInfo('admin deleted pool credential ' + id + ' -> ' + ok);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok, error: ok ? '' : '凭据不存在' });
		return;
	}

	if (path === '/admin/api/creds/toggle' && method === 'POST') {
		let j = parseJsonBody(body);
		let id = '' + (j.id || '');
		if (id === 'default') {
			jsonResponse(conn, 400, { ok: false, error: '网页登录凭据不可停用' });
			return;
		}
		let en = truthy(j.enabled);
		let ok = togglePoolCred(id, en);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok, enabled: en, error: ok ? '' : '凭据不存在' });
		return;
	}

	if (path === '/admin/api/creds/test' && method === 'POST') {
		// 单条凭据可用性测试：拿它去请求一次模型列表
		let j = parseJsonBody(body);
		let id = '' + (j.id || '');
		let token = '';
		if (id === 'default') {
			token = getToken(cfg) || '';
		} else {
			let c = findPoolById(id);
			if (c) token = '' + (c.accessToken || '');
		}
		if (length(token) === 0) {
			jsonResponse(conn, 404, { ok: false, error: '凭据不存在' });
			return;
		}
		let st = credStatus(token, time());
		if (st === 'expired') {
			jsonResponse(conn, 200, { ok: false, expired: true, error: '该凭据已过期，请重新登录或更换' });
			return;
		}
		let out = F.runCurl(cfg, [
			'-sS', '-m', '20', '-o', '/dev/null', '-w', '%{http_code}',
			'-H', 'Authorization: Bearer ' + token,
			'-H', 'User-Agent: WorkBuddy/' + clientVersion(cfg),
			cfg.endpoint + '/v3/config',
		]);
		let code = trim('' + (out || ''));
		let good = (code === '200');
		jsonResponse(conn, 200, {
			ok: good, httpCode: code,
			error: good ? '' : ('上游返回 HTTP ' + code),
			status: st,
		});
		return;
	}

	if (path === '/admin/api/creds/login/start' && method === 'POST') {
		// 发起一次新的网页登录，用于往池里增加凭据。
		// startWebLogin 定义在文件后段，这里必须走前向引用表。
		let r = F.startWebLogin(cfg);
		if (!r || r.ok !== true) {
			jsonResponse(conn, 500, { ok: false, error: (r && r.error) || '无法发起登录' });
			return;
		}
		logInfo('admin started web login');
		jsonResponse(conn, 200, { ok: true, authUrl: r.authUrl || '', already: !!r.alreadyRunning });
		return;
	}

	if (path === '/admin/api/creds/login/status' && method === 'GET') {
		// 轮询用：告诉前端登录是否还在等、是否成功、还剩多久
		if (!login.running) {
			// 已经结束：区分"刚刚成功"与"未在登录"
			jsonResponse(conn, 200, {
				ok: true, running: false,
				done: login.ok === true,
				lastError: '' + (login.lastError || ''),
			});
			// 成功一次后清掉 ok，避免重复提示
			if (login.ok === true) login.ok = false;
			return;
		}
		let el = int(LOGIN_TIMEOUT_MS / 1000) - (time() - (login.startedAt || 0));
		jsonResponse(conn, 200, {
			ok: true,
			running: true,
			done: false,
			authUrl: '' + (login.authUrl || ''),
			remain: el > 0 ? el : 0,
			lastError: '' + (login.lastError || ''),
		});
		return;
	}

	if (path === '/admin/api/keys/add' && method === 'POST') {
		let j = parseJsonBody(body);
		let r = addApiKey('' + (j.name || ''));
		if (r === null) {
			jsonResponse(conn, 500, { ok: false, error: '写入密钥文件失败' });
			return;
		}
		logInfo('admin added api key ' + r.id);
		jsonResponse(conn, 200, { ok: true, id: r.id, key: r.key, name: r.name });
		return;
	}

	if (path === '/admin/api/keys/delete' && method === 'POST') {
		let j = parseJsonBody(body);
		let ok = deleteApiKey('' + (j.id || ''));
		logInfo('admin deleted api key ' + (j.id || '') + ' -> ' + ok);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok });
		return;
	}

	if (path === '/admin/api/keys/toggle' && method === 'POST') {
		let j = parseJsonBody(body);
		let on = truthy(j.enabled);
		let ok = toggleApiKey('' + (j.id || ''), on);
		logInfo('admin toggled api key ' + (j.id || '') + ' -> ' + on);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok, enabled: on });
		return;
	}

	// ---- 自定义上游管理 ----

	if (path === '/admin/api/upstreams/add' && method === 'POST') {
		let j = parseJsonBody(body);
		let r = addUpstream(
			'' + (j.name || ''),
			'' + (j.prefix || ''),
			'' + (j.baseUrl || ''),
			'' + (j.keys || '')
		);
		if (!r.ok) {
			jsonResponse(conn, 400, { ok: false, error: r.error });
			return;
		}
		logInfo('admin added upstream ' + r.upstream.prefix);
		jsonResponse(conn, 200, {
			ok: true,
			id: r.upstream.id,
			prefix: r.upstream.prefix,
			baseUrl: r.upstream.baseUrl,
			keyCount: length(r.upstream.keys),
		});
		return;
	}

	if (path === '/admin/api/upstreams/delete' && method === 'POST') {
		let j = parseJsonBody(body);
		let ok = deleteUpstream('' + (j.id || ''));
		logInfo('admin deleted upstream ' + (j.id || '') + ' -> ' + ok);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok });
		return;
	}

	if (path === '/admin/api/upstreams/toggle' && method === 'POST') {
		let j = parseJsonBody(body);
		let on = truthy(j.enabled);
		let ok = toggleUpstream('' + (j.id || ''), on);
		logInfo('admin toggled upstream ' + (j.id || '') + ' -> ' + on);
		jsonResponse(conn, ok ? 200 : 404, { ok: ok, enabled: on });
		return;
	}

	if (path === '/admin/api/upstreams/keys' && method === 'POST') {
		let j = parseJsonBody(body);
		let r = setUpstreamKeys('' + (j.id || ''), '' + (j.keys || ''));
		if (!r.ok) {
			jsonResponse(conn, 400, { ok: false, error: r.error });
			return;
		}
		logInfo('admin updated upstream keys ' + (j.id || '') + ' -> ' + r.count);
		jsonResponse(conn, 200, { ok: true, count: r.count });
		return;
	}

	// 测试某个上游是否可用（用它的 Key 拉一次 /models）
	if (path === '/admin/api/upstreams/test' && method === 'POST') {
		let j = parseJsonBody(body);
		let id = '' + (j.id || '');
		let up = null;
		let all = loadUpstreams();
		for (let u in all) if (u.id === id) { up = u; break; }
		if (up === null) {
			jsonResponse(conn, 404, { ok: false, error: '上游不存在' });
			return;
		}
		let models = fetchUpstreamModels(up);
		jsonResponse(conn, 200, {
			ok: length(models) > 0,
			count: length(models),
			models: models,
		});
		return;
	}

	if (path === '/admin/api/config/save' && method === 'POST') {
		let j = parseJsonBody(body);
		let ctx = uci.cursor();
		let changed = [];

		// 注意：ucode 没有 undefined 这个标识符（写 `!== undefined` 会在运行时抛
		// "access to undeclared variable undefined"），也没有 has()。
		// 判断字段是否出现用 `'key' in obj`。
		if ('only_free_models' in j) {
			ctx.set('workbuddy', 'main', 'only_free_models',
				truthy(j.only_free_models) ? '1' : '0');
			push(changed, 'only_free_models');
		}
		if ('auto_client_version' in j) {
			ctx.set('workbuddy', 'main', 'auto_client_version',
				truthy(j.auto_client_version) ? '1' : '0');
			push(changed, 'auto_client_version');
		}
		if (type(j.client_version) === 'string' && length(trim(j.client_version)) > 0) {
			ctx.set('workbuddy', 'main', 'client_version', trim(j.client_version));
			push(changed, 'client_version');
		}

		// 公网访问开关 + 外部端口。先写配置再落地防火墙规则，这样即使规则失败，
		// 配置里记录的仍是用户的意图，下次 reload 会自动补齐。
		// wantWan 记录"本次是否触及了公网相关配置"——只要触及就重写规则，
		// 这样单独改外部端口（开关保持开启）也能立刻生效。
		let wanTouched = false;
		if ('wan_access' in j) {
			ctx.set('workbuddy', 'main', 'wan_access', truthy(j.wan_access) ? '1' : '0');
			push(changed, 'wan_access');
			wanTouched = true;
		}
		if ('wan_port' in j) {
			let raw = trim('' + j.wan_port);
			// 空 = 重置为跟随内部端口。写空串即可，loadConfig 会回退到内部端口。
			if (raw === '') {
				ctx.set('workbuddy', 'main', 'wan_port', '');
				push(changed, 'wan_port');
				wanTouched = true;
			} else {
				let wp = +raw;
				// 校验：必须是 1–65535 的整数，否则拒绝保存，不写脏值进 UCI
				if (wp < 1 || wp > 65535 || wp !== int(wp)) {
					jsonResponse(conn, 200, { ok: false, error: '外部端口必须是 1–65535 之间的整数' });
					return;
				}
				ctx.set('workbuddy', 'main', 'wan_port', '' + wp);
				push(changed, 'wan_port');
				wanTouched = true;
			}
		}

		let rc = ctx.commit('workbuddy');
		if (rc !== true && rc !== 0 && rc !== null) {
			jsonResponse(conn, 500, { ok: false, error: 'uci commit 失败' });
			return;
		}

		// 重新载入配置，让本次修改立即生效
		cfg = loadConfig();

		// 防火墙规则落地。失败时明确报错，不要让用户以为已经生效。
		if (wanTouched) {
			let r = applyWanAccess(cfg, cfg.wanAccess);
			if (!r.ok) {
				jsonResponse(conn, 200, {
					ok: false,
					error: r.error,
					changed: changed,
					wan: wanAccessStatus(cfg),
				});
				return;
			}
			logInfo('wan: ' + (cfg.wanAccess ? 'on' : 'off') +
				(cfg.wanAccess ? ' (wan:' + cfg.wanPort + ' -> lan:' + cfg.port + ')' : ''));
		}

		logInfo('admin saved config: ' + join(',', changed));
		jsonResponse(conn, 200, {
			ok: true,
			changed: changed,
			wan: wanAccessStatus(cfg),
		});
		return;
	}

	// 公网访问：单独查询实际生效状态
	if (path === '/admin/api/wan' && method === 'GET') {
		jsonResponse(conn, 200, { ok: true, wan: wanAccessStatus(cfg) });
		return;
	}

	jsonResponse(conn, 404, { error: { message: 'no such admin endpoint' } });
}

// 用当前池中下一个凭据发起上游请求。
// 失败（限流 / 鉴权失败 / 空响应）时自动换凭据重试，直到用完 tryLimit。
function dispatch(conn, head, body) {
	let req = parseHead(head);
	let method = req.method;
	// 分离 path 与 query
	let qIdx = index(req.path, '?');
	let path = (qIdx >= 0) ? substr(req.path, 0, qIdx) : req.path;
	let query = (qIdx >= 0) ? substr(req.path, qIdx + 1) : '';

	// /health 始终放行，便于探活与端口映射自检
	let isHealth = (method === 'GET' && path === '/health');

	// ---------- 管理页：独立鉴权，不走 API 密钥 ----------
	if (path === '/admin' || substr(path, 0, 7) === '/admin/') {
		handleAdmin(conn, req, method, path, query, body);
		return;
	}

	if (!isHealth && authRequired(cfg)) {
		let hit = matchApiKey(cfg, req.headers, query);
		if (hit === null) {
			logErr(sprintf('unauthorized request from %s to %s', conn.ip || '?', path));
			jsonResponse(conn, 401, {
				error: {
					message: 'unauthorized: 缺少或无效的 API 密钥',
					hint: '请携带 Authorization: Bearer <密钥> 或 X-API-Key 头',
				},
			});
			return;
		}
		conn.apiKeyName = hit.name || hit.id || '';
	}

	// GET /health
	if (isHealth) {
		let pool = loadPool(cfg);
		let ups = loadUpstreams();
		let upEnabled = 0;
		let upKeys = 0;
		for (let u in ups) {
			if (u.enabled) upEnabled++;
			upKeys += length(u.keys);
		}
		jsonResponse(conn, 200, {
			ok: true, service: 'luci-app-workbuddy',
			hasToken: (length(pool) > 0),
			credentials: length(pool),
			authRequired: authRequired(cfg),
			apiKeysDefined: apiKeysDefined(),
			apiKeysActive: length(loadApiKeys()),
			onlyFreeModels: cfg.onlyFree,
			clientVersion: clientVersion(cfg),
			autoClientVersion: cfg.autoVersion,
			adminEnabled: adminEnabled(cfg),
			upstreams: length(ups),
			upstreamsEnabled: upEnabled,
			upstreamKeys: upKeys,
			version: APP_VERSION,
		});
		return;
	}

	// GET /models, /v1/models
	if (method === 'GET' && (path === '/models' || path === '/v1/models')) {
		let list = availableModels(cfg);
		let data = [];

		// 全部来源统一带供应商前缀，客户端一眼看出模型来自哪：
		//   workbuddy/deepseek-v4.1-flash   ← 本机 WorkBuddy 自身
		//   sensenova/deepseek-v4-flash     ← 自定义上游
		// 设计取舍：统一加前缀虽然有悖"改动最小"，但混用（一部分带、一部分不带）
		// 会让客户端无法判断某个模型到底该走哪个上游 —— 例如名字恰好叫
		// "sensenova/xxx" 的原生模型会被误路由。统一加前缀消除这种歧义。
		for (let m in list) {
			let e = { id: WB_PREFIX + '/' + m.id, name: m.name, object: 'model' };
			if (m.contextWindow) e.context_window = m.contextWindow;
			if (m.maxTokens) e.max_tokens = m.maxTokens;
			push(data, e);
		}

		// 追加自定义上游的模型（逐个上游拉取其 /models）
		let ups = loadUpstreams();
		for (let u in ups) {
			if (!u.enabled) continue;
			let remote = fetchUpstreamModels(u);
			for (let m in remote) {
				push(data, {
					id: u.prefix + '/' + m.id,
					name: m.id + ' · ' + u.name,
					object: 'model',
					provider: u.prefix,
					base_url: u.baseUrl,
				});
			}
		}

		jsonResponse(conn, 200, { object: 'list', data: data });
		return;
	}

	// GET /upstreams —— 自定义上游状态（不含 Key 明文，仅掩码）
	if (method === 'GET' && path === '/upstreams') {
		jsonResponse(conn, 200, { ok: true, upstreams: upstreamStatus() });
		return;
	}

	// GET /credentials —— 查看凭据池状态（不含 token 本身）
	if (method === 'GET' && path === '/credentials') {
		let pool = loadPool(cfg);
		let now = time();
		let out = [];
		for (let c in pool) {
			let st = credState[c.id] || {};
			push(out, {
				id: c.id,
				source: c.source,
				cooling: (st.coolUntil || 0) > now,
				coolRemain: ((st.coolUntil || 0) > now) ? ((st.coolUntil || 0) - now) : 0,
				fails: st.fails || 0,
				lastError: st.lastErr || '',
			});
		}
		jsonResponse(conn, 200, { ok: true, count: length(out), credentials: out });
		return;
	}

	// GET /login
	if (method === 'GET' && path === '/login') {
		let r = startWebLogin(cfg);
		jsonResponse(conn, r.ok ? 200 : 502, r);
		return;
	}

	// GET /login/status
	if (method === 'GET' && path === '/login/status') {
		let pool = loadPool(cfg);
		jsonResponse(conn, 200, {
			hasToken: (length(pool) > 0),
			credentials: length(pool),
			loginRunning: login.running,
			loginOk: login.ok,
			lastError: login.lastError,
			authUrl: login.authUrl,
			cacheFile: tokenPath(cfg),
		});
		return;
	}

	if (method !== 'POST') {
		jsonResponse(conn, 405, { error: { message: 'method not allowed' } });
		return;
	}

	handleChat(conn, body);
}

// ---------- 连接读取与接受 ----------
// 注意：ucode 的函数声明不提升（no hoisting），被引用的函数必须先定义。
// 因此这里的顺序固定为：onData（引用 dispatch）→ onAccept（引用 onData）。

function onData(conn) {
	if (conn.closed) return;

	let chunk;
	try {
		chunk = conn.sock.recv(8192);
	} catch (e) {
		closeConn(conn);
		return;
	}

	if (chunk === null) {
		closeConn(conn);
		return;
	}
	if (length(chunk) === 0) {
		closeConn(conn);
		return;
	}

	conn.buf += chunk;

	// 找 header 结束
	if (conn.headerEnd < 0) {
		let idx = index(conn.buf, '\r\n\r\n');
		if (idx < 0) {
			if (length(conn.buf) > 65536) closeConn(conn);
			return;
		}
		conn.headerEnd = idx + 4;
		let head = substr(conn.buf, 0, idx);
		conn.head = head;
		let cl = match(head, /\r\nContent-Length:\s*([0-9]+)/i);
		conn.bodyLen = cl ? +cl[1] : 0;
	}

	let got = length(conn.buf) - conn.headerEnd;
	if (got < conn.bodyLen) return;

	let body = substr(conn.buf, conn.headerEnd, conn.bodyLen);
	try {
		dispatch(conn, conn.head, body);
	} catch (e) {
		logErr('dispatch error: ' + e);
		jsonResponse(conn, 500, { error: { message: '' + e } });
	}
}

function onAccept(listenSock) {
	let addr = {};
	let peer = listenSock.accept(addr, socket.SOCK_CLOEXEC);
	if (!peer) return;

	// 关闭 Nagle 算法：让 SSE 的逐字小分片立即发出，显著降低流式延迟
	try { peer.setopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, true); } catch (e) { }

	let conn = {
		sock: peer,
		buf: '',
		handle: null,
		headersSent: false,
		closed: false,
		bodyLen: 0,
		headerEnd: -1,
		ip: (addr && addr.address) ? addr.address : '?',
	};
	push(connections, conn);

	// ULOOP_BLOCKING：本 ucode 版本中，若 fd 被置为非阻塞，socket/proc 的
	// recv()/read() 会因 EAGAIN 返回 null 而被误判为 EOF。加此标志保证读取可靠。
	conn.handle = uloop.handle(peer, () => onData(conn), uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);
}

// ---------- 启动 ----------

function main() {
	if (!cfg.enabled) {
		logInfo('service disabled in config');
		return;
	}

	uloop.init();

	let listenSock = socket.create(socket.AF_INET, socket.SOCK_STREAM, 0);
	if (!listenSock) {
		logErr('socket create failed: ' + socket.error());
		return;
	}
	listenSock.setopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, true);

	if (!listenSock.bind(cfg.host + ':' + cfg.port)) {
		logErr('bind failed on ' + cfg.host + ':' + cfg.port + ': ' + listenSock.error());
		return;
	}
	if (!listenSock.listen(64)) {
		logErr('listen failed: ' + listenSock.error());
		return;
	}

	uloop.handle(listenSock, () => onAccept(listenSock), uloop.ULOOP_READ | uloop.ULOOP_BLOCKING);

	let pool = loadPool(cfg);
	let keys = loadApiKeys();
	logInfo(sprintf('listening on %s:%d -> %s (credentials=%d, apikeys=%d, auth=%s)',
		cfg.host, cfg.port, cfg.endpoint, length(pool), length(keys),
		authRequired(cfg) ? 'on' : 'OFF'));

	if (length(pool) === 0)
		logInfo('no credential yet - visit /login or call any model to start login');
	if (!authRequired(cfg))
		logInfo('warning: no API key configured, service is open to anyone who can reach it');
	if (cfg.onlyFree)
		logInfo('only_free_models: on (收费模型将被过滤，chat 自动替换为免费模型)');

	// 预热模型缓存：启动 1.5 秒后后台拉取一次，避免首个 /models 请求等待。
	// 拉取是阻塞的，但只发生一次，且监听已先就绪。
	uloop.timer(1500, () => {
		if (length(loadPool(cfg)) === 0) return;
		availableModels(cfg);
		logInfo('model cache warmed');
	});

	uloop.run();
	uloop.done();
}

main();
