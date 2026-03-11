const path = require("path");

const INVALID_INSTANTIATION_KEYWORDS = new Set([
  "module", "endmodule", "input", "output", "inout", "wire", "reg", "logic",
  "always", "always_ff", "always_comb", "always_latch", "initial", "assign",
  "if", "else", "for", "while", "case", "casex", "casez", "endcase", "begin", "end",
  "parameter", "localparam", "function", "endfunction", "task", "endtask",
  "generate", "endgenerate", "genvar", "typedef", "enum", "struct", "union",
]);

function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

function relFromProject(projectRoot, absPath) {
  return normalizeSlashes(path.relative(projectRoot, absPath));
}

function stripComments(content) {
  const noBlock = String(content || "").replace(/\/\*[\s\S]*?\*\//g, "");
  return noBlock.replace(/\/\/.*$/gm, "");
}

function extractComment(lines, index) {
  const comment = [];
  for (let i = index - 1; i >= 0; i -= 1) {
    const line = String(lines[i] || "").trim();
    if (line.startsWith("//")) {
      comment.unshift(line.replace(/^\/\/\s*/, ""));
    } else if (line.startsWith("*/")) {
      for (let j = i - 1; j >= 0; j -= 1) {
        const blockLine = String(lines[j] || "").trim();
        if (blockLine.startsWith("/*")) break;
        comment.unshift(blockLine.replace(/^\*\s?/, ""));
        i = j;
      }
    } else {
      break;
    }
  }
  return comment.join(" ");
}

function parseInfoBlock(rawContent, startTag, endTag) {
  const re = new RegExp(`\\[${startTag}\\]([\\s\\S]*?)\\[${endTag}\\]`, "i");
  const match = String(rawContent || "").match(re);
  if (!match) return null;

  const body = match[1];
  const lines = body.split(/\r?\n/);
  const info = {
    name: null,
    target: null,
    role: null,
    summary: [],
    stateDescription: [],
    scenario: [],
    checkPoint: [],
  };

  let currentSection = null;
  const pushToSection = (sectionName, text) => {
    if (!text) return;
    if (!Object.prototype.hasOwnProperty.call(info, sectionName)) return;
    info[sectionName].push(text);
  };

  lines.forEach((rawLine) => {
    const line = rawLine.trim();
    if (!line) return;

    let m = line.match(/^Name\s*:\s*(.+)$/i);
    if (m) {
      info.name = m[1].trim();
      currentSection = null;
      return;
    }
    m = line.match(/^Target\s*:\s*(.+)$/i);
    if (m) {
      info.target = m[1].trim();
      currentSection = null;
      return;
    }
    m = line.match(/^Role\s*:\s*(.+)$/i);
    if (m) {
      info.role = m[1].trim();
      currentSection = null;
      return;
    }

    m = line.match(/^Summary\s*:\s*(.*)$/i);
    if (m) {
      currentSection = "summary";
      pushToSection(currentSection, m[1].trim());
      return;
    }
    m = line.match(/^StateDescription\s*:\s*(.*)$/i);
    if (m) {
      currentSection = "stateDescription";
      pushToSection(currentSection, m[1].trim());
      return;
    }
    m = line.match(/^Scenario\s*:\s*(.*)$/i);
    if (m) {
      currentSection = "scenario";
      pushToSection(currentSection, m[1].trim());
      return;
    }
    m = line.match(/^CheckPoint\s*:\s*(.*)$/i);
    if (m) {
      currentSection = "checkPoint";
      pushToSection(currentSection, m[1].trim());
      return;
    }

    const bullet = line.match(/^[-*]\s+(.+)$/);
    if (bullet && currentSection) {
      pushToSection(currentSection, bullet[1].trim());
      return;
    }

    if (currentSection) {
      pushToSection(currentSection, line);
    }
  });

  ["summary", "stateDescription", "scenario", "checkPoint"].forEach((section) => {
    const dedup = [];
    const seen = new Set();
    info[section]
      .map((row) => row.trim())
      .filter(Boolean)
      .forEach((row) => {
        const key = row.toLowerCase();
        if (seen.has(key)) return;
        seen.add(key);
        dedup.push(row);
      });
    info[section] = dedup;
  });

  return info;
}

function parseModuleInfo(rawContent, fallbackName) {
  const parsed = parseInfoBlock(rawContent, "MODULE_INFO_START", "MODULE_INFO_END");
  if (!parsed) {
    return {
      name: fallbackName,
      role: null,
      summary: [],
      stateDescription: [],
    };
  }
  return {
    name: parsed.name || fallbackName,
    role: parsed.role || null,
    summary: parsed.summary || [],
    stateDescription: parsed.stateDescription || [],
  };
}

function parseTbInfo(rawContent, fallbackName) {
  const parsed = parseInfoBlock(rawContent, "TB_INFO_START", "TB_INFO_END");
  if (!parsed) {
    return {
      name: fallbackName,
      target: null,
      role: null,
      scenario: [],
      checkPoint: [],
    };
  }
  return {
    name: parsed.name || fallbackName,
    target: parsed.target || null,
    role: parsed.role || null,
    scenario: parsed.scenario || [],
    checkPoint: parsed.checkPoint || [],
  };
}

function escapeRegex(value) {
  return String(value || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function buildModuleRecords(projectRoot, sourceDocuments) {
  const rows = Array.isArray(sourceDocuments) ? sourceDocuments : [];
  if (rows.length === 0) {
    throw new Error("manifest_resolved_empty:src_files");
  }

  return rows.map((document) => {
    const absPath = path.resolve(document.absPath);
    const raw = String(document.raw || "");
    const clean = stripComments(raw);
    const fileName = path.basename(absPath);
    const moduleMatch = clean.match(/\bmodule\s+(?:(?:automatic|static)\s+)?([A-Za-z_]\w*)\b/i);
    const moduleName = moduleMatch ? moduleMatch[1] : path.basename(fileName, path.extname(fileName));

    return {
      moduleName,
      fileName,
      absPath,
      relPath: relFromProject(projectRoot, absPath),
      raw,
      clean,
      ports: [],
      children: [],
      fsmDetected: false,
      moduleInfo: parseModuleInfo(raw, moduleName),
    };
  });
}

function buildSubBlockModules(allModules, selectedModuleNames, topModuleName) {
  const moduleByLower = new Map(
    (allModules || []).map((mod) => [mod.moduleName.toLowerCase(), mod])
  );
  const unknown = [];
  let modules = [];
  const hasExplicitSelection = Array.isArray(selectedModuleNames) && selectedModuleNames.length > 0;

  if (!hasExplicitSelection) {
    modules = (allModules || []).slice();
  } else {
    selectedModuleNames.forEach((name) => {
      const key = String(name).trim().toLowerCase();
      if (!key) return;
      const found = moduleByLower.get(key);
      if (found) {
        modules.push(found);
      } else {
        unknown.push(name);
      }
    });
  }

  if (topModuleName && (!hasExplicitSelection || modules.length > 0)) {
    const topKey = String(topModuleName).trim().toLowerCase();
    const topModule = moduleByLower.get(topKey);
    if (topModule) {
      modules = modules.filter((mod) => mod.moduleName.toLowerCase() !== topKey);
      modules.unshift(topModule);
    }
  }

  const dedup = [];
  const seen = new Set();
  modules.forEach((mod) => {
    const key = mod.moduleName.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    dedup.push(mod);
  });

  return { modules: dedup, unknown };
}

function parsePorts(moduleInfo) {
  const escapedModule = escapeRegex(moduleInfo.moduleName);
  const headerRegex = new RegExp(
    `\\bmodule\\s+${escapedModule}\\b\\s*(?:#\\s*\\([\\s\\S]*?\\)\\s*)?\\(([\\s\\S]*?)\\)\\s*;`,
    "m"
  );
  const headerMatch = moduleInfo.clean.match(headerRegex);
  const header = headerMatch ? headerMatch[1] : "";

  const ports = [];
  const seen = new Set();

  const lines = header.split(/\r?\n/);
  let currentDir = null;
  let currentType = "wire";
  let currentWidth = "1";

  lines.forEach((lineRaw) => {
    const line = lineRaw.trim();
    if (!line) return;

    let working = line.replace(/[()]/g, "").replace(/,$/, "").trim();
    if (!working) return;

    const dirMatch = working.match(/^(input|output|inout)\b/i);
    if (dirMatch) {
      currentDir = dirMatch[1].toLowerCase();
      currentType = "wire";
      currentWidth = "1";
      working = working.slice(dirMatch[0].length).trim();
    } else if (!currentDir) {
      return;
    }

    const typeMatch = working.match(/^(wire|reg|logic)\b/i);
    if (typeMatch) {
      currentType = typeMatch[1].toLowerCase();
      currentWidth = "1";
      working = working.slice(typeMatch[0].length).trim();
    }

    working = working.replace(/^(signed|unsigned)\b/i, "").trim();

    const widthMatch = working.match(/^(\[[^\]]+\])/);
    if (widthMatch) {
      currentWidth = widthMatch[1].trim();
      working = working.slice(widthMatch[0].length).trim();
    }

    const names = working
      .split(",")
      .map((token) => token.split("=")[0].trim().replace(/[);]+$/g, ""))
      .filter(Boolean);

    names.forEach((name) => {
      if (seen.has(name)) return;
      seen.add(name);
      ports.push({
        name,
        direction: currentDir,
        type: currentType,
        width: currentWidth || "1",
      });
    });
  });

  moduleInfo.ports = ports;
}

function detectFsm(moduleInfo) {
  const content = moduleInfo.clean;
  const hasStateCase = /\bcase\s*\(\s*[A-Za-z_]\w*(?:state|cur)[A-Za-z_0-9]*\s*\)/i.test(content);
  const hasStateDecl = /\b(localparam|parameter)\b[\s\S]{0,260}\b[A-Za-z_]\w*(?:state|idle|init|run|wait|done)\w*\s*=/i.test(content);
  const hasNextStateAssign = /\b[A-Za-z_]\w*(?:next|nxt|_d)\w*\s*(?:<=|=)\s*[A-Za-z_]\w+/i.test(content);
  const hasAlways = /\balways\s*@|\balways_comb\b|\balways_ff\b/i.test(content);
  moduleInfo.fsmDetected = (hasAlways && hasStateCase) || (hasStateDecl && hasNextStateAssign);
}

function detectHierarchy(modules) {
  const knownModules = new Set((modules || []).map((row) => row.moduleName));
  const moduleMap = new Map((modules || []).map((row) => [row.moduleName, row]));

  (modules || []).forEach((mod) => {
    const children = [];
    const seen = new Set();
    const instRegex = /(^|\n)\s*([A-Za-z_]\w*)\s*(?:#\s*\([\s\S]*?\)\s*)?([A-Za-z_]\w*)\s*\(/g;
    let match;
    while ((match = instRegex.exec(mod.clean)) !== null) {
      const typeName = match[2];
      const instName = match[3];
      if (!knownModules.has(typeName)) continue;
      if (INVALID_INSTANTIATION_KEYWORDS.has(typeName.toLowerCase())) continue;
      if (typeName === mod.moduleName) continue;

      const key = `${typeName}:${instName}`;
      if (seen.has(key)) continue;
      seen.add(key);
      children.push({ moduleName: typeName, instanceName: instName });
    }
    mod.children = children;
  });

  const instantiated = new Set();
  (modules || []).forEach((mod) => mod.children.forEach((child) => instantiated.add(child.moduleName)));

  const rootCandidates = (modules || [])
    .map((mod) => mod.moduleName)
    .filter((name) => !instantiated.has(name))
    .sort((a, b) => a.localeCompare(b));

  const topModule = moduleMap.has("Top")
    ? "Top"
    : (rootCandidates[0] || ((modules || [])[0] ? modules[0].moduleName : null));

  return { moduleMap, topModule, rootCandidates };
}

function analyzeOneSourceDocuments({ projectRoot, sourceDocuments, selectedModuleNames = null } = {}) {
  const allModules = buildModuleRecords(projectRoot, sourceDocuments);
  allModules.forEach(parsePorts);
  allModules.forEach(detectFsm);
  const hierarchy = detectHierarchy(allModules);
  const selected = buildSubBlockModules(allModules, selectedModuleNames, hierarchy.topModule);

  return {
    allModules,
    hierarchy,
    selectedModules: selected.modules,
    unknownModules: selected.unknown,
  };
}

function buildHierarchyTree(topModule, moduleMap) {
  if (!topModule) return "`(module not found)`";
  const lines = [];
  const visit = (name, depth, stack) => {
    lines.push(`${"  ".repeat(depth)}- ${name}`);
    const mod = moduleMap.get(name);
    if (!mod) return;
    const children = mod.children
      .map((child) => child.moduleName)
      .sort((a, b) => a.localeCompare(b));
    children.forEach((child) => {
      if (stack.has(child)) {
        lines.push(`${"  ".repeat(depth + 1)}- ${child} (recursive)`);
        return;
      }
      const nextStack = new Set(stack);
      nextStack.add(child);
      visit(child, depth + 1, nextStack);
    });
  };
  visit(topModule, 0, new Set([topModule]));
  return lines.join("\n");
}

function formatPortTable(ports) {
  if (!ports || ports.length === 0) {
    return [
      "| Name | Direction | Width | Description |",
      "|------|-----------|-------|-------------|",
      "| - | - | - | - |",
      "",
    ].join("\n");
  }

  const lines = [
    "| Name | Direction | Width | Description |",
    "|------|-----------|-------|-------------|",
  ];
  ports.forEach((port) => {
    const direction = port.direction === "input"
      ? "Input"
      : (port.direction === "output" ? "Output" : "Inout");
    const width = port.width && port.width !== "1" ? `${port.width}-bit` : "1-bit";
    lines.push(`| \`${port.name}\` | ${direction} | ${width} | - |`);
  });
  lines.push("");
  return lines.join("\n");
}

function buildDirectoryTreeSnippet(directoryNames) {
  const present = Array.isArray(directoryNames) ? directoryNames.filter(Boolean) : [];
  if (present.length === 0) {
    return [
      "Project/",
      "└── src/",
    ].join("\n");
  }

  const lines = ["Project/"];
  present.forEach((name, index) => {
    const isLast = index === present.length - 1;
    lines.push(`${isLast ? "└──" : "├──"} ${name}/`);
  });
  return lines.join("\n");
}

function pushVisualLine(lines, label, assetPath, missingHint, altText) {
  if (!assetPath) {
    lines.push(`- ${label}: (미생성) \`${missingHint}\``);
    return;
  }

  const rel = normalizeSlashes(assetPath);
  const lower = rel.toLowerCase();
  if (
    lower.endsWith(".svg") ||
    lower.endsWith(".png") ||
    lower.endsWith(".jpg") ||
    lower.endsWith(".jpeg") ||
    lower.endsWith(".gif")
  ) {
    lines.push(`- ${label}: ![${altText}](${rel})`);
    return;
  }
  lines.push(`- ${label}: [${path.basename(rel)}](${rel})`);
}

function renderOneSourceMarkdown(model) {
  const uniqueModuleNames = Array.from(new Set((model.allModules || []).map((mod) => mod.moduleName))).sort();
  const lines = [];

  lines.push(`# 📋 ${model.projectName} 설계 결과 보고서`);
  lines.push("");
  lines.push("---");
  lines.push("");
  lines.push("| 항목 | 내용 |");
  lines.push("| :--- | :--- |");
  lines.push("| **과목명** | 디지털 시스템 설계 |");
  lines.push(`| **프로젝트명** | **${model.projectName}** |`);
  lines.push(`| **최상위 모듈** | \`${model.topModule || "-"}\` |`);
  lines.push(`| **제출일** | ${model.todayKo} |`);
  lines.push(`| **생성 시각** | ${model.generatedAtKo} |`);
  lines.push(`| **전체 모듈 수** | ${uniqueModuleNames.length}개 |`);
  lines.push("");
  lines.push("---");
  lines.push("");

  lines.push("## 📑 목차 (Table of Contents)");
  lines.push("");
  lines.push("1. [개요 (Introduction)](#1-개요-introduction)");
  lines.push("   - [1.1 설계 목적 및 배경](#11-설계-목적-및-배경)");
  lines.push("   - [1.2 주요 기능 명세](#12-주요-기능-명세-specifications)");
  lines.push("   - [1.3 설계 환경](#13-설계-환경-design-environment)");
  lines.push("   - [1.4 시스템 데이터시트](#14-시스템-데이터시트-system-data-sheet)");
  lines.push("   - [1.5 프로젝트 디렉토리 구조](#15-프로젝트-디렉토리-구조-directory-structure)");
  lines.push("2. [전체 시스템 구조 (System Architecture)](#2-전체-시스템-구조-system-architecture)");
  lines.push("   - [2.1 최상위 블록도](#21-최상위-블록도-top-level-block-diagram)");
  lines.push("   - [2.2 계층 구조](#22-계층-구조-hierarchy)");
  lines.push("   - [2.3 클럭 및 리셋 아키텍처](#23-클럭-및-리셋-아키텍처-clock--reset-strategy)");
  lines.push("   - [2.4 전체 신호 흐름](#24-전체-신호-흐름-및-인터럽트-구조)");
  lines.push("   - [2.5 통합 레지스터 맵](#25-통합-레지스터-맵-global-register-map)");
  lines.push("3. [상세 모듈 설계 (Detailed Module Design)](#3-상세-모듈-설계-detailed-module-design)");
  lines.push("4. [검증 및 시뮬레이션 (Verification)](#4-검증-및-시뮬레이션-verification)");
  lines.push("5. [구현 및 합성 결과 (Implementation & Synthesis)](#5-구현-및-합성-결과-implementation--synthesis)");
  lines.push("6. [결론 및 고찰 (Conclusion)](#6-결론-및-고찰-conclusion)");
  lines.push("7. [부록 (Appendix)](#7-부록-appendix)");
  lines.push("");
  lines.push("---");
  lines.push("");

  lines.push("## 1. 개요 (Introduction)");
  lines.push("");
  lines.push("### 1.1 설계 목적 및 배경");
  lines.push("");
  lines.push(`본 보고서는 **${model.projectName}** 프로젝트의 RTL 설계 결과를 자동 생성한 문서입니다.`);
  lines.push("소스 코드, 다이어그램, 시뮬레이션 결과를 토대로 설계의 구조 및 검증 상태를 체계적으로 정리합니다.");
  lines.push("");
  lines.push("> 💡 이 보고서는 자동 생성된 초안입니다. 각 섹션의 **수동 보완 필요** 항목을 직접 작성하여 완성도를 높이세요.");
  lines.push("");

  lines.push("### 1.2 주요 기능 명세 (Specifications)");
  lines.push("");
  lines.push("| 항목 | 값 |");
  lines.push("| :--- | :--- |");
  lines.push(`| 최상위 모듈 | \`${model.topModule || "-"}\` |`);
  lines.push(`| 전체 고유 모듈 수 | ${uniqueModuleNames.length}개 |`);
  if ((model.allModules || []).length !== uniqueModuleNames.length) {
    lines.push(`| 스캔된 모듈 정의 수 (중복 포함) | ${model.allModules.length}개 |`);
  }
  lines.push(`| 상세 설계 기술 대상 | ${(model.modules || []).length}개 (Top 포함) |`);
  lines.push("");
  lines.push("**모듈 목록:**");
  lines.push("");
  uniqueModuleNames.forEach((name) => lines.push(`- \`${name}\``));
  lines.push("");

  lines.push("### 1.3 설계 환경 (Design Environment)");
  lines.push("");
  lines.push("| 항목 | 내용 |");
  lines.push("| :--- | :--- |");
  lines.push("| OS | Windows 10/11 |");
  lines.push("| 언어 | Verilog-2001 / SystemVerilog |");
  lines.push("| 합성 도구 | Xilinx Vivado |");
  lines.push("| 타깃 디바이스 | Basys3 (XC7A35T) / 프로젝트별 상이 |");
  lines.push("| 시뮬레이터 | Vivado Simulator / ModelSim |");
  lines.push("| 문서 생성 | Node.js + Pandoc + PowerShell |");
  lines.push("");

  lines.push("### 1.4 시스템 데이터시트 (System Data Sheet)");
  lines.push("");
  lines.push("**핵심 인터페이스 (Top 모듈 기준)**");
  lines.push("");
  lines.push("| 신호 종류 | 포트명 |");
  lines.push("| :--- | :--- |");
  lines.push(`| 🕐 Clock | ${model.topClocks.length > 0 ? model.topClocks.map((row) => `\`${row}\``).join(", ") : "미검출"} |`);
  lines.push(`| 🔁 Reset | ${model.topResets.length > 0 ? model.topResets.map((row) => `\`${row}\``).join(", ") : "미검출"} |`);
  lines.push("");
  lines.push("> ⚠️ **수동 보완 필요:** 동작 주파수, 전원 전압, I/O 전기적 특성은 타깃 디바이스 데이터시트 기준으로 직접 보완하세요.");
  lines.push("");

  lines.push("### 1.5 프로젝트 디렉토리 구조 (Directory Structure)");
  lines.push("");
  lines.push("```text");
  lines.push(model.directoryTree);
  lines.push("```");
  lines.push("");

  lines.push("## 2. 전체 시스템 구조 (System Architecture)");
  lines.push("");
  lines.push("---");
  lines.push("");
  lines.push("## 2. 전체 시스템 구조 (System Architecture)");
  lines.push("");
  lines.push("### 2.1 최상위 블록도 (Top-level Block Diagram)");
  lines.push("");
  if (model.topAssets) {
    pushVisualLine(
      lines,
      "Top Detailed",
      model.topAssets.detailed,
      `output/Diagram/Detailed/${model.topModule}/${model.topModule}_detailed.svg`,
      `${model.topModule} detailed`
    );
    pushVisualLine(
      lines,
      "Top Simple",
      model.topAssets.simple,
      `output/Diagram/Simple/${model.topModule}/${model.topModule}.svg`,
      `${model.topModule} simple`
    );
  } else {
    lines.push("> ⚠️ Top 다이어그램 자산을 찾지 못했습니다. `code_schematic_draw.bat`를 먼저 실행하세요.");
  }
  lines.push("");
  lines.push("### 2.2 계층 구조 (Hierarchy)");
  lines.push("");
  lines.push("```text");
  lines.push(model.hierarchyTree);
  lines.push("```");
  lines.push("");
  lines.push("### 2.3 클럭 및 리셋 아키텍처 (Clock & Reset Strategy)");
  lines.push("");
  lines.push("| 구분 | 신호명 | 비고 |");
  lines.push("| :--- | :--- | :--- |");
  if (model.topClocks.length > 0) {
    model.topClocks.forEach((clockName) => lines.push(`| 🕐 Clock | \`${clockName}\` | Top 포트 기준 자동 검출 |`));
  } else {
    lines.push("| 🕐 Clock | *(미검출)* | source 내 `iClk` 규칙 확인 필요 |");
  }
  if (model.topResets.length > 0) {
    model.topResets.forEach((resetName) => lines.push(`| 🔁 Reset | \`${resetName}\` | sync/async 여부는 always 블록 검토 |`));
  } else {
    lines.push("| 🔁 Reset | *(미검출)* | `iRst`/`iRstn` 규칙 확인 필요 |");
  }
  lines.push("");
  lines.push("### 2.4 전체 신호 흐름 및 인터럽트 구조");
  lines.push("");
  lines.push("상위 모듈에서 하위 모듈로 제어/데이터 신호가 전달되는 정적 계층 구조 기반으로 동작합니다.");
  lines.push("");
  lines.push("> ⚠️ **수동 보완 필요:** 인터럽트/예외 처리 신호는 모듈별 RTL 구현 기준으로 보완하세요.");
  lines.push("");
  lines.push("### 2.5 통합 레지스터 맵 (Global Register Map)");
  lines.push("");
  lines.push("| Offset | 이름 | Direction | Reset Value | 설명 |");
  lines.push("| :--- | :--- | :--- | :--- | :--- |");
  lines.push("| - | - | - | - | SW 접근 레지스터를 수동으로 채워주세요 |");
  lines.push("");

  lines.push("---");
  lines.push("");
  lines.push("## 3. 상세 모듈 설계 (Detailed Module Design)");
  lines.push("");
  lines.push("### 3.1 공통 설계 원칙 (Design Methodology)");
  lines.push("");
  lines.push("| 원칙 | 내용 |");
  lines.push("| :--- | :--- |");
  lines.push("| Naming | `iXxx` (입력) / `oXxx` (출력) / `w` (내부 wire) / `state` (FSM 상태) |");
  lines.push("| FSM 방식 | Moore FSM 권장 (출력이 현재 상태에만 의존) |");
  lines.push("| 리셋 | Active-Low Async Reset (`iRstn`) 기준 |");
  lines.push("| 로직 분리 | 조합(always @(*)) / 순차(always @(posedge)) 블록 분리 |");
  lines.push("");

  (model.modules || []).forEach((mod, index) => {
    const modInfo = mod.moduleInfo || { summary: [], stateDescription: [] };
    const sectionNo = index + 1;

    lines.push("---");
    lines.push("");
    lines.push(`### 3.2.${sectionNo} \`${mod.moduleName}\` 모듈 설계`);
    lines.push("");
    lines.push("#### a. 기능 개요");
    lines.push("");
    lines.push("| 항목 | 내용 |");
    lines.push("| :--- | :--- |");
    lines.push(`| 소스 파일 | \`${mod.relPath}\` |`);
    lines.push(`| 하위 모듈 | ${mod.children.length > 0 ? mod.children.map((child) => `\`${child.moduleName}\``).join(", ") : "-"} |`);
    lines.push(`| FSM 포함 | ${mod.fsmDetected ? "✅ 감지됨" : "❌ 미검출"} |`);
    lines.push(`| 역할 | ${modInfo.role || "수동 보완 필요"} |`);
    lines.push("");
    if (Array.isArray(modInfo.summary) && modInfo.summary.length > 0) {
      lines.push("**기능 요약:**");
      lines.push("");
      modInfo.summary.forEach((item) => lines.push(`- ${item}`));
      lines.push("");
    } else {
      lines.push(`> ⚠️ \`${mod.moduleName}\` 모듈의 세부 기능 설명을 수동으로 보완하세요.`);
      lines.push("");
    }

    lines.push("#### b. 모듈 블록도 (Module Block Diagram)");
    lines.push("");
    pushVisualLine(
      lines,
      "Simple Diagram",
      mod.assets.simple,
      `output/Diagram/Simple/${mod.moduleName}/${mod.moduleName}.svg`,
      `${mod.moduleName} simple`
    );
    if (mod.isTopModule) {
      pushVisualLine(
        lines,
        "Detailed Diagram",
        mod.assets.detailed,
        `output/Diagram/Detailed/${mod.moduleName}/${mod.moduleName}_detailed.svg`,
        `${mod.moduleName} detailed`
      );
    }
    lines.push("");

    lines.push("#### c. 입출력 포트 정의 (I/O Port Table)");
    lines.push("");
    lines.push(formatPortTable(mod.ports));

    lines.push("#### d. 상태 천이도 (FSM Diagram)");
    lines.push("");
    if (mod.assets.fsm) {
      pushVisualLine(
        lines,
        "FSM Diagram",
        mod.assets.fsm,
        `output/fsm/${mod.moduleName}/${mod.moduleName}_fsm.svg`,
        `${mod.moduleName} fsm`
      );
    } else if (mod.fsmDetected) {
      lines.push("> ⚠️ FSM 패턴이 감지되었으나 FSM 다이어그램 파일이 없습니다. `code_fsm_draw.bat`를 실행하세요.");
    } else {
      lines.push("- 명시적 FSM 패턴 미검출");
    }
    lines.push("");

    lines.push("#### e. 핵심 로직 및 타이밍 분석 (Timing Analysis)");
    lines.push("");
    if (Array.isArray(modInfo.stateDescription) && modInfo.stateDescription.length > 0) {
      lines.push("**상태 설명:**");
      lines.push("");
      modInfo.stateDescription.forEach((item) => lines.push(`- ${item}`));
      lines.push("");
    }
    lines.push("| 항목 | 내용 |");
    lines.push("| :--- | :--- |");
    lines.push(`| 테스트벤치 | ${mod.wave.tbSource ? `\`${mod.wave.tbSource}\`` : `\`tb/tb_${mod.moduleName}.(v|sv)\` 자동 매칭 실패`} |`);
    if (mod.tbInfo && mod.tbInfo.role) lines.push(`| TB 역할 | ${mod.tbInfo.role} |`);
    lines.push(`| 파형 산출물 | ${mod.wave.existing.length + mod.wave.imagePaths.length}개 |`);
    lines.push("");
  });

  lines.push("---");
  lines.push("");
  lines.push("## 4. 검증 및 시뮬레이션 (Verification)");
  lines.push("");
  lines.push("### 4.1 테스트벤치 구성 및 검증 시나리오");
  lines.push("");
  lines.push("| 모듈 | TB 파일 | 시나리오 |");
  lines.push("| :--- | :--- | :--- |");
  (model.modules || []).forEach((mod) => {
    const tbFile = mod.wave.tbSource ? `\`${mod.wave.tbSource}\`` : "*(자동 매칭 실패)*";
    let scenario = "수동 보완 필요";
    if (mod.tbInfo && Array.isArray(mod.tbInfo.scenario) && mod.tbInfo.scenario.length > 0) {
      scenario = mod.tbInfo.scenario.join("; ");
    }
    lines.push(`| \`${mod.moduleName}\` | ${tbFile} | ${scenario} |`);
  });
  lines.push("");
  lines.push("### 4.2 시뮬레이션 결과 분석 (Waveform Analysis)");
  lines.push("");
  (model.modules || []).forEach((mod) => {
    if (mod.wave.imagePaths.length > 0) {
      lines.push(`**\`${mod.moduleName}\` 파형 이미지:**`);
      lines.push("");
      mod.wave.imagePaths.forEach((imagePath, idx) => lines.push(`![${mod.moduleName} waveform ${idx + 1}](${imagePath})`));
      lines.push("");
    } else if (mod.wave.existing.length > 0) {
      lines.push(`**\`${mod.moduleName}\` 파형 산출물:**`);
      lines.push("");
      mod.wave.existing.forEach((artifactPath) => lines.push(`- \`${artifactPath}\``));
      lines.push("");
    }
  });
  lines.push("> ⚠️ 커버리지 리포트는 시뮬레이터 결과를 수동 첨부하세요.");
  lines.push("");
  lines.push("### 4.3 하드웨어 동작 검증 (In-System Validation)");
  lines.push("");
  lines.push("> ⚠️ **수동 보완 필요:** 오실로스코프/ILA 실측 결과를 이 섹션에 추가하세요.");
  lines.push("");

  lines.push("---");
  lines.push("");
  lines.push("## 5. 구현 및 합성 결과 (Implementation & Synthesis)");
  lines.push("");
  lines.push("### 5.1 하드웨어 제약 사항 (XDC/SDC)");
  lines.push("");
  if ((model.constraintFiles || []).length > 0) {
    model.constraintFiles.forEach((filePath) => lines.push(`- \`${filePath}\``));
  } else {
    lines.push("> ⚠️ 제약 파일(.xdc/.sdc)이 `constrs/` 폴더에서 검출되지 않았습니다.");
  }
  lines.push("");
  lines.push("### 5.2 합성 및 구현 요약");
  lines.push("");
  lines.push("> ⚠️ **수동 보완 필요:** Vivado 합성 결과 (Warning/Error 목록, Optimization 내용)를 작성하세요.");
  lines.push("");
  lines.push("### 5.3 핀 제약 사항 및 I/O 표준");
  lines.push("");
  lines.push("| 핀 이름 | PACKAGE_PIN | IOSTANDARD | 기능 |");
  lines.push("| :--- | :--- | :--- | :--- |");
  lines.push("| - | - | - | XDC 파일 기준으로 수동 보완 |");
  lines.push("");
  lines.push("### 5.4 자원 소모량 (Resource Utilization)");
  lines.push("");
  lines.push("| 자원 | Used | Available | 비율 |");
  lines.push("| :--- | :--- | :--- | :--- |");
  lines.push("| LUT | - | - | 합성 리포트 반영 |");
  lines.push("| FF | - | - | 합성 리포트 반영 |");
  lines.push("| BRAM | - | - | 합성 리포트 반영 |");
  lines.push("| DSP | - | - | 합성 리포트 반영 |");
  lines.push("");
  lines.push("### 5.5 타이밍 리포트 (Timing Summary)");
  lines.push("");
  lines.push("| 지표 | 값 |");
  lines.push("| :--- | :--- |");
  lines.push("| WNS (Worst Negative Slack) | - |");
  lines.push("| TNS (Total Negative Slack) | - |");
  lines.push("| Fmax (최대 동작 주파수) | - |");
  lines.push("");
  lines.push("### 5.6 파워 리포트 (Power Report)");
  lines.push("");
  lines.push("| 구분 | 예상 전력 |");
  lines.push("| :--- | :--- |");
  lines.push("| 동적 전력 (Dynamic) | - |");
  lines.push("| 정적 전력 (Static) | - |");
  lines.push("| 전체 합계 | - |");
  lines.push("");

  lines.push("---");
  lines.push("");
  lines.push("## 6. 결론 및 고찰 (Conclusion)");
  lines.push("");
  lines.push("### 6.1 설계 결과 및 성능 평가");
  lines.push("");
  lines.push("자동 생성 보고서 기준으로 구조/자산 연계 상태를 확인했습니다.");
  lines.push("");
  lines.push("> ⚠️ **수동 보완 필요:** 설계 목표 달성 여부, 성능 측정 결과, 비교 분석 등을 직접 작성하세요.");
  lines.push("");
  lines.push("### 6.2 문제 해결 과정 (Troubleshooting)");
  lines.push("");
  lines.push("| 문제 | 원인 | 해결책 |");
  lines.push("| :--- | :--- | :--- |");
  lines.push("| 누락 자산 | 해당 배치 미실행 | 각 bat 단계 순서대로 재실행 |");
  lines.push("");
  lines.push("### 6.3 향후 개선 방향 및 소감");
  lines.push("");
  lines.push("> ⚠️ **수동 보완 필요:** 설계 경험, 배운 점, 개선 아이디어를 작성하세요.");
  lines.push("");

  lines.push("---");
  lines.push("");
  lines.push("## 7. 부록 (Appendix)");
  lines.push("");
  lines.push("### 7.1 소스 파일 목록");
  lines.push("");
  lines.push("| 모듈명 | 파일 경로 |");
  lines.push("| :--- | :--- |");
  (model.allModules || []).forEach((mod) => lines.push(`| \`${mod.moduleName}\` | \`${mod.relPath}\` |`));
  lines.push("");
  lines.push("### 7.2 제약 파일 목록");
  lines.push("");
  if ((model.constraintFiles || []).length > 0) {
    model.constraintFiles.forEach((filePath) => lines.push(`- \`${filePath}\``));
  } else {
    lines.push("- *(없음)*");
  }
  lines.push("");
  lines.push("### 7.3 산출물 디렉토리");
  lines.push("");
  lines.push("| 종류 | 경로 |");
  lines.push("| :--- | :--- |");
  lines.push("| 다이어그램 (Simple/Detailed) | `output/Diagram/` |");
  lines.push("| FSM 다이어그램 | `output/fsm/` |");
  lines.push("| 보고서 문서 | `output/docs/` |");
  lines.push("");

  return lines.join("\n");
}

module.exports = {
  normalizeSlashes,
  relFromProject,
  parseTbInfo,
  analyzeOneSourceDocuments,
  buildHierarchyTree,
  buildDirectoryTreeSnippet,
  renderOneSourceMarkdown,
};
