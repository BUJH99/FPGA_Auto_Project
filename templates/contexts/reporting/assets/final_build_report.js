(function () {
  "use strict";

  function textOr(value, fallback) {
    if (value === undefined || value === null || value === "") {
      return fallback;
    }
    return String(value);
  }

  function toPercent(value) {
    var txt = textOr(value, "0");
    return /[%]$/.test(txt) ? txt : txt + "%";
  }

  function addRow(tbody, c1, c2, c3, c4) {
    var tr = document.createElement("tr");
    [c1, c2, c3, c4].forEach(function (cell) {
      var td = document.createElement("td");
      td.textContent = textOr(cell, "-");
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  }

  function escapeHtml(value) {
    return textOr(value, "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function normalizeArray(value) {
    return Array.isArray(value) ? value : [];
  }

  var reportData = window.REPORT_DATA;
  if (!reportData || typeof reportData !== "object") {
    reportData = {};
  }

  // 1. Diagram Page
  var diagram = reportData.blockDiagram || {};
  var diagramImage = document.getElementById("blockDiagramImage");
  var diagramEmpty = document.getElementById("blockDiagramEmpty");
  var diagramSource = document.getElementById("diagramSource");

  if (diagramImage && diagramEmpty && diagramSource) {
    if (diagram.has && diagram.path) {
      diagramImage.src = diagram.path;
      diagramImage.style.display = "block";
      diagramEmpty.style.display = "none";
      diagramSource.textContent = "Diagram file: " + diagram.path;
    } else {
      diagramImage.style.display = "none";
      diagramEmpty.style.display = "block";
      diagramSource.textContent = "Diagram file: N/A";
    }
  }

  // 2. Module description page
  var modulesContainer = document.getElementById("modules-container");
  var modules = normalizeArray(reportData.modules);

  function openModal(src, caption) {
    var modal = document.getElementById("schematic-modal");
    var modalImg = document.getElementById("modal-image");
    var modalCaption = document.getElementById("modal-caption");
    if (!modal || !modalImg || !modalCaption) return;
    modal.style.display = "flex";
    modalImg.src = src;
    modalCaption.textContent = caption;
  }

  function closeModal() {
    var modal = document.getElementById("schematic-modal");
    if (!modal) return;
    modal.style.display = "none";
  }

  if (modulesContainer) {
    if (modules.length === 0) {
      modulesContainer.innerHTML = '<div class="panel">No module descriptions found.</div>';
    } else {
      modulesContainer.innerHTML = modules
        .map(function (m) {
          var schematicLink = m.schematic
            ? '<br><span class="view-schem-link" data-src="' +
              escapeHtml(m.schematic) +
              '" data-caption="' +
              escapeHtml(m.name + " Schematic") +
              '">View Schematic</span>'
            : "";
          return (
            '<div class="module-card">' +
            '<div class="module-header">' +
            '<span class="module-name">' +
            escapeHtml(textOr(m.name, "N/A")) +
            "</span>" +
            '<span class="module-file">' +
            escapeHtml(textOr(m.file, "N/A")) +
            "</span>" +
            "</div>" +
            '<div class="module-desc">' +
            escapeHtml(textOr(m.desc, "")) +
            schematicLink +
            "</div>" +
            "</div>"
          );
        })
        .join("");

      modulesContainer.addEventListener("click", function (event) {
        var target = event.target;
        if (!target || !target.classList || !target.classList.contains("view-schem-link")) return;
        openModal(target.getAttribute("data-src"), target.getAttribute("data-caption"));
      });
    }
  }

  var closeModalBtn = document.querySelector(".close-modal");
  if (closeModalBtn) {
    closeModalBtn.addEventListener("click", closeModal);
  }
  window.addEventListener("click", function (event) {
    var modal = document.getElementById("schematic-modal");
    if (modal && event.target === modal) closeModal();
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") closeModal();
  });

  // 3. Timing summary page
  var timing = reportData.timing || {};
  var kpiWns = document.getElementById("kpiWns");
  if (kpiWns) {
    document.getElementById("kpiTns").textContent = textOr(timing.tns, "N/A");
    document.getElementById("kpiWhs").textContent = textOr(timing.whs, "N/A");
    document.getElementById("kpiThs").textContent = textOr(timing.ths, "N/A");
    kpiWns.textContent = textOr(timing.wns, "N/A");

    var wnsNum = parseFloat(timing.wns);
    kpiWns.style.color = !isNaN(wnsNum) && wnsNum < 0 ? "#b91c1c" : "#0f172a";

    var timingBody = document.getElementById("timingTableBody");
    if (timingBody) {
      addRow(timingBody, "Slack (ns)", textOr(timing.wns, "N/A"), textOr(timing.whs, "N/A"), textOr(timing.tpws, "N/A"));
      addRow(timingBody, "Total Negative Slack", textOr(timing.tns, "N/A"), textOr(timing.ths, "N/A"), textOr(timing.tpws, "N/A"));
      addRow(timingBody, "Total Endpoints", textOr(timing.totalEndpoints, "N/A"), "-", "-");
    }
  }

  // 4. Utilization page
  var util = reportData.utilization || {};
  var utilBody = document.getElementById("utilTableBody");
  if (utilBody) {
    addRow(utilBody, "Slice LUTs", textOr(util.lutsUsed, "0"), textOr(util.lutsAvail, "0"), toPercent(util.lutsPerc));
    addRow(utilBody, "Slice Registers", textOr(util.regsUsed, "0"), textOr(util.regsAvail, "0"), toPercent(util.regsPerc));
    if (Array.isArray(util.io) && util.io.length > 0) {
      util.io.forEach(function (row) {
        addRow(utilBody, textOr(row.name, "IO"), textOr(row.used, "0"), textOr(row.avail, "0"), toPercent(row.perc));
      });
    } else {
      addRow(utilBody, "Additional IO utilization", "N/A", "N/A", "N/A");
    }
  }

  var envBody = document.getElementById("envListBody");
  if (envBody) {
    var envList = normalizeArray(reportData.environment);
    if (envList.length > 0) {
      envList.forEach(function (item) {
        var li = document.createElement("li");
        var left = document.createElement("span");
        var right = document.createElement("strong");
        left.textContent = textOr(item.name, "-");
        right.textContent = textOr(item.value, "-");
        li.appendChild(left);
        li.appendChild(right);
        envBody.appendChild(li);
      });
    } else {
      var li = document.createElement("li");
      var left = document.createElement("span");
      var right = document.createElement("span");
      left.textContent = "Environment data";
      right.textContent = "Not Available";
      li.appendChild(left);
      li.appendChild(right);
      envBody.appendChild(li);
    }
  }

  // 5. Dynamic WaveDrom pages (one test sequence per page)
  function buildWaveDromPages() {
    var waveHost = document.getElementById("wavedromPageHost");
    if (!waveHost) return;

    var waveData = reportData.wavedrom || {};
    var cases = normalizeArray(waveData.cases);
    if (cases.length === 0) return;

    cases.forEach(function (caseItem, idx) {
      var section = document.createElement("section");
      section.className = "report-page report-page-wave";
      section.setAttribute("data-page-wave-index", String(idx + 1));

      var title = document.createElement("h2");
      title.className = "page-title";
      title.textContent = "Timing Diagram - " + textOr(caseItem.name, "Unnamed Case");
      section.appendChild(title);

      var sub = document.createElement("p");
      sub.className = "page-sub";
      sub.textContent =
        "Status: " +
        textOr(caseItem.status, "N/A") +
        " | Time: " +
        textOr(caseItem.startTime, "0") +
        " ~ " +
        textOr(caseItem.endTime, "0") +
        (waveData.timescale ? " (" + waveData.timescale + ")" : "");
      section.appendChild(sub);

      var panel = document.createElement("div");
      panel.className = "panel wavedrom-panel";
      section.appendChild(panel);

      if (caseItem.wavedrom && Array.isArray(caseItem.wavedrom.signal) && caseItem.wavedrom.signal.length > 0) {
        var script = document.createElement("script");
        script.type = "WaveDrom";
        script.text = JSON.stringify(caseItem.wavedrom);
        panel.appendChild(script);
      } else {
        panel.textContent = "No waveform payload in this case.";
      }

      if (Array.isArray(caseItem.signals) && caseItem.signals.length > 0) {
        var hint = document.createElement("div");
        hint.className = "hint";
        hint.textContent = "Signals: " + caseItem.signals.join(", ");
        section.appendChild(hint);
      }

      waveHost.appendChild(section);
    });

    if (window.WaveDrom && typeof window.WaveDrom.ProcessAll === "function") {
      window.WaveDrom.ProcessAll();
    }
  }

  buildWaveDromPages();

  // Pagination logic
  var pages = Array.prototype.slice.call(document.querySelectorAll(".report-page"));
  var indicator = document.getElementById("pageIndicator");
  var btnPrev = document.getElementById("btnPrev");
  var btnNext = document.getElementById("btnNext");
  var current = 0;

  function renderPage() {
    pages.forEach(function (page, idx) {
      if (idx === current) page.classList.add("active");
      else page.classList.remove("active");
    });

    if (indicator) indicator.textContent = String(current + 1) + " / " + String(pages.length);
    if (btnPrev) btnPrev.disabled = current === 0;
    if (btnNext) btnNext.disabled = current === pages.length - 1;
  }

  function move(step) {
    var next = current + step;
    if (next < 0 || next >= pages.length) return;
    current = next;
    renderPage();
  }

  if (btnPrev) btnPrev.addEventListener("click", function () { move(-1); });
  if (btnNext) btnNext.addEventListener("click", function () { move(1); });

  document.addEventListener("keydown", function (event) {
    var modal = document.getElementById("schematic-modal");
    var modalOpen = modal && modal.style.display === "flex";
    if (modalOpen) return;
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      move(-1);
    }
    if (event.key === "ArrowRight") {
      event.preventDefault();
      move(1);
    }
  });

  renderPage();
})();
