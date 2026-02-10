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
    if (/[%]$/.test(txt)) {
      return txt;
    }
    return txt + "%";
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

  var reportData = window.REPORT_DATA;
  if (!reportData || typeof reportData !== "object") {
    reportData = {};
  }
  window.reportData = reportData;

  var diagram = reportData.blockDiagram || {};
  var diagramImage = document.getElementById("blockDiagramImage");
  var diagramEmpty = document.getElementById("blockDiagramEmpty");
  var diagramSource = document.getElementById("diagramSource");

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

  var timing = reportData.timing || {};
  var kpiWns = document.getElementById("kpiWns");
  document.getElementById("kpiTns").textContent = textOr(timing.tns, "N/A");
  document.getElementById("kpiWhs").textContent = textOr(timing.whs, "N/A");
  document.getElementById("kpiThs").textContent = textOr(timing.ths, "N/A");
  kpiWns.textContent = textOr(timing.wns, "N/A");

  var wnsNum = parseFloat(timing.wns);
  kpiWns.style.color = !isNaN(wnsNum) && wnsNum < 0 ? "#b91c1c" : "#0f172a";

  var timingBody = document.getElementById("timingTableBody");
  addRow(timingBody, "Slack (ns)", textOr(timing.wns, "N/A"), textOr(timing.whs, "N/A"), textOr(timing.tpws, "N/A"));
  addRow(timingBody, "Total Negative Slack", textOr(timing.tns, "N/A"), textOr(timing.ths, "N/A"), textOr(timing.tpws, "N/A"));
  addRow(timingBody, "Total Endpoints", textOr(timing.totalEndpoints, "N/A"), "-", "-");

  var util = reportData.utilization || {};
  var utilBody = document.getElementById("utilTableBody");
  addRow(utilBody, "Slice LUTs", textOr(util.lutsUsed, "0"), textOr(util.lutsAvail, "0"), toPercent(util.lutsPerc));
  addRow(utilBody, "Slice Registers", textOr(util.regsUsed, "0"), textOr(util.regsAvail, "0"), toPercent(util.regsPerc));

  if (Array.isArray(util.io) && util.io.length > 0) {
    util.io.forEach(function (row) {
      addRow(
        utilBody,
        textOr(row.name, "IO"),
        textOr(row.used, "0"),
        textOr(row.avail, "0"),
        toPercent(row.perc)
      );
    });
  } else {
    addRow(utilBody, "Additional IO utilization", "N/A", "N/A", "N/A");
  }

  var envBody = document.getElementById("envListBody");
  if (Array.isArray(reportData.environment) && reportData.environment.length > 0) {
    reportData.environment.forEach(function (item) {
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

  var pages = Array.prototype.slice.call(document.querySelectorAll(".report-page"));
  var indicator = document.getElementById("pageIndicator");
  var btnPrev = document.getElementById("btnPrev");
  var btnNext = document.getElementById("btnNext");
  var current = 0;

  function renderPage() {
    pages.forEach(function (page, idx) {
      if (idx === current) {
        page.classList.add("active");
      } else {
        page.classList.remove("active");
      }
    });
    indicator.textContent = String(current + 1) + " / " + String(pages.length);
    btnPrev.disabled = current === 0;
    btnNext.disabled = current === pages.length - 1;
  }

  function move(step) {
    var next = current + step;
    if (next < 0 || next >= pages.length) {
      return;
    }
    current = next;
    renderPage();
  }

  btnPrev.addEventListener("click", function () { move(-1); });
  btnNext.addEventListener("click", function () { move(1); });
  document.addEventListener("keydown", function (event) {
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
