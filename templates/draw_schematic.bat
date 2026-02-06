@echo off
setlocal EnableDelayedExpansion

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
    if /i "!MODULE_NAME!"=="Top" set "HAS_TOP=1"
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
    echo   - Enter: default Top
) else (
    echo   - Enter: default !MODULE_1!
)
echo.
set "USER_INPUT="
set /p "USER_INPUT=Select module number(s): "

REM Handle default
if "%USER_INPUT%"=="" (
    if "!HAS_TOP!"=="1" (
        set "USER_INPUT=Top"
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

REM Create Diagram folder structure if it doesn't exist
if not exist "Diagram" mkdir Diagram
if not exist "Diagram\Simple" mkdir Diagram\Simple
if not exist "Diagram\Detailed" mkdir Diagram\Detailed
if not exist "Diagram\JSON" mkdir Diagram\JSON
echo [INFO] Output directory structure:
echo   - Diagram\Simple\    (Simple box diagrams)
echo   - Diagram\Detailed\  (Detailed internal diagrams)
echo   - Diagram\JSON\      (Intermediate JSON files)
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
    REM Look for pattern: ModuleName instance_name (
    set "HAS_SUBMODULES=0"
    for /f "delims=" %%L in ('findstr /r /c:"^[ 	]*[A-Z][a-zA-Z0-9_]*[ 	][ 	]*[a-zA-Z0-9_]*[ 	]*(" "!SOURCE_FILE!"') do (
        REM Exclude keywords like input, output, module, etc.
        echo %%L | findstr /i /v /c:"input" /c:"output" /c:"inout" /c:"module" /c:"endmodule" /c:"parameter" /c:"localparam" /c:"assign" /c:"always" /c:"initial" /c:"wire" /c:"reg" >nul
        if !errorlevel! equ 0 (
            set "HAS_SUBMODULES=1"
        )
    )
    
    if !HAS_SUBMODULES! equ 1 (
        echo [INFO] Module %%M has sub-modules - generating BOTH detailed and simple versions
        
        REM === Generate DETAILED version ===
        set "JSON_FILE=Diagram\JSON\output_%%M.json"
        set "SVG_DETAILED=Diagram\Detailed\%%M_detailed.svg"
        set "DRAWIO_DETAILED=Diagram\Detailed\%%M_detailed.drawio"
        
        echo [INFO] Generating detailed diagram...
        %YOSYS_CMD% -p "read_verilog -sv %VERILOG_FILES%; hierarchy -top %%M; proc; opt; write_json !JSON_FILE!" >nul 2>&1
        if !errorlevel! neq 0 (
            echo [ERROR] Yosys synthesis failed for %%M
        ) else (
            echo [INFO] Cleaning JSON...
            powershell -ExecutionPolicy Bypass -File process_schematic.ps1 -JsonPath !JSON_FILE!
            
            echo [INFO] Generating detailed SVG...
            call npx --yes netlistsvg !JSON_FILE! --skin skin.svg -o !SVG_DETAILED! >nul 2>&1
            
            if exist !SVG_DETAILED! (
                echo [SUCCESS] Generated !SVG_DETAILED!
                
                echo [INFO] Converting detailed to Draw.io...
                node svg2drawio.js !SVG_DETAILED! !DRAWIO_DETAILED!
                if exist !DRAWIO_DETAILED! (
                    echo [SUCCESS] Generated !DRAWIO_DETAILED!
                )
            ) else (
                echo [ERROR] Failed to generate detailed SVG for %%M
            )
        )
        
        REM === Generate SIMPLE version ===
        set "SVG_SIMPLE=Diagram\Simple\%%M.svg"
        set "DRAWIO_SIMPLE=Diagram\Simple\%%M.drawio"
        
        echo [INFO] Generating simple diagram...
        powershell -ExecutionPolicy Bypass -File generate_simple_svg.ps1 -VerilogFile !SOURCE_FILE! -OutputSvg !SVG_SIMPLE!
        
        if exist !SVG_SIMPLE! (
            echo [SUCCESS] Generated !SVG_SIMPLE!
            
            echo [INFO] Converting simple to Draw.io...
            node svg2drawio.js !SVG_SIMPLE! !DRAWIO_SIMPLE!
            if exist !DRAWIO_SIMPLE! (
                echo [SUCCESS] Generated !DRAWIO_SIMPLE!
            )
        ) else (
            echo [ERROR] Failed to generate simple SVG for %%M
        )
        
    ) else (
        echo [INFO] Module %%M is a leaf module - generating simple version only
        
        REM === Generate SIMPLE version only ===
        set "SVG_SIMPLE=Diagram\Simple\%%M.svg"
        set "DRAWIO_SIMPLE=Diagram\Simple\%%M.drawio"
        
        echo [INFO] Generating simple diagram...
        powershell -ExecutionPolicy Bypass -File generate_simple_svg.ps1 -VerilogFile !SOURCE_FILE! -OutputSvg !SVG_SIMPLE!
        
        if exist !SVG_SIMPLE! (
            echo [SUCCESS] Generated !SVG_SIMPLE!
            
            echo [INFO] Converting to Draw.io...
            node svg2drawio.js !SVG_SIMPLE! !DRAWIO_SIMPLE!
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
echo Opening Diagram folder...
explorer Diagram
pause
endlocal
