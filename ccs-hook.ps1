# cc-connect "message.received" hook: turns /ccs into Feishu interactive cards.
#
#   /ccs                          -> provider picker
#   /ccs switch <id>              -> (after the switch) model picker for that provider
#   /ccs models <id>              -> model picker
#   /ccs map <id> <model>         -> claude: tier picker (sonnet / sonnet[1m] / opus / ...)
#   /ccs map <id> <model> <tier>  -> claude: offer "/model <alias>" for the current session
#
# Buttons use cc-connect's native "cmd:" card action, so clicks are dispatched as commands
# from the clicking user; ccs.ps1 does the actual work.
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
$args2 = @($tokens | Select-Object -Skip 2)
$step = switch -Regex ($sub) {
    '^(list|ls|pick|menu|card)$'          { 'providers' }
    '^(switch|use|select|set|to)$'        { if ($args2.Count -eq 1) { 'models' } }
    '^(models|model-list|catalog)$'       { if ($args2.Count -eq 1) { 'models' } }
    '^map$'                               { if ($args2.Count -eq 2) { 'tiers' } elseif ($args2.Count -eq 3) { 'applied' } }
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
}

# ---- card building blocks ----

function New-CmdButton([string]$Label, [string]$Command, [string]$Type, [string]$AfterTitle, [string]$AfterMarkdown) {
    $value = @{ action = "cmd:$Command"; session_key = $sessionKey }
    if ($AfterTitle) { $value.after_click = @{ title = $AfterTitle; color = 'blue'; markdown = $(if ($AfterMarkdown) { $AfterMarkdown } else { '结果稍后以消息回复。' }) } }
    @{ tag = 'button'; text = @{ tag = 'plain_text'; content = $Label }; type = $Type; value = $value }
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

    $buttons = foreach ($p in ($Catalog.Providers | Where-Object { $_.Selectable })) {
        $label = $p.Name
        if ($p.Model) { $label += " · $($p.Model)" } elseif ($p.Models.Count -gt 0) { $label += " · $($p.Models.Count) 模型" }
        if ($p.Current) { $label = "✅ $label" }
        New-CmdButton $label "/ccs switch $($p.Id)" $(if ($p.Current) { 'primary' } else { 'default' }) "⏳ 正在切换到 $($p.Name)…" '切换结果和模型列表稍后发出。'
    }
    Add-ButtonRows $elements $buttons 4
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
    $shown = @($ordered | Select-Object -First 32)
    $buttons = foreach ($m in $shown) {
        $isConfigured = $Models.Configured -contains $m
        switch ($AppType) {
            'claude' { New-CmdButton $(if ($isConfigured) { "⭐ $m" } else { $m }) "/ccs map $($Target.Id) $m" $(if ($isConfigured) { 'primary' } else { 'default' }) "⏳ 已选 $m" '请在下一张卡片中选择映射到哪个别名。' }
            'codex'  { New-CmdButton $(if ($isConfigured) { "⭐ $m" } else { $m }) "/ccs map $($Target.Id) $m" $(if ($isConfigured) { 'primary' } else { 'default' }) "⏳ 正在设置 $m…" $null }
            default  { New-CmdButton $m "/model $($Target.Id)/$m" 'default' "⏳ 切换会话模型 → $($Target.Id)/$m" $null }
        }
    }
    if ($buttons.Count -eq 0) { [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = '没有可用的模型信息' } }) }
    Add-ButtonRows $elements $buttons 3
    if ($ordered.Count -gt $shown.Count) { [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = "还有 $($ordered.Count - $shown.Count) 个模型未显示，可用 /ccs models $($Target.Name) 查看全部" }) }) }
    if ($Models.UpstreamError) { [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = "上游模型列表不可用: $($Models.UpstreamError)" }) }) }
    New-Card "选择模型 · $($Target.Name)" 'turquoise' $elements
}

function New-TiersCard($Target, [string]$Model) {
    $elements = New-Object System.Collections.ArrayList
    [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = "**$Model** 映射到哪个别名？`n带 [1m] 的档位会以 **$Model[1M]** 写入；all 表示 haiku/sonnet/opus/fable 全部档位" } })
    $buttons = foreach ($t in $TierButtons) {
        $label = if ($t -like 'all*') { $t -replace '^all', '全部档位' } else { $t }
        New-CmdButton $label "/ccs map $($Target.Id) $Model $t" $(if ($t -like 'sonnet*') { 'primary' } else { 'default' }) "⏳ 正在写入 $label → $Model…" $null
    }
    Add-ButtonRows $elements $buttons 3
    New-Card "映射 · $($Target.Name)" 'orange' $elements
}

function New-AppliedCard($Target, [string]$Model, $TierSpec) {
    $elements = New-Object System.Collections.ArrayList
    $value = if ($TierSpec.OneM) { Add-CcsOneMSuffix $Model } else { $Model }
    [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = "已请求把 **$($Target.Name)** 的 **$($TierSpec.Alias)** 映射到 **$value**。`n当前会话用的仍是 cc-connect 里设置的模型别名；要让这次映射真正生效，把会话模型切到 $($TierSpec.Alias)：" } })
    Add-ButtonRows $elements @((New-CmdButton "切到 /model $($TierSpec.Alias)" "/model $($TierSpec.Alias)" 'primary' "✅ 已发送 /model $($TierSpec.Alias)" $null)) 2
    New-Card "应用到会话 · $($TierSpec.Alias)" 'green' $elements
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
    switch ($step) {
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
    Send-FeishuMessage $token $cred.Domain $chatId 'interactive' ($card | ConvertTo-Json -Depth 12 -Compress)
    Write-HookLog "card=$step project=$project app=$AppType chat=$chatId content='$content'"
} catch {
    Write-HookLog "ERROR step=$step project=$project app=$AppType session=$sessionKey : $($_.Exception.Message)"
    if ($markerTouched -and $token -and $cred -and $chatId) {
        try { Send-FeishuMessage $token $cred.Domain $chatId 'text' (@{ text = "❌ 卡片发送失败: $($_.Exception.Message)" } | ConvertTo-Json -Compress) } catch {}
    }
    Write-Error $_.Exception.Message
    exit 1
}
