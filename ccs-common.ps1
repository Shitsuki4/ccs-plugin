# ccs-plugin shared helpers. Dot-sourced by ccs.ps1, ccs-hook.ps1 and install.ps1.
Set-StrictMode -Version 2.0

$script:CcsPluginVersion = '0.1.0'

function Get-CcsPaths {
    $userHome = $env:USERPROFILE
    $ccSwitch = Join-Path $userHome '.cc-switch'
    $ccConnect = Join-Path $userHome '.cc-connect'
    [pscustomobject]@{
        CcSwitchDir   = $ccSwitch
        ControlConfig = Join-Path $ccSwitch 'control-api.json'
        Database      = Join-Path $ccSwitch 'cc-switch.db'
        Settings      = Join-Path $ccSwitch 'settings.json'
        CcConnectDir  = $ccConnect
        ConnectConfig = Join-Path $ccConnect 'config.toml'
        StateDir      = Join-Path $env:LOCALAPPDATA 'ccs-plugin'
        CardMarker    = Join-Path $env:LOCALAPPDATA 'ccs-plugin\last-card.stamp'
    }
}

function Get-CcsSettingsKey([string]$AppType) {
    switch ($AppType) {
        'claude' { 'currentProviderClaude' }
        'codex'  { 'currentProviderCodex' }
        'gemini' { 'currentProviderGemini' }
        default  { 'currentProvider' + $AppType.Substring(0, 1).ToUpper() + $AppType.Substring(1) }
    }
}

function Test-CcsPort([int]$Port, [int]$TimeoutMs = 500) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

# Returns @{BaseUrl; Token; Port} when the patched CC Switch control API is reachable, else $null.
function Get-CcsControlApi {
    $paths = Get-CcsPaths
    if (-not (Test-Path $paths.ControlConfig)) { return $null }
    try { $cfg = Get-Content $paths.ControlConfig -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if (-not $cfg.enabled -or -not $cfg.port -or -not $cfg.token) { return $null }
    if (-not (Test-CcsPort ([int]$cfg.port))) { return $null }
    [pscustomobject]@{
        BaseUrl = "http://127.0.0.1:$($cfg.port)"
        Token   = [string]$cfg.token
        Port    = [int]$cfg.port
    }
}

$script:CcsApiErrorText = @{
    unauthorized                    = '控制接口令牌不匹配，请检查 ~/.cc-switch/control-api.json'
    application_not_allowed         = '该应用未在 control-api.json 的 allowed_apps 中，或不支持此操作'
    invalid_application             = '无效的应用类型'
    proxy_not_running               = 'CC Switch 本地代理未开启，请先在桌面端启用代理模式'
    auto_failover_enabled           = '已开启自动故障转移，手动切换被拒绝；请先在桌面端关闭'
    provider_not_found              = '供应商不存在（可能已被删除）'
    provider_not_proxy_compatible   = '该供应商不支持代理接管，无法切换'
    model_not_found                 = '该供应商没有这个模型'
    invalid_model                   = '模型名包含不允许的字符'
    invalid_tier                    = '无效的映射档位'
    switch_failed                   = 'CC Switch 切换失败，请查看 ~/.cc-switch/logs/cc-switch.log'
}

function Invoke-CcsControl($Api, [string]$Method, [string]$Path, $Body) {
    $params = @{
        Method          = $Method
        Uri             = "$($Api.BaseUrl)$Path"
        Headers         = @{ Authorization = "Bearer $($Api.Token)" }
        TimeoutSec      = 30
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
        $params.ContentType = 'application/json'
    }
    try {
        $resp = Invoke-WebRequest @params
        return ([System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json)
    } catch {
        $status = $null; $code = $null
        if ($_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            try { $code = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch {}
        }
        if ($code -and $script:CcsApiErrorText.ContainsKey($code)) {
            throw "$($script:CcsApiErrorText[$code]) [$code]"
        }
        if ($status -in 404, 422) { throw "控制接口版本过旧，不支持此操作；请更新 CC Switch 补丁版（install.ps1 -InstallCcSwitch）" }
        if ($status) { throw "控制接口返回 HTTP $status $code" }
        throw "无法连接 CC Switch 控制接口: $($_.Exception.Message)"
    }
}

function New-CcsProvider([string]$Id, [string]$Name, [string]$Model, $Models, [bool]$Selectable, [bool]$Current) {
    [pscustomobject]@{
        Id         = $Id
        Name       = $Name
        Model      = $Model
        Models     = @($Models | Where-Object { $_ })
        Selectable = $Selectable
        Current    = $Current
    }
}

function Get-CcsSqlite {
    $cmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\sqlite3.exe'),
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\sqlite3.exe'),
        'C:\sqlite\sqlite3.exe'
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    throw '未检测到带控制接口的 CC Switch，也找不到 sqlite3.exe（冷切换需要）。安装: winget install SQLite.SQLite，或运行 install.ps1 -InstallCcSwitch 安装带控制接口的构建'
}

function Test-CcsIdentifier([string]$Value) {
    return ($Value -match '^[A-Za-z0-9._\-]{1,256}$')
}

# Catalog: @{Mode='hot'|'cold'; Providers; CurrentId; ProxyManaged; ProxyRunning; AutoFailover}
function Get-CcsCatalog([string]$AppType) {
    if (-not (Test-CcsIdentifier $AppType)) { throw "非法的应用类型: $AppType" }
    $api = Get-CcsControlApi
    if ($api) {
        $r = Invoke-CcsControl $api 'GET' "/api/v1/providers/$AppType"
        $list = foreach ($x in @($r.providers)) {
            New-CcsProvider $x.id $x.name $x.model $x.models ([bool]$x.selectable) ($x.id -eq $r.current_id)
        }
        $managed = if ($r.PSObject.Properties['proxy_managed']) { [bool]$r.proxy_managed } else { $true }
        return [pscustomobject]@{
            Mode = 'hot'; Providers = @($list); CurrentId = [string]$r.current_id; ProxyManaged = $managed
            ProxyRunning = [bool]$r.proxy_running; AutoFailover = [bool]$r.auto_failover
        }
    }
    if ($AppType -notin @('claude', 'codex', 'gemini', 'grokbuild')) {
        throw "$AppType 不经过本地代理，切换需要带控制接口的 CC Switch（install.ps1 -InstallCcSwitch）"
    }

    $paths = Get-CcsPaths
    if (-not (Test-Path $paths.Database)) { throw "找不到 CC Switch 数据库: $($paths.Database)" }
    $sqlite = Get-CcsSqlite
    $sql = "SELECT id, name, is_current, category, settings_config FROM providers WHERE app_type='$AppType' ORDER BY sort_index, name;"
    $raw = & $sqlite -json $paths.Database $sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "读取 cc-switch.db 失败: $raw" }
    $rows = @()
    $text = ($raw -join "`n").Trim()
    if ($text) { $rows = @($text | ConvertFrom-Json) }

    $settingsCurrent = $null
    if (Test-Path $paths.Settings) {
        try {
            $s = Get-Content $paths.Settings -Raw -Encoding UTF8 | ConvertFrom-Json
            $key = Get-CcsSettingsKey $AppType
            if ($s.PSObject.Properties[$key]) { $settingsCurrent = [string]$s.$key }
        } catch {}
    }
    $ids = @($rows | ForEach-Object { $_.id })
    $currentId = if ($settingsCurrent -and ($ids -contains $settingsCurrent)) { $settingsCurrent } else { [string](($rows | Where-Object { $_.is_current -eq 1 } | Select-Object -First 1).id) }

    $list = foreach ($x in $rows) {
        $model = ''
        try {
            $cfg = $x.settings_config | ConvertFrom-Json
            if ($AppType -eq 'claude' -and $cfg.env -and $cfg.env.ANTHROPIC_MODEL) { $model = [string]$cfg.env.ANTHROPIC_MODEL }
            elseif ($cfg.PSObject.Properties['model']) { $model = [string]$cfg.model }
        } catch {}
        New-CcsProvider $x.id $x.name $model @($model) ($x.category -ne 'official') ($x.id -eq $currentId)
    }
    return [pscustomobject]@{
        Mode = 'cold'; Providers = @($list); CurrentId = $currentId; ProxyManaged = $true
        ProxyRunning = (Test-CcsPort 15721); AutoFailover = $false
    }
}

# Models a provider can be mapped to: @{Configured; Upstream; UpstreamError}
function Get-CcsProviderModels([string]$AppType, [string]$Id) {
    if (-not (Test-CcsIdentifier $Id)) { throw "非法的供应商 ID: $Id" }
    $api = Get-CcsControlApi
    if ($api) {
        $r = Invoke-CcsControl $api 'GET' "/api/v1/providers/$AppType/models/$Id"
        return [pscustomobject]@{
            Configured = @($r.configured | Where-Object { $_ })
            Upstream = @($r.upstream | Where-Object { $_ })
            UpstreamError = [string]$r.upstream_error
        }
    }
    $catalog = Get-CcsCatalog $AppType
    $p = $catalog.Providers | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $p) { throw "供应商不存在: $Id" }
    [pscustomobject]@{ Configured = @($p.Models); Upstream = @(); UpstreamError = '未检测到控制接口，无法拉取上游模型列表' }
}

$script:CcsTierAliases = @('sonnet', 'opus', 'haiku', 'fable')

# "sonnet[1m]" -> @{Tiers=@('sonnet'); OneM=$true; Alias='sonnet[1m]'}; "all" -> every tier.
function ConvertTo-CcsTierSpec([string]$Spec) {
    $s = ([string]$Spec).Trim().ToLower()
    $oneM = $false
    if ($s -match '^(.*)\[1m\]$') { $s = $Matches[1]; $oneM = $true }
    switch ($s) {
        { $_ -in @('all', '全部', '*') } { return [pscustomobject]@{ Tiers = @(); OneM = $oneM; Alias = $null } }
        { $_ -in $script:CcsTierAliases } { return [pscustomobject]@{ Tiers = @($s); OneM = $oneM; Alias = ($s + $(if ($oneM) { '[1m]' } else { '' })) } }
        { $_ -in @('default', 'subagent') } { return [pscustomobject]@{ Tiers = @($s); OneM = $oneM; Alias = $null } }
        default { return $null }
    }
}

function Add-CcsOneMSuffix([string]$Model) {
    if ($Model -match '\[1m\]$') { return $Model }
    return "$Model[1M]"
}

function Resolve-CcsProvider($Providers, [string]$Query) {
    $q = ([string]$Query).Trim()
    if (-not $q) { return $null }
    $providers = @($Providers)
    $m = @($providers | Where-Object { $_.Id -eq $q })
    if ($m.Count -eq 1) { return $m[0] }
    $m = @($providers | Where-Object { $_.Name -ieq $q })
    if ($m.Count -eq 1) { return $m[0] }
    if ($q -match '^\d+$') {
        $i = [int]$q
        if ($i -ge 1 -and $i -le $providers.Count) { return $providers[$i - 1] }
    }
    $m = @($providers | Where-Object { $_.Name -like "*$q*" -or $_.Id -like "$q*" })
    if ($m.Count -eq 1) { return $m[0] }
    if ($m.Count -gt 1) { throw ('匹配到多个供应商，请写全名: ' + (($m | ForEach-Object { $_.Name }) -join ' / ')) }
    return $null
}

function Format-CcsCatalog($Catalog, [string]$AppType) {
    $modeText = if (-not $Catalog.ProxyManaged) { '直连配置' } elseif ($Catalog.Mode -eq 'hot') { '热切换' } else { '冷切换·需重启代理' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("CC Switch · $AppType 供应商（$modeText）")
    $i = 0
    foreach ($p in $Catalog.Providers) {
        $i++
        $mark = if ($p.Current) { '✅' } elseif (-not $p.Selectable) { '🚫' } else { '  ' }
        $model = if ($p.Model) { "  ·  $($p.Model)" } elseif ($p.Models.Count -gt 0) { "  ·  $($p.Models.Count) 个模型" } else { '' }
        [void]$sb.AppendLine(("{0,2}. {1} {2}{3}" -f $i, $mark, $p.Name, $model))
    }
    if ($Catalog.ProxyManaged -and -not $Catalog.ProxyRunning) { [void]$sb.AppendLine('⚠️ 本地代理未运行，切换不会生效') }
    if ($Catalog.AutoFailover) { [void]$sb.AppendLine('⚠️ 已开启自动故障转移，手动切换会被拒绝') }
    if ($Catalog.ProxyManaged) { [void]$sb.Append('用法: /ccs switch <序号|名称>   /ccs models <名称>') }
    else { [void]$sb.Append('用法: /ccs switch <序号|名称> 启用供应商，再用 /model <供应商ID>/<模型> 选模型') }
    return $sb.ToString()
}

# Hot: control API (all app types). Cold: settings.json + DB + restart CC Switch (proxy apps only).
function Select-CcsProvider([string]$AppType, [string]$Id) {
    if (-not (Test-CcsIdentifier $AppType)) { throw "非法的应用类型: $AppType" }
    if (-not (Test-CcsIdentifier $Id)) { throw "非法的供应商 ID: $Id" }
    $api = Get-CcsControlApi
    if ($api) {
        [void](Invoke-CcsControl $api 'POST' "/api/v1/providers/$AppType/select" @{ id = $Id })
        return 'hot'
    }
    if ($AppType -notin @('claude', 'codex', 'gemini', 'grokbuild')) {
        throw "$AppType 不经过本地代理，切换需要带控制接口的 CC Switch（install.ps1 -InstallCcSwitch）"
    }
    Invoke-CcsColdSwitch $AppType $Id
    return 'cold'
}

# Claude: remap the given tiers (empty = all) to $Model. Codex: set the provider's upstream model.
function Set-CcsProviderModel([string]$AppType, [string]$Id, [string]$Model, [string[]]$Tiers = @()) {
    if (-not (Test-CcsIdentifier $AppType)) { throw "非法的应用类型: $AppType" }
    if (-not (Test-CcsIdentifier $Id)) { throw "非法的供应商 ID: $Id" }
    if (-not $Model -or $Model.Length -gt 128 -or $Model -notmatch '^[A-Za-z0-9 ._:/\-\[\]]+$') { throw "非法的模型名: $Model" }
    $api = Get-CcsControlApi
    if (-not $api) { throw '修改模型映射需要带控制接口的 CC Switch（install.ps1 -InstallCcSwitch）' }
    $body = @{ id = $Id; model = $Model }
    if ($Tiers.Count -gt 0) { $body.tiers = @($Tiers) }
    [void](Invoke-CcsControl $api 'POST' "/api/v1/providers/$AppType/model" $body)
}

function Invoke-CcsColdSwitch([string]$AppType, [string]$Id) {
    $paths = Get-CcsPaths
    $sqlite = Get-CcsSqlite

    if (Test-Path $paths.Settings) {
        $rawSettings = Get-Content $paths.Settings -Raw -Encoding UTF8
        $settings = $rawSettings | ConvertFrom-Json
        $key = Get-CcsSettingsKey $AppType
        if ($settings.PSObject.Properties[$key]) { $settings.$key = $Id }
        else { $settings | Add-Member -NotePropertyName $key -NotePropertyValue $Id }
        Copy-Item $paths.Settings "$($paths.Settings).ccs-bak" -Force
        [System.IO.File]::WriteAllText($paths.Settings, ($settings | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding $false))
    }

    $sql = "UPDATE providers SET is_current = CASE WHEN id = '$Id' THEN 1 ELSE 0 END WHERE app_type = '$AppType';"
    $out = & $sqlite $paths.Database $sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "写入 cc-switch.db 失败: $out" }

    $proc = Get-Process -Name 'cc-switch' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { Write-Output '（CC Switch 未在运行，设置将在下次启动时生效）'; return }
    $exe = $proc.Path
    $active = @(Get-NetTCPConnection -LocalPort 15721 -State Established -ErrorAction SilentlyContinue).Count
    if ($active -gt 0) { Write-Output "（代理上有 $active 个活动连接，重启会中断它们）" }
    Stop-Process -Id $proc.Id -Force
    if (-not $proc.WaitForExit(10000)) { throw '无法结束 CC Switch 进程' }
    Start-Sleep -Milliseconds 800
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (Test-CcsPort 15721) { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'CC Switch 已重启，但 30 秒内代理端口 15721 未就绪，请检查桌面端'
}

# ---- cc-connect config.toml (read-only parser; tolerant of odd indentation) ----

function ConvertFrom-CcsTomlValue([string]$Raw) {
    $v = $Raw.Trim()
    if ($v -match '^"(.*)"\s*(#.*)?$') {
        $s = $Matches[1]
        return ($s -replace '\\"', '"' -replace '\\\\', '\')
    }
    if ($v -match "^'(.*)'\s*(#.*)?$") { return $Matches[1] }
    return ($v -replace '\s*#.*$', '')
}

# Returns project descriptors with line ranges so install.ps1 can edit safely.
function Get-CcsConnectProjects([string]$ConfigPath) {
    if (-not (Test-Path $ConfigPath)) { throw "找不到 cc-connect 配置: $ConfigPath" }
    $lines = @(Get-Content $ConfigPath -Encoding UTF8)
    $projects = New-Object System.Collections.ArrayList
    $cur = $null; $ctx = ''; $platform = $null; $command = $null; $hook = $null

    $closeProject = {
        param($endIndex)
        if ($null -ne $cur) {
            $cur.EndLine = $endIndex
            while ($cur.EndLine -gt $cur.StartLine -and [string]::IsNullOrWhiteSpace($lines[$cur.EndLine])) { $cur.EndLine-- }
        }
    }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }

        if ($t -match '^\[\[projects\]\]$') {
            & $closeProject ($i - 1)
            $cur = [pscustomobject]@{
                Name = ''; AgentType = ''; Feishu = $null; StartLine = $i; EndLine = $lines.Count - 1
                Commands = (New-Object System.Collections.ArrayList); Hooks = (New-Object System.Collections.ArrayList)
            }
            [void]$projects.Add($cur)
            $ctx = 'project'; $platform = $null; $command = $null; $hook = $null
            continue
        }
        if ($t -match '^\[\[?([A-Za-z0-9_.\-]+)\]?\]$') {
            $name = $Matches[1]
            if (-not $name.StartsWith('projects.')) {
                & $closeProject ($i - 1)
                $cur = $null; $ctx = 'toplevel'
                continue
            }
            if ($null -eq $cur) { continue }
            switch -Regex ($name) {
                '^projects\.platforms$'          { $platform = [pscustomobject]@{ Type = ''; Options = @{} }; $ctx = 'platform' }
                '^projects\.platforms\.options$' { $ctx = 'platform.options' }
                '^projects\.agent$'              { $ctx = 'agent' }
                '^projects\.commands$'           { $command = [pscustomobject]@{ Name = ''; Exec = ''; StartLine = $i; EndLine = $i }; [void]$cur.Commands.Add($command); $ctx = 'command' }
                '^projects\.hooks$'              { $hook = [pscustomobject]@{ Event = ''; Command = ''; StartLine = $i; EndLine = $i }; [void]$cur.Hooks.Add($hook); $ctx = 'hook' }
                default                          { $ctx = 'other' }
            }
            continue
        }

        if ($null -eq $cur) { continue }
        if ($t -match '^([A-Za-z0-9_\-]+)\s*=\s*(.+)$') {
            $k = $Matches[1]; $v = ConvertFrom-CcsTomlValue $Matches[2]
            switch ($ctx) {
                'project'          { if ($k -eq 'name') { $cur.Name = $v } }
                'agent'            { if ($k -eq 'type') { $cur.AgentType = $v } }
                'platform'         { if ($k -eq 'type') { $platform.Type = $v } else { $platform.Options[$k] = $v } }
                'platform.options' { if ($platform) { $platform.Options[$k] = $v } }
                'command'          { if ($k -eq 'name') { $command.Name = $v } elseif ($k -eq 'exec') { $command.Exec = $v }; $command.EndLine = $i }
                'hook'             { if ($k -eq 'event') { $hook.Event = $v } elseif ($k -eq 'command') { $hook.Command = $v }; $hook.EndLine = $i }
            }
            if (($ctx -in @('platform', 'platform.options')) -and $platform -and $platform.Type -eq 'feishu' -and -not $cur.Feishu) {
                $cur.Feishu = $platform
            }
        }
    }
    & $closeProject ($lines.Count - 1)
    return @($projects)
}

function Get-CcsFeishuCredential([string]$ConfigPath, [string]$ProjectName) {
    $project = Get-CcsConnectProjects $ConfigPath | Where-Object { $_.Name -eq $ProjectName } | Select-Object -First 1
    if (-not $project) { throw "config.toml 中没有项目 '$ProjectName'" }
    if (-not $project.Feishu) { throw "项目 '$ProjectName' 没有配置飞书平台" }
    $opt = $project.Feishu.Options
    if (-not $opt['app_id'] -or -not $opt['app_secret']) { throw "项目 '$ProjectName' 的飞书 app_id/app_secret 缺失" }
    $domain = 'https://open.feishu.cn'
    if ($opt['domain'] -and ($opt['domain'] -match 'lark')) { $domain = 'https://open.larksuite.com' }
    [pscustomobject]@{ AppId = $opt['app_id']; AppSecret = $opt['app_secret']; Domain = $domain }
}
