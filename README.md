# ccs-plugin

在飞书聊天里用 `/ccs` 切换 [CC Switch](https://github.com/farion1231/cc-switch) 供应商和模型映射，带可点击的卡片。
只依赖 [cc-connect](https://github.com/chenhg5/cc-connect) 官方功能（自定义命令 + 消息钩子 + `cmd:` 卡片动作），
cc-connect 和 CC Switch 都可以直接官方升级，不需要本地编译。

支持 CC Switch 管理的全部应用：Claude Code、Codex、Gemini、Grok Build、Pi、OpenCode、OpenClaw、Hermes。

```
/ccs                          一张卡同时选供应商 / 模型 / 别名，点 ✍️ 写入才生效
/ccs switch <序号|名称>        切换供应商（兼容旧的分步卡片）
/ccs models <名称>             该供应商已配置 + 上游可用的模型
/ccs map <名称> <模型> [档位]   Claude: 把 sonnet / sonnet[1m] / opus / … 映射到该上游模型
                              Codex: 设置该供应商的上游模型
/ccs apply <名称> <模型> [档位] 切换供应商并写入映射
/ccs status                   当前供应商与模式
```

### 一张卡三个下拉

```
① 供应商    ② 模型    ③ 映射别名（Claude）    →  ✍️ 写入
```

三个下拉一开始就同时出现。改供应商只刷新模型列表，不会把另外两个藏起来；点写入才真正切供应商、写映射。
默认预填当前供应商和它正在用的模型，打开就能直接写。

CC Switch 代理按请求里的别名（haiku/sonnet/opus/fable）决定映射到哪个上游模型；插件写的就是这些映射，
所以 `/model sonnet[1m]` 这类 cc-connect 侧的别名可以继续用，只是它背后的真实模型换了。

## 安装（Windows）

```powershell
irm https://raw.githubusercontent.com/Shitsuki4/ccs-plugin/main/install.ps1 | iex
```

安装脚本会：

1. 把脚本放到 `~/.cc-connect/plugins/ccs`
2. 在 `config.toml` **顶层**写入 `[[commands]]` `/ccs` 和 `[[hooks]]` `message.received`（官方 cc-connect 不读 `[[projects.commands]]`）。应用类型在运行时从 `CC_HOOK_PROJECT` 或 exec 工作目录推断
3. 生成 `~/.cc-switch/control-api.json`（随机令牌，允许全部应用）
4. 若飞书项目没有 `admin_from`，官方版会拒绝执行 `/ccs` exec（特权命令）。安装脚本会把已有的 `allow_from` 复制过去；都没有则需要你自己加

然后重启 cc-connect，在飞书发 `/ccs`。

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
| `-InstallOfficialCcConnect` | 用官方最新 Release 替换 `~\.cc-connect\cc-connect.exe`（会重启，所有会话短暂断开）。**不会**走 PATH / `Get-Command`，避免覆盖 npm shim |
| `-Source <dir>` | 从本地目录安装而不是下载 |
| `-Uninstall` | 移除配置块和脚本 |

## 工作原理

```
/ccs ──▶ cc-connect 钩子 (message.received) ──▶ ccs-hook.ps1 ──▶ 飞书 OpenAPI 发/PATCH 卡片
                                                                      │
下拉选择 ──▶ cmd:/ccs pick p|m|t <值> ──▶ 钩子 PATCH 同一张卡（模型列表随供应商刷新）
写入按钮 ──▶ cmd:/ccs apply <id> <模型> [档位] ──▶ ccs.ps1 ──▶ 15722（热）或 DB+重启（冷）
```

- 钩子对 `/ccs` 及其子命令动作；其它消息立即退出
- 下拉选项值是 `cmd:/ccs pick …`，写入按钮是 `cmd:/ccs apply …`；官方版把自定义 **exec** 当特权命令，调用者必须在该项目的 `admin_from` 里
- 飞书凭据直接从 `config.toml` 读取，不另存；卡片 `message_id` 存在 `%LOCALAPPDATA%\ccs-plugin\card-*.json`

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
