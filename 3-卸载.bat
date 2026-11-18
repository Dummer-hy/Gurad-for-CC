@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 卸载 Claude 保护
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0卸载.ps1"
