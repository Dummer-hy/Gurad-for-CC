@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Claude 安全网络修复
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0修复-Claude安全网络.ps1"
