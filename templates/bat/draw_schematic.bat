@echo off
setlocal EnableDelayedExpansion

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
cd /d "%TARGET_PROJECT%"
echo Target Project: %TARGET_PROJECT%

REM Check for Yosys (trying yowasp-yosys first, then yosys)
set YOSYS_CMD=yosys

where yowasp-yosys >nul 2>nul
if %errorlevel% equ 0 (
    echo [INFO] Found yowasp-yosys. Using it.
    set YOSYS_CMD=yowasp-yosys
) else (
    where yosys >nul 2>nul
    if %errorlevel% neq 0 (
        echo [ERROR] Neither 'yosys' nor 'yowasp-yosys' found in PATH.
        echo Please ensure Yosys is installed.
        pause
        exit /b 1
    )
)

set "NETLISTSVG_CMD=%~dp0..\node_modules\netlistsvg\bin\netlistsvg.js"
if not exist "%NETLISTSVG_CMD%" (
    echo [ERROR] netlistsvg not found at templates\node_modules
    echo [INFO] Run: cd templates ^&^& npm install
    pause
    exit /b 1
)

REM Dynamically find all Verilog files in src folder
set "VERILOG_FILES="
set "ALL_MODULES="
set "MODULE_COUNT=0"
set "HAS_TOP=0"
for %%f in (src\*.v) do (
    set /a MODULE_COUNT+=1
    set "MODULE_NAME=%%~nf"
    set "VERILOG_FILES=!VERILOG_FILES! src/%%~nxf"
    set "ALL_MODULES=!ALL_MODULES! !MODULE_NAME!"
    set "MODULE_!MODULE_COUNT!=!MODULE_NAME!"
    if /i "!MODULE_NAME!"=="Top" (
        set "HAS_TOP=1"
        set "TOP_MODULE_NAME=!MODULE_NAME!"
    )
)

if !MODULE_COUNT! equ 0 (
    echo [ERROR] No .v files found in src/ folder.
    pause
    exit /b 1
)

echo [INFO] Detected source files: %VERILOG_FILES%
echo.
echo ========================================================
echo  Module Selection
echo ========================================================
echo  Scanned module files in src:
for /l %%i in (1,1,!MODULE_COUNT!) do (
    echo   [%%i] !MODULE_%%i!
)
echo.

:SELECT_MODULES
echo  Input format:
echo   - Number(s): 1 3 5  ^(space/comma separated^)
echo   - ALL: generate all modules
if "!HAS_TOP!"=="1" (
    echo   - Enter: default !TOP_MODULE_NAME!
) else (
    echo   - Enter: default !MODULE_1!
)
echo.
set "USER_INPUT="
set /p "USER_INPUT=Select module number(s): "

REM Handle default
if "%USER_INPUT%"=="" (
    if "!HAS_TOP!"=="1" (
        set "USER_INPUT=!TOP_MODULE_NAME!"
    ) else (
        set "USER_INPUT=!MODULE_1!"
    )
    goto :SELECTION_DONE
)

REM Handle ALL
if /i "%USER_INPUT%"=="ALL" (
    set "USER_INPUT=%ALL_MODULES%"
    goto :SELECTION_DONE
)

if /i "%USER_INPUT%"=="!TOP_MODULE_NAME!" (
    set "USER_INPUT=!TOP_MODULE_NAME!"
    goto :SELECTION_DONE
)

REM Convert numeric selection to module names
set "SELECTED_MODULES="
set "SELECTION_OK=1"
set "SELECTION_RAW=%USER_INPUT:,= %"
for %%I in (%SELECTION_RAW%) do (
    set "TOKEN=%%~I"
    set "NON_DIGIT="
    for /f "delims=0123456789" %%A in ("!TOKEN!") do set "NON_DIGIT=%%A"
    if defined NON_DIGIT (
        echo [ERROR] Invalid selection token: %%I
        set "SELECTION_OK=0"
    ) else (
        if %%I lss 1 (
            echo [ERROR] Selection out of range: %%I
            set "SELECTION_OK=0"
        ) else (
            if %%I gtr !MODULE_COUNT! (
                echo [ERROR] Selection out of range: %%I
                set "SELECTION_OK=0"
            ) else (
                set "SELECTED_MODULES=!SELECTED_MODULES! !MODULE_%%I!"
            )
        )
    )
)

if "!SELECTION_OK!"=="0" (
    echo [INFO] Please enter valid module numbers.
    echo.
    goto :SELECT_MODULES
)

if "!SELECTED_MODULES!"=="" (
    echo [ERROR] No valid module selected.
    echo.
    goto :SELECT_MODULES
)

set "USER_INPUT=!SELECTED_MODULES!"

:SELECTION_DONE
for /f "tokens=* delims= " %%A in ("%USER_INPUT%") do set "USER_INPUT=%%A"

echo.
echo [INFO] Generating schematics for: %USER_INPUT%
echo.

REM Create output/Diagram folder structure if it doesn't exist
if not exist "output" mkdir output
if not exist "output\Diagram" mkdir output\Diagram
if not exist "output\Diagram\Simple" mkdir output\Diagram\Simple
if not exist "output\Diagram\Detailed" mkdir output\Diagram\Detailed
if not exist "output\Diagram\JSON" mkdir output\Diagram\JSON
echo [INFO] Output directory structure:
echo   - output\Diagram\Simple\    (Simple box diagrams)
echo   - output\Diagram\Detailed\  (Detailed internal diagrams)
echo   - output\Diagram\JSON\      (Intermediate JSON files)
echo.

REM Loop through each requested module
for %%M in (%USER_INPUT%) do (
    echo --------------------------------------------------------
    echo  Processing Module: %%M
    echo --------------------------------------------------------
    
    REM Find the source file for this module
    set "SOURCE_FILE="
    for %%F in (src\*.v) do (
        findstr /i /c:"module %%M" "%%F" >nul 2>&1
        if !errorlevel! equ 0 (
            set "SOURCE_FILE=%%F"
        )
    )
    
    if "!SOURCE_FILE!"=="" (
        echo [ERROR] Could not find source file for module %%M
        goto :next_module
    )
    
    echo [INFO] Found %%M in !SOURCE_FILE!
    
    REM Check if this module has sub-modules (instantiates other modules)
    REM Use PowerShell to avoid findstr stdin hang issue
    set "HAS_SUBMODULES=0"
    for /f %%R in ('powershell -NoProfile -Command "$lines = Get-Content '!SOURCE_FILE!'; $found = 0; foreach ($l in $lines) { if ($l -match '^\s*[a-zA-Z_]\w+\s+[a-zA-Z_]\w+\s*\(' -and $l -notmatch '^\s*(module|function|task|input|output|inout|wire|reg|logic|assign|always|initial|localparam|parameter|generate|if|else|for|case|begin|end)\b') { $found = 1; break } }; $found"') do (
        set "HAS_SUBMODULES=%%R"
    )
    
    if !HAS_SUBMODULES! equ 1 (
        echo [INFO] Module %%M has sub-modules - generating BOTH detailed and simple versions
        
        REM === Generate DETAILED version ===
        set "JSON_FILE=output\Diagram\JSON\output_%%M.json"
        set "SVG_DETAILED=output\Diagram\Detailed\%%M_detailed.svg"
        set "DRAWIO_DETAILED=output\Diagram\Detailed\%%M_detailed.drawio"
        
        echo [INFO] Generating detailed diagram...
        %YOSYS_CMD% -p "read_verilog -sv %VERILOG_FILES%; hierarchy -top %%M; proc; opt; write_json !JSON_FILE!" >nul 2>&1
        if !errorlevel! neq 0 (
            echo [ERROR] Yosys synthesis failed for %%M
        ) else (
            echo [INFO] Cleaning JSON...
            powershell -ExecutionPolicy Bypass -File "%~dp0..\tools\process_schematic.ps1" -JsonPath !JSON_FILE!
            
            echo [INFO] Generating detailed SVG...
            if exist !SVG_DETAILED! del /q !SVG_DETAILED! >nul 2>&1
            call node "%NETLISTSVG_CMD%" !JSON_FILE! --skin "%~dp0..\tools\skin.svg" -o !SVG_DETAILED! >nul 2>&1
            if !errorlevel! neq 0 (
                echo [ERROR] netlistsvg generation failed for %%M
                goto :next_module
            )
            
            if exist !SVG_DETAILED! (
                echo [SUCCESS] Generated !SVG_DETAILED!
                echo [INFO] Converting detailed to Draw.io...
                node "%~dp0..\tools\svg2drawio.js" !SVG_DETAILED! !DRAWIO_DETAILED!
                if exist !DRAWIO_DETAILED! (
                    echo [SUCCESS] Generated !DRAWIO_DETAILED!
                )
            ) else (
                echo [ERROR] Failed to generate detailed SVG for %%M
            )
        )
        
        REM === Generate SIMPLE version ===
        set "SVG_SIMPLE=output\Diagram\Simple\%%M.svg"
        set "DRAWIO_SIMPLE=output\Diagram\Simple\%%M.drawio"
        
        echo [INFO] Generating simple diagram...
        powershell -ExecutionPolicy Bypass -File "%~dp0..\tools\generate_simple_svg.ps1" -VerilogFile !SOURCE_FILE! -OutputSvg !SVG_SIMPLE!
        
        if exist !SVG_SIMPLE! (
            echo [SUCCESS] Generated !SVG_SIMPLE!
            
            echo [INFO] Converting simple to Draw.io...
            node "%~dp0..\tools\svg2drawio.js" !SVG_SIMPLE! !DRAWIO_SIMPLE!
            if exist !DRAWIO_SIMPLE! (
                echo [SUCCESS] Generated !DRAWIO_SIMPLE!
            )
        ) else (
            echo [ERROR] Failed to generate simple SVG for %%M
        )
        
    ) else (
        echo [INFO] Module %%M is a leaf module - generating simple version only
        
        REM === Generate SIMPLE version only ===
        set "SVG_SIMPLE=output\Diagram\Simple\%%M.svg"
        set "DRAWIO_SIMPLE=output\Diagram\Simple\%%M.drawio"
        
        echo [INFO] Generating simple diagram...
        powershell -ExecutionPolicy Bypass -File "%~dp0..\tools\generate_simple_svg.ps1" -VerilogFile !SOURCE_FILE! -OutputSvg !SVG_SIMPLE!
        
        if exist !SVG_SIMPLE! (
            echo [SUCCESS] Generated !SVG_SIMPLE!
            
            echo [INFO] Converting to Draw.io...
            node "%~dp0..\tools\svg2drawio.js" !SVG_SIMPLE! !DRAWIO_SIMPLE!
            if exist !DRAWIO_SIMPLE! (
                echo [SUCCESS] Generated !DRAWIO_SIMPLE!
            )
        ) else (
            echo [ERROR] Failed to generate SVG for %%M
        )
    )
    
    :next_module
    echo.
)

echo [INFO] All tasks completed.
exit /b 0
