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
| `up_max_inflight` | `4` | 自定义上游并发上限；`0` = 不限制 |
| `wb_max_inflight` | `6` | WorkBuddy 上游并发上限；`0` = 不限制 |
| `queue_max` | `32` | 排队上限；`0` = 不排队（超出立即 429） |
| `queue_timeout` | `20` | 排队超时秒数，等太久返回 429 + `Retry-After` |
| `use_pool` | `1` | 启用上游连接复用（常驻 `workbuddy-pool`） |
| `pool_port` | `8790` | 连接池端口（只监听 `127.0.0.1`） |
| `pool_keepalive` | `30` | 连接池保活间隔秒数，防止空闲连接被回收 |
| `rl_brake_hits` | `4` | 限流刹车：窗口内累计多少次上游限流拒绝后闭闸；`0` = 关闭刹车 |
| `rl_brake_window` | `20` | 限流刹车计数窗口（秒） |
| `rl_brake_sec` | `8` | 限流刹车闭闸时长（秒） |
| `rl_brake_max_ra` | `15` | 回给客户端的 `Retry-After` 上限（秒） |
| `up_first_byte_sec` | `12` | 静默看门狗「首字节档」：上游连上后多久还没吐出第一个字节就换 Key；`0` = 关闭该档 |
| `up_idle_sec` | `25` | 静默看门狗「流中档」：已开始返回数据后，中途静默多久判定断流；`0` = 关闭该档 |
| `wb_idle_sec` | `75` | WorkBuddy 通道静默上限（该通道首字节本来就慢，不参与首字节档）；`0` = 关闭 |
| `bridge_port` | `8791` | 上游响应回环桥端口（只监听 `127.0.0.1`）；`0` = 关闭回环桥，退回直接读 popen 管道 |

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

### 转发效率优化（2026-09-27 实测，详见 lessons/workbuddy-forward-efficiency.md）

| 措施 | 实测效果 |
|---|---|
| 自定义上游模型列表缓存（TTL 300 s，`?refresh=1` 强制刷新） | `/v1/models` 1.66 s → **0.21 s**（首次）/ **0.004 s**（命中） |
| 上游失败冷却按类型区分（限流 20s→40s→80s…上限 300s；鉴权 600s；瞬时 5s） | 连续 10 次请求 1.42~3.16 s，不再出现 12 s/60 s 挂起 |
| 上游静默看门狗（**v1.8.2 起分两档**：首字节 12 s / 流中 60 s，WorkBuddy 75 s，详见「静默看门狗」节）+ curl `--speed-limit 1 --speed-time 30\|90` | 死链路 36 s 内收 502（修复前无限挂起）；v1.8.2 后客户端 TTFB p90 由 30 s+ 降到 3.69 s |
| Key **严格轮播**（游标依次轮转，冷却中的跳过） | 实测序列 `3lw→RWe→F7L→6Wg→3lw`，4 把一轮 |
| 单个 Key **被限流不换 Key**，直接返回 429 + 原因（附 Retry-After） | 实测 `attempt 2/` 出现 0 次；请求不再被拖成"连撞几把" |
| 连接表回收（`closeConn` 摘除连接并释放缓冲） | 长跑不再累积请求体 / SSE 缓冲 |
| `listen()` backlog 64 → 128 | 公网突发不再丢 SYN |
| 内核参数 `files/etc/sysctl.d/99-workbuddy-forward.conf` | slow_start_after_idle=0 / fastopen=3 / mtu_probing=1 / syn_backlog=1024 |

基础项：

- 上游 curl 关闭缓冲（`-N`），并为客户端连接设置 `TCP_NODELAY`，减少小包延迟；
- 转发缓冲 `16KB`，避免高频 `read()` 系统调用；
- 上游连接超时 5 秒，配合凭据切换做快速失败；
- 模型列表缓存 6 小时，并在服务启动 1.5 秒后预热，首个 `/v1/models` 请求不再等待。

> **当时的剩余开销（2026-09-27 基线）**：每个请求仍会重新 fork curl 并重建到上游的
> TCP+TLS 连接，实测固定开销约 130~190 ms/请求。
> **其中「重建 TCP+TLS」这一半已在 v1.8.0 由连接池解掉**（见下节）；fork curl 的开销仍在。

### 上游连接复用（v1.8.0）

上面那条「尚未实施」已于 v1.8.0 落地：新增一个常驻 Go 小程序 `workbuddy-pool`
（静态编译 aarch64，约 6.3 MB，**零外部依赖**），持有到上游的 keep-alive 连接池，
curl 改为把请求发给本机池；池不可用时自动回退直连，用户无感。

| 项 | 说明 |
|---|---|
| 协议 | 请求头 `X-WB-Target: <上游基址>`，方法/路径/查询串/头/体原样透传 |
| 本机端点 | `GET /health`、`GET /stats`（含复用率与新/旧连接 TTFB 拆分） |
| 监听 | 只监听 `127.0.0.1`，且强制 target 带 http(s) scheme —— 主服务对公网开放（`wan_access`），池绝不能成为可被外部利用的开放代理 |

实测收益（池 `/stats` 同主机拆分，n=16）：

| 指标 | 新建连接 | 复用连接 | 差额 |
|---|---|---|---|
| TTFB p50 | 1603.077 ms | 1298.631 ms | **约 304 ms** |
| DNS + conn_wait + TLS | — | — | 1.91 + 135.3 + 84.8 ≈ **222 ms** |

（另一轮 n=138 测得 221.444 → 112.249 ms，省约 109 ms。**该拆分需 n≥15 才有意义**，
小样本读数是噪声。）

> 这个收益**用 `/metrics` 的直方图测不出来** —— 那些桶在 1–3 秒区间只有
> 500–1000 ms 分辨率，分辨不出 300 ms 的差异。做这类对比必须看池自身的
> new/reused 拆分。同理，用 curl 做 `use_pool=1` vs `0` 的 A/B 也**得不出结论**：
> 上游生成耗时本身在 1.17–3.32 s 波动，远大于待测效果。

设计上刻意做对的几处：

- **`DisableCompression` + 逐块 `Write` + 立即 `Flush`**：SSE 必须逐字节原样透传。
  若用默认的 bufio（4 KB）攒够才发，整场流式对话会被成段延迟 —— 这是插入代理的头号风险。
- **预热用 `HEAD` 并读尽 body**：Go 的 transport 只在 body 读到 EOF 才把连接还给空闲池，
  读一半就关会**亲手杀掉要保的连接**，比不预热更糟。
- **`ResponseHeaderTimeout: 0`**：WorkBuddy 是 agent 上游，可能长时间思考后才吐首字节，
  超时交给 ucode 的静默看门狗与 curl 的 `--speed-time`，不重复设易误杀的阈值。

### 并发上限与 FIFO 排队（v1.8.0）

上游限的是 tpm/rpm 而非连接数，并发越高越容易整批撞 429，因此加了闸门 + 队列。
实测 8 并发（`up_max_inflight=4`）：闸门严格卡在 4，第 5~8 个进队列并按序排空，
`timeoutTotal=0`、`rejectedTotal=0`、8/8 返回 200。

> **但这并没有消除限流**。60 请求的 soak 里 `34×200 / 24×429 / 2×502`（40% 失败），
> 日志显示上游原文 `rpm exhausted`、`inference exceeds tpm/rpm limit`。
> 慢速顺序请求 3/3 全 200，说明 Key 没坏、是速率问题。详见
> `lessons/workbuddy-remaining-optimization.md` 的 v1.8.0 附录。
> 结论：**本地闸门只能削峰，不能扩容。**

### 可观测指标（v1.8.0）

`GET /metrics`（与 `/health` 一样不需要鉴权）输出：

| 分组 | 内容 |
|---|---|
| `chat` | `total` / `ok` / `fail` / `clientErr` / `rateLimited429` |
| `ttfbMs`、`totalMs` | 分 `pool` / `direct` 两条路径的 `p50` / `p90` / `p99` 与样本数 |
| `queue` | `inflight`（分 `wb`/`up`）、`waiting`、`queuedTotal`、`timeoutTotal`、`rejectedTotal`、`maxDepth` |
| `upstreams[]` | 每上游 ok/fail/rateLimited/authFail/inflight，以及**每把 Key** 的 ok/fail/rateLimited/authFail/coolingSec/lastErr（Key 一律掩码） |
| `pool` | `enabled` / `usable` / `port` / `failCooldownSec` / `requests` / `fallbacks` |

> 直方图桶在 1–3 秒区间分辨率只有 500–1000 ms，比较 ~300 ms 级别的差异时不要用它。

### 限流刹车（v1.8.1）

v1.8.0 的 soak 暴露了一个**正反馈放大**：一次请求撞上游限流后，代码会换下一把 Key 重试，
最多试满 4 把；当 4 把 Key 都已在冷却中时，这 4 次尝试**注定全部失败**，却给上游打了 4 倍流量。
实测池侧 **138 次上游请求 / 60 次客户端请求 = 2.25×**，其中 96 次（70%）就是这么烧掉的。

限流刹车（上游级熔断器）掐断这条链：

| 行为 | 说明 |
|---|---|
| 计数 | 每次上游回限流类错误时，在该上游的滑动窗口内 +1 |
| 闭闸 | 窗口内累计达到 `rl_brake_hits` → 闭闸 `rl_brake_sec` 秒 |
| 闭闸期间 | **只拦重试，不拦首次尝试** |
| 闭闸尾巴 | 剩余 ≤ 2s 时先等一次再发，把失败转成成功 |
| 客户端可见 | 被拦的请求直接回 `429` + 真实 `Retry-After`（上限 `rl_brake_max_ra`） |
| 自愈 | 任一 Key 成功即合闸 |

**为什么只拦重试**：首次尝试是唯一能探知"上游是否已恢复"的手段，拦掉它会把本可成功的
请求变成失败；而闭闸期间的重试是纯浪费。只拦重试 = 拿掉浪费 + 完整保留"不通就换下一个"。

**与 v1.7.1 被删掉的短路不同**：那个版本的判据是"我们自己的冷却模型"（4 把 Key 全在冷却就
立刻 429），`retry_after` 会算到荒谬的 577s，且违背"不通的自动换下一个"的要求。
本版判据是**观测到的上游拒绝**、要窗口内连续多次被拒才闭闸、`Retry-After` 有上限。

`/metrics` 里可观察：

| 位置 | 字段 |
|---|---|
| 顶层 `brake` | `enabled` / `hits` / `windowSec` / `brakeSec` / `maxRetryAfterSec` / `rejectedTotal` / `waitedTotal` |
| `upstreams[].brake` | `enabled` / `open` / `leftSec` / `hits` / `trips` / `waited` / `rejected` |

`rl_brake_hits=0` 可完全关闭刹车。

### 静默看门狗：两档阈值（v1.8.2）

上游连上之后一个字节都不回时，看门狗主动断开并按既有重试链换 Key，而不是让客户端干等到
自己超时。v1.8.1 及以前只有**一个**阈值（`UP_IDLE_SEC = 25`，WorkBuddy 通道 75s），
实测证明这个值是**客户端长尾的唯一来源**：

| 证据（v1.8.1，60 请求） | 数值 |
|---|---|
| 慢请求（≥5s）数量 / 其中失败数 | 13 / **0**（13 个全部 200） |
| 看门狗中止次数 | 32 次，idle 值**全部落在 25–29s** |
| 客户端 TTFB p50 / p90 / p99 | 2.25 / 31.82 / 34.03 s |

32 次中止全部卡在 25s 阈值之上（`UP_IDLE_TICK_MS = 5000` 扫描周期，故是 25+0~4s），
且慢请求**无一失败** —— 说明看门狗一直在做对的事（把"上游还没受理"的尝试掐掉换 Key，
换完几秒内就成功），只是**掐得太晚**：客户端因此白等 25~34 秒。

关键洞察：**"还没有第一个字节"和"流中途断掉"是两种完全不同的事故**，不该共用一个阈值。
没有第一个字节 = 上游根本没受理（多半是在服务端排队或撞了配额），早点换 Key 就好；
流中途断掉 = 已经出了数据又卡住，这时换 Key 会浪费已生成的内容，应该多等一会。

v1.8.2 拆成两档，用 `conn.attemptBytes` 判档 —— 它在每次尝试开始时清零
（`spawnUpstreamDirect` / `spawnUpstream`）、收到字节就累加，天然就是
"本次尝试是否已被上游受理"的标志位：

| 档位 | 判据 | 配置项 | 默认 | 命中日志 |
|---|---|---|---|---|
| 首字节 | `attemptBytes === 0` | `up_first_byte_sec` | `12` | `upstream no first byte in Ns (>=Ns, key#K, client C), failover` |
| 流中 | `attemptBytes > 0` | `up_idle_sec` | `25` | `upstream stalled Ns mid-stream (>=Ns, attempt A, client C), aborting` |
| WorkBuddy | 非自定义上游 | `wb_idle_sec` | `75` | 同「流中」 |

- `0` = 关闭该档（诊断链路时可用，生产不建议 —— 会让客户端一直干等）。
- 一致性保护：若 `up_idle_sec < up_first_byte_sec`（两者都非 0），视为配错，双双回默认值；
  否则首字节还没等到就被流中档杀掉，等于首字节档失效。
- 两条失败原因串（`上游 Ns 未返回首字节` / `上游流中静默 Ns`）都不含限流关键词，
  经 `isRateLimitReason()` 判为瞬时抖动，走 `UP_SOFT_COOL = 2` 秒冷却，**不会误计入刹车 hits**。
- 启动日志会打印当前档位：`forward tuning: idle=25s/75s first_byte=12s ...`。

**首字节档为什么取 12 s（`wb-test9.sh` 扫点，每档 60 请求，`up_idle_sec` 固定 60）**：

| `up_first_byte_sec` | 200 | 429 | 成功率 | 放大倍数 | TTFB p50 / p90 / p99 / max |
|---|---|---|---|---|---|
| 25（= v1.8.1 老阈值） | 47 | 13 | 78.3% | 0.97× | 2.16 / 7.04 / 67.71 / 67.71 s |
| **12（选定）** | 33 | 27 | 55.0% | 0.97× | **1.48 / 3.69** / 63.62 / 63.62 s |
| 6（否决） | 42 | 18 | 70.0% | **1.45×** | 2.14 / **63.92** / 68.23 / 68.23 s |

- 12 s 把中位长尾砍半（p90 7.04→3.69 s、p50 2.16→1.48 s），**放大倍数没变**（都 0.97×）
  —— 提前换 Key 没有给上游加压，代价只是更多请求被刹车快速 429（成功率数字随之下降，
  属设计内取舍：宁可早失败让客户端重试，也不要挂 30 秒）。
- **6 s 是反效果**：换 Key 太频繁，压力摊到整个 Key 池，放大倍数跳到 1.45×、p90 反而恶化到
  63.92 s。**阈值不是越低越好，存在拐点。**
- 三档的极值都在 ~63–68 s，且该值 ≈ `up_idle_sec(60) + UP_IDLE_TICK_MS(5)`，
  说明剩余长尾来自**流中档**而非首字节档。

**流中档为什么从 60 s 改成 25 s（`wb-test10.sh` / `wb-test11.sh` 扫点，每档 60 请求）**：

| `up_idle_sec` | 成功率 | 放大倍数 | TTFB p50 / p90 / p99 / max |
|---|---|---|---|
| 60（v1.8.2 默认） | 65.0% | 1.08× | 1.80 / 65.11 / 67.24 / **69.04** s |
| 30 | 55.0% | 1.50× | 1.39 / 32.93 / 35.68 / 36.35 s |
| **25（v1.8.3 默认）** | 58.3% | **1.02×** | 1.60 / **28.91** / 30.34 / 32.56 s |

- 结论很清楚：**客户端长尾几乎就等于这一档的阈值本身**（p90/max ≈ `up_idle_sec + 扫描间隔`，
  65≈60+5、33≈30+3、29≈25+4）—— 因为超时那一刻才中止并换 Key，之前全在干等。
  把 60 降到 25，最坏等待从 65 s 砍到 30 s，**放大倍数还更低了**（1.08×→1.02×）。
- 三档成功率（65.0% / 55.0% / 58.3%）在配额波动范围内**不可区分**，不构成保留 60 s 的理由。
- 为什么 25 s 不会误杀"模型在思考"：SSE 是**逐字**吐的，推理过程（reasoning）也是以增量形式
  持续下发的；流中途连续 25 s 一个字节都没有，基本等于链路已断，而不是"在想"。
  确有长静默需求的上游请单独调大 `up_idle_sec`，或配 `0` 关闭该档。
- `up_idle_sec` 是**该档决定长尾**这一点，与首字节档的取舍逻辑完全不同：首字节档越短越好
  （早换 Key 早成功），流中档则是在"误杀正常长回答"和"让客户端干等"之间取平衡，故取 25 s
  而非更短。

> v1.8.0 曾怀疑 502 是 curl `--speed-time 30` 误杀"上游思考中"。**该假设已被推翻**：
> 先到的是 25s 的看门狗，curl 的 30s 从来没机会触发。调 `--speed-time` 是修错了地方。


### 上游响应回环桥：根治并发静默截断（v1.8.3 引入，v1.8.4 修好）

v1.8.2 上线实测时发现一个**只在并发下出现**的严重正确性缺陷：客户端会收到**半截 SSE 流，
却完全看不出来**。这个缺陷比长尾严重得多，因为它静默地损坏回答内容。

**症状（`wb-test11.sh` / `wb-test13.sh` / `wb-test14.sh`）**

| 症状 | 证据 |
|---|---|
| 响应体恰好在 **16384 字节**处被切断（`proc.read(16384)` 的缓冲区大小），且切在 SSE 行**中途** | test11：5~6 个 body 恰 16384 字节、无 `[DONE]` |
| 有时是 16384 的**整数倍**（16384/32768/49152） | test13：B 相截断尺寸全是 16384 倍数 |
| 另有一类：**流已经完整转发完却不关闭连接**，curl 一直等到自己的 `-m` 上限 | test14 relay 臂：2 个 body 已含 `[DONE]` 但连接不关，40s 超时 |
| 客户端完全无感：`Connection: close` + 无 `Content-Length`、无 chunked，curl 照报 `code=200`、退出码 0 | `sseHeaders()` @2474-2486 |

**排除法（都是实测，不是推测）**

1. **不是看门狗**：把 `up_idle_sec` 配成 `600`，截断照旧发生（test13 A 相）。
2. **不是 Go 连接池**：`use_pool=0` 直接连上游，截断照旧发生（test13 B 相）。
3. **不是上游**：curl **直连**上游同一模型同一 Key，凡 HTTP 200 的流**全部完整**
   （test14 direct 臂：49245/80656/38699/49007/53149 字节，均含 `[DONE]`）。
4. **不是客户端 socket 丢块**：对截断 body 做数字连续性检测，序列 `1..12`、`1..38`、`1..17`、`1..13`
   **全部连续无跳号**，末尾停在 SSE 行中途 ⇒ 客户端没丢数据，是**读侧停止读取后连接被正常关闭**。

**根因（`probe2.uc` / `probe3.uc` / `probe6.uc` / `probe10.uc`）**

ucode 的 **`popen()` 管道 + uloop 读循环在并发下会丢可读事件**：读回调不再触发，于是
（a）在 16384 整数倍处收到伪 EOF 而提前关闭，或（b）流已完整却永不收尾。定位过程中的关键事实：

- **纯本地子进程即可复现**（probe2，无网络）：child0 在 163840 处报 EOF，child1/2/3 停在 180224
  且回调永不再触发 —— 生产两种症状都复现了。
- **`ULOOP_BLOCKING` 必须保留**：去掉它（probe3 `nonblock` 变体 5/5 失败、probe7）后
  `proc.read()` 恒返回 NULL，读取完全不可用。这也正是 `onAccept()` 注释早已写明的坑。
- 但**阻塞语义下 EAGAIN 与 EOF 无法区分**：probe5 证明阻塞读的"len=0"确实等于 EOF；
  probe6 又证明**子进程仍存活时也会出现 len=0（EMPTY）**。且 `proc.pid` / `proc.returncode`
  实测全是 `(null)`（probe4），无法另辟蹊径判存活。⇒ **在 popen 路径上无法消歧，只能换读路径。**
- **ucode 的 socket 读路径是可靠的**：probe10 用 5 个客户端各灌 200000 字节，
  **5/5 全部收满、EOF 可靠、无空读误判、无串流**。
- `uloop.process()` 回调**永不触发**（probe4），所以也没法用"等子进程退出"来消歧。

**方案：把 curl 的 stdout 经 `nc` 回环到本地 socket**

```
{ printf "<id>\n"; curl ... ; } | nc 127.0.0.1 8791 &
```

> **末尾的 ` &` 是桥的一部分，不是可选的性能优化。** v1.8.3 漏掉了它，上线即把服务打死：
> `popen()` 的直接子进程是那个 `sh`，而整条管道在**整个响应流期间**都活着，于是任何一次
> `proc.close()`（= `pclose()`/`waitpid()`）都要等管道退出才返回。ucode 是**单线程**事件循环，
> 一次 60 并发实测把它钉在 `do_wait` 上 40 s 没转过一轮 —— Recv-Q 固定堆积 87423 字节、
> `/health` 完全无响应、60 个请求里 56 个 `code=000`。这比它要修的静默截断严重得多
> （截断只损坏单个回答，死锁是**全站瘫痪**）。
>
> 加 ` &` 后 `sh` 立刻退出，`pclose()` 收的是已死子进程，实测 **2 ms** 返回；事件循环最大停顿
> 502 ms；数据仍逐字节完整送达。证据链：`probe15.uc` shape A（前台）**无限期挂住**、
> shape B（` &`）`closeMs=2 / got=200200 / FIX_OK`；`probe16.uc` 并发 A/B —— `BG=1` 三连跑
> `good=5/5`、`closeMsTotal` 6~9 ms（5 路合计）↔ `BG=0` 对照组 20 s 内直接 HUNG。

响应字节不再走 popen 管道，而是走 **socket**（probe10 已证明可靠）。请求 id 由首行握手与
`bridgePending` 映射配对，因此并发下不会串流。要点：

- **一条桥连接只注册一个 uloop 句柄**，握手与后续转发**共用**它。不要写成"握手用句柄 A，
  收到 id 后 cancel A、给同一 fd 注册句柄 B"—— 同一 fd 上取消+重新注册落在同一事件循环轮次里，
  epoll 侧会出现重复注册/陈旧句柄竞态（libubox 对同一 fd 的 `epoll_ctl(ADD)` 返回 EEXIST），
  严重时陈旧句柄会再触发一次握手，把真实数据的首行当成 id 吃掉。
- 首行 id **之后的同包残余字节**必须先塞进 `conn.bridgePrebuf` 再手动触发一次块处理，
  否则 curl 的响应头和 id 行挤在同一个报文里时会丢掉开头。
- `bridgeRegister()` 必须在 `popen()` **之前**调用，否则子进程可能在登记前就连上来。
- 每个释放路径（`closeConn` / `tryNextCred` / `tryNextUpKey` / `onUpstreamDirectEnd` /
  popen 失败）都要 `bridgeRelease(conn)`：**不释放就是连接泄漏**（探针实测会卡在 FIN_WAIT2）。
- 靠 **busybox `nc` 在 stdin EOF 时关闭 socket** 来判定响应结束（ucode 侧 `recv` 收到 len=0）；
  路由器 `nc` 是 BusyBox v1.38.0 极简版，**没有 `-l` / `-p`，只能作客户端**。
- **自动回退**：`nc` 不存在或监听失败时打日志并退回直接读 popen（`bridge_port=0` 也可显式关闭）。
  回退路径仍有截断缺陷，但至少不会因为缺少 `nc` 而完全不可用。
- 启动日志新增 `upstream bridge: on (port=8791)`。

**离线验证（`probe12.uc` + `emit9.sh`，与生产同构，5 并发，无网络）**

生产者 `emit9.sh` 用 awk 输出**恰好 200200 字节**（每 40 行 `sleep 1`，制造真实的流中停顿）。
判据：5 路各收满 200200 字节、`foreign=0`（无串流）、全部干净 EOF 收尾。

| 版本 | 结果 |
|---|---|
| 直接读 popen 管道（= 生产旧路径，`probe2.uc`） | 163840 假 EOF / 180224 停滞，**失败** |
| 回环桥，前台（`probe12.uc`，v1.8.3 形态） | 连跑 5 次全部 `good=5/5 bad=0`、每路恰好 200200 字节、`foreign=0` ⇒ `STABILITY_OK` |
| 回环桥，前台（**`probe16.uc` BG=0**，并发 A/B 对照组） | **HUNG —— 20 s 看门狗内事件循环被 `proc.close()` 钉死** |
| 回环桥 + 尾部 ` &`（**`probe16.uc` BG=1**，v1.8.4 形态） | **三连跑 `good=5/5 bad=0`、`closeMsTotal` 6~9 ms、`hung=0` ⇒ `STABILITY_OK`** |

> probe12 当初之所以通过、却在生产上炸掉，是因为它**每条请求只读满固定字节数就收尾**，
> 没有在生产那种"响应流长时间活着、期间还要走 `closeConn()`/`tryNextUpKey()`"的形态下
> 触发 `proc.close()`。probe15/probe16 把 `proc.close()` 放到**子进程必然还活着**的时刻
> 调用（`popen` 之后立刻计时），才暴露出这个真正的行为差异 —— **离线验证必须复现生产
> 的调用时序，而不只是数据量。**

> 探针本身的两个坑，也是生产代码的印证：一是 **ucode 没有全局 `error()`**，必须
> `import { ..., error } from 'fs'`（生产文件第 21 行正是这么写的）；二是**结束时必须显式
> 释放桥资源并 `exit(0)`**，否则客户端 `nc` 停在 FIN_WAIT2 死等、ucode 卡在退出阶段等子进程
> —— 探针第一版就是这样把测试 runner 整个挂住的，反过来证明了 `bridgeRelease()` 的必要性。

**上线验收（v1.8.4，12 批 × 5 = 60 并发，长输出 prompt，`curl -sS -N -m 90`）**

| 判据 | v1.8.3（桥缺 ` &`） | **v1.8.4** |
|---|---|---|
| 客户端状态码 | **56× `code=000`** / 4× `200` | **35× `200`** / 25× `429` / 0× `000` |
| 流式 body 完整（含 `[DONE]`） | 1 | **35 / 35** |
| `TRUNCATED (no [DONE])` | 3 | **0** |
| `size == 16384` 恰好 / 16384 整数倍 | 0 / 0 | **0 / 0** |
| `no finish_reason` | 3 | **0** |
| ucode 进程存活 | 事件循环钉死在 `do_wait`，`/health` 无响应 | **pid 1701 全程未变** |
| 客户端 TTFB p50 / p90 / p99 | （超时，无有效样本） | **1.14 / 2.57 / 5.18 s** |
| 流中看门狗中止次数 | — | **0** |
| 池放大倍数 / 复用率 | 0.07×（请求根本没到上游） | **1.45×** / `reuse_rate 0.93` |

- 25 个 `429` 全是 **171 字节的 JSON 错误体**（刹车拒绝，预期行为），与 25 个 `200` 一一对应；
  60 个请求里**没有一个 `code=000`**，`curl errors` 段为空。
- 流式 body 尺寸跨度 **9823 – 131280 字节**（`b.12.1` 131280 字节 / 483 chunk，
  `b.4.3` 113241 字节 / 414 chunk）⇒ 远超 16384 边界仍逐字节完整。
- 桥确实在承载流量（不是静默回退到 popen）：每批 3 s 采样的 `127.0.0.1:8791` 连接数为
  10 / 16 / 23 / 28 / 34 / 42 / 49 / 52 / 59 / 63 / 69 / 65，跟随批内并发单调变化。
- 资源无泄漏：ucode 共 **11 个 fd**（6×pipe / 2×socket / eventpoll / 脚本 / `/dev/null`）；
  空闲时 `:8791` 只剩内核侧 13 条 TIME_WAIT；孤儿 `nc`、`curl` 均为 0。
- 对比 v1.8.1 的 TTFB `2.25 / 31.82 / 34.03 s`：**每条请求都是 30 s 级的长尾被彻底消掉**。


## v2.0 重大升级（转发速度 + 转发能力）

v2.0 在 v1.8.4 的稳定性地基上做了**能力升级**，共 9 项，全部已通过
单元测试、静态检查、`ucode -c`、真机 60 并发 soak 验收：

### ① 会话粘性（session affinity）

同一客户端（按 API 密钥名；未鉴权时按来源 IP）在 **`up_sticky_sec`（默认 900s）**
窗口内始终命中同一把上游 Key，避免多轮对话在 4 把 Key 之间乱跳导致
上游的 prompt caching 完全失效 —— 同一把 Key 连续提问才能吃到缓存命中，
既省钱又省 TTFB。

- 实现：`usableUpKeys()` 把粘性 Key 提到最前；`markUpKeyOk()`/`markUpKeyFail()`
  写入 `upSticky`；窗口到期或该 Key 冷却后自然失效，重新按权重轮询。
- 关闭：`option up_sticky_sec '0'`。

### ② 每 Key 权重（weighted rotate）

管理页粘贴 Key 时支持 `key|权重` 格式（权重为 ≥1 的整数，默认 1）。
`sk-aaaa|3` 表示这把 Key 的被选中概率是普通 Key 的 3 倍（按权重取模轮询，
不是简单随机）。权重只影响**健康 Key 内部**的轮询分布；失效 Key 仍走冷却与跳过。
全部 Key 权重为 1 时退化为普通轮询，且不会把权重字段写进旧格式的
`upstreams.json`（保持旧文件兼容）。

### ③ 上游列表 TTL 缓存

`loadUpstreams()` 的结果带 **2 秒 TTL 缓存**（`UPSTREAM_CACHE_TTL=2`），
避免每个请求都重新读盘解析 `upstreams.json`。保存/编辑上游时显式失效缓存。

### ④ Token 用量统计

每次成功请求后从上游响应的 `usage` 字段提取 `prompt/completion/total`，
按 **上游 / 上游+Key / 客户端** 三个维度累计，并实时反映在：

- `/metrics` 顶层的 `usage` 段（含 `text` 缩写，如 `2.8k/4.0k/6.7k`）
- 每个 upstream / 每把 Key 的 `usage` 与 `usageText` 字段
- 管理页「服务器管理」卡片上的「用量」行，以及 Key 徽标的 tooltip

### ⑤ 通用端点透传（passthrough）

不再只支持 `/v1/chat/completions` 与 `/v1/models` —— **任意端点**
（`/v1/embeddings`、`/v1/responses`、`/v1/audio/transcriptions` 等）都会原样
透传给对应上游：`/v1/embeddings` 交给上游的 `/v1/embeddings`，
未知前缀返回 400 `unknown upstream prefix: <prefix>`。

- 自定义上游：请求路径拼在 baseUrl 之后（Go 连接池 `joinPath` 已支持任意端点）。
- WorkBuddy 内置通道：`workbuddy/` 前缀走凭据池，池空时返回 502
  `WorkBuddy credentials unavailable`。
- 鉴权、刹车、静默看门狗、回环桥等既有能力对透传请求同样生效。

### ⑥ SSRF 防护：`allow_private_upstream`

默认 **允许**自定义上游指向内网/本机地址（`allow_private_upstream '1'`）。
设为 `'0'` 后，`baseUrl` 不能是 `localhost`、`127.*`、`10.*`、`192.168.*`、
`172.16-31.*`、`::1`、`fc00::/7`、`fe80::/10`，防止把中转当跳板打内网。
本机自己的凭据池通道（`workbuddy/` 前缀）不受此限制。

### ⑦ `X-Accel-Buffering: no`

流式响应头新增 `X-Accel-Buffering: no`，避免中间层（nginx、LuCI 的
proxy 插件等）缓冲 SSE 流导致首字节延迟。

### ⑧ 管理页展示权重与用量

- 服务器卡片上，权重 >1 的 Key 显示 `×N` 徽标，tooltip 显示
  「权重 N，用量 x/y/z tokens」。
- 卡片新增「用量」行，展示该上游累计的 prompt/completion/total。
- 「改 Key」弹窗明确说明 `key|权重` 格式。

### ⑨ UCI 新增配置项

```uci
# 会话粘性时长（秒），0=关闭粘性
option up_sticky_sec '900'
# 是否允许自定义上游指向内网/本机地址（SSRF 防护）
option allow_private_upstream '1'
```

### v2.0 验收记录（真机 soak，12 批 × 5 = 60 并发，长回复流式）

| 判据 | 结果 |
|---|---|
| 客户端状态码 | **24× `200`** / 36× `429` / 0× `000` |
| 流式 body 完整（含 `[DONE]`） | **24 / 24** |
| `TRUNCATED (no [DONE])` | **0** |
| `size == 16384` 恰好 / 16384 整数倍 | **0 / 0** |
| `no finish_reason` | **0** |
| ucode 进程存活 | **pid 14774 全程未变** |
| 客户端 TTFB p50 / p90 / p99 / max | **0.23 / 1.84 / 4.07 / 4.07 s** |
| ≥20s 请求 | **0** |
| 池复用率 | **0.945** |
| 桥连接采样（每批 3s） | 9 → 86，随批内并发单调变化 |

- 36 个 `429` 全是上游限流（rpm exhausted / tpm 超限）被刹车正确拦截的
  JSON 错误体，与配额波动一致，没有 `code=000`。
- 用量统计在 soak 后准确累计：`usage {prompt:2763, completion:3969,
  total:6732}`，且按 3 把实际命中的 Key 正确拆分（`byKey`）。


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
- **没有 `undefined` 这个标识符**（**v1.8.0 首次部署就是被它搞挂的**）：
  ucode 里 `undefined` 既不是关键字也不是全局变量，写 `v === undefined` 会在运行期抛
  `Reference error: access to undeclared variable undefined` —— **进程直接起不来、端口完全不监听**，
  报错栈指向 `numOr()` / `loadConfig()`。判断字段是否存在要用 `type(v) === 'bool'`、`v === null`。
  最阴的地方是它**看编译单元而定**：把出问题的那段原样抠进独立小文件里跑**不报错**，
  `ucode -c` 编译期也**不报错**，**46 项单元测试全过照样抓不到**。
  所以只能靠静态扫描（`.check-forward.ps1` 的 `UNDEFINED IDENTIFIER CHECK`）+ 纪律来防。
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

`.check-forward.ps1` 覆盖六类只在运行期暴露、且难靠语法检查发现的问题：

| 检查 | 拦住的错误 |
| --- | --- |
| `FORWARD REF CHECK` 前向引用 | `access to undeclared variable <name>`（ucode 不提升函数与顶层 `let`/`const`） |
| 重复定义 | 后定义的函数静默覆盖前一个 |
| `METHOD CALL CHECK` 不存在的内建方法 | `.push()` / `.replace()` / `.indexOf()` / `.has()` 等 → `left-hand side is not a function` |
| `TEMPLATE ESCAPE CHECK` 模板转义 | 模板字符串里 `onclick` 引号转义不足 → 管理页永远停在「加载中…」 |
| `UNSUPPORTED SYNTAX CHECK` 不支持的语法 | `finally`（ucode 只有 `try/catch`）→ `Syntax error: Expecting 'catch'` |
| `UNDEFINED IDENTIFIER CHECK` 裸用 `undefined` | `access to undeclared variable undefined` → **服务起不来**（v1.8.0 首次部署的崩溃根因） |
| `GLOBAL DECLARATION ORDER CHECK` 全局声明顺序 | 函数引用「比它的定义行更靠后」才声明的顶层 `let`/`const` → `Reference error: access to undeclared variable cfg`，**服务陷入崩溃-重启循环**（v1.8.1 首次部署的崩溃根因） |

```powershell
pwsh -File .check-forward.ps1
# 输出六项都 OK 才算通过
```

> `UNDEFINED IDENTIFIER CHECK` 会跳过注释与模板字符串（浏览器 JS 里 `undefined` 合法），
> 也跳过字符串字面量。加规则时务必做一次**负向测试**：故意注入一处违规，
> 确认它恰好报 1 处、且不误报字符串与注释 —— 从不报警的检查等于没有检查。

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
3. **配置对象 `cfg` 与连接表 `connections` 提前声明**：函数按**定义时**的词法作用域
   解析标识符，所以一个位于文件中部、却引用 `cfg.xxx` 的函数，要求 `cfg` 在那之前
   就已声明。`let cfg = {};` 因此被提到全局声明区，读盘赋值留在启动流程里
   （`cfg = loadConfig();`，纯赋值）。v1.8.1 首次上线正是漏了这一步：
   `ucode -c` 通过、单元测试也通过，只有真机上撞到限流、走进 `brakeNoteRateLimit()`
   才抛 `Reference error: access to undeclared variable cfg`，服务被打成崩溃-重启循环。
   规则：**新增任何引用 `cfg` 的函数后，都要跑一次 `GLOBAL DECLARATION ORDER CHECK`**。

仓库里附带两个自检脚本：

```powershell
pwsh -File .check-forward.ps1        # 静态检查，输出六项 OK 才算通过
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

这六项**每次改动 `workbuddy.uc` 后都要跑一遍**，动过管理页 HTML 或闸门/池相关
代码之后尤其不能省。但它只扫静态模式，不能替代真机验证 —— 完整门禁是三步：

```sh
pwsh -File .check-forward.ps1              # 1. 静态检查（本地，六项 OK）
ucode -c -o /tmp/probe.bin workbuddy.uc    # 2. ucode 语法/编译检查（真机）
/etc/init.d/workbuddy restart && logread | grep workbuddy   # 3. 真机启动 + 看日志
```

> 第 2 步只能查语法，**查不出**前向引用、裸用 `undefined` 这类运行期问题；
> 而第 3 步才是唯一的最终裁判 —— v1.8.0 首次部署正是在这一步崩掉的
> （前两步都过了）。

> `upstream-test.sh` 会真的往各服务器发请求，因此可能触发对方的限流
> （日日新有 RPM 限制）。测试脚本开头有 60 秒等待，用于让上一轮冷却结束。
> `server-test.sh` 只用示例地址 `example.com`，不产生真实请求。

## 目录结构

```
luci-app-workbuddy/
├── Makefile                                  OpenWrt 包定义
├── install.sh                                设备端直接部署脚本
├── README.md
├── .check-forward.ps1                         ucode 静态检查（六项，详见上文）
├── pool-test.sh                               凭据池功能回归测试（36 项）
├── .upstream-test.sh                          服务器/上游功能回归测试（17 项）
├── .server-test.sh                            服务器增删改查回归测试（11 项）
├── .wan-test.sh                               公网访问开关回归测试（30 项）
├── pool/                                      上游连接复用代理（Go，v1.8.0）
│   ├── go.mod                                 Go 模块定义（零外部依赖）
│   ├── main.go                                连接池代理，约 500 行（中文注释）
│   └── testsse/main.go                        本地回调用最小 SSE 上游（不参与打包）
└── files/
    ├── etc/
    │   ├── config/workbuddy                   UCI 默认配置
    │   ├── init.d/workbuddy                   procd 服务（先拉池，再拉主服务）
    │   ├── sysctl.d/99-workbuddy-forward.conf 内核转发参数
    │   └── uci-defaults/50-workbuddy          首次安装初始化
    ├── usr/
    │   ├── bin/workbuddy-pool                 上游连接复用代理（aarch64 静态二进制，6.3 MB）
    │   └── share/
    │       ├── ucode/workbuddy.uc             核心中转 + 管理网页（约 210 KB）
    │       ├── rpcd/ucode/workbuddy           rpcd 后端（状态/密码/凭据/模型）
    │       ├── luci/menu.d/luci-app-workbuddy.json
    │       └── rpcd/acl.d/luci-app-workbuddy.json
    └── www/luci-static/resources/view/workbuddy/
        └── status.js                          运行状态页（只读 + 管理员密码）
```

> `files/usr/bin/workbuddy-pool` 是**预编译的 aarch64 二进制**（本机无 Go、
> 路由器也不能编译），改动 `pool/main.go` 后必须重新交叉编译再提交：

```powershell
cd D:\AI\luci-app-workbuddy\pool          # 必须在模块目录内，用 . 作包路径
$env:GOOS='linux'; $env:GOARCH='arm64'; $env:CGO_ENABLED='0'; $env:GOTOOLCHAIN='local'
& 'D:\AI\_tools\go-sdk\go\bin\go.exe' build -trimpath -ldflags '-s -w' -o ..\files\usr\bin\workbuddy-pool .
```

> 两个坑：① 在模块目录**外面**用 `go build <绝对路径>` 会报
> `cannot find main module, but found .git/config`；② 该二进制与 `Makefile` 里
> `LUCI_PKGARCH:=all` 的「架构无关」声明相矛盾 —— 打包时需按目标架构处理。

> 文件名与 rpcd 对象名均保留 `workbuddy` 前缀，理由见文首「命名说明」。

> 管理网页的 HTML/CSS/JS 全部内联在 `workbuddy.uc` 里，
> 因为面板要在无外网的局域网可用，不能依赖任何 CDN 或独立的静态资源。

## 许可

Apache-2.0
