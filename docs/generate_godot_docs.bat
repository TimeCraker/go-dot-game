@echo off
chcp 65001 >nul
title AsterNova Godot Project Doc Generator
echo 正在启动 Godot 游戏项目文档生成脚本...
echo --------------------------------------------------
echo 项目名称: AsterNova (Godot)
echo 目标目录: %~dp0
echo --------------------------------------------------
echo.

:: 以绕过执行策略的方式运行同目录下的 ps1 脚本
:: 确保你的 ps1 脚本命名为 generate_godot_docs.ps1 并放在同一个文件夹下
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate_godot_docs.ps1"

echo.
echo 任务处理完成！
echo.
pause