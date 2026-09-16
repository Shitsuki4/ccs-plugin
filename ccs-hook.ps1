# cc-connect "message.received" hook: turns /ccs into Feishu interactive cards.
#
#   /ccs                          -> provider picker
#   /ccs switch <id>              -> (after the switch) model picker for that provider
#   /ccs models <id>              -> model picker
#   /ccs map <id> <model>         -> claude: tier picker (sonnet / sonnet[1m] / opus / ...)
#   /ccs map <id> <model> <tier>  -> claude: offer "/model <alias>" for the current session
#
# Pickers are select_static dropdowns whose option values are "cmd:..." commands, so a
# selection is dispatched as a command from the clicking user and chains into the next
# card (cascader-style provider -> model -> alias). ccs.ps1 does the actual work.
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z\-]+$')][string]$AppType = '',
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'

$content = ([string]$env:CC_HOOK_CONTENT).Trim()
$sessionKey = [string]$env:CC_HOOK_SESSION_KEY
$project = [string]$env:CC_HOOK_PROJECT
if ($env:CC_HOOK_EVENT -and $env:CC_HOOK_EVENT -ne 'message.received') { exit 0 }
if (-not $sessionKey.StartsWith('feishu:')) { exit 0 }
if ($content -notmatch '^/(ccs|cc-switch)(\s|$)') { exit 0 }

$tokens = @($content -split '\s+' | Where-Object { $_ })
$sub = if ($tokens.Count -ge 2) { $tokens[1].ToLower() } else { 'list' }
# /ccs map <id> <model> [tier] — tier may be quoted or contain [1m]; keep raw tail intact
$args2 = @($tokens | Select-Object -Skip 2)
$step = switch -Regex ($sub) {
    '^(list|ls|menu|card|cascade)$'        { 'cascade' }
    '^(pick)$'                             { 'pick' }
    '^(apply)$'                            { 'apply' }
    '^(pickers)$'                          { 'providers' }
    '^(switch|use|select|set|to)$'         { if ($args2.Count -eq 1) { 'models' } }
    '^(models|model-list|catalog)$'        { if ($args2.Count -eq 1) { 'models' } }
    '^map$'                                { if ($args2.Count -eq 2) { 'tiers' } elseif ($args2.Count -eq 3) { 'applied' } }
}
if (-not $step) { exit 0 }

. (Join-Path $PSScriptRoot 'ccs-common.ps1')
if (-not $AppType) { $AppType = Resolve-CcsAppType }
$paths = Get-CcsPaths
if (-not $ConfigPath) { $ConfigPath = $paths.ConnectConfig }
New-Item -ItemType Directory -Force $paths.StateDir | Out-Null
$logFile = Join-Path $paths.StateDir 'hook.log'
$TierButtons = @('sonnet', 'sonnet[1m]', 'opus', 'opus[1m]', 'haiku', 'fable', 'fable[1m]', 'all', 'all[1m]')

function Write-HookLog([string]$Message) {
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) { Clear-Content $logFile }
        Add-Content -Path $logFile -Value ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message) -Encoding UTF8
    } catch {}
}

function Get-FeishuTenantToken($Cred) {
    $cache = Join-Path $paths.StateDir ("token-" + $Cred.AppId + ".json")
    if (Test-Path $cache) {
        try {
            $c = Get-Content $cache -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([DateTime]::Parse($c.expires_at) -gt (Get-Date).AddMinutes(2)) { return $c.token }
        } catch {}
    }
    $body = @{ app_id = $Cred.AppId; app_secret = $Cred.AppSecret } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod -Method Post -Uri "$($Cred.Domain)/open-apis/auth/v3/tenant_access_token/internal" `
        -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15
    if ($r.code -ne 0) { throw "获取 tenant_access_token 失败: $($r.code) $($r.msg)" }
    $expiresAt = (Get-Date).AddSeconds([int]$r.expire).ToString('o')
    [System.IO.File]::WriteAllText($cache, (@{ token = $r.tenant_access_token; expires_at = $expiresAt } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
    return $r.tenant_access_token
}

function Send-FeishuMessage([string]$Token, [string]$Domain, [string]$ChatId, [string]$MsgType, [string]$Content) {
    $msg = @{ receive_id = $ChatId; msg_type = $MsgType; content = $Content } | ConvertTo-Json -Compress -Depth 4
    $r = Invoke-RestMethod -Method Post -Uri "$Domain/open-apis/im/v1/messages?receive_id_type=chat_id" `
        -Headers @{ Authorization = "Bearer $Token" } -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($msg)) -TimeoutSec 15
    if ($r.code -ne 0) { throw "发送消息失败: $($r.code) $($r.msg)" }
    try { return [string]$r.data.message_id } catch { return $null }
}

function Update-FeishuCard([string]$Token, [string]$Domain, [string]$MessageId, $Card) {
    $body = @{ content = ($Card | ConvertTo-Json -Depth 12 -Compress) } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod -Method Patch -Uri "$Domain/open-apis/im/v1/messages/$MessageId" `
        -Headers @{ Authorization = "Bearer $Token" } -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15
    if ($r.code -ne 0) { throw "更新卡片失败: $($r.code) $($r.msg)" }
}

# Card state per session: remembers which message holds the current /ccs card so the
# next step can patch it in place (cascader-style progressive reveal on one card).
function Get-CcsCardStatePath([string]$SessionKey) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hex = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($SessionKey)))).Replace('-', '').Substring(0, 16).ToLower()
    Join-Path $paths.StateDir "card-$hex.json"
}
function Save-CcsCardState([string]$SessionKey, $State) {
    $obj = [ordered]@{
        message_id  = [string]$State.message_id
        provider_id = [string]$State.provider_id
        model       = [string]$State.model
        tier        = [string]$State.tier
        at          = (Get-Date).ToString('o')
    }
    [System.IO.File]::WriteAllText((Get-CcsCardStatePath $SessionKey), ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
}
function Get-CcsCardState([string]$SessionKey) {
    $p = Get-CcsCardStatePath $SessionKey
    if (-not (Test-Path $p)) { return $null }
    try {
        $o = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
        return @{
            message_id  = [string]$o.message_id
            provider_id = [string]$o.provider_id
            model       = [string]$o.model
            tier        = [string]$o.tier
        }
    } catch { return $null }
}

# ---- card building blocks ----

function New-CmdButton([string]$Label, [string]$Command, [string]$Type, [string]$AfterTitle, [string]$AfterMarkdown) {
    $value = @{ action = "cmd:$Command"; session_key = $sessionKey }
    if ($AfterTitle) { $value.after_click = @{ title = $AfterTitle; color = 'blue'; markdown = $(if ($AfterMarkdown) { $AfterMarkdown } else { '结果稍后以消息回复。' }) } }
    @{ tag = 'button'; text = @{ tag = 'plain_text'; content = $Label }; type = $Type; value = $value }
}

# select_static dropdown: the picked option's value lands in the callback's Action.Option,
# which cc-connect only dispatches when it carries the "cmd:" prefix, so both option values
# and initial_option get it prepended here. The element value map carries session_key and
# the after_click feedback card (Action.Value).
function New-SelectRow([string]$Placeholder, $Options, [string]$InitValue, [string]$AfterTitle, [string]$AfterMarkdown) {
    $opts = @($Options | ForEach-Object {
        @{ text = @{ tag = 'plain_text'; content = [string]$_.Text }; value = "cmd:$($_.Value)" }
    })
    $value = @{ session_key = $sessionKey }
    if ($AfterTitle) { $value.after_click = @{ title = $AfterTitle; color = 'blue'; markdown = $(if ($AfterMarkdown) { $AfterMarkdown } else { '结果稍后以消息回复。' }) } }
    $elem = @{
        tag         = 'select_static'
        placeholder = @{ tag = 'plain_text'; content = $Placeholder }
        options     = $opts
        value       = $value
    }
    if ($InitValue) { $elem.initial_option = "cmd:$InitValue" }
    @{ tag = 'action'; actions = @($elem) }
}

function Add-ButtonRows($Elements, $Buttons, [int]$PerRow = 4) {
    $buttons = @($Buttons)
    for ($i = 0; $i -lt $buttons.Count; $i += $PerRow) {
        $chunk = @($buttons[$i..([Math]::Min($i + $PerRow - 1, $buttons.Count - 1))])
        [void]$Elements.Add(@{ tag = 'action'; actions = $chunk; layout = 'flow' })
    }
}

function New-Card([string]$Title, [string]$Template, $Elements) {
    [void]$Elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = "ccs-plugin v$script:CcsPluginVersion · $AppType" }) })
    @{
        config   = @{ wide_screen_mode = $true; update_multi = $true }
        header   = @{ title = @{ tag = 'plain_text'; content = $Title }; template = $Template }
        elements = $Elements.ToArray()
    }
}

function Test-SafeToken([string]$Value) { return ($Value -match '^[A-Za-z0-9._:/\-\[\]]{1,128}$') }

# ---- cards ----

function New-ProvidersCard($Catalog) {
    $current = $Catalog.Providers | Where-Object { $_.Current } | Select-Object -First 1
    $currentText = if ($current) { "**$($current.Name)**" + $(if ($current.Model) { " · $($current.Model)" } else { '' }) } else { '未设置' }
    $modeText = if (-not $Catalog.ProxyManaged) { '直连配置：点击启用供应商，再选模型' } elseif ($Catalog.Mode -eq 'hot') { '热切换，下一次请求即生效' } else { '冷切换，会重启 CC Switch 代理（约 10 秒）' }

    $elements = New-Object System.Collections.ArrayList
    $head = if ($Catalog.ProxyManaged) { "当前：$currentText`n$modeText" } else { $modeText }
    [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = $head } })
    if ($Catalog.ProxyManaged -and -not $Catalog.ProxyRunning) { [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = '⚠️ 本地代理未运行，切换不会生效' } }) }
    if ($Catalog.AutoFailover) { [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = '⚠️ 已开启自动故障转移，手动切换会被拒绝' } }) }

    $options = foreach ($p in ($Catalog.Providers | Where-Object { $_.Selectable })) {
        $text = $p.Name
        if ($p.Model) { $text += " · $($p.Model)" } elseif ($p.Models.Count -gt 0) { $text += " · $($p.Models.Count) 模型" }
        if ($p.Current) { $text = "✅ $text" }
        @{ Text = $text; Value = "/ccs switch $($p.Id)" }
    }
    $currentOpt = if ($current) { "/ccs switch $($current.Id)" } else { $null }
    [void]$elements.Add((New-SelectRow '选择要切换的供应商…' $options $currentOpt "⏳ 已选供应商，正在切换…" '切换结果和模型列表稍后发出。'))
    $blocked = @($Catalog.Providers | Where-Object { -not $_.Selectable } | ForEach-Object { $_.Name })
    if ($blocked.Count -gt 0) { [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = ('不可通过代理切换: ' + ($blocked -join ' / ')) }) }) }
    [void]$elements.Add(@{ tag = 'hr' })
    Add-ButtonRows $elements @((New-CmdButton '🔄 刷新' '/ccs' 'default' $null $null)) 4
    New-Card "CC Switch · $AppType 供应商" 'blue' $elements
}

function New-ModelsCard($Target, $Models) {
    $elements = New-Object System.Collections.ArrayList
    $intro = switch ($AppType) {
        'claude' { "供应商 **$($Target.Name)**：先选上游模型，下一步选择它映射到哪个别名（sonnet / sonnet[1m] / opus …）" }
        'codex'  { "供应商 **$($Target.Name)**：选择上游模型，代理会把所有请求改写成该模型" }
        default  { "供应商 **$($Target.Name)**：选择模型后会执行 /model $($Target.Id)/<模型>" }
    }
    [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = $intro } })

    $seen = New-Object System.Collections.Generic.HashSet[string]
    $ordered = New-Object System.Collections.ArrayList
    foreach ($m in @($Models.Configured) + @($Models.Upstream)) {
        if ($m -and (Test-SafeToken $m) -and $seen.Add($m)) { [void]$ordered.Add($m) }
    }
    $shown = @($ordered | Select-Object -First 100)
    $options = foreach ($m in $shown) {
        $isConfigured = $Models.Configured -contains $m
        $text = $(if ($isConfigured) { "⭐ $m" } else { $m })
        $cmd = switch ($AppType) {
            'claude' { "/ccs map $($Target.Id) $m" }
            'codex'  { "/ccs map $($Target.Id) $m" }
            default  { "/model $($Target.Id)/$m" }
        }
        @{ Text = $text; Value = $cmd }
    }
    if ($options.Count -eq 0) { [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = '没有可用的模型信息' } }) }
    else {
        $after = switch ($AppType) {
            'claude' { "⏳ 已选模型，请在下一张卡片中选择映射别名…" }
            'codex'  { "⏳ 正在设置上游模型…" }
            default  { "⏳ 正在切换会话模型…" }
        }
        $initial = $null
        if ($AppType -ne 'claude') {
            $curModel = $Models.Configured | Select-Object -First 1
            if ($curModel) { $initial = switch ($AppType) { 'codex' { "/ccs map $($Target.Id) $curModel" } default { "/model $($Target.Id)/$curModel" } } }
        }
        [void]$elements.Add((New-SelectRow '选择模型…' $options $initial $after $null))
    }
    if ($ordered.Count -gt $shown.Count) { [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = "还有 $($ordered.Count - $shown.Count) 个模型未显示，可用 /ccs models $($Target.Name) 查看全部" }) }) }
    if ($Models.UpstreamError) { [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = "上游模型列表不可用: $($Models.UpstreamError)" }) }) }
    New-Card "选择模型 · $($Target.Name)" 'turquoise' $elements
}

function New-TiersCard($Target, [string]$Model) {
    $elements = New-Object System.Collections.ArrayList
    [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = "**$Model** 映射到哪个别名？`n带 [1m] 的档位会以 **$Model[1M]** 写入；all 表示 haiku/sonnet/opus/fable 全部档位" } })
    $options = foreach ($t in $TierButtons) {
        $text = if ($t -like 'all*') { $t -replace '^all', '全部档位' } else { $t }
        @{ Text = $text; Value = "/ccs map $($Target.Id) $Model $t" }
    }
    $initial = "/ccs map $($Target.Id) $Model sonnet"
    [void]$elements.Add((New-SelectRow '映射到哪个别名…' $options $initial "⏳ 正在写入映射…" $null))
    New-Card "映射 · $($Target.Name)" 'orange' $elements
}

function New-AppliedCard($Target, [string]$Model, $TierSpec) {
    $elements = New-Object System.Collections.ArrayList
    $value = if ($TierSpec.OneM) { Add-CcsOneMSuffix $Model } else { $Model }
    [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = "已请求把 **$($Target.Name)** 的 **$($TierSpec.Alias)** 映射到 **$value**。`n当前会话用的仍是 cc-connect 里设置的模型别名；要让这次映射真正生效，把会话模型切到 $($TierSpec.Alias)：" } })
    Add-ButtonRows $elements @((New-CmdButton "切到 /model $($TierSpec.Alias)" "/model $($TierSpec.Alias)" 'primary' "✅ 已发送 /model $($TierSpec.Alias)" $null)) 2
    New-Card "应用到会话 · $($TierSpec.Alias)" 'green' $elements
}

# ---- single-card cascader ----
# One card holds up to three select_static dropdowns: provider -> model -> alias tier.
# Each pick re-renders and PATCHes the same message in place; the final pick applies.

function ConvertTo-CcsPickerCommand([string]$Kind, [string]$Value) {
    "/ccs pick $Kind '$Value'"
}

function New-CascadeCard([string]$AppType, $Catalog, $Models, [hashtable]$Sel, [string]$StatusText, [string]$StatusColor) {
    # fill missing keys so StrictMode property access never throws
    foreach ($k in @('provider_id', 'model', 'tier')) { if (-not $Sel.ContainsKey($k)) { $Sel[$k] = '' } }
    $elements = New-Object System.Collections.ArrayList

    # status line
    $line = ''
    if ($Sel.provider_id) {
        $pv = $Catalog.Providers | Where-Object { $_.Id -eq $Sel.provider_id } | Select-Object -First 1
        if ($pv) { $line = "**$($pv.Name)**" + $(if ($pv.Model) { " · $($pv.Model)" }) }
    }
    if ($line -and $Sel.model) { $line += " · **$($Sel.model)**" }
    elseif ($Sel.model) { $line = "**$($Sel.model)**" }
    if ($line -and $Sel.tier) { $line += " → **$($Sel.tier)**" }
    if (-not $line) { $line = '未选择' }
    $head = if ($StatusText) { "$StatusText`n当前选择：$line" } else { "当前选择：$line" }
    [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = $head } })
    if ($Catalog.ProxyManaged -and -not $Catalog.ProxyRunning) { [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = '⚠️ 本地代理未运行，切换不会生效' } }) }

    # 1. provider dropdown
    $pOpts = foreach ($p in ($Catalog.Providers | Where-Object { $_.Selectable })) {
        $text = $p.Name
        if ($p.Model) { $text += " · $($p.Model)" }
        if ($p.Current) { $text = "✅ $text" }
        @{ Text = $text; Value = (ConvertTo-CcsPickerCommand 'provider' $p.Id) }
    }
    $pInit = if ($Sel.provider_id) { ConvertTo-CcsPickerCommand 'provider' $Sel.provider_id } else { $null }
    [void]$elements.Add((New-SelectRow '① 选择供应商…' $pOpts $pInit "⏳ 已选供应商，正在加载模型…" $null))

    # 2. model dropdown (only once a provider is picked)
    if ($Sel.provider_id -and $Models) {
        $seen = New-Object System.Collections.Generic.HashSet[string]
        $ordered = New-Object System.Collections.ArrayList
        foreach ($m in @($Models.Configured) + @($Models.Upstream)) {
            if ($m -and (Test-SafeToken $m) -and $seen.Add($m)) { [void]$ordered.Add($m) }
        }
        $shown = @($ordered | Select-Object -First 100)
        $mOpts = foreach ($m in $shown) {
            $isCfg = $Models.Configured -contains $m
            @{ Text = $(if ($isCfg) { "⭐ $m" } else { $m }); Value = (ConvertTo-CcsPickerCommand 'model' $m) }
        }
        $mInit = if ($Sel.model) { ConvertTo-CcsPickerCommand 'model' $Sel.model } else { $null }
        [void]$elements.Add((New-SelectRow '② 选择模型…' $mOpts $mInit "⏳ 已选模型，选择映射别名…" $null))
        if ($ordered.Count -gt $shown.Count) {
            [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = "还有 $($ordered.Count - $shown.Count) 个模型未列出" }) })
        }
        if ($Models.UpstreamError) {
            [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = "上游模型列表不可用: $($Models.UpstreamError)" }) })
        }
    }

    # 3. tier dropdown (claude only; codex needs no tier)
    if ($AppType -eq 'claude' -and $Sel.model) {
        $tOpts = foreach ($t in $TierButtons) {
            $text = if ($t -like 'all*') { $t -replace '^all', '全部档位' } else { $t }
            @{ Text = $text; Value = (ConvertTo-CcsPickerCommand 'tier' $t) }
        }
        $tInit = if ($Sel.tier) { ConvertTo-CcsPickerCommand 'tier' $Sel.tier } else { $null }
        [void]$elements.Add((New-SelectRow '③ 映射到哪个别名…' $tOpts $tInit "⏳ 正在写入映射…" $null))
    }

    # confirm button appears once everything needed is picked
    $ready = $Sel.provider_id -and $Sel.model -and ($AppType -ne 'claude' -or $Sel.tier)
    if ($ready) {
        $applyCmd = "/ccs apply $($Sel.provider_id) '$($Sel.model)' $(if ($AppType -eq 'claude') { $Sel.tier })"
        [void]$elements.Add(@{
            tag     = 'action'
            actions = @((New-CmdButton '✍️ 写入' $applyCmd 'primary' "⏳ 正在写入 $($Sel.model)$(if ($AppType -eq 'claude') { " → $($Sel.tier)" })…" '结果稍后以消息回复。'))
        })
    }

    $template = 'blue'
    if ($StatusColor) { $template = $StatusColor }
    elseif ($ready) { $template = 'green' }
    elseif ($Sel.model) { $template = 'turquoise' }
    elseif ($Sel.provider_id) { $template = 'purple' }
    $title = "CC Switch 配置 · $AppType"
    New-Card $title $template $elements
}

# ---- main ----

$markerTouched = $false
$token = $null; $cred = $null; $chatId = $null
try {
    $parts = $sessionKey.Split(':')
    if ($parts.Count -lt 2 -or -not $parts[1]) { throw "无法从会话键解析 chat_id: $sessionKey" }
    $chatId = $parts[1]
    $cred = Get-CcsFeishuCredential $ConfigPath $project

    $card = $null
    $patchMessageId = $null
    switch ($step) {
        'cascade' {
            # fresh single-card cascader
            $catalog = Get-CcsCatalog $AppType
            if ($catalog.Providers.Count -eq 0) { throw "CC Switch 中没有 $AppType 供应商" }
            $card = New-CascadeCard $AppType $catalog $null @{} $null $null
        }
        'pick' {
            # dropdown callback: /ccs-pick provider '<id>' | model '<m>' | tier '<t>'
            if ($args2.Count -lt 2) { exit 0 }
            $kind = $args2[0].ToLower()
            $raw = $args2[1..($args2.Count - 1)] -join ' '
            $val = $raw.Trim("'`u{2018}`u{2019}`u{201C}`u{201D}".ToCharArray()).Trim()
            if (-not $val -or $kind -notin @('provider', 'model', 'tier')) { exit 0 }
            if ($kind -ne 'provider' -and -not (Test-SafeToken $val)) { exit 0 }

            $state = Get-CcsCardState $sessionKey
            if (-not $state -or -not $state.message_id) { Write-HookLog "pick: no card state, ignoring pick $kind"; exit 0 }
            $patchMessageId = $state.message_id

            $catalog = Get-CcsCatalog $AppType
            if ($catalog.Providers.Count -eq 0) { throw "CC Switch 中没有 $AppType 供应商" }

            $sel = @{ provider_id = $state.provider_id; model = $state.model; tier = $state.tier }
            switch ($kind) {
                'provider' {
                    $t = Resolve-CcsProvider $catalog.Providers $val
                    if (-not $t -or -not $t.Selectable) { Write-HookLog "pick: provider '$val' not found/unselectable"; exit 0 }
                    $sel = @{ provider_id = $t.Id; model = ''; tier = '' }
                }
                'model'  { if (-not $sel.provider_id) { exit 0 }; $sel.model = $val; $sel.tier = '' }
                'tier'   { if (-not $sel.model) { exit 0 }; $sel.tier = $val }
            }
            Save-CcsCardState $sessionKey @{
                message_id  = $patchMessageId
                provider_id = $sel.provider_id
                model       = $sel.model
                tier        = $sel.tier
            }

            $models = $null
            if ($sel.provider_id) {
                $t = $catalog.Providers | Where-Object { $_.Id -eq $sel.provider_id } | Select-Object -First 1
                if ($t) { $models = Get-CcsProviderModels $AppType $t.Id }
            }
            $status = "已记录选择（第 $($tokens.Count) 项：$kind）"
            $card = New-CascadeCard $AppType $catalog $models $sel $status $null
            Write-HookLog "card=pick kind=$kind val='$val' provider=$($sel.provider_id) model=$($sel.model) tier=$($sel.tier)"
        }
        'apply' {
            # executed only via the card's 写入 button (cmd:/ccs apply ...); the
            # marker makes ccs.ps1 print the hint while the hook does the real work
            if ($args2.Count -lt 2) { exit 0 }
            $provId = $args2[0]
            if (-not (Test-CcsIdentifier $provId)) { exit 0 }
            $state = Get-CcsCardState $sessionKey
            $rest = @($args2 | Select-Object -Skip 1)
            $model = $rest[0].Trim("'".ToCharArray())
            if (-not (Test-SafeToken $model)) { exit 0 }
            $tier = if ($AppType -eq 'claude' -and $rest.Count -ge 2) { $rest[-1] } else { $null }

            $catalog = Get-CcsCatalog $AppType
            $target = $catalog.Providers | Where-Object { $_.Id -eq $provId } | Select-Object -First 1
            if (-not $target) { exit 0 }

            # 1. switch provider if not current
            $applied = New-Object System.Collections.ArrayList
            if (-not $target.Current) {
                $mode = Select-CcsProvider $AppType $target.Id
                [void]$applied.Add("切换供应商 → **$($target.Name)**（$mode）")
            }
            # 2. write model mapping
            $tierSpec = $null
            if ($AppType -eq 'claude') {
                $tierSpec = if ($tier) { ConvertTo-CcsTierSpec $tier } else { ConvertTo-CcsTierSpec 'all' }
                $value = if ($tierSpec.OneM) { Add-CcsOneMSuffix $model } else { $model }
                Set-CcsProviderModel $AppType $target.Id $value $tierSpec.Tiers
                $scope = if ($tierSpec.Alias) { $tierSpec.Alias } elseif ($tierSpec.Tiers.Count -gt 0) { $tierSpec.Tiers -join ',' } else { '全部档位' }
                [void]$applied.Add("$scope → **$value**")
            } elseif ($AppType -eq 'codex') {
                Set-CcsProviderModel $AppType $target.Id $model
                [void]$applied.Add("上游模型 → **$model**")
            } else {
                # direct apps (pi etc.): the session model is picked via the /model builtin
                [void]$applied.Add("模型 → **$model**（点下方按钮切换会话模型）")
            }

            $suffix = if ($target.Current) { '下一次请求即生效' } else { '切换已提交，生效于下次请求' }
            $elements = New-Object System.Collections.ArrayList
            [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = "**$($target.Name)**：$($applied -join '，')`n$suffix" } })
            $switchModelBtn = $null
            if ($AppType -eq 'claude' -and $tierSpec.Alias) {
                $switchModelBtn = New-CmdButton "切到 /model $($tierSpec.Alias)" "/model $($tierSpec.Alias)" 'primary' "✅ 已发送 /model $($tierSpec.Alias)" $null
            } elseif ($AppType -notin @('claude', 'codex')) {
                $switchModelBtn = New-CmdButton "切到 /model $($target.Id)/$model" "/model $($target.Id)/$model" 'primary' "✅ 已发送 /model" $null
            }
            $againBtn = New-CmdButton '再配一个' '/ccs' 'default' $null $null
            $btns = @($againBtn); if ($switchModelBtn) { $btns = @($switchModelBtn, $againBtn) }
            Add-ButtonRows $elements $btns 2
            $card = New-Card '✅ 已写入' 'green' $elements
            # clear state so the next /ccs starts fresh
            Save-CcsCardState $sessionKey @{ message_id = ''; provider_id = ''; model = ''; tier = '' }
            Write-HookLog "card=apply provider=$($target.Id) model=$model tier=$tier"
        }
        'providers' {
            $catalog = Get-CcsCatalog $AppType
            if ($catalog.Providers.Count -eq 0) { throw "CC Switch 中没有 $AppType 供应商" }
            $card = New-ProvidersCard $catalog
        }
        'models' {
            $catalog = Get-CcsCatalog $AppType
            $target = Resolve-CcsProvider $catalog.Providers $args2[0]
            if (-not $target) { exit 0 }
            $models = Get-CcsProviderModels $AppType $target.Id
            if ($models.Configured.Count -eq 0 -and $models.Upstream.Count -eq 0) { exit 0 }
            $card = New-ModelsCard $target $models
        }
        'tiers' {
            if ($AppType -ne 'claude') { exit 0 }
            if (-not (Test-SafeToken $args2[1])) { exit 0 }
            $catalog = Get-CcsCatalog $AppType
            $target = Resolve-CcsProvider $catalog.Providers $args2[0]
            if (-not $target) { exit 0 }
            $card = New-TiersCard $target $args2[1]
        }
        'applied' {
            if ($AppType -ne 'claude') { exit 0 }
            $tierSpec = ConvertTo-CcsTierSpec $args2[2]
            if (-not $tierSpec -or -not $tierSpec.Alias) { exit 0 }
            if (-not (Test-SafeToken $args2[1])) { exit 0 }
            $catalog = Get-CcsCatalog $AppType
            $target = Resolve-CcsProvider $catalog.Providers $args2[0]
            if (-not $target) { exit 0 }
            $card = New-AppliedCard $target $args2[1] $tierSpec
        }
    }
    if (-not $card) { exit 0 }

    $token = Get-FeishuTenantToken $cred
    # Touch the marker so ccs.ps1 (running concurrently) prints a hint instead of a duplicate list.
    [System.IO.File]::WriteAllText($paths.CardMarker, (Get-Date).ToString('o'))
    $markerTouched = $true
    if ($step -eq 'pick' -and $patchMessageId) {
        # cascade step: patch the existing card in place, no new message
        Update-FeishuCard $token $cred.Domain $patchMessageId $card
    } else {
        $msgId = Send-FeishuMessage $token $cred.Domain $chatId 'interactive' ($card | ConvertTo-Json -Depth 12 -Compress)
        if ($step -eq 'cascade' -and $msgId) {
            Save-CcsCardState $sessionKey @{ message_id = $msgId; provider_id = ''; model = ''; tier = '' }
        }
    }
    Write-HookLog "card=$step project=$project app=$AppType chat=$chatId content='$content'"
} catch {
    Write-HookLog "ERROR step=$step project=$project app=$AppType session=$sessionKey : $($_.Exception.Message)"
    if ($markerTouched -and $token -and $cred -and $chatId) {
        try { Send-FeishuMessage $token $cred.Domain $chatId 'text' (@{ text = "❌ 卡片发送失败: $($_.Exception.Message)" } | ConvertTo-Json -Compress) } catch {}
    }
    Write-Error $_.Exception.Message
    exit 1
}
