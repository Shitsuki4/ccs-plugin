# ccs-plugin

在飞书聊天里用 `/ccs` 切换 [CC Switch](https://github.com/farion1231/cc-switch) 供应商和模型映射，带可点击的卡片。
只依赖 [cc-connect](https://github.com/chenhg5/cc-connect) 官方功能（自定义命令 + 消息钩子 + `cmd:` 卡片动作），
cc-connect 和 CC Switch 都可以直接官方升级，不需要本地编译。

支持 CC Switch 管理的全部应用：Claude Code、Codex、Gemini、Grok Build、Pi、OpenCode、OpenClaw、Hermes。

```
/ccs                          列出供应商（飞书收到选择卡片）
/ccs switch <序号|名称>        切换供应商 → 自动弹出该供应商的模型卡片
/ccs models <名称>             该供应商已配置 + 上游可用的模型
/ccs map <名称> <模型> [档位]   Claude: 把 sonnet / sonnet[1m] / opus / … 映射到该上游模型
                              Codex: 设置该供应商的上游模型
/ccs status                   当前供应商与模式
```

### Claude 的三步卡片

```
选供应商（any）  →  选上游模型（claude-fable-5-1 …）  →  选映射别名（sonnet[1m] / opus …）  →  一键 /model sonnet[1m]
```

CC Switch 代理按请求里的别名（haiku/sonnet/opus/fable）决定映射到哪个上游模型；插件写的就是这些映射，
所以 `/model sonnet[1m]` 这类 cc-connect 侧的别名可以继续用，只是它背后的真实模型换了。

## 安装（Windows）

```powershell
irm https://raw.githubusercontent.com/Shitsuki4/ccs-plugin/main/install.ps1 | iex
```

安装脚本会：

1. 把脚本放到 `~/.cc-connect/plugins/ccs`
2. 给每个带飞书平台的 cc-connect 项目写入 `/ccs` 自定义命令和 `message.received` 钩子（写入前备份 `config.toml`）
3. 生成 `~/.cc-switch/control-api.json`（随机令牌，允许全部应用）

然后重启 cc-connect（`cc-connect daemon restart`），在飞书发 `/ccs`。

### 热切换：带控制接口的 CC Switch

官方 CC Switch 把当前供应商缓存在进程内存里，外部程序改不了，所以切换要么重启它（冷切换，代理中断约 10 秒，仅 Claude/Codex/Gemini/Grok），
要么用本仓库 [GitHub Actions](.github/workflows/build-cc-switch.yml) 自动构建的补丁版——官方源码 + `patches/control_api.rs`，
在 `127.0.0.1:15722` 暴露一个只监听回环、Bearer 令牌鉴权的控制接口。模型映射、上游模型列表、Pi 等直连应用的切换都需要它。

```powershell
# 从本仓库 Release 下载补丁版并替换（会关闭并重启 CC Switch）
.\install.ps1 -InstallCcSwitch
```

补丁版的内置更新源指向本仓库，不会再被官方更新覆盖。官方发新版后，Actions 每天自动跟进构建（也可手动 Run workflow 指定 tag），
再跑一次 `install.ps1 -InstallCcSwitch` 即可更新。

`/ccs` 会自动探测：15722 在线走热切换，否则退回冷切换（需要 `sqlite3`：`winget install SQLite.SQLite`）。

### 控制接口

| 请求 | 说明 |
|---|---|
| `GET /api/v1/providers/{app}` | 供应商列表、当前 ID、`proxy_managed`、`proxy_running`、`auto_failover` |
| `POST /api/v1/providers/{app}/select` `{"id"}` | 切换供应商（代理应用热切换；Pi 等直连应用走桌面端原生切换） |
| `GET /api/v1/providers/{app}/models/{id}` | 已配置模型 + 上游 `/v1/models`（Claude），密钥不出进程 |
| `POST /api/v1/providers/{app}/model` `{"id","model","tiers"?}` | Claude: 写 `ANTHROPIC_DEFAULT_*_MODEL`；Codex: 写 config.toml 的 `model` |

`tiers` 可选值 `haiku sonnet opus fable subagent default`，缺省全部。

## 常用参数

| 参数 | 说明 |
|---|---|
| `-Project a,b` | 只配置指定项目 |
| `-InstallCcSwitch` | 安装/更新补丁版 CC Switch |
| `-InstallOfficialCcConnect` | 用官方最新 Release 替换 cc-connect.exe（会重启，所有会话短暂断开） |
| `-Source <dir>` | 从本地目录安装而不是下载 |
| `-Uninstall` | 移除配置块和脚本 |

## 工作原理

```
/ccs ──▶ cc-connect 钩子 (message.received) ──▶ ccs-hook.ps1 ──▶ 飞书 OpenAPI 发卡片
                                                                      │
点击按钮 ──▶ cc-connect 原生 cmd: 动作 ──▶ 以点击者身份派发 "/ccs switch <id>"
                                                                      │
                                              ccs.ps1 ──▶ 15722 控制接口（热）或 DB+重启（冷）
```

- 钩子只对内容恰好是 `/ccs` 的飞书消息动作，其它消息立即退出
- 卡片按钮值是 `cmd:/ccs switch <id>`，权限沿用 cc-connect 对该用户的正常命令权限
- 飞书凭据直接从 `config.toml` 读取，不另存

## 安全提示

- cc-connect 的自定义 exec 命令会把用户输入拼进 shell，只把机器人开放给受信任的用户（`allow_from`）
- `control-api.json` 里的令牌等价于切换供应商的权限，脚本已把文件 ACL 收紧为当前用户 + SYSTEM
- 补丁版 CC Switch 未签名

## 目录

```
ccs.ps1               /ccs 命令
ccs-hook.ps1          飞书卡片钩子
ccs-common.ps1        共用逻辑：控制接口、冷切换、config.toml 解析
install.ps1           安装/更新/卸载
patches/control_api.rs   CC Switch 控制接口（Rust）
patches/apply.py         把补丁应用到官方源码树
.github/workflows/build-cc-switch.yml
```

MIT License.
