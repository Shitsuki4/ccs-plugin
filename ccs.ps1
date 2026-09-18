# /ccs — switch CC Switch providers (and model mappings) from chat.
# Registered in cc-connect as a custom exec command; ccs-hook.ps1 adds the Feishu cards.
#
#   ccs.ps1 [list]                              providers (Feishu: one card with 3 dropdowns)
#   ccs.ps1 pick p|m|t <value>                  card-side selection ack (hook PATCHes the card)
#   ccs.ps1 apply <target> <model> [<tier>]     switch + map in one shot
#   ccs.ps1 applycard <key>                     same, with target/model/tier read from the card state
#   ccs.ps1 switch <target>                     switch provider (direct-config apps: browse only)
#   ccs.ps1 models <target>                     models the provider offers
#   ccs.ps1 map <target> <model> [<tier>]       claude: map tier(s) -> model; codex: set upstream model
#   ccs.ps1 status | help
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Action = 'list',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @(),
    [ValidatePattern('^[a-z\-]+$')][string]$AppType = '',
    [switch]$NoCardHint
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'ccs-common.ps1')
if (-not $AppType) { $AppType = Resolve-CcsAppType }

$TierUsage = 'sonnet | sonnet[1m] | opus | opus[1m] | haiku | fable | fable[1m] | all | all[1m]'

function Wait-CcsCardMarker {
    # ccs-hook.ps1 runs concurrently and touches the marker right before it sends a card.
    if ($NoCardHint) { return $false }
    $marker = (Get-CcsPaths).CardMarker
    $deadline = (Get-Date).AddMilliseconds(3000)
    do {
        if (Test-Path $marker) {
            $age = (Get-Date) - (Get-Item $marker).LastWriteTime
            if ($age.TotalSeconds -lt 15) { return $true }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Show-Help {
    @"
/ccs                          一张卡同时选供应商 / 模型 / 别名，点写入生效
/ccs switch <序号|名称>        切换供应商
/ccs models <名称>             查看该供应商可用的模型
/ccs map <名称> <模型> [档位]   Claude: 把档位映射到该模型（档位: $TierUsage，默认 all）
                              Codex: 设置该供应商的上游模型
/ccs apply <名称> <模型> [档位] 切换供应商并写入映射
/ccs status                   当前供应商与模式
ccs-plugin v$script:CcsPluginVersion · 应用: $AppType
"@
}

function Resolve-OrFail($Catalog, [string]$Query) {
    $target = Resolve-CcsProvider $Catalog.Providers $Query
    if (-not $target) {
        Write-Output "没有找到供应商 '$Query'"
        Write-Output (Format-CcsCatalog $Catalog $AppType)
        exit 1
    }
    return $target
}

function Format-ModelList($Target, $Models) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("$($Target.Name) 的模型")
    if ($Models.Configured.Count -gt 0) { [void]$sb.AppendLine('已配置: ' + ($Models.Configured -join ', ')) }
    if ($Models.Upstream.Count -gt 0) {
        $shown = @($Models.Upstream | Select-Object -First 40)
        [void]$sb.AppendLine("上游可用 ($($Models.Upstream.Count)): " + ($shown -join ', ') + $(if ($Models.Upstream.Count -gt 40) { ' …' } else { '' }))
    } elseif ($Models.UpstreamError) {
        [void]$sb.AppendLine("（上游模型列表不可用: $($Models.UpstreamError)）")
    }
    switch ($AppType) {
        'claude' { [void]$sb.Append("用法: /ccs map $($Target.Name) <模型> <$TierUsage>") }
        'codex'  { [void]$sb.Append("用法: /ccs map $($Target.Name) <模型>") }
        default  { [void]$sb.Append("用法: /model $($Target.Id)/<模型>") }
    }
    return $sb.ToString()
}

# Shared by /ccs apply (explicit args) and /ccs applycard (args read from the card state file).
function Invoke-CcsApply($Catalog, $Target, [string]$Model, $TierSpec) {
    if (-not $Catalog.ProxyManaged) {
        Write-Output "ℹ️ $($Target.Name) 是直连配置应用（$AppType）：供应商由 CC Switch 写进应用自己的配置，聊天里切不了，也没有「当前供应商」这回事。"
        Write-Output "选模型请发: /model $($Target.Id)/$Model"
        return
    }
    if (-not $Target.Selectable) { Write-Output "🚫 $($Target.Name) 不支持代理接管，无法切换"; exit 1 }
    if (-not $Target.Current) { [void](Select-CcsProvider $AppType $Target.Id) }
    switch ($AppType) {
        'claude' {
            if (-not $TierSpec) { $TierSpec = ConvertTo-CcsTierSpec 'all' }
            $value = if ($TierSpec.OneM) { Add-CcsOneMSuffix $Model } else { $Model }
            Set-CcsProviderModel $AppType $Target.Id $value $TierSpec.Tiers
            $scope = if ($TierSpec.Alias) { $TierSpec.Alias } elseif ($TierSpec.Tiers.Count -gt 0) { $TierSpec.Tiers -join ',' } else { '全部档位' }
            Write-Output "✅ $($Target.Name): $scope → $value，下一次请求即生效"
            if ($TierSpec.Alias) { Write-Output "要用这个别名请发 /model $($TierSpec.Alias)" }
        }
        'codex' {
            Set-CcsProviderModel $AppType $Target.Id $Model
            Write-Output "✅ $($Target.Name) 的上游模型已设为 $Model，下一次请求即生效"
        }
        default {
            Write-Output "❌ 代理接管只支持 claude / codex，$AppType 请用 /model 命令"
            exit 1
        }
    }
}

try {
    $rest = @($Rest | Where-Object { $_ -ne $null -and $_ -ne '' })
    switch -Regex ($Action.ToLower()) {
        '^(list|ls|menu|card|cascade|)$' {
            if (Wait-CcsCardMarker) {
                Write-Output '👆 已发送选择卡片：三个下拉同时可选，点 ✍️ 写入才生效'
                break
            }
            $catalog = Get-CcsCatalog $AppType
            if ($catalog.Providers.Count -eq 0) { Write-Output "CC Switch 中没有 $AppType 供应商"; break }
            Write-Output (Format-CcsCatalog $catalog $AppType)
        }
        '^(pick)$' {
            # Hook PATCHes the same card; exec must print something or cc-connect says "(no output)"
            $kind = if ($rest.Count -ge 1) { $rest[0].ToLower() } else { '' }
            $val = if ($rest.Count -ge 2) { ($rest | Select-Object -Skip 1) -join ' ' } else { '' }
            switch ($kind) {
                { $_ -in @('p', 'provider') } { Write-Output "已选供应商 $val" }
                { $_ -in @('m', 'model') }    { Write-Output "已选模型 $val" }
                { $_ -in @('t', 'tier') }     { Write-Output "已选别名 $val" }
                default                       { Write-Output '已记录选择' }
            }
        }
        '^(apply)$' {
            if ($rest.Count -lt 2) { Write-Output "用法: /ccs apply <供应商> <模型> [档位]`n档位: $TierUsage"; exit 1 }
            $tierSpec = $null
            if ($rest.Count -ge 3) {
                $tierSpec = ConvertTo-CcsTierSpec $rest[-1]
                if (-not $tierSpec) { Write-Output "未知档位 '$($rest[-1])'，可选: $TierUsage"; exit 1 }
            }
            $modelIdx = if ($tierSpec) { $rest.Count - 2 } else { $rest.Count - 1 }
            $model = $rest[$modelIdx]
            $query = (($rest[0..($modelIdx - 1)]) -join ' ').Trim()
            $catalog = Get-CcsCatalog $AppType
            $target = Resolve-OrFail $catalog $query
            Invoke-CcsApply $catalog $target $model $tierSpec
        }
        '^(applycard)$' {
            # Fired by the card's ✍️ 写入 button. The button only carries the state key, so the
            # supplier/model/tier are read here — at click time — instead of being frozen into the
            # card when it was rendered.
            $key = if ($rest.Count -ge 1) { $rest[0].Trim().ToLower() } else { '' }
            if ($key -notmatch '^[0-9a-f]{16}$') { Write-Output '❌ 无效的卡片标识，请重新发 /ccs'; exit 1 }
            $state = Get-CcsCardStateByKey $key
            if (-not $state) { Write-Output '❌ 卡片选择已失效（卡片太旧或状态被清理），请重新发 /ccs'; exit 1 }
            if (-not $state.model) { Write-Output '❌ 卡片里还没有选模型，请重新发 /ccs'; exit 1 }
            $tierSpec = $null
            if ($state.tier) {
                $tierSpec = ConvertTo-CcsTierSpec $state.tier
                if (-not $tierSpec) { Write-Output "❌ 卡片里的档位 '$($state.tier)' 已失效，请重新发 /ccs"; exit 1 }
            }
            $catalog = Get-CcsCatalog $AppType
            $target = if ($state.provider_id) { Resolve-OrFail $catalog $state.provider_id } else { $catalog.Providers | Where-Object { $_.Current } | Select-Object -First 1 }
            if (-not $target) { Write-Output '❌ 卡片里没有供应商，请重新发 /ccs'; exit 1 }
            Invoke-CcsApply $catalog $target $state.model $tierSpec
        }
        '^(switch|use|select|set|to)$' {
            $query = ($rest -join ' ').Trim()
            if (-not $query) { Write-Output '用法: /ccs switch <序号|名称>'; exit 1 }
            $catalog = Get-CcsCatalog $AppType
            $target = Resolve-OrFail $catalog $query
            if (-not $catalog.ProxyManaged) {
                Write-Output "ℹ️ $($target.Name)：$AppType 的供应商由 CC Switch 直接写进应用自己的配置，没有「当前供应商」可切换，聊天里切它是空操作。"
                Write-Output "看模型: /ccs models $($target.Name)"
                break
            }
            if ($target.Current) { Write-Output "ℹ️ $($target.Name) 已经是当前 $AppType 供应商"; break }
            if (-not $target.Selectable) { Write-Output "🚫 $($target.Name) 不支持代理接管，无法切换"; exit 1 }
            $mode = Select-CcsProvider $AppType $target.Id
            $model = if ($target.Model) { "（$($target.Model)）" } else { '' }
            if ($mode -eq 'hot') { Write-Output "✅ 已切换 $AppType 供应商 → $($target.Name)$model，下一次请求即生效" }
            else { Write-Output "✅ 已切换 $AppType 供应商 → $($target.Name)$model，CC Switch 代理已重启（冷切换）" }
        }
        '^(models|model-list|catalog)$' {
            $query = ($rest -join ' ').Trim()
            if (-not $query) { Write-Output '用法: /ccs models <序号|名称>'; exit 1 }
            $catalog = Get-CcsCatalog $AppType
            $target = Resolve-OrFail $catalog $query
            $models = Get-CcsProviderModels $AppType $target.Id
            Write-Output (Format-ModelList $target $models)
        }
        '^(map|model)$' {
            if ($rest.Count -lt 2) { Write-Output "用法: /ccs map <供应商> <模型> [档位]`n档位: $TierUsage"; exit 1 }
            $tierSpec = $null
            if ($rest.Count -ge 3) {
                $tierSpec = ConvertTo-CcsTierSpec $rest[-1]
                if (-not $tierSpec) { Write-Output "未知档位 '$($rest[-1])'，可选: $TierUsage"; exit 1 }
            }
            $modelIdx = if ($tierSpec) { $rest.Count - 2 } else { $rest.Count - 1 }
            $model = $rest[$modelIdx]
            $query = (($rest[0..($modelIdx - 1)]) -join ' ').Trim()
            $catalog = Get-CcsCatalog $AppType
            $target = Resolve-OrFail $catalog $query

            switch ($AppType) {
                'claude' {
                    if (-not $tierSpec -and $Action.ToLower() -eq 'map') {
                        if (Wait-CcsCardMarker) { Write-Output "👆 请在卡片中选择 $model 映射到哪个别名"; break }
                        Write-Output "请指定档位: /ccs map $($target.Name) $model <$TierUsage>"
                        exit 1
                    }
                    if (-not $tierSpec) { $tierSpec = ConvertTo-CcsTierSpec 'all' }
                    $value = if ($tierSpec.OneM) { Add-CcsOneMSuffix $model } else { $model }
                    Set-CcsProviderModel $AppType $target.Id $value $tierSpec.Tiers
                    $scope = if ($tierSpec.Alias) { $tierSpec.Alias } elseif ($tierSpec.Tiers.Count -gt 0) { $tierSpec.Tiers -join ',' } else { '全部档位' }
                    $suffix = if ($target.Current) { '，下一次请求即生效' } else { "（$($target.Name) 不是当前供应商，切过去后生效）" }
                    Write-Output "✅ $($target.Name): $scope → $value$suffix"
                    if ($tierSpec.Alias) { Write-Output "会话模型仍是 cc-connect 当前设置；要用这个别名请发 /model $($tierSpec.Alias)" }
                }
                'codex' {
                    Set-CcsProviderModel $AppType $target.Id $model
                    $suffix = if ($target.Current) { '，下一次请求即生效' } else { "（$($target.Name) 不是当前供应商，切过去后生效）" }
                    Write-Output "✅ $($target.Name) 的上游模型已设为 $model$suffix"
                }
                default {
                    Write-Output "$AppType 的模型由 cc-connect 直接选择: /model $($target.Id)/$model"
                }
            }
        }
        '^(status|current|now)$' {
            $catalog = Get-CcsCatalog $AppType
            $cur = $catalog.Providers | Where-Object { $_.Current } | Select-Object -First 1
            if (-not $catalog.ProxyManaged) {
                Write-Output "$AppType 没有「当前供应商」：CC Switch 只负责增删，由应用自己选模型"
                $configured = Get-CcsConfiguredModel ([string]$env:CC_HOOK_PROJECT)
                if ($configured) { Write-Output "cc-connect 正在用: $configured" }
                Write-Output "模式: 直连配置（CC Switch 写入应用自己的配置）"
                break
            }
            $modeText = if ($catalog.Mode -eq 'hot') { '热切换（控制接口在线）' } else { '冷切换（未检测到控制接口）' }
            $curText = if ($cur) { "$($cur.Name)" + $(if ($cur.Model) { " · $($cur.Model)" } else { '' }) } else { '未设置' }
            Write-Output "当前 $AppType 供应商: $curText"
            Write-Output "模式: $modeText · 代理: $(if ($catalog.ProxyRunning) { '运行中' } else { '未运行' })"
        }
        '^(help|-h|--help|\?)$' { Write-Output (Show-Help) }
        default { Write-Output "未知子命令 '$Action'"; Write-Output (Show-Help); exit 1 }
    }
} catch {
    Write-Output "❌ $($_.Exception.Message)"
    exit 1
}
