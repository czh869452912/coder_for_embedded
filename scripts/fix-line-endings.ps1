# ============================================================
# fix-line-endings.ps1
# 在 Windows 上将项目脚本和配置文件的行尾从 CRLF 转换为 LF，
# 避免导入 Linux 服务器后因行尾格式导致脚本无法执行。
#
# 用法：
#   cd <项目根目录>
#   powershell -ExecutionPolicy Bypass -File scripts\fix-line-endings.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\fix-line-endings.ps1 -DryRun
# ============================================================

param(
    [switch]$DryRun   # 仅打印将被修改的文件，不实际写入
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 需要处理的文件类型
$extensions = @('*.sh', '*.yml', '*.yaml', '*.conf', '*.env', '*.py', '*.rc')

# 脚本自身所在目录的上一级（项目根目录）
$root = Split-Path -Parent $PSScriptRoot

Write-Host "项目根目录: $root"
if ($DryRun) { Write-Host "[DryRun] 只检查，不写入文件" -ForegroundColor Yellow }
Write-Host ""

$totalFixed  = 0
$totalSkipped = 0

foreach ($ext in $extensions) {
    $files = Get-ChildItem -Path $root -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        # 读取原始字节，检测是否含有 CRLF 或 UTF-8 BOM (EF BB BF)
        $bytes = [System.IO.File]::ReadAllBytes($file.FullName)

        $hasCRLF = $false
        for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
            if ($bytes[$i] -eq 0x0D -and $bytes[$i+1] -eq 0x0A) {
                $hasCRLF = $true
                break
            }
        }

        $hasBOM = ($bytes.Length -ge 3 -and
                   $bytes[0] -eq 0xEF -and
                   $bytes[1] -eq 0xBB -and
                   $bytes[2] -eq 0xBF)

        if (-not $hasCRLF -and -not $hasBOM) {
            $totalSkipped++
            continue
        }

        $issues = @()
        if ($hasCRLF) { $issues += 'CRLF' }
        if ($hasBOM)  { $issues += 'BOM'  }
        $issueStr = $issues -join '+'

        $relPath = $file.FullName.Substring($root.Length + 1)
        if ($DryRun) {
            Write-Host "[检测到 $issueStr] $relPath" -ForegroundColor Cyan
        } else {
            $newBytes = [System.Collections.Generic.List[byte]]::new($bytes.Length)
            $start = 0
            # 跳过 UTF-8 BOM
            if ($hasBOM) { $start = 3 }

            for ($i = $start; $i -lt $bytes.Length; $i++) {
                # 跳过 CR（0x0D），仅保留 LF（0x0A）
                if ($bytes[$i] -eq 0x0D -and ($i + 1 -lt $bytes.Length) -and $bytes[$i+1] -eq 0x0A) {
                    continue
                }
                $newBytes.Add($bytes[$i])
            }
            [System.IO.File]::WriteAllBytes($file.FullName, $newBytes.ToArray())
            Write-Host "[已修复 $issueStr] $relPath" -ForegroundColor Green
        }
        $totalFixed++
    }
}

Write-Host ""
if ($DryRun) {
    Write-Host "检测完成：$totalFixed 个文件含 CRLF/BOM，$totalSkipped 个文件无需处理。" -ForegroundColor Yellow
} else {
    Write-Host "完成：已修复 $totalFixed 个文件，跳过 $totalSkipped 个文件（无需处理）。" -ForegroundColor Green
}
