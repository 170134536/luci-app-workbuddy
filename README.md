# AI 中转服务器（luci-app-workbuddy）

在 OpenWrt / ImmortalWrt 路由器上运行 **AI 中转服务器**，把**本机 WorkBuddy 账号**
与**任意多个第三方 OpenAI 兼容服务器**聚合起来，对局域网/公网暴露**统一的
OpenAI 兼容接口**（`/v1/chat/completions`、`/v1/models`）。

每台服务器 = 一个 API 地址 + 一组 Key，组内 Key 自动轮询做负载均衡；
模型统一带 `<服务器前缀>/` 前缀，客户端据此选择走哪台服务器。

配套两块界面：

| 界面 | 位置 | 用途 |
| --- | --- | --- |
| **独立管理网页** | `http://<路由器IP>:8789/admin` | 日常管理：服务器与 Key、API 密钥、凭据池、模型策略。用管理员密码登录 |
| **LuCI 状态页** | 服务 → AI 中转服务器 | 只读查看运行状态；设置管理员密码 |

> 设计取舍：日常管理放在独立网页，是因为它需要在**公网**上也能用（LuCI 默认只在内网）。
> LuCI 页面因此精简为「状态展示 + 管理员密码设置」，避免同一份配置两处维护。

> **命名说明**：对外可见的名字是「AI 中转服务器」。内部标识符（UCI 配置节
> `workbuddy`、服务名 `/etc/init.d/workbuddy`、ucode 模块 `workbuddy.uc`、
> rpcd 对象名）**保持不变** —— WorkBuddy 上游的登录流程、凭据文件、已有配置
> 都绑定在这些路径上，改内部名需要数据迁移且会打断运行中的实例。

## 这是什么

WorkBuddy 官方客户端只在 PC / 移动端提供。本插件把它的接口协议**用纯 ucode 重新实现**，
让路由器本身成为一个常驻中转：家里任何设备（手机、平板、电视盒子、其他电脑）
只要支持自定义 OpenAI 接口，就能共享同一个 WorkBuddy 账号；
同时还能挂接第三方服务（日日新、点点等），把它们也统一到一个入口下。

路由器上没有 Node.js、没有 TLS 库，因此本实现：

| 环节 | 做法 | 原因 |
| --- | --- | --- |
| 进程与事件循环 | `ucode-mod-uloop` | 路由器原生，内存占用低 |
| HTTP 服务端 | `ucode-mod-socket` 监听 TCP，手写 HTTP 解析 | 无需引入额外 Web 服务 |
| HTTPS 上游 | 调用 `curl` 子进程 | ucode 无 TLS 能力，这是唯一可靠路径 |
| 配置存储 | `uci`（`/etc/config/workbuddy`） | 与系统一致，可被 LuCI 直接管理 |
| 凭据存储 | `/etc/workbuddy/token.json`（权限 600） | 与 UCI 分离，避免配置备份泄露凭据 |
| 服务器配置 | `/etc/workbuddy/upstreams.json`（权限 600） | 第三方地址与 Key，同样不进配置备份 |
| 管理页鉴权 | sha256 签名 Cookie（含过期戳） | 见下文「管理页安全设计」 |

## 运行时要求

- 内核：已在 **6.18.44**（ImmortalWrt SNAPSHOT, qualcommax/ipq60xx, aarch64）实测
- `ucode` 及模块：`fs`、`uloop`、`socket`、`uci`、`ubus`、`digest`
- `curl`（带 TLS）
- `luci-base`、`rpcd`（管理界面）
- 内存：实测常驻约 3–5 MB

## 核心功能

### 1. API 密钥可随时查看与复制

管理网页 → 「API 密钥」标签页会列出**全部密钥的明文值**（含已禁用的），
每条都有「复制」按钮。密钥不是"只显示一次"：

- 明文本来就存在 `/etc/workbuddy/apikeys.json`（600 权限）里才能做校验，
  "只显示一次"只是界面上的选择，不是存储限制
- 管理页登录后即可随时查看、复制、启用/停用、删除

### 2. 客户端版本自动获取

配置项 `auto_client_version` 默认开启。获取策略是**多源探测 + 自校准 + 下限兜底**：

1. 依次尝试 `VERSION_SOURCES` 里的探测地址（`/api/version`、`/version.json`）
2. **自校准**：记录上游实际接受过的最高版本号（`/etc/workbuddy/version.json`）。
   上游对版本号很宽松，因此"能成功请求的版本"比任何探测源都可靠
3. 全部失败时回退到配置里的 `client_version`（默认 `5.5.2`）

> 已核实：官方**没有**公开的客户端版本接口。`/v3/config` 只含插件市场的
> `versionUrl`；`/v3/version`、`/version.json` 等均 404；`download.codebuddy.cn/version.json`
> 是 CodeBuddy 的清单（且无 Windows 条目）。因此采用上述策略而非依赖单一接口。

关闭自动获取：LuCI 管理页或管理网页里把 `auto_client_version` 设为 `0`，
即固定使用 `client_version`。

### 3. 仅免费模型（防扣费）

`only_free_models` 默认开启：

- `/v1/models` 只返回免费额度模型（x0.00 积分）
- chat 请求若指定收费模型，**自动替换**为免费模型并记录日志

已实测确认的免费模型：`deepseek-v4.1-flash`、`hy4-preview-f`、`hy3`。

### 4. 多凭据负载均衡

多条凭据轮流使用，避免单账号被限流：

- 某条凭据失败会进入 60 秒冷却，自动切到下一条
- 冷却中的凭据会在管理页标出剩余时间
- 凭据来源：网页登录（`token.json`，作为 `default`）+ 手动添加（`pool.json`）

### 5. 服务器管理（多 API 地址 + 批量 Key 负载均衡）

这是本插件的核心能力。**每台服务器 = 一个 API 地址 + 一组 Key**，
可在管理页随时添加、修改、停用、删除。

**内置服务器（不可删除）**

| 服务器 | 地址 | Key 来源 |
|---|---|---|
| WorkBuddy | `https://www.workbuddy.ai` | 账号凭据池（见「凭据池」页，支持多账号轮询） |

内置服务器在列表里固定显示为第一张卡（左侧有蓝色标条），**没有删除按钮** ——
删掉它免费模型与凭据池就没有入口了；需要停用它请到「设置」页关闭服务。

**自定义服务器（可自由增删）**

任何 OpenAI 兼容服务都能接入。每台服务器配：

- **名称** —— 备注用，会显示在模型列表的 `name` 里（`模型名 · 名称`）
- **模型前缀** —— 路由依据，只能用小写字母、数字、`-`、`_`，长度 2–32
- **服务器 API 地址** —— 填到 `/v1` 为止，本服务自动拼接 `/chat/completions` 与 `/models`
- **API Key 密钥** —— **每行一条，支持批量粘贴**，自动去重、自动去首尾空格

**Key 负载均衡**

- 请求时从该服务器的 Key 池中**轮流取用**（round-robin）
- 某条 Key 失败（限流/鉴权失败/额度耗尽）→ 该 Key 进入冷却，自动换下一条重试
- 连续失败按指数退避，冷却上限 10 分钟；成功后立即恢复
- 冷却中的 Key 在管理页以黄色徽章标出剩余秒数，悬停可看最后一次错误
- 同一台服务器的多条 Key 互相独立，**每台服务器各自维护轮询游标**

**模型路由**

请求的模型名决定走哪台服务器，**所有**来源统一带服务器前缀：

| 模型名前缀 | 实际去向 |
|---|---|
| `workbuddy/` | 本机 WorkBuddy 凭据池（多账号轮询） |
| `<自定义前缀>/` | 对应的第三方服务器，用它自己的 Key 池 |
| 无斜杠（如 `hy3`） | 按原名直发 WorkBuddy，兼容旧客户端 |

前缀不存在时返回 400 `unknown upstream prefix: xxx`。

配置存于 `/etc/workbuddy/upstreams.json`（权限 600）。同一前缀不允许重复，
否则路由会有歧义，添加时会被拒绝。

> **免费模型防护（`onlyFree`）不作用于自定义服务器的模型** —— 它们本就不是
> WorkBuddy 的模型，用 WorkBuddy 的免费清单去校验必然"不通过"，会把请求
> 错误地改写成 WorkBuddy 的默认模型。

### 6. 公网访问开关

管理页的「设置」标签页里有一个独立开关，一键控制**管理页与 API** 是否对公网开放。
**默认关闭**，只允许局域网访问。

打开开关后，插件会**自动**在 UCI firewall 里创建端口转发规则
（`workbuddy_wan`，WAN → 本机监听端口）并 reload 防火墙；关闭时自动删除该规则。
不需要你手工去「网络 → 防火墙 → 端口转发」配置。

**自定义公网端口**：开关下方有一个「公网端口」输入框，可以把外网端口和内网端口分开：

```
外网 http://<公网IP>:18789  →  路由器 18789 端口  →  本机 8789（内部监听，不变）
```

- 留空 = 内外端口一致（都用 `port`）
- 填一个不显眼的端口（如 `18789`）能降低被扫描概率
- 端口必须是 1–65535 的整数，非法值会被拒绝；改成空串会回退到内部端口
- 开关保持开启时改端口，保存后立即重写规则生效

| 状态 | 含义 |
| --- | --- |
| 仅局域网可访问 | 默认。无防火墙规则 |
| 已生效 | 规则已建且 nftables 已放行，外网可达 |

**安全护栏**

- **未设置管理密码时拒绝开启** —— 此时开放公网等于任何人都能登录，接口会直接报错
- 开启时前端会二次确认，页面同时显示风险提示
- 关闭是幂等的，规则会被立即回收
- 即使开着，管理页仍受管理员密码保护、API 仍受 API 密钥保护

> 为什么写 UCI 而不是直接塞 nft 规则：fw4 会在 reload 时**重建整张 nftables 表**，
> 手写的 nft 规则会被冲掉；写进 UCI 才能被 fw4 持久地重新生成。
> 附带好处是规则在 LuCI 防火墙页面可见可审计，你想手动关掉也有地方关。

## 安装

### 方式一：源码编译（推荐用于正式分发）

把本目录放进 OpenWrt/ImmortalWrt 的 `package/` 或 feed 中：

```sh
# 在 SDK 或 buildroot 根目录
make package/luci-app-workbuddy/compile V=s
# 产物在 bin/packages/<arch>/base/luci-app-workbuddy_1.0.0-r1_*.apk
```

依赖 LuCI 的构建体系（`feeds/luci/luci.mk`），因此需要先执行 `./scripts/feeds install -a`。

### 方式二：设备上直接部署（无 SDK 时）

ImmortalWrt SNAPSHOT 使用 apk v3 格式，而设备端不含 `abuild` / `apk adbsign`，
无法本地打包。此时用附带的安装脚本按文件结构就地部署：

```sh
# 把整个目录上传到路由器后
cd /root/luci-app-workbuddy
sh install.sh
```

脚本会：检查并自动安装缺失依赖 → 部署文件 → 注册 procd 服务 → 重启 rpcd/uhttpd
→ 校验端口与 `/health`。

卸载：

```sh
sh install.sh remove
```

## 配置

配置文件 `/etc/config/workbuddy`。

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `enabled` | `1` | 是否启用服务 |
| `port` | `8789` | 监听端口 |
| `host` | `0.0.0.0` | 监听地址；`127.0.0.1` 表示仅本机 |
| `only_free_models` | `1` | 仅免费模型：过滤模型列表并在转发前替换收费模型 |
| `wan_access` | `0` | 公网访问开关：`1` 时自动创建防火墙转发规则并放行 WAN |
| `wan_port` | 空 | 公网外部端口：留空跟随 `port`；设置后外网端口与内网端口分离 |
| `auto_client_version` | `1` | 自动获取客户端版本（多源探测 + 自校准） |
| `client_version` | `5.5.2` | 客户端版本；自动获取失败时作为兜底 |
| `admin_password` | 空 | 管理网页密码；留空则管理网页停用 |
| `endpoint` | `https://www.workbuddy.ai` | 内置服务器（WorkBuddy）地址 |
| `token_file` | `/etc/workbuddy/token.json` | 凭据缓存路径 |
| `share_token` | 空 | 旧版单一令牌（兼容用）；推荐改用 API 密钥 |
| `debug` | `0` | 调试日志 |

配置项大多可在**管理网页 → 服务设置**里改；改完自动生效，无需手动重启。
管理网页不可用时（例如忘了密码），直接改本文件：

```sh
uci set workbuddy.main.admin_password='新密码'
uci commit workbuddy
/etc/init.d/workbuddy restart
```

### 数据文件

| 路径 | 权限 | 内容 |
| --- | --- | --- |
| `/etc/workbuddy/token.json` | `600` | 网页登录凭据，对应池中的 `default` |
| `/etc/workbuddy/pool.json` | `600` | 多账号凭据池 |
| `/etc/workbuddy/apikeys.json` | `600` | API 密钥列表（含明文值） |
| `/etc/workbuddy/upstreams.json` | `600` | 自定义服务器配置（地址 + 多条 Key） |
| `/etc/workbuddy/version.json` | `600` | 客户端版本自校准缓存 |

## 管理网页

独立的管理面板，地址 `http://<路由器IP>:8789/admin`。

### 首次使用

1. 在 LuCI（**服务 → WorkBuddy**）的「管理员密码」栏设置密码并保存
2. 或者命令行：`uci set workbuddy.main.admin_password='你的密码'; uci commit workbuddy; /etc/init.d/workbuddy reload`
3. 浏览器打开 `http://<路由器IP>:8789/admin`，输入密码登录

未设置密码时访问 `/admin` 会提示「未设置管理员密码」，不会暴露任何信息。

### 功能

| 标签页 | 内容 |
| --- | --- |
| **概览** | 运行状态、凭据数、密钥数、客户端版本、当前模型 |
| **API 密钥** | 列出全部密钥明文，支持复制、新建、启用/停用、删除 |
| **服务器管理** | 服务器增删改查：添加/测试/改 Key/停用/删除，显示每条 Key 的冷却状态 |
| **凭据池** | 多账号轮询管理：查看/添加/测试/停用/删除，过期提示与自动判重 |
| **服务设置** | 仅免费模型、客户端版本自动获取、固定版本号、**公网访问开关** |

### 服务器管理

「服务器管理」页分两块：上面是**服务器列表**，下面是**添加服务器**表单。

**服务器列表**第一张卡固定是内置的 WorkBuddy（左侧蓝条标记为「内置」，
带「已登录/未登录」状态与账号数），它没有删除按钮。其余是自定义服务器卡片。

**添加服务器需要填**

| 字段 | 说明 |
| --- | --- |
| 服务器名称 | 备注用，会显示在模型列表的 `name` 里（`模型名 · 名称`） |
| 模型前缀 | 路由依据。客户端里模型名要写成 `前缀/模型名` |
| 服务器 API 地址 | 填到 `/v1` 为止，例如 `https://token.sensenova.cn/v1` |
| API Key 密钥 | **每行一条，支持批量粘贴**；空行与重复项会被自动去掉 |

**卡片上的状态**

| 徽章 | 含义 |
| --- | --- |
| 内置 | WorkBuddy 自身，不可删除 |
| 启用 / 已停用 | 停用后该服务器的模型从 `/v1/models` 消失，请求会被拒 |
| N/M Key 可用 | M 条 Key 中当前有 N 条不在冷却中 |
| 绿底 Key | 可用 |
| 黄底 Key | 冷却中，悬停可看最后一次错误 |

**每张卡的操作**

- **测试** —— 用该服务器的 Key 拉一次 `/models`，成功时弹出前 6 个模型名
- **改 Key** —— 打开弹层，粘贴新的一组 Key **批量覆盖**原有全部 Key
- **停用 / 启用**
- **删除** —— 二次确认后删除该服务器及其全部 Key，同时清掉内存里的冷却记录

> 注意「删除」与「停用」的区别：**停用**只是让模型从列表消失、请求被拒，
> 配置与 Key 都还在，随时可以再启用；**删除**会连同 Key 一起永久移除。

### 凭据池管理

「凭据池」页分两块：上面的表格列出池中全部凭据，下面的「添加凭据」提供两种方式。

**条目的状态徽章**

| 徽章 | 含义 |
| --- | --- |
| 正常 | token 有效且剩余有效期充足 |
| N 天后过期 | 有效，但不足 30 天到期，提前提醒 |
| N 天后过期（黄） | 不足 7 天到期，需要尽快处理 |
| 已过期 | token 已失效，**不会参与轮询**，请重新登录或更换 |
| 冷却 Ns | 该账号刚被上游限流，暂停使用 N 秒后自动恢复 |
| 已停用 | 手动停用，保留在池中但不参与轮询 |

**添加方式一 · 登录账号获取**
点「登录并添加账号」，页面会打开授权链接（同时显示可复制链接）。
在浏览器里完成 WorkBuddy 授权后，凭据自动加入池中。授权窗口 300 秒。
刷新页面不会丢失正在进行的登录流程。

**添加方式二 · 手动添加 token**
粘贴 access token 即可，会自动去掉 `Bearer ` 前缀和首尾引号。

**自动判重（两层）**

| 情况 | 结果 |
| --- | --- |
| token 内容完全相同 | 拒绝，提示已存在并指出是哪个条目 |
| 同一账号的另一个 token（JWT `sub` 相同） | 拒绝，提示该账号已在池中 |
| 已过期的 token | 拒绝，提示重新登录 |
| 不是合法 JWT / 解析不出 payload | 拒绝，提示确认复制完整 |

> 判重同时覆盖 `pool.json` 与网页登录凭据（`token.json`）。
> 只查前者会漏掉「把自己当前登录的账号再添加一遍」这个最常见的重复场景。

**账号与有效期从哪来**
WorkBuddy 的 access token 是标准 JWT，管理页直接解析其 payload：

| 字段 | 用途 |
| --- | --- |
| `exp` | 计算剩余天数，驱动过期徽章，并在轮询时跳过已过期凭据 |
| `preferred_username` | 显示账号名；手动添加时留空名称则自动采用它 |
| `sub` | 账号唯一 ID，用于识别「同账号的不同 token」 |

解析在 ucode 内实现（`b64UrlDecode` + `parseJwt`），**不验签**——
这里只用于展示与去重，不做安全判断。

### 管理页安全设计

| 项目 | 做法 | 理由 |
| --- | --- | --- |
| 会话凭证 | `sha256(salt+密码+过期戳)` 的前 32 位十六进制 | 不用明文/MD5；把过期时间签进去，服务端能真正拒绝过期会话 |
| Cookie 属性 | `Path=/; Max-Age=86400; HttpOnly; SameSite=Lax` | **刻意不加 `Secure`**：面板走局域网明文 HTTP，加了 `Secure` 浏览器就永不回传 Cookie，表现为"密码正确却登录不上"且无任何报错 |
| 绑定 UA | **不绑定** | UA 由客户端控制，绑定会造成无故掉线 |
| 改密码 | 立即失效所有会话 | 签名里含密码，改后旧签名自然失效 |
| 登录限速 | 同一来源 IP 连错 8 次锁定 300 秒 | 防暴力破解 |
| 页面依赖 | 全部内联 HTML/CSS/JS | 面板要在无外网的局域网可用，不能依赖 CDN |

> 锁定是内存态，重启服务即解除。忘记密码时改 `admin_password` 即可。

## 登录 WorkBuddy 账号

服务需要 WorkBuddy 的 access token。有两种方式：

### 网页授权（推荐）

浏览器访问 `http://<路由器IP>:8789/login`（需带 API 密钥）完成授权，
或在管理网页的「凭据池」页点「登录 WorkBuddy」。

返回的 `authUrl` 用浏览器打开完成授权，凭据会在约 1 秒内自动写入路由器。
授权窗口 300 秒。

### 手动导入已有凭据

如果 PC 上已经登录过 WorkBuddy，可直接复用其凭据文件：

```sh
# 在电脑上找到 token.json（DSH 插件用户通常在 ~/.dsh-workbuddy/token.json）
# 复制到路由器 /etc/workbuddy/token.json 后
chmod 600 /etc/workbuddy/token.json
/etc/init.d/workbuddy restart
```

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/health` | 存活、凭据数、服务器数、鉴权开关状态、公网访问状态 |
| GET | `/models`、`/v1/models` | 模型列表（OpenAI 格式；开启仅免费时只含免费模型） |
| GET | `/credentials` | 凭据池冷却/失败状态（不含 token 本身） |
| GET | `/upstreams` | 服务器状态（Key 只回掩码，不含明文） |
| GET | `/login` | 发起网页登录，返回授权链接 |
| GET | `/login/status` | 登录进度 |
| POST | `/v1/chat/completions` | 对话补全，支持流式 |

### 鉴权

只要在 LuCI 里生成过 **任意一条 API 密钥**，所有请求都必须携带密钥：

- `Authorization: Bearer <密钥>`（推荐）
- `X-API-Key: <密钥>`
- `?key=<密钥>`

`/health` 始终免鉴权，方便探活。

> **安全要点**：即使在界面上把密钥全部「禁用」，代理**依然保持强制鉴权**，
> 只是这些密钥都无法通过校验（一律 401）。这是刻意设计 —— 避免误操作
> 禁用最后一条密钥后，代理直接对公网敞开。

### 仅免费模型

`only_free_models`（默认开启）做两件事：

1. `/v1/models` 只返回倍率为 `x0.00` 的免费模型；
2. 若客户端仍请求了收费模型，转发前自动替换成免费模型，并在日志留痕：
   `only_free: model "hy4-preview" not free -> fallback "deepseek-v4.1-flash"`

这样即使客户端内置了收费模型名，也不会产生费用。

> **注意**：该项**不作用于自定义服务器的模型**。第三方服务器的模型名不在
> WorkBuddy 的免费清单里，若也走这个替换逻辑，会被错误地改写成 WorkBuddy
> 的默认模型。判据是请求是否被路由到自定义服务器。

### 模型名与路由

发往 `/v1/chat/completions` 的 `model` 字段决定实际去向：

```
workbuddy/deepseek-v4.1-flash   → 内置 WorkBuddy，它收到 "deepseek-v4.1-flash"
sensenova/deepseek-v4-flash     → 该服务器，它收到 "deepseek-v4-flash"
askdiandian/dots3-note-prev     → 该服务器，它收到 "dots3-note-prev"
hy3                             → 无斜杠，按原名直发 WorkBuddy（兼容旧客户端）
```

- 前缀不存在时返回 400：`unknown upstream prefix: xxx`
- 无斜杠的模型名不做前缀解析，直接走 WorkBuddy，老客户端无需改动
- `stream` 字段会原样透传给自定义服务器，因此非流式请求拿到的是完整 JSON；
  WorkBuddy 自身始终返回 SSE，非流式由本代理合并

### 调用示例

```sh
curl http://192.168.69.1:8789/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer wb-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
  -d '{
    "model": "workbuddy/hy3",
    "messages": [{"role":"user","content":"你好"}],
    "stream": true
  }'
```

流式与非流式都支持：请求体 `"stream": false` 时服务会把 SSE 流合并成一个
标准 completion 对象返回。

## 多账号凭据池（负载均衡）

一个账号在 WorkBuddy 繁忙时可能被限流。**管理网页 → 凭据池** 可以把多个账号的
`accessToken` 加入池中，代理会：

- **轮询**：每次请求按游标依次选用不同凭据，均匀分摊压力；
- **失败自动切换**：某个凭据返回 401 / 429 / 空响应时，立刻换下一个重试
  （单次请求最多试 3 个凭据）；
- **自动冷却**：失败凭据进入指数退避冷却（60s 起，逐次翻倍，上限 600s），
  冷却期内不再被选中；成功后计数清零；
- **跳过过期凭据**：解析 JWT 的 `exp`，已过期的凭据不参与轮询，
  避免把请求浪费在死 token 上（但仍会显示在管理页，方便你更换）；
- **跨存储去重**：`pool.json` 与网页登录凭据（`token.json`）按 token 全文
  与账号 `sub` 双重判重，同一账号不会重复占用多个轮询位；
- **识别网关错误页**：WorkBuddy 网关失败时会返回 HTML 错误页（如
  `401 Authorization Required`）而不是 JSON，本服务能正确识别并计入冷却。

网页登录获得的凭据显示为「网页登录凭据」（id 固定为 `default`，不可删除/禁用，
需用「退出登录」清除）；手动添加的凭据可随时测试、启用、禁用、删除。

> **关于轮询的实测边界**：轮转算法本身已验证（3 个账号严格按
> `A → B → C → A` 交替）。但"多个真实账号互相接管"只有在池中确实存在
> **两个不同账号**时才会发生——同一账号的两个 token 会被判重合并为一条。

## 外网访问（公网 IP）

1. 在 **服务器管理 / API 密钥** 里先生成一条 API 密钥，并确认**管理员密码足够强**
   （两者都是公网暴露时的唯一防线）；
2. 进管理页 **设置 → 公网访问**，打开「允许公网调用管理页与 API」并保存。
   插件会自动创建并应用防火墙规则，无需手工配置。

   如需自定义外部端口，可到 **网络 → 防火墙 → 端口转发** 编辑那条
   `workbuddy_wan` 规则（例如改成 `18789` 降低被扫描概率）。

3. 路由器 WAN 若是公网 IP，即可用 `http://<公网IP>:8789/v1` 访问；
4. 若 WAN 是运营商大内网，需要另配 DDNS + 内网穿透，或让光猫做 DMZ。

> **开关默认关闭**，安装后不会自动暴露。想收回公网访问，把开关关掉即可 ——
> 规则会被立即删除并 reload 防火墙。

## 性能说明

- 上游 curl 关闭缓冲（`-N`），并为客户端连接设置 `TCP_NODELAY`，减少小包延迟；
- 转发缓冲 `16KB`，避免高频 `read()` 系统调用；
- 上游连接超时 5 秒，配合凭据切换做快速失败；
- 模型列表缓存 6 小时，并在服务启动 1.5 秒后预热，首个 `/v1/models` 请求不再等待。

## 接入第三方客户端

把「API 地址」填成 `http://<路由器IP或公网IP>:8789/v1`，密钥填上面生成的
**API 密钥**（若尚未生成密钥则随便填）。模型名填 `/v1/models` 返回的任一 `id`。

## 故障排查

```sh
# 服务状态
/etc/init.d/workbuddy status
netstat -ltn | grep 8789
curl -s http://127.0.0.1:8789/health

# 日志
logread | grep workbuddy
```

常见问题：

- **端口没监听**：`uci get workbuddy.main.enabled` 是否为 `1`；看 `logread` 是否有 ucode 报错。
- **`/models` 报错但 `/health` 正常**：多半是没登录，访问 `/login` 完成授权。
- **LuCI 里看不到菜单**：`/etc/init.d/rpcd restart` 并强制刷新浏览器缓存（Ctrl+F5）。
- **调用返回 502**：上游不可达，检查路由器能否解析并访问 `www.workbuddy.ai`。

## ucode 实现注意事项

本实现踩过并已规避的 ucode 与 JavaScript 的差异（改动代码时请留意）：

- **函数声明不提升**：被引用的函数必须先定义，否则运行时报
  `access to undeclared variable`。文件内函数顺序按依赖排列。
- **顶层 `let` / `const` 同样不提升**：函数编译时按**当时**的词法作用域解析标识符，
  所以被函数引用的模块级变量必须声明在该函数**之前**。本实现中
  `modelCache` 必须早于 `freeModelIds()`，`F`（前向引用表）必须早于
  `spawnUpstream()`。踩坑表现：`access to undeclared variable modelCache`。
- **没有 `String()` / `typeof` / `undefined`**：用 `'' + x` 转换、`type(x)` 判断类型、
  与 `null` 比较。**特别注意**：`obj.field !== undefined` 会直接抛
  `Reference error: access to undeclared variable undefined`，
  判断字段是否存在要用 `type(obj.field) === 'int' || type(obj.field) === 'string'`。
- **字符串函数是全局的**：`lc()`、`uc()`、`trim()`、`length()`、`substr()`、`replace()`、
  `match()`、`split()`、`join()`、`sprintf()`。
- **正则不支持 `(?:...)`**：非捕获组会报 `Repetition not preceded by valid expression`，
  改用普通捕获组。（`\s` / `\S` 可用，但 `\d` 不可用，请写 `[0-9]`。）
- **`popen()` 只接受字符串命令**：数组形式返回 `null`（"Invalid argument"）。
  因此所有外部数据必须经 `shquote()` 转义后拼入命令行。
- **`uloop.handle()` 需带 `ULOOP_BLOCKING`**：否则 fd 被置为非阻塞，
  `read()` / `recv()` 会因 EAGAIN 返回 `null`，被误判为 EOF。
- **没有 `log.info()`**：log 模块只提供 `syslog(level, fmt, ...)`，
  本实现直接输出到 stdout 交由 procd 转发。
- **没有 `getpid()`**：用 `time()` 配合 `clock()[1]` 生成唯一临时文件名。
- **没有目录遍历**：`opendir` / `readdir` / `closedir` 都不可用，
  所以多凭据池必须集中存放在单个 `pool.json` 里，而不是一个凭据一个文件。
- **没有 `decodeURIComponent`**：需自行实现百分号解码（见 `urlDecode()`）。
- **`sort()` 是原地排序**（返回原数组）。
- **对象字面量的数字键要加引号**：`{'200': 'OK'}`，否则语法错误。
- **rpcd 的 ucode 插件必须放在 `/usr/share/rpcd/ucode/`**：`/usr/libexec/rpcd/` 是
  shell 插件目录（用 `$1 = list|call` 参数约定），放错位置 rpcd 不会注册 ubus 对象。
- **rpcd 布尔参数会以字符串传入**：即使声明为 `bool`，`ubus -v list` 显示的仍是
  `String` 类型，且传 JSON 布尔值会被 ubus 以 `Invalid argument` 拒绝。
  LuCI 侧必须传 `'true'` / `'false'` 字符串，服务端用 `truthy()` 归一化。
- **不能从 rpcd 方法里调用 ubus**：rpcd 是单线程的，`ubus call ...` 会等待 rpcd
  自己处理，形成自等待死锁。调用方看到的是
  `Command failed: ubus call <obj> <method> (Unknown error)`，且没有任何日志。
  判断服务是否运行请改用 `ps` / pid 文件。
- **uci 的 `get_all()` 会带出元数据键**：`.anonymous` / `.type` / `.name` / `.index`
  都以点号开头。把它们原样放进 rpcd 的返回对象会让 ubus 序列化失败
  （同样表现为 `(Unknown error)`）。必须过滤掉点号开头的键。
- **`digest()` 不是全局函数**：必须 `require('digest')`，然后 `d.sha256(s)`；
  直接调用全局 `digest()` 会报 `left-hand side is not a function`。
- **`open()` / `writefile()` 不可靠地作为全局存在**：统一走 `require('fs')`，
  例如 `fs.open()` / `fs.writefile()` / `fs.dirname()` / `fs.rename()`。
- **字符串没有方法**：`s.replace()` / `s.match()` 会在运行时报
  `left-hand side expression is not an array or object`。
  但**全局函数** `replace(s, a, b)` 和 `match(s, re)` 是可用的。
- **没有 `undefined` 标识符**：写 `x !== undefined` 会抛
  `access to undeclared variable undefined`。判断键是否存在用 `'key' in obj`。
- **没有 `has()` 函数**：`has(obj, 'k')` 会报 `left-hand side is not a function`。
- **数组没有 `.push()` 方法**：`arr.push(x)` 会报 `left-hand side is not a function`。
  必须用全局函数 `push(arr, x)`。这个错误只在被调到的那一行才抛出，
  所以同一个文件里其它 `push()` 调用都正常时，很难注意到漏了一处。
- **`split()` 的参数顺序与 JS 相反**：ucode 是 `split(subject, separator)`，
  等价于 JS 的 `subject.split(separator)`。写成 `split('\n', text)`
  会按**字面字符 `n`** 切分并返回单元素数组（因为 text 里没有字母 n 时
  整串就是一段）。症状极具迷惑性：接口不报错，但"粘贴了一堆 Key
  却提示至少需要一条"。本实现曾因此在自定义上游的 Key 解析上栽过一次。
- **`delete obj[key]` 不可用**：会报
  `Reference error: left-hand side expression is not an object`。
  删除键要重建表（遍历时跳过目标键），数组中删元素用 `splice()`。
- **`match()` 只接受正则字面量**：`match(s, '/.../')`（字符串形式的模式）
  即使能匹配也返回 `null`。必须写成 `match(s, /.../)`。
  不做正则匹配时优先用 `index(s, sub)` + `substr()`，语义更直观。
- **`for (let x in array)` 取的是元素本身**（不是下标），
  这点与 JS 的 `for...in` 不同；对对象则遍历键。
- **函数重名会静默覆盖**：ucode 允许同名函数重复定义，只有最后一个生效，
  且不报错。管理页的 JS 函数与后端 ucode 函数同名时尤其容易踩到，
  建议 UI 侧函数统一加 `UI` 后缀（如 `addUpstreamUI`）。
- **多行输入不要用 `prompt()`**：浏览器原生 `prompt()` 是**单行**输入框，
  粘贴多行内容会被压成一行（换行丢失）。凡是"批量粘贴"场景
  （Key 列表、订阅链接等）都要用页面内 `<textarea>` 弹层。
  本实现的 `editUpKeys()` 就是为此从 `prompt()` 改成了弹层 `openModal()`。
- **产品改名时把名字提成常量**：界面上出现十几处的产品名若硬编码，
  改一次要动十几处且容易漏。本实现统一走 `const APP_NAME = 'AI 中转服务器'`，
  同时把**内部标识符**（UCI 节名、服务名、模块名、路由路径）与**显示名**
  彻底分开 —— 改显示名不影响任何已有配置与运行中的数据。
- **模板字符串里写 `onclick` 必须用 `\\'`（双反斜杠）** ← 本项目最凶险的坑。

  管理页整体是一个 ucode 反引号模板字符串，里面嵌了生成 HTML 的 JS。要在
  JS 字符串里输出 `\'`，源码必须写 **`\\'`**。实测四种写法的渲染结果：

  | 模板字符串里写的 | 实际渲染出 |
  | --- | --- |
  | `'a'` | `'a'` ✅ |
  | `\'a\'` | `'a'` ❌ 反斜杠被吃掉 |
  | `\\'a\\'` | `\'a\'` ✅ 正确 |
  | `\\\'a\\\'` | `\'a\'` ✅（多余反斜杠被合并） |

  踩坑表现：`onclick="testUp(\'' + esc(id) + '\')"` 渲染成
  `onclick="testUp('' + esc(id) + '')"` —— 引号被吃成两个连续单引号，
  浏览器解析整段 `<script>` 时抛 `SyntaxError`，**整个管理页的 JS 全部不执行**。

  症状是**页面能打开但永远停在「加载中…」**，因为 `load()` 根本没跑起来，
  而服务端一切正常（`/admin/api/state` 返回 200）。排查时容易误判成后端问题。

  验证方法：抓渲染后的 JS，`grep "('' + esc"` 应为 0 条。
  静态检查脚本 `.check-forward.ps1` 已加入该项检测（`TEMPLATE ESCAPE CHECK`）。

  > **修复记录（v1.5.1）**：这个 bug 在本项目里**一直存在**，不只是新增代码
  > 引入的 —— 密钥列表、凭据池的按钮全都中招，整段管理页 JS 因此从未真正
  > 跑起来过。表现就是页面能打开、标题正常，但所有面板永远停在「加载中…」。
  > 服务端 `/admin/api/state` 一直是好的，所以很容易误判成后端故障。
  > 本次把 13 处 `\'` 全部修正为 `\\'`，并加了静态检测防复发。

- **`.ps1` 脚本必须带 UTF-8 BOM**：不带 BOM 时 Windows PowerShell 会按本地
  代码页解析，中文字符串被误读并**污染后续代码的语法解析** —— 表现为
  脚本里明明正确的表达式抛「不能对 Null 值表达式调用方法」这类莫名错误。
  本次 `.check-forward.ps1` 加上 BOM 后才恢复正常。
- **字符串没有 `.indexOf()` / `.includes()`**：用全局 `match(s, /re/)`
  或 `index(s, sub)`。`.indexOf()` 与 `.push()` 报的是同一个错误信息
  （`left-hand side is not a function`），排查时要看行号而不是错误文本。
- **没有 `rand()` / `getpid()`**：生成密钥的熵来自
  `time()` + 进程内自增计数 + `/dev/urandom`，再经 sha256 混合。
- **没有 base64 模块，也没有全局 `b64dec` / `b64enc`**：
  `require('base64')` 报 `No module named 'base64' could be found`。
  本实现自带 `b64UrlDecode()`（纯 ucode 位运算，约 20 行），
  用于解析 JWT；只需解码，不需编码。
- **`popen` 不是全局函数**：`popen(...)` 报 `left-hand side is not a function`；
  要走 `require('fs').popen`。但解析 JWT 用自实现的解码器更划算，不必开子进程。

### 静态检查脚本

`.check-forward.ps1` 覆盖两类只在运行期暴露、且难靠语法检查发现的问题：

| 检查 | 拦住的错误 |
| --- | --- |
| 前向引用 | `access to undeclared variable <name>`（ucode 不提升函数与顶层 `let`/`const`） |
| 重复定义 | 后定义的函数静默覆盖前一个 |
| 不存在的内建方法 | `.push()` / `.replace()` / `.indexOf()` / `.has()` 等 → `left-hand side is not a function` |

```powershell
pwsh -File .check-forward.ps1
# 输出两项都 OK 才算通过
```

> 该脚本会跳过模板字符串区间，因为反引号里的 JS 是给浏览器执行的，
> 那里的 `.push()` / `.replace()` 都是合法的。

### 调试这类问题的有效手段

`ucode -c -o /dev/null <file>` 只做语法检查，**查不出**上述词法作用域问题。
真正的验证必须触发实际代码路径，然后看运行时错误：

```sh
logread | grep workbuddy          # 运行时报错会带文件、行号、调用栈
curl -s http://127.0.0.1:8789/health
```

本实现有两处刻意的写法：

1. **前向引用表**：`spawnUpstream → tryNextCred → onUpstreamEnd` 三者互相调用，
   无法用重排顺序解决，因此引入 `let F = {}`（声明在所有函数之前），
   彼此通过 `F.xxx()` 调用。
2. **基础工具集中在文件顶部**：ucode 对函数和顶层 `let`/`const` 都不做提升，
   `sha256Hex` / `secureEq` / `truthy` / `writeJsonFile` / `readJsonFile` /
   `genApiKey` 等被广泛复用的底层函数一律放在文件最前面的
   「基础工具函数」区，避免"定义在使用之后"。

仓库里附带两个自检脚本：

```powershell
pwsh -File .check-forward.ps1        # 静态检查，输出两项 OK 才算通过
```

```sh
# 在路由器上跑凭据池功能回归测试（36 项断言）
export WB_ADMIN_PW='你的管理员密码'
sh /root/luci-app-workbuddy/pool-test.sh

# 服务器与上游功能回归测试（17 项断言，含真实上游对话与 Key 轮询）
sh /root/luci-app-workbuddy/upstream-test.sh

# 服务器增删改查回归测试（11 项断言，含批量 Key 与去重）
sh /root/luci-app-workbuddy/server-test.sh

# 公网访问开关回归测试（30 项断言，含真实防火墙规则建/删、自定义外部端口与安全护栏）
sh /root/luci-app-workbuddy/wan-test.sh
```

四套合计 **94 项断言**。当前实测结果：`36 / 17 / 11 / 30` 全部通过。

静态检查除「前向引用」「非法方法」外，还含一项 **`TEMPLATE ESCAPE CHECK`** ——
专门扫模板字符串里 `onclick` 的引号转义。改动管理页后务必跑一遍：

```sh
pwsh -File .check-forward.ps1        # 应输出 3 项 OK
```

> `upstream-test.sh` 会真的往各服务器发请求，因此可能触发对方的限流
> （日日新有 RPM 限制）。测试脚本开头有 60 秒等待，用于让上一轮冷却结束。
> `server-test.sh` 只用示例地址 `example.com`，不产生真实请求。

## 目录结构

```
luci-app-workbuddy/
├── Makefile                                  OpenWrt 包定义
├── install.sh                                设备端直接部署脚本
├── README.md
├── .check-forward.ps1                         ucode 静态检查（前向引用/重复定义/非法方法）
├── pool-test.sh                               凭据池功能回归测试（36 项）
├── .upstream-test.sh                          服务器/上游功能回归测试（17 项）
├── .server-test.sh                            服务器增删改查回归测试（11 项）
├── .wan-test.sh                               公网访问开关回归测试（30 项）
└── files/
    ├── etc/
    │   ├── config/workbuddy                   UCI 默认配置
    │   ├── init.d/workbuddy                   procd 服务
    │   └── uci-defaults/50-workbuddy          首次安装初始化
    ├── usr/
    │   └── share/
    │       ├── ucode/workbuddy.uc             核心中转 + 管理网页（约 79 KB）
    │       ├── rpcd/ucode/workbuddy           rpcd 后端（状态/密码/凭据/模型）
    │       ├── luci/menu.d/luci-app-workbuddy.json
    │       └── rpcd/acl.d/luci-app-workbuddy.json
    └── www/luci-static/resources/view/workbuddy/
        └── status.js                          运行状态页（只读 + 管理员密码）
```

> 文件名与 rpcd 对象名均保留 `workbuddy` 前缀，理由见文首「命名说明」。

> 管理网页的 HTML/CSS/JS 全部内联在 `workbuddy.uc` 里，
> 因为面板要在无外网的局域网可用，不能依赖任何 CDN 或独立的静态资源。

## 许可

Apache-2.0
