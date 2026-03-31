$ProjectRoot = "C:\Users\TimeCraker\Desktop\go-dot-game"
$DocsDir = Join-Path -Path $ProjectRoot -ChildPath "docs"
$WikiDir = Join-Path -Path $ProjectRoot -ChildPath ".wiki.git"
$WikiRepoUrl = "https://github.com/TimeCraker/asternova-godot.wiki.git"

if (-not (Test-Path -Path $DocsDir)) {
    New-Item -ItemType Directory -Path $DocsDir | Out-Null
    Write-Host "Success: Created output directory." -ForegroundColor Green
}

Write-Host "Starting Godot project document generation..." -ForegroundColor Cyan

# 1. 生成项目树
$TreeOutputPath = Join-Path -Path $DocsDir -ChildPath "project_tree.txt"
Write-Host "-> [1/3] Generating Project Tree (Filtered)..."
Push-Location -Path $ProjectRoot
cmd /c "tree /f /a | findstr /V /I `".godot \.git \.import addons`"" | Out-File -FilePath $TreeOutputPath -Encoding utf8
Pop-Location

# 2. 合并脚本代码 (修复了引发 ParserError 的引号问题)
$CodeOutputPath = Join-Path -Path $DocsDir -ChildPath "all_scripts_merged.txt"
Write-Host "-> [2/3] Merging GDScript and Logic files..."
Get-ChildItem -Path $ProjectRoot -Include *.gd,*.proto,*.cfg,*.glsl -Recurse | 
    Where-Object { $_.FullName -notmatch "\\\.godot\\" -and $_.FullName -notmatch "\\addons\\" } | 
    ForEach-Object {
        # 使用单引号包裹内部路径，避免解析冲突
        $RelativePath = $_.FullName.Replace($ProjectRoot, '')
        $header = "`r`n--- FILE: $RelativePath ---`r`n"
        
        $header | Out-File -FilePath $CodeOutputPath -Append -Encoding UTF8
        Get-Content $_.FullName -Encoding UTF8 | Out-File -FilePath $CodeOutputPath -Append -Encoding UTF8
    }

# 3. 同步并合并 Wiki
Write-Host "-> [3/3] Syncing and Merging Wiki notes..."
if (-not (Test-Path -Path $WikiDir)) {
    Write-Host "   Wiki directory not found. Cloning..." -ForegroundColor Yellow
    git clone $WikiRepoUrl $WikiDir
} else {
    Write-Host "   Wiki directory exists. Pulling latest..." -ForegroundColor Yellow
    Push-Location -Path $WikiDir
    git pull
    Pop-Location
}

$WikiOutputPath = Join-Path -Path $DocsDir -ChildPath "all_wiki_merged.txt"
if (Test-Path -Path $WikiDir) {
    # 清空旧文件
    $null > $WikiOutputPath
    Get-ChildItem -Path $WikiDir -Filter *.md -Recurse | 
        ForEach-Object {
            $header = "`r`n--- WIKI PAGE: $($_.Name) ---`r`n"
            $header | Out-File -FilePath $WikiOutputPath -Append -Encoding UTF8
            Get-Content $_.FullName -Encoding UTF8 | Out-File -FilePath $WikiOutputPath -Append -Encoding UTF8
        }
    Write-Host "   Wiki notes merged successfully." -ForegroundColor Green
}

Write-Host "DONE! Godot docs saved to $DocsDir" -ForegroundColor Green