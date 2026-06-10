@echo off
setlocal enabledelayedexpansion

set REGISTRY=%1
if "%REGISTRY%"=="" set REGISTRY=localhost:5000
set TAG=%2
if "%TAG%"=="" set TAG=latest

set SERVICES=eureka-server auth-service grades-service notification-service api-gateway

echo === Building and pushing all Docker images ===
echo Registry: %REGISTRY%
echo Tag:      %TAG%
echo.

for %%s in (%SERVICES%) do (
  echo --- Building %%s ---
  docker build -f backend\%%s\Dockerfile -t %REGISTRY%/mytutorial/%%s:%TAG% .\backend
  echo --- Pushing %%s ---
  docker push %REGISTRY%/mytutorial/%%s:%TAG%
  echo.
)

echo === Done ===