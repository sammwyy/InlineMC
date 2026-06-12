@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem Minimal local-first Minecraft launcher.

set API=http://localhost:3000/v1/plan.txt

set "MC_HOME=%APPDATA%\.minecraft"
set "CACHE_DIR=%MC_HOME%\cache"
set "PLAN_DIR=%CACHE_DIR%\inlineversions"
set "LAST_USERNAME_FILE=%CACHE_DIR%\last_username"
set "LAST_VERSION_FILE=%CACHE_DIR%\last_version"

set OS=windows
set ARCH=x64

set UUID=00000000-0000-0000-0000-000000000000
set ACCESS_TOKEN=0
set USER_TYPE=legacy

if not exist "%MC_HOME%" mkdir "%MC_HOME%"
if not exist "%CACHE_DIR%" mkdir "%CACHE_DIR%"
if not exist "%PLAN_DIR%" mkdir "%PLAN_DIR%"

set "LAST_USERNAME="
set "LAST_VERSION="

if exist "%LAST_USERNAME_FILE%" set /p "LAST_USERNAME="<"%LAST_USERNAME_FILE%"
if exist "%LAST_VERSION_FILE%" set /p "LAST_VERSION="<"%LAST_VERSION_FILE%"

echo ====================
echo       InlineMC
echo ====================

call :prompt_player_name
call :prompt_version

> "%LAST_USERNAME_FILE%" echo %PLAYER_NAME%
> "%LAST_VERSION_FILE%" echo %REQUESTED_VERSION%

set "VERSION=%REQUESTED_VERSION%"
set "PLAN_FILE=%PLAN_DIR%\%REQUESTED_VERSION%_response.txt"

if not exist "%PLAN_FILE%" (
    echo Downloading launch plan...
    curl -L -o "%PLAN_FILE%" "%API%?version=%REQUESTED_VERSION%&os=%OS%&arch=%ARCH%"
)

set MAIN_CLASS=
set ASSET_INDEX_ID=
set VERSION_TYPE=release
set CLASSPATH=
set JVM_ARGS=
set GAME_ARGS=
set NATIVES_DIR=%MC_HOME%\versions\%VERSION%\natives
set SKIP_NEXT_GAME_ARG=

for /f "usebackq tokens=1-6 delims=|" %%A in ("%PLAN_FILE%") do (
    set KIND=%%A
    set P1=%%B
    set P2=%%C
    set P3=%%D
    set P4=%%E
    set P5=%%F

    if "!KIND!"=="VERSION" (
        set VERSION=!P1!
        set NATIVES_DIR=%MC_HOME%\versions\!VERSION!\natives
    )
    if "!KIND!"=="VERSION_TYPE" set VERSION_TYPE=!P1!
    if "!KIND!"=="MAIN_CLASS" set MAIN_CLASS=!P1!
    if "!KIND!"=="ASSET_INDEX_ID" set ASSET_INDEX_ID=!P1!

    if "!KIND!"=="CLIENT" (
        call :download "!P1!" "!P2!" "!P3!"
    )

    if "!KIND!"=="LIBRARY" (
        call :download "!P1!" "!P2!" "!P3!"
    )

    if "!KIND!"=="NATIVE" (
        call :download "!P1!" "!P2!" "!P3!"
        call :extract_native "!P1!" "!P5!"
    )

    if "!KIND!"=="ASSET_INDEX" (
        call :download "!P1!" "!P2!" "!P3!"
    )

    if "!KIND!"=="ASSET" (
        call :download "!P1!" "!P2!" "!P3!"
    )

    if "!KIND!"=="CLASSPATH" (
        if defined CLASSPATH (
            set CLASSPATH=!CLASSPATH!;%MC_HOME%\!P1!
        ) else (
            set CLASSPATH=%MC_HOME%\!P1!
        )
    )

    if "!KIND!"=="JVM_ARG" (
        call :append_jvm_arg "!P1!"
    )

    if "!KIND!"=="GAME_ARG" (
        call :append_game_arg "!P1!"
    )
)

if not defined MAIN_CLASS (
    echo Missing MAIN_CLASS.
    exit /b 1
)

if not defined ASSET_INDEX_ID (
    echo Missing ASSET_INDEX_ID.
    exit /b 1
)

set GAME_ARGS=%GAME_ARGS:${auth_player_name}=%PLAYER_NAME%%
set GAME_ARGS=%GAME_ARGS:${version_name}=%VERSION%%
set GAME_ARGS=%GAME_ARGS:${game_directory}=%MC_HOME%%
set GAME_ARGS=%GAME_ARGS:${assets_root}=%MC_HOME%\assets%
set GAME_ARGS=%GAME_ARGS:${assets_index_name}=%ASSET_INDEX_ID%%
set GAME_ARGS=%GAME_ARGS:${auth_uuid}=%UUID%%
set GAME_ARGS=%GAME_ARGS:${auth_access_token}=%ACCESS_TOKEN%%
set GAME_ARGS=%GAME_ARGS:${user_type}=%USER_TYPE%%
set GAME_ARGS=%GAME_ARGS:${version_type}=%VERSION_TYPE%%

echo Launching Minecraft %VERSION%...
java %JVM_ARGS% -cp "%CLASSPATH%" %MAIN_CLASS% %GAME_ARGS%

exit /b

:prompt_player_name
set "INPUT_PLAYER_NAME="

if defined LAST_USERNAME (
    set /p "INPUT_PLAYER_NAME=username [%LAST_USERNAME%]: "
) else (
    set /p "INPUT_PLAYER_NAME=username: "
)

if not defined INPUT_PLAYER_NAME if defined LAST_USERNAME set "INPUT_PLAYER_NAME=%LAST_USERNAME%"

if not defined INPUT_PLAYER_NAME (
    echo username is required.
    goto :prompt_player_name
)

set "PLAYER_NAME=%INPUT_PLAYER_NAME%"
exit /b 0

:prompt_version
set "INPUT_VERSION="

if defined LAST_VERSION (
    set /p "INPUT_VERSION=version [%LAST_VERSION%]: "
) else (
    set /p "INPUT_VERSION=version [1.21.1]: "
)

if not defined INPUT_VERSION (
    if defined LAST_VERSION (
        set "INPUT_VERSION=%LAST_VERSION%"
    ) else (
        set "INPUT_VERSION=1.21.1"
    )
)

set "REQUESTED_VERSION=%INPUT_VERSION%"
exit /b 0

:download
set REL_PATH=%~1
set SHA1=%~2
set URL=%~3
set OUT=%MC_HOME%\%REL_PATH%

if exist "%OUT%" (
    call :verify "%OUT%" "%SHA1%"
    if "!ERRORLEVEL!"=="0" exit /b 0
    echo Hash mismatch, redownloading: %REL_PATH%
    del "%OUT%" >nul 2>nul
)

for %%F in ("%OUT%") do (
    if not exist "%%~dpF" mkdir "%%~dpF"
)

echo Downloading %REL_PATH%
curl -L -o "%OUT%" "%URL%"

call :verify "%OUT%" "%SHA1%"
if not "!ERRORLEVEL!"=="0" (
    echo Failed SHA1 verification: %REL_PATH%
    exit /b 1
)

exit /b 0

:verify
set FILE=%~1
set EXPECTED=%~2

if "%EXPECTED%"=="" exit /b 0

for /f "tokens=1" %%H in ('certutil -hashfile "%FILE%" SHA1 ^| findstr /r "^[0-9a-fA-F][0-9a-fA-F]*$"') do (
    set ACTUAL=%%H
)

if /I "%ACTUAL%"=="%EXPECTED%" exit /b 0
exit /b 1

:extract_native
set REL_PATH=%~1
set EXTRACT_REL=%~2
set SRC=%MC_HOME%\%REL_PATH%
set DST=%MC_HOME%\%EXTRACT_REL%

if not exist "%DST%" mkdir "%DST%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Expand-Archive -Force -LiteralPath '%SRC%' -DestinationPath '%DST%'"

exit /b 0

:append_jvm_arg
set ARG=%~1
set ARG=%ARG:${natives_directory}=%NATIVES_DIR%%
set ARG=%ARG:${launcher_name}=inlinemc%
set ARG=%ARG:${launcher_version}=0.1%
set ARG=%ARG:${classpath}=%CLASSPATH%%

if "%ARG%"=="-cp" exit /b 0
if "%ARG%"=="${classpath}" exit /b 0

set JVM_ARGS=%JVM_ARGS% %ARG%
exit /b 0

:append_game_arg
set ARG=%~1

if defined SKIP_NEXT_GAME_ARG (
    set SKIP_NEXT_GAME_ARG=
    exit /b 0
)

if "%ARG%"=="--demo" exit /b 0
if "%ARG%"=="--width" (
    set SKIP_NEXT_GAME_ARG=1
    exit /b 0
)
if "%ARG%"=="--height" (
    set SKIP_NEXT_GAME_ARG=1
    exit /b 0
)
if "%ARG%"=="--quickPlayPath" (
    set SKIP_NEXT_GAME_ARG=1
    exit /b 0
)
if "%ARG%"=="--quickPlaySingleplayer" (
    set SKIP_NEXT_GAME_ARG=1
    exit /b 0
)
if "%ARG%"=="--quickPlayMultiplayer" (
    set SKIP_NEXT_GAME_ARG=1
    exit /b 0
)
if "%ARG%"=="--quickPlayRealms" (
    set SKIP_NEXT_GAME_ARG=1
    exit /b 0
)

set GAME_ARGS=%GAME_ARGS% %ARG%
exit /b 0
