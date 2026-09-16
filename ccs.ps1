# /ccs — switch CC Switch providers (and model mappings) from chat.
# Registered in cc-connect as a custom exec command; ccs-hook.ps1 adds the Feishu cards.
#
#   ccs.ps1 [list]                              providers
#   ccs.ps1 switch <target>                     switch provider (Pi: enable provider)
#   ccs.ps1 models <target>                     models the provider offers
#   ccs.ps1 map <target> <model> [<tier>]       claude: map tier(s) -> model; codex: set upstream model
#   ccs.ps1 status | help
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Action = 'list',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest = @(),
    [ValidatePattern('^[a-z\-]+$')][string]$AppType = 'claude',
    [switch]$NoCardHint
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'ccs-common.ps1')

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
/ccs                          列出供应商（飞书会收到可点击的卡片）
/ccs switch <序号|名称>        切换供应商
/ccs models <名称>             查看该供应商可用的模型
/ccs map <名称> <模型> [档位]   Claude: 把档位映射到该模型（档位: $TierUsage，默认 all）
                              Codex: 设置该供应商的上游模型
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

try {
    $rest = @($Rest | Where-Object { $_ -ne $null -and $_ -ne '' })
    switch -Regex ($Action.ToLower()) {
        '^(list|ls|pick|menu|card|)$' {
            if (Wait-CcsCardMarker) {
                Write-Output '👆 已发送选择卡片，点击即可切换（或 /ccs switch <序号|名称>）'
                break
            }
            $catalog = Get-CcsCatalog $AppType
            if ($catalog.Providers.Count -eq 0) { Write-Output "CC Switch 中没有 $AppType 供应商"; break }
            Write-Output (Format-CcsCatalog $catalog $AppType)
        }
        '^(switch|use|select|set|to)$' {
            $query = ($rest -join ' ').Trim()
            if (-not $query) { Write-Output '用法: /ccs switch <序号|名称>'; exit 1 }
            $catalog = Get-CcsCatalog $AppType
            $target = Resolve-OrFail $catalog $query
            if (-not $catalog.ProxyManaged) {
                [void](Select-CcsProvider $AppType $target.Id)
                Write-Output "✅ 已启用 $AppType 供应商 $($target.Name)。选模型: /model $($target.Id)/<模型>（共 $($target.Models.Count) 个）"
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
            $modeText = if (-not $catalog.ProxyManaged) { '直连配置（由 CC Switch 写入应用配置）' } elseif ($catalog.Mode -eq 'hot') { '热切换（控制接口在线）' } else { '冷切换（未检测到控制接口）' }
            $curText = if ($cur) { "$($cur.Name)" + $(if ($cur.Model) { " · $($cur.Model)" } else { '' }) } else { '未设置' }
            Write-Output "当前 $AppType 供应商: $curText"
            if ($catalog.ProxyManaged) { Write-Output "模式: $modeText · 代理: $(if ($catalog.ProxyRunning) { '运行中' } else { '未运行' })" }
            else { Write-Output "模式: $modeText" }
        }
        '^(help|-h|--help|\?)$' { Write-Output (Show-Help) }
        default { Write-Output "未知子命令 '$Action'"; Write-Output (Show-Help); exit 1 }
    }
} catch {
    Write-Output "❌ $($_.Exception.Message)"
    exit 1
}
