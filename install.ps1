<#
.SYNOPSIS
  Install, update or remove ccs-plugin (chat-side CC Switch provider switching for cc-connect).

.DESCRIPTION
  Copies the plugin scripts, wires a "/ccs" custom command plus a "message.received" hook into
  ~/.cc-connect/config.toml for every Feishu project, and (optionally) installs the patched
  CC Switch build that exposes the loopback control API. Only official cc-connect features are used.

.EXAMPLE
  irm https://raw.githubusercontent.com/Shitsuki4/ccs-plugin/main/install.ps1 | iex
.EXAMPLE
  .\install.ps1 -InstallCcSwitch            # also fetch the patched CC Switch (hot switching)
.EXAMPLE
  .\install.ps1 -Source . -Project my-project
.EXAMPLE
  .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Repo = 'Shitsuki4/ccs-plugin',
    [string]$Ref = 'main',
    [string]$Source = '',
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.cc-connect\plugins\ccs'),
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.cc-connect\config.toml'),
    [string[]]$Project = @(),
    [switch]$InstallCcSwitch,
    [switch]$InstallOfficialCcConnect,
    [switch]$NoConfig,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PluginFiles = @('ccs.ps1', 'ccs-common.ps1', 'ccs-hook.ps1', 'install.ps1')
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Ok([string]$Text) { Write-Host "    ✓ $Text" -ForegroundColor Green }
function Note([string]$Text) { Write-Host "    · $Text" -ForegroundColor DarkGray }
function Warn([string]$Text) { Write-Host "    ! $Text" -ForegroundColor Yellow }

function Get-ShellExe {
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { return 'pwsh' }
    return 'powershell'
}

function ConvertTo-TomlString([string]$Value) {
    '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
}

function Read-ConfigLines([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }
    $newline = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    [pscustomobject]@{ Lines = [System.Collections.ArrayList]@($text -split "`r?`n"); Newline = $newline; Bom = $hasBom }
}

function Write-ConfigLines([string]$Path, $Doc) {
    $text = ($Doc.Lines -join $Doc.Newline)
    $enc = if ($Doc.Bom) { New-Object System.Text.UTF8Encoding $true } else { $Utf8NoBom }
    [System.IO.File]::WriteAllText($Path, $text, $enc)
}

function Get-AppTypeForAgent([string]$AgentType) {
    switch ($AgentType) {
        'claudecode' { 'claude' }
        'codex'      { 'codex' }
        'gemini'     { 'gemini' }
        'pi'         { 'pi' }
        'opencode'   { 'opencode' }
        default      { '' }
    }
}

$AllCcSwitchApps = @('claude', 'codex', 'gemini', 'grokbuild', 'opencode', 'openclaw', 'hermes', 'pi', 'claude-desktop')

# ---------------------------------------------------------------- files
function Install-PluginFiles {
    Step "安装插件文件到 $InstallDir"
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    foreach ($f in $PluginFiles) {
        $dest = Join-Path $InstallDir $f
        if ($Source) {
            $src = Join-Path (Resolve-Path $Source) $f
            if ((Resolve-Path $src).Path -ne [System.IO.Path]::GetFullPath($dest)) { Copy-Item $src $dest -Force }
        } else {
            $url = "https://raw.githubusercontent.com/$Repo/$Ref/$f"
            Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        }
        Ok $f
    }
}

# ---------------------------------------------------------------- control-api.json
function Ensure-ControlApiConfig {
    $path = (Get-CcsPaths).ControlConfig
    Step "检查 $path"
    if (Test-Path $path) {
        $cfg = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $cfg.enabled) { Warn 'control-api.json 存在但 enabled=false，热切换不会启用'; return }
        $missing = @($AllCcSwitchApps | Where-Object { $cfg.allowed_apps -notcontains $_ })
        if ($missing.Count -gt 0) {
            $cfg.allowed_apps = @($cfg.allowed_apps) + $missing
            [System.IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json), $Utf8NoBom)
            Ok "已存在（端口 $($cfg.port)），allowed_apps 补充: $($missing -join ', ')。CC Switch 重启后生效"
        } else { Ok "已存在（端口 $($cfg.port)）" }
        return
    }
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $token = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
    $cfg = [ordered]@{ enabled = $true; port = 15722; token = $token; allowed_apps = $AllCcSwitchApps }
    New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
    [System.IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json), $Utf8NoBom)
    try {
        & icacls $path /inheritance:r /grant:r "*S-1-5-18:(F)" "$($env:USERDOMAIN)\$($env:USERNAME):(F)" | Out-Null
    } catch { Warn "无法收紧文件权限: $($_.Exception.Message)" }
    Ok '已生成（随机令牌，端口 15722）。CC Switch 重启后生效'
}

# ---------------------------------------------------------------- config.toml
# Official cc-connect only wires top-level [[commands]] / [[hooks]]. Per-project
# [[projects.commands]] is ignored (that's why /ccs became "Unknown command"
# after swapping off the fork). App type is inferred at runtime from
# CC_HOOK_PROJECT or the exec cwd.
function New-CommandBlock {
    $shell = Get-ShellExe
    $exec = "$shell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'ccs.ps1')`" {{args}}"
    @(
        '[[commands]]',
        '  name = "ccs"',
        '  description = "切换 CC Switch 供应商 (ccs-plugin)"',
        "  exec = $(ConvertTo-TomlString $exec)"
    )
}

function New-HookBlock {
    $shell = Get-ShellExe
    $cmd = "$shell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDir 'ccs-hook.ps1')`""
    @(
        '[[hooks]]',
        '  event = "message.received"',
        '  type = "command"',
        "  command = $(ConvertTo-TomlString $cmd)",
        '  timeout = 30'
    )
}

function Select-TargetProjects($Projects) {
    $targets = @()
    foreach ($p in $Projects) {
        if ($Project.Count -gt 0 -and ($Project -notcontains $p.Name)) { continue }
        $app = Get-AppTypeForAgent $p.AgentType
        if (-not $p.Feishu) { Note "跳过 $($p.Name)：没有飞书平台"; continue }
        if (-not $app) { Note "跳过 $($p.Name)：agent 类型 '$($p.AgentType)' 不对应 CC Switch 应用"; continue }
        $targets += [pscustomobject]@{ Project = $p; AppType = $app }
    }
    if ($Project.Count -gt 0) {
        foreach ($name in $Project) { if (-not ($Projects | Where-Object { $_.Name -eq $name })) { Warn "config.toml 中没有项目 '$name'" } }
    }
    return $targets
}

function Get-CcsPluginRanges([string]$Path) {
    $ranges = New-Object System.Collections.ArrayList
    foreach ($p in Get-CcsConnectProjects $Path) {
        foreach ($c in $p.Commands) { if ($c.Name -eq 'ccs' -and $c.Exec -like '*ccs.ps1*') { [void]$ranges.Add(@{ Start = $c.StartLine; End = $c.EndLine }) } }
        foreach ($h in $p.Hooks) { if ($h.Command -like '*ccs-hook.ps1*') { [void]$ranges.Add(@{ Start = $h.StartLine; End = $h.EndLine }) } }
    }
    $g = Get-CcsGlobalTables $Path
    foreach ($c in $g.Commands) { if ($c.Name -eq 'ccs' -and $c.Exec -like '*ccs.ps1*') { [void]$ranges.Add(@{ Start = $c.StartLine; End = $c.EndLine }) } }
    foreach ($h in $g.Hooks) { if ($h.Command -like '*ccs-hook.ps1*') { [void]$ranges.Add(@{ Start = $h.StartLine; End = $h.EndLine }) } }
    return @($ranges)
}

function Remove-ConfigRanges($Doc, $Ranges) {
    foreach ($r in ($Ranges | Sort-Object { $_.Start } -Descending)) {
        $start = $r.Start
        if ($start -gt 0 -and [string]::IsNullOrWhiteSpace($Doc.Lines[$start - 1])) { $start-- }
        $count = $r.End - $start + 1
        if ($count -gt 0) { $Doc.Lines.RemoveRange($start, $count) }
    }
}

function Ensure-ProjectAdminFrom($Doc, $Project) {
    if ($Project.AdminFrom) { return }
    $allow = $null
    if ($Project.Feishu -and $Project.Feishu.Options.Contains('allow_from')) { $allow = [string]$Project.Feishu.Options['allow_from'] }
    if (-not $allow) {
        Warn "$($Project.Name) 没有 admin_from：官方版把 /ccs exec 当特权命令，未设管理员会拒绝执行。请在该 [[projects]] 下加 admin_from = `"你的飞书 open_id`""
        return
    }
    for ($i = $Project.StartLine; $i -le $Project.EndLine; $i++) {
        if ($Doc.Lines[$i] -match '^(\s*)name\s*=') {
            $indent = $Matches[1]
            $Doc.Lines.Insert($i + 1, ('{0}admin_from = {1}' -f $indent, (ConvertTo-TomlString $allow)))
            Ok "$($Project.Name) 已写入 admin_from（从 allow_from 复制，/ccs exec 需要管理员）"
            return
        }
    }
}

function Update-ConnectConfig {
    Step "写入 cc-connect 配置 $ConfigPath"
    if (-not (Test-Path $ConfigPath)) { throw "找不到 $ConfigPath" }
    $backup = "$ConfigPath.ccs-bak-$(Get-Date -Format yyyyMMddHHmmss)"
    Copy-Item $ConfigPath $backup -Force
    Note "备份: $backup"

    $projects = Get-CcsConnectProjects $ConfigPath
    $targets = Select-TargetProjects $projects
    if ($targets.Count -eq 0) { Warn '没有可配置的项目'; return }

    $doc = Read-ConfigLines $ConfigPath
    foreach ($t in ($targets | Sort-Object { $_.Project.StartLine } -Descending)) { Ensure-ProjectAdminFrom $doc $t.Project }
    Write-ConfigLines $ConfigPath $doc

    $doc = Read-ConfigLines $ConfigPath
    Remove-ConfigRanges $doc (Get-CcsPluginRanges $ConfigPath)
    $tail = New-Object System.Collections.ArrayList
    if ($doc.Lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($doc.Lines[$doc.Lines.Count - 1])) { [void]$tail.Add('') }
    [void]$tail.Add('')
    foreach ($line in (New-CommandBlock)) { [void]$tail.Add($line) }
    [void]$tail.Add('')
    foreach ($line in (New-HookBlock)) { [void]$tail.Add($line) }
    $doc.Lines.AddRange([string[]]@($tail))
    Write-ConfigLines $ConfigPath $doc

    $g = Get-CcsGlobalTables $ConfigPath
    $cmdOk = $g.Commands | Where-Object { $_.Name -eq 'ccs' -and $_.Exec -like '*ccs.ps1*' } | Select-Object -First 1
    $hookOk = $g.Hooks | Where-Object { $_.Command -like '*ccs-hook.ps1*' } | Select-Object -First 1
    if (-not $cmdOk -or -not $hookOk) { throw "写入后校验失败（全局 [[commands]]/[[hooks]]），已保留备份 $backup" }
    $leftover = @()
    foreach ($p in Get-CcsConnectProjects $ConfigPath) {
        foreach ($c in $p.Commands) { if ($c.Name -eq 'ccs') { $leftover += $p.Name } }
    }
    if ($leftover.Count -gt 0) { Warn "仍有项目级 [[projects.commands]] ccs（官方版会忽略）: $($leftover -join ', ')" }
    Ok "已写入全局 /ccs 命令和 message.received 钩子（覆盖 $($targets.Count) 个飞书项目）"
}

function Remove-ConnectConfig {
    Step "从 $ConfigPath 移除 ccs-plugin 配置"
    if (-not (Test-Path $ConfigPath)) { Warn '配置文件不存在'; return }
    $backup = "$ConfigPath.ccs-bak-$(Get-Date -Format yyyyMMddHHmmss)"
    Copy-Item $ConfigPath $backup -Force
    $doc = Read-ConfigLines $ConfigPath
    $ranges = @(Get-CcsPluginRanges $ConfigPath)
    Remove-ConfigRanges $doc $ranges
    Write-ConfigLines $ConfigPath $doc
    Ok "已移除 $($ranges.Count) 个配置块（备份 $backup）"
}

# ---------------------------------------------------------------- CC Switch
function Install-PatchedCcSwitch {
    Step '安装带控制接口的 CC Switch'
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases" -Headers @{ 'User-Agent' = 'ccs-plugin' }
    $rel = $releases | Where-Object { $_.tag_name -like 'cc-switch-*' } | Select-Object -First 1
    if (-not $rel) { throw "仓库 $Repo 还没有 cc-switch-* Release，请先在 GitHub Actions 运行 build-cc-switch" }
    $asset = $rel.assets | Where-Object { $_.name -eq 'cc-switch-windows-x64.exe' } | Select-Object -First 1
    $sums = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
    if (-not $asset) { throw "Release $($rel.tag_name) 缺少 cc-switch-windows-x64.exe" }
    Note "版本: $($rel.tag_name)"

    $tmp = Join-Path $env:TEMP "ccs-plugin-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $exeTmp = Join-Path $tmp 'cc-switch.exe'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $exeTmp -UseBasicParsing
    if ($sums) {
        $expected = ((Invoke-WebRequest -Uri $sums.browser_download_url -UseBasicParsing).Content -split '\s+')[0].ToLower()
        $actual = (Get-FileHash $exeTmp -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) { throw "SHA256 校验失败: 期望 $expected 实际 $actual" }
        Ok 'SHA256 校验通过'
    }

    $proc = Get-Process -Name 'cc-switch' -ErrorAction SilentlyContinue | Select-Object -First 1
    $target = if ($proc) { $proc.Path } else { Join-Path $env:LOCALAPPDATA 'Programs\CC Switch\cc-switch.exe' }
    if (-not (Test-Path $target)) { throw "找不到已安装的 CC Switch: $target（请先安装官方版）" }
    if ($proc) {
        Warn '正在关闭 CC Switch（经过本地代理的请求会中断几秒）'
        Stop-Process -Id $proc.Id -Force
        if (-not $proc.WaitForExit(15000)) { throw '无法结束 cc-switch.exe' }
        Start-Sleep -Milliseconds 800
    }
    Copy-Item $target "$target.ccs-bak-$(Get-Date -Format yyyyMMddHHmmss)" -Force
    Copy-Item $exeTmp $target -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $target -WorkingDirectory (Split-Path $target) | Out-Null
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if (Test-CcsPort 15722) { Ok '控制接口 127.0.0.1:15722 已就绪'; return }
        Start-Sleep -Milliseconds 500
    }
    Warn '已替换并启动 CC Switch，但 40 秒内控制接口未就绪；请检查 ~/.cc-switch/logs/cc-switch.log'
}

# ---------------------------------------------------------------- cc-connect
function Get-CcConnectExePath {
    # Never use Get-Command: PATH often hits an npm/corepack shim (cc-connect.ps1 / .cmd)
    # ahead of the real binary. Overwriting the shim turns it into a 50MB MZ that pwsh
    # then tries to parse as a script, and the running ~/.cc-connect/cc-connect.exe is left
    # untouched. Prefer the live process path, else the well-known install location.
    $homeExe = Join-Path $env:USERPROFILE '.cc-connect\cc-connect.exe'
    $proc = Get-Process -Name 'cc-connect' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
    if ($proc) { return $proc.Path }
    return $homeExe
}

function Wait-CcConnectGone([int]$Seconds = 15) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name 'cc-connect' -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return -not [bool](Get-Process -Name 'cc-connect' -ErrorAction SilentlyContinue)
}

function Get-CcConnectDaemonParent {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -match '^(powershell|pwsh)\.exe$') -and
            $_.CommandLine -and
            ($_.CommandLine -like '*cc-connect-daemon.ps1*')
        } |
        Select-Object -First 1
}

function Install-OfficialCcConnect {
    Step '替换为官方 cc-connect'
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/chenhg5/cc-connect/releases/latest' -Headers @{ 'User-Agent' = 'ccs-plugin' }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $asset = $rel.assets | Where-Object { $_.name -like "*windows-$arch*.zip" } | Select-Object -First 1
    if (-not $asset) { throw "官方 Release $($rel.tag_name) 没有 windows-$arch 资产" }
    Note "版本: $($rel.tag_name)"

    $target = Get-CcConnectExePath
    if (-not $target.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝覆盖非 exe 路径（多半是 npm shim）: $target"
    }
    if (-not (Test-Path $target)) { throw "找不到 cc-connect.exe（$target）" }
    Note "目标: $target"

    $tmp = Join-Path $env:TEMP "ccs-plugin-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $zip = Join-Path $tmp 'cc-connect.zip'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $tmp -Force
    $newExe = Get-ChildItem $tmp -Recurse -Filter 'cc-connect*.exe' | Select-Object -First 1
    if (-not $newExe) { throw '压缩包中没有 cc-connect.exe' }

    $daemon = Get-CcConnectDaemonParent
    Warn '正在停止 cc-connect（所有聊天会话会断开，稍后自动恢复）'
    # Do not call `daemon stop`/`daemon start`: official `daemon install` would rewrite
    # the scheduled task and drop the custom daemon.ps1 PATH snapshot. Kill only the
    # child exe and let daemon.ps1's while-loop relaunch the new binary.
    Get-Process -Name 'cc-connect' -ErrorAction SilentlyContinue | Stop-Process -Force
    if (-not (Wait-CcConnectGone 20)) { throw '无法结束 cc-connect.exe' }

    Copy-Item $target "$target.ccs-bak-$(Get-Date -Format yyyyMMddHHmmss)" -Force
    Copy-Item $newExe.FullName $target -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    if ($daemon) {
        $wait = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $wait -and -not (Get-Process -Name 'cc-connect' -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 400
        }
        if (Get-Process -Name 'cc-connect' -ErrorAction SilentlyContinue) { Ok '已替换，守护脚本已拉起新进程' }
        else { Warn '守护脚本尚未拉起；若 10 秒后仍没有进程，请手动 schtasks /run /tn cc-connect' }
    } elseif (Get-ScheduledTask -TaskName 'cc-connect' -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName 'cc-connect'
        Ok '已通过计划任务重新启动'
    } else {
        Start-Process -FilePath $target -WorkingDirectory (Split-Path $target) -WindowStyle Hidden | Out-Null
        Ok '已重新启动 cc-connect 进程'
    }

    $ver = (& $target --version 2>&1 | Out-String).Trim()
    if ($ver -match 'ccs-picker') { throw "替换后仍是 fork 版本:`n$ver" }
    Note $ver
}

# ---------------------------------------------------------------- main
try {
    if ($Uninstall) {
        if (Test-Path (Join-Path $InstallDir 'ccs-common.ps1')) { . (Join-Path $InstallDir 'ccs-common.ps1') }
        elseif ($Source) { . (Join-Path $Source 'ccs-common.ps1') }
        else { throw "找不到 $InstallDir\ccs-common.ps1，无法解析配置；可加 -Source <仓库目录>" }
        Remove-ConnectConfig
        if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Ok "已删除 $InstallDir" }
        Note 'control-api.json 与 CC Switch 二进制未改动；如需恢复官方 CC Switch，用安装目录里的 *.ccs-bak-* 备份覆盖回去'
        Write-Host "`n完成。重启 cc-connect 后生效。" -ForegroundColor Green
        return
    }

    Install-PluginFiles
    # Dot-source at script scope so the helpers are visible to every function below.
    . (Join-Path $InstallDir 'ccs-common.ps1')
    Note "ccs-plugin v$script:CcsPluginVersion"
    Ensure-ControlApiConfig
    if (-not $NoConfig) { Update-ConnectConfig }
    if ($InstallCcSwitch) { Install-PatchedCcSwitch }
    if ($InstallOfficialCcConnect) { Install-OfficialCcConnect }

    Write-Host ''
    Write-Host '完成。接下来：' -ForegroundColor Green
    if (-not $InstallOfficialCcConnect) { Write-Host '  1. 重启 cc-connect 使配置生效：cc-connect daemon restart（或重启进程）' }
    if (-not (Test-CcsPort 15722)) { Write-Host '  2. 热切换需要带控制接口的 CC Switch：重新运行 install.ps1 -InstallCcSwitch；否则 /ccs 以冷切换（重启代理）方式工作' }
    Write-Host '  3. 在飞书里发送 /ccs 试试'
} catch {
    Write-Host "`n❌ $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
