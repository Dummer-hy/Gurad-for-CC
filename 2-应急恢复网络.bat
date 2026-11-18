@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 应急恢复网络
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Rescue-恢复网络.ps1"
