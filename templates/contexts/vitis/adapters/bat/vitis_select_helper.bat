@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "MODE=%~1"
if /i "%MODE%"=="bit" goto :SELECT_BIT
if /i "%MODE%"=="bits" goto :SELECT_BIT
if /i "%MODE%"=="xsa" goto :SELECT_XSA
if /i "%MODE%"=="platform" goto :SELECT_PLATFORM
if /i "%MODE%"=="apps" goto :SELECT_APPS
echo [ERROR] Unknown Vitis selection mode: %MODE%
exit /b 1

:SELECT_BIT
set "TARGET_PROJECT=%~f2"
set "RETURN_VAR=%~3"
for %%I in ("%~dp0..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "VITIS_PLAN_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_plan_cli.js"
set "MANIFEST_JSON=%TARGET_PROJECT%\output\manifest\manifest_resolved.json"
set "CHOICE_COUNT=0"
if exist "%MANIFEST_JSON%" (
    for /f "tokens=1,2,3,4 delims=|" %%A in ('node "%VITIS_PLAN_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --list bits 2^>nul') do (
        set /a CHOICE_COUNT+=1
        set "ITEM_VALUE_!CHOICE_COUNT!=%%~C"
        if "%%~D"=="" (
            set "ITEM_LABEL_!CHOICE_COUNT!=%%~B"
        ) else (
            set "ITEM_LABEL_!CHOICE_COUNT!=%%~D"
        )
    )
)
if !CHOICE_COUNT! equ 0 (
    echo [INFO] No bitstream files found from the Vitis manifest bit discovery.
    goto :RETURN_EMPTY
)
echo.
echo Available bitstream files:
call :PRINT_CHOICES
echo.
set "CHOICE="
set /p "CHOICE=Select Bitstream (number, L=latest, Enter=latest, B=back, Q=cancel): "
if "!CHOICE!"=="" set "CHOICE=1"
if /i "!CHOICE!"=="L" set "CHOICE=1"
if /i "!CHOICE!"=="B" (
    echo [INFO] Returning to Vitis menu.
    endlocal
    exit /b 99
)
if /i "!CHOICE!"=="Q" (
    echo [INFO] User cancelled Vitis selection.
    endlocal
    exit /b 99
)
call :VALIDATE_NUMBER "!CHOICE!" !CHOICE_COUNT!
if errorlevel 1 goto :CANCEL
call set "SELECTED_VALUE=%%ITEM_VALUE_!CHOICE!%%"
goto :RETURN_VALUE

:SELECT_XSA
set "TARGET_PROJECT=%~f2"
set "RETURN_VAR=%~3"
for %%I in ("%~dp0..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "VITIS_PLAN_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_plan_cli.js"
set "MANIFEST_JSON=%TARGET_PROJECT%\output\manifest\manifest_resolved.json"
set "CHOICE_COUNT=0"
if exist "%MANIFEST_JSON%" (
    for /f "tokens=1,2,3,4 delims=|" %%A in ('node "%VITIS_PLAN_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --list xsas 2^>nul') do (
        set /a CHOICE_COUNT+=1
        set "ITEM_VALUE_!CHOICE_COUNT!=%%~C"
        if "%%~D"=="" (
            set "ITEM_LABEL_!CHOICE_COUNT!=%%~B"
        ) else (
            set "ITEM_LABEL_!CHOICE_COUNT!=%%~D"
        )
    )
)
if !CHOICE_COUNT! equ 0 (
    echo [INFO] No exported XSA files found from the Vitis manifest XSA discovery.
    goto :RETURN_EMPTY
)
echo.
echo Available XSA files:
call :PRINT_CHOICES
echo.
set "CHOICE="
set /p "CHOICE=Select XSA (number, L=latest, Enter=latest, B=back, Q=cancel): "
if "!CHOICE!"=="" set "CHOICE=1"
if /i "!CHOICE!"=="L" set "CHOICE=1"
if /i "!CHOICE!"=="B" (
    echo [INFO] Returning to Vitis menu.
    endlocal
    exit /b 99
)
if /i "!CHOICE!"=="Q" (
    echo [INFO] User cancelled Vitis selection.
    endlocal
    exit /b 99
)
call :VALIDATE_NUMBER "!CHOICE!" !CHOICE_COUNT!
if errorlevel 1 goto :CANCEL
call set "SELECTED_VALUE=%%ITEM_VALUE_!CHOICE!%%"
goto :RETURN_VALUE

:SELECT_PLATFORM
set "TARGET_PROJECT=%~f2"
set "RETURN_VAR=%~3"
for %%I in ("%~dp0..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "VITIS_PLAN_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_plan_cli.js"
set "MANIFEST_JSON=%TARGET_PROJECT%\output\manifest\manifest_resolved.json"
set "CHOICE_COUNT=0"
if exist "%MANIFEST_JSON%" (
    for /f "tokens=1,2,3,4 delims=|" %%A in ('node "%VITIS_PLAN_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --list platforms 2^>nul') do (
        set /a CHOICE_COUNT+=1
        set "ITEM_VALUE_!CHOICE_COUNT!=%%~C"
        if "%%~D"=="" (
            set "ITEM_LABEL_!CHOICE_COUNT!=%%~B"
        ) else (
            set "ITEM_LABEL_!CHOICE_COUNT!=%%~D"
        )
    )
)
if !CHOICE_COUNT! equ 0 (
    echo [INFO] No exported platform files found from the Vitis manifest platform discovery.
    goto :RETURN_EMPTY
)
echo.
echo Available Vitis platforms:
call :PRINT_CHOICES
echo.
set "CHOICE="
set /p "CHOICE=Select Platform (number, L=latest, Enter=latest, B=back, Q=cancel): "
if "!CHOICE!"=="" set "CHOICE=1"
if /i "!CHOICE!"=="L" set "CHOICE=1"
if /i "!CHOICE!"=="B" (
    echo [INFO] Returning to Vitis menu.
    endlocal
    exit /b 99
)
if /i "!CHOICE!"=="Q" (
    echo [INFO] User cancelled Vitis selection.
    endlocal
    exit /b 99
)
call :VALIDATE_NUMBER "!CHOICE!" !CHOICE_COUNT!
if errorlevel 1 goto :CANCEL
call set "SELECTED_VALUE=%%ITEM_VALUE_!CHOICE!%%"
goto :RETURN_VALUE

:SELECT_APPS
set "TARGET_PROJECT=%~f2"
set "MANIFEST_JSON=%~f3"
set "ALLOW_MULTI=%~4"
set "RETURN_VAR=%~5"
for %%I in ("%~dp0..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "VITIS_PLAN_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_plan_cli.js"
set "CHOICE_COUNT=0"
for /f "tokens=1,2,3,4 delims=|" %%A in ('node "%VITIS_PLAN_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --list applications 2^>nul') do (
    set /a CHOICE_COUNT+=1
    set "ITEM_VALUE_!CHOICE_COUNT!=%%~C"
    if "%%~D"=="" (
        set "ITEM_LABEL_!CHOICE_COUNT!=%%~B"
    ) else (
        set "ITEM_LABEL_!CHOICE_COUNT!=%%~D"
    )
)
if !CHOICE_COUNT! equ 0 (
    echo [INFO] No Vitis applications are configured in the manifest.
    goto :RETURN_EMPTY
)
echo.
echo Available Vitis applications:
call :PRINT_CHOICES
echo.
set "CHOICE="
if "%ALLOW_MULTI%"=="1" (
    set /p "CHOICE=Select Application(s) (number list, A=all, Enter=1, B=back, Q=cancel): "
) else (
    set /p "CHOICE=Select Application (number, Enter=1, B=back, Q=cancel): "
)
if "!CHOICE!"=="" set "CHOICE=1"
if /i "!CHOICE!"=="B" (
    echo [INFO] Returning to Vitis menu.
    endlocal
    exit /b 99
)
if /i "!CHOICE!"=="Q" (
    echo [INFO] User cancelled Vitis selection.
    endlocal
    exit /b 99
)
if "%ALLOW_MULTI%"=="1" if /i "!CHOICE!"=="A" (
    set "SELECTED_VALUE=__ALL__"
    goto :RETURN_VALUE
)
set "SELECTED_VALUE="
set "TOKENS=!CHOICE:,= !"
for %%T in (!TOKENS!) do (
    set "TOKEN=%%~T"
    echo(!TOKEN!| findstr /r "^[0-9][0-9]*$" >nul
    if not errorlevel 1 (
        call :VALIDATE_NUMBER "!TOKEN!" !CHOICE_COUNT!
        if errorlevel 1 goto :CANCEL
        call set "TOKEN_VALUE=%%ITEM_VALUE_!TOKEN!%%"
    ) else (
        set "TOKEN_VALUE=!TOKEN!"
    )
    if defined SELECTED_VALUE (
        set "SELECTED_VALUE=!SELECTED_VALUE!,!TOKEN_VALUE!"
    ) else (
        set "SELECTED_VALUE=!TOKEN_VALUE!"
    )
    if not "%ALLOW_MULTI%"=="1" goto :RETURN_VALUE
)
goto :RETURN_VALUE

:PRINT_CHOICES
for /l %%I in (1,1,!CHOICE_COUNT!) do (
    echo   [%%I] !ITEM_LABEL_%%I!
)
exit /b 0

:VALIDATE_NUMBER
set "NUMBER=%~1"
set "MAX_VALUE=%~2"
echo(%NUMBER%| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo [ERROR] Invalid selection: %NUMBER%
    exit /b 1
)
if %NUMBER% lss 1 (
    echo [ERROR] Selection is out of range: %NUMBER%
    exit /b 1
)
if %NUMBER% gtr %MAX_VALUE% (
    echo [ERROR] Selection is out of range: %NUMBER%
    exit /b 1
)
exit /b 0

:RETURN_EMPTY
set "SELECTED_VALUE="
goto :RETURN_VALUE

:RETURN_VALUE
endlocal & set "%RETURN_VAR%=%SELECTED_VALUE%"
exit /b 0

:CANCEL
echo [INFO] User cancelled Vitis selection.
endlocal
exit /b 99
