# cc-connect "message.received" hook: turns /ccs into Feishu interactive cards.
#
#   /ccs                -> single cascade card: provider / model / alias dropdowns + apply
#   /ccs pick p <id>    -> record provider choice, patch the same card in place
#   /ccs pick m <model> -> record model choice, patch the same card in place
#   /ccs pick t <tier>  -> record alias choice, patch the same card in place
#   /ccs apply|applycard …  -> executed by ccs.ps1 (hook stays out of the way)
#
# select_static option values carry "cmd:" so cc-connect dispatches them as commands;
# the hook then PATCHes the stored card message_id (im/v1/messages/:id) so all three
# selections accumulate on ONE card. The apply button carries only the state key — the
# selection is read from that file when the button fires, never baked into the card.
# Apps CC Switch configures directly (Pi) get no apply button: their model options carry a
# self-contained "/model <providerId>/<model>" instead, and their provider row is browse-only.
# Legacy text flows still work: /ccs switch|models|map render the old chained cards.
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
    '^(list|ls|menu|card|cascade)$'        { 'cascade' }
    '^(pick)$'                             { 'pick' }
    '^(apply)$'                            { 'applied-skip' }
    '^(switch|use|select|set|to)$'         { if ($args2.Count -eq 1) { 'models' } }
    '^(models|model-list|catalog)$'        { if ($args2.Count -eq 1) { 'models' } }
    '^map$'                                { if ($args2.Count -eq 2) { 'tiers' } elseif ($args2.Count -eq 3) { 'applied' } }
}
if (-not $step) { exit 0 }
# apply is handled by ccs.ps1; don't send a competing card
if ($step -eq 'applied-skip') { exit 0 }

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

# Card state helpers (Get-CcsCardState / Save-CcsCardState / Get-CcsCardStateKey) live in
# ccs-common.ps1 so ccs.ps1 can read the latest dropdown selection at apply time.

function New-CmdButton([string]$Label, [string]$Command, [string]$Type, [string]$AfterTitle, [string]$AfterMarkdown) {
    $value = @{ action = "cmd:$Command"; session_key = $sessionKey }
    if ($AfterTitle) { $value.after_click = @{ title = $AfterTitle; color = 'blue'; markdown = $(if ($AfterMarkdown) { $AfterMarkdown } else { '结果稍后以消息回复。' }) } }
    @{ tag = 'button'; text = @{ tag = 'plain_text'; content = $Label }; type = $Type; value = $value }
}

# No after_click on dropdowns: cc-connect would replace the whole card with a
# loading stub and wipe the other two dropdowns. Keep the card, PATCH it later.
function New-SelectRow([string]$Placeholder, $Options, [string]$InitValue) {
    $opts = @($Options | ForEach-Object {
        @{ text = @{ tag = 'plain_text'; content = [string]$_.Text }; value = "cmd:$($_.Value)" }
    })
    $elem = @{
        tag         = 'select_static'
        placeholder = @{ tag = 'plain_text'; content = $Placeholder }
        options     = $opts
        value       = @{ session_key = $sessionKey }
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

function ConvertTo-PickCmd([string]$Kind, [string]$Value) { "/ccs pick $Kind $Value" }

function Get-OrderedModels($Models) {
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $ordered = New-Object System.Collections.ArrayList
    if (-not $Models) { return @() }
    foreach ($m in @($Models.Configured) + @($Models.Upstream)) {
        if ($m -and (Test-SafeToken $m) -and $seen.Add($m)) { [void]$ordered.Add($m) }
    }
    return @($ordered)
}

# One card, three dropdowns always visible. Changing provider only swaps the
# model list; the write button reads the accumulated selection when it fires.
function New-ComboCard($Catalog, [hashtable]$Sel) {
    foreach ($k in @('provider_id', 'model', 'tier')) { if (-not $Sel.ContainsKey($k)) { $Sel[$k] = '' } }
    $current = $Catalog.Providers | Where-Object { $_.Current } | Select-Object -First 1
    $target = $null
    if ($Sel.provider_id) { $target = $Catalog.Providers | Where-Object { $_.Id -eq $Sel.provider_id } | Select-Object -First 1 }
    if (-not $target) { $target = $current }
    # Direct-config apps have no current provider; open on the first one instead of nothing.
    if (-not $target) { $target = $Catalog.Providers | Select-Object -First 1 }

    $models = $null
    $ordered = @()
    if ($target) {
        try { $models = Get-CcsProviderModels $AppType $target.Id } catch {}
        $ordered = @(Get-OrderedModels $models)
        if ($Sel.model -and ($ordered -notcontains $Sel.model)) { $Sel.model = '' }
        if (-not $Sel.model -and $target.Model) {
            $plain = [string]($target.Model -replace '\[1[Mm]\]$', '')
            if ($ordered -contains $target.Model) { $Sel.model = [string]$target.Model }
            elseif ($plain -and ($ordered -contains $plain)) { $Sel.model = $plain }
        }
        if (-not $Sel.model -and $models -and $models.Configured.Count -gt 0 -and ($ordered -contains $models.Configured[0])) {
            $Sel.model = [string]$models.Configured[0]
        }
    }

    $elements = New-Object System.Collections.ArrayList
    $direct = -not $Catalog.ProxyManaged
    # Direct-config apps have no current provider; the running pairing is the one in the card.
    $live = if ($direct -and $target) { "**$($target.Name)**" + $(if ($Sel.model) { " · $($Sel.model)" } else { '' }) }
            elseif ($current) { "**$($current.Name)**" + $(if ($current.Model) { " · $($current.Model)" } else { '' }) }
            else { '未设置' }
    if ($direct) {
        [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = "当前运行：$live`n直连配置：CC Switch 把供应商直接写进 $AppType 自己的配置，没有「当前供应商」可切换；模型下拉选中即刻执行 /model" } })
    } else {
        $picked = @()
        if ($target) { $picked += $target.Name }
        if ($Sel.model) { $picked += $Sel.model }
        if ($Sel.tier) { $picked += $Sel.tier }
        $pickedText = if ($picked.Count -gt 0) { $picked -join '  →  ' } else { '（尚未选择）' }
        $modeText = if ($Catalog.Mode -eq 'hot') { '热切换，写入后下一次请求即生效' } else { '冷切换，写入会重启代理' }
        [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = "当前运行：$live`n本次选择：**$pickedText**`n$modeText" } })
    }
    if ($Catalog.ProxyManaged -and -not $Catalog.ProxyRunning) { [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = '⚠️ 本地代理未运行，切换不会生效' } }) }
    if ($Catalog.AutoFailover) { [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = '⚠️ 已开启自动故障转移，手动切换会被拒绝' } }) }

    $pOpts = foreach ($p in ($Catalog.Providers | Where-Object { $_.Selectable })) {
        $text = $p.Name
        if ($p.Model) { $text += " · $($p.Model)" }
        if ($p.Current) { $text = "✅ $text" }
        @{ Text = $text; Value = (ConvertTo-PickCmd 'p' $p.Id) }
    }
    $pInit = if ($target) { ConvertTo-PickCmd 'p' $target.Id } else { $null }
    [void]$elements.Add((New-SelectRow $(if ($direct) { '① 供应商（仅浏览）' } else { '① 供应商' }) $pOpts $pInit))

    $shown = @($ordered | Select-Object -First 100)
    if ($shown.Count -eq 0) {
        [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = '② 模型：该供应商暂无模型列表' } })
    } else {
        $mOpts = foreach ($m in $shown) {
            $star = ($models -and ($models.Configured -contains $m))
            # Direct-config apps: bake the whole command into the option so the value is correct by
            # construction, however fast the click lands after the pick.
            $cmd = if ($direct -and $target) { "/model $($target.Id)/$m" } else { ConvertTo-PickCmd 'm' $m }
            @{ Text = $(if ($star) { "⭐ $m" } else { $m }); Value = $cmd }
        }
        $mInit = if ($Sel.model) {
            if ($direct -and $target) { "/model $($target.Id)/$($Sel.model)" } else { ConvertTo-PickCmd 'm' $Sel.model }
        } else { $null }
        [void]$elements.Add((New-SelectRow $(if ($direct) { '② 模型（选中即刻生效）' } else { '② 模型' }) $mOpts $mInit))
        if ($ordered.Count -gt $shown.Count) {
            [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = "还有 $($ordered.Count - $shown.Count) 个模型未列出" }) })
        }
    }
    if ($models -and $models.UpstreamError) {
        [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = "上游模型列表不可用: $($models.UpstreamError)" }) })
    }

    if ($AppType -eq 'claude') {
        $tOpts = foreach ($t in $TierButtons) {
            $text = if ($t -like 'all*') { $t -replace '^all', '全部档位' } else { $t }
            @{ Text = $text; Value = (ConvertTo-PickCmd 't' $t) }
        }
        $tInit = if ($Sel.tier) { ConvertTo-PickCmd 't' $Sel.tier } else { $null }
        [void]$elements.Add((New-SelectRow '③ 映射别名' $tOpts $tInit))
    }

    # The button carries only the state key; ccs.ps1 reads the latest selection when it fires, so
    # the applied model can no longer be a value that was stale at render time.
    $ready = (-not $direct) -and $target -and $Sel.model -and ($AppType -ne 'claude' -or $Sel.tier)
    $btns = New-Object System.Collections.ArrayList
    if ($ready) {
        [void]$btns.Add((New-CmdButton '✍️ 写入' "/ccs applycard $(Get-CcsCardStateKey $sessionKey)" 'primary' '⏳ 正在写入…' '实际生效的供应商与模型会写在结果里。'))
    }
    [void]$btns.Add((New-CmdButton '🔄 重置' '/ccs' 'default' $null $null))
    Add-ButtonRows $elements $btns 2

    if ($direct) {
        [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = '供应商在 CC Switch 里增删；这张卡只负责把模型发给 cc-connect' }) })
    } else {
        $blocked = @($Catalog.Providers | Where-Object { -not $_.Selectable } | ForEach-Object { $_.Name })
        if ($blocked.Count -gt 0) { [void]$elements.Add(@{ tag = 'note'; elements = @(@{ tag = 'plain_text'; content = ('不可通过代理切换: ' + ($blocked -join ' / ')) }) }) }
    }

    $template = if ($ready) { 'green' } elseif ($direct) { 'turquoise' } else { 'blue' }
    New-Card "CC Switch · $AppType" $template $elements
}

function New-ModelsCard($Target, $Models) {
    $elements = New-Object System.Collections.ArrayList
    $intro = switch ($AppType) {
        'claude' { "供应商 **$($Target.Name)**：先选上游模型，下一步选择它映射到哪个别名（sonnet / sonnet[1m] / opus …）" }
        'codex'  { "供应商 **$($Target.Name)**：选择上游模型，代理会把所有请求改写成该模型" }
        default  { "供应商 **$($Target.Name)**：选择模型后会执行 /model $($Target.Id)/<模型>" }
    }
    [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = $intro } })
    $ordered = @(Get-OrderedModels $Models)
    $shown = @($ordered | Select-Object -First 100)
    $options = foreach ($m in $shown) {
        $isConfigured = $Models.Configured -contains $m
        $cmd = switch ($AppType) {
            'claude' { "/ccs map $($Target.Id) $m" }
            'codex'  { "/ccs map $($Target.Id) $m" }
            default  { "/model $($Target.Id)/$m" }
        }
        @{ Text = $(if ($isConfigured) { "⭐ $m" } else { $m }); Value = $cmd }
    }
    if ($options.Count -eq 0) { [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = '没有可用的模型信息' } }) }
    else { [void]$elements.Add((New-SelectRow '选择模型…' $options $null)) }
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
    [void]$elements.Add((New-SelectRow '映射到哪个别名…' $options ("/ccs map $($Target.Id) $Model sonnet")))
    New-Card "映射 · $($Target.Name)" 'orange' $elements
}

function New-AppliedCard($Target, [string]$Model, $TierSpec) {
    $elements = New-Object System.Collections.ArrayList
    $value = if ($TierSpec.OneM) { Add-CcsOneMSuffix $Model } else { $Model }
    [void]$elements.Add(@{ tag = 'div'; text = @{ tag = 'lark_md'; content = "已请求把 **$($Target.Name)** 的 **$($TierSpec.Alias)** 映射到 **$value**。`n当前会话用的仍是 cc-connect 里设置的模型别名；要让这次映射真正生效，把会话模型切到 $($TierSpec.Alias)：" } })
    Add-ButtonRows $elements @((New-CmdButton "切到 /model $($TierSpec.Alias)" "/model $($TierSpec.Alias)" 'primary' "✅ 已发送 /model $($TierSpec.Alias)" $null)) 2
    New-Card "应用到会话 · $($TierSpec.Alias)" 'green' $elements
}

$markerTouched = $false
$token = $null; $cred = $null; $chatId = $null
try {
    $parts = $sessionKey.Split(':')
    if ($parts.Count -lt 2 -or -not $parts[1]) { throw "无法从会话键解析 chat_id: $sessionKey" }
    $chatId = $parts[1]
    $cred = Get-CcsFeishuCredential $ConfigPath $project

    $card = $null
    $patchMessageId = $null
    $sel = $null
    # Stamp before the slow catalog/models fetch so ccs.ps1 doesn't dump the text list.
    [System.IO.File]::WriteAllText($paths.CardMarker, (Get-Date).ToString('o'))
    $markerTouched = $true
    switch ($step) {
        'cascade' {
            $catalog = Get-CcsCatalog $AppType
            if ($catalog.Providers.Count -eq 0) { throw "CC Switch 中没有 $AppType 供应商" }
            $cur = $catalog.Providers | Where-Object { $_.Current } | Select-Object -First 1
            $sel = @{
                provider_id = $(if ($cur) { [string]$cur.Id } else { '' })
                model       = $(if ($cur -and $cur.Model) { [string]$cur.Model } else { '' })
                tier        = $(if ($AppType -eq 'claude') { 'sonnet' } else { '' })
            }
            if (-not $catalog.ProxyManaged) {
                # No current provider to fall back on: seed from the "<providerId>/<model>" that
                # cc-connect is actually running, so the card opens on the live pairing.
                $configured = Get-CcsConfiguredModel $project
                if ($configured -match '^([^/]+)/(.+)$') {
                    $seedId = $Matches[1]; $seedModel = $Matches[2]
                    if ($catalog.Providers | Where-Object { $_.Id -eq $seedId }) {
                        $sel.provider_id = $seedId
                        $sel.model = $seedModel
                    }
                }
            }
            $card = New-ComboCard $catalog $sel
        }
        'pick' {
            if ($args2.Count -lt 2) { exit 0 }
            $kind = $args2[0].ToLower()
            $val = ($args2 | Select-Object -Skip 1) -join ' '
            $val = $val.Trim().Trim("`"'")
            if ($kind -notin @('p', 'm', 't', 'provider', 'model', 'tier')) { exit 0 }
            if ($kind -eq 'provider') { $kind = 'p' }
            if ($kind -eq 'model') { $kind = 'm' }
            if ($kind -eq 'tier') { $kind = 't' }
            if ($kind -ne 'p' -and -not (Test-SafeToken $val)) { exit 0 }

            $state = Get-CcsCardState $sessionKey
            if (-not $state -or -not $state.message_id) { Write-HookLog "pick: no card state"; exit 0 }
            $patchMessageId = $state.message_id
            $catalog = Get-CcsCatalog $AppType
            $sel = @{ provider_id = $state.provider_id; model = $state.model; tier = $state.tier }
            switch ($kind) {
                'p' {
                    $t = Resolve-CcsProvider $catalog.Providers $val
                    if (-not $t) { exit 0 }
                    if ($catalog.ProxyManaged -and -not $t.Selectable) { exit 0 }
                    $sel.provider_id = $t.Id
                    $sel.model = ''
                }
                'm' { if (-not $sel.provider_id) { exit 0 }; $sel.model = $val }
                't' { $sel.tier = $val }
            }
            # Persist before the slow render. The write button carries only this key and reads the
            # file at click time, so the earlier the pick lands the smaller the window in which a
            # fast click applies the previous selection instead of this one.
            Save-CcsCardState (Get-CcsCardStateKey $sessionKey) @{
                message_id  = $patchMessageId
                provider_id = $sel.provider_id
                model       = $sel.model
                tier        = $sel.tier
            }
            $card = New-ComboCard $catalog $sel
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
    [System.IO.File]::WriteAllText($paths.CardMarker, (Get-Date).ToString('o'))
    $markerTouched = $true
    if ($step -eq 'pick' -and $patchMessageId) {
        try {
            Update-FeishuCard $token $cred.Domain $patchMessageId $card
        } catch {
            Write-HookLog "PATCH failed, sending new card: $($_.Exception.Message)"
            $msgId = Send-FeishuMessage $token $cred.Domain $chatId 'interactive' ($card | ConvertTo-Json -Depth 12 -Compress)
            if ($msgId -and $sel) {
                Save-CcsCardState (Get-CcsCardStateKey $sessionKey) @{
                    message_id  = $msgId
                    provider_id = $sel.provider_id
                    model       = $sel.model
                    tier        = $sel.tier
                }
            }
        }
    } else {
        $msgId = Send-FeishuMessage $token $cred.Domain $chatId 'interactive' ($card | ConvertTo-Json -Depth 12 -Compress)
        if ($step -eq 'cascade' -and $msgId) {
            Save-CcsCardState (Get-CcsCardStateKey $sessionKey) @{
                message_id  = $msgId
                provider_id = $sel.provider_id
                model       = $sel.model
                tier        = $sel.tier
            }
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
