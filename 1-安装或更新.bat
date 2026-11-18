@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 安装 Claude 保护
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0安装.ps1"
