function renderSimulationHtmlReport(projectName, generatedFiles) {
  let html = `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>${projectName} - Simulation Report</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/wavedrom/3.5.0/skins/default.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/wavedrom/3.5.0/wavedrom.min.js"></script>
<style>
body { font-family: 'Segoe UI', Arial, sans-serif; margin: 0; padding: 20px; background-color: #f4f7f6; color: #333; }
.header { text-align: center; margin-bottom: 40px; padding-bottom: 20px; border-bottom: 1px solid #ddd; }
.header h1 { margin: 0; color: #2c3e50; }
.header p { color: #7f8c8d; }
.wave-card {
  background: white;
  border-radius: 8px;
  box-shadow: 0 2px 10px rgba(0,0,0,0.05);
  padding: 20px;
  margin-bottom: 30px;
}
.wave-card h2 { margin-top: 0; font-size: 1.2rem; color: #2980b9; border-left: 4px solid #3498db; padding-left: 10px; }
.wave-card p { color: #666; font-size: 0.9rem; margin-bottom: 15px; }
.wave-view { overflow-x: auto; padding: 10px 0; }
</style>
</head>
<body onload="WaveDrom.ProcessAll()">
<div class="header">
  <h1>${projectName}</h1>
  <p>Simulation Report | Generated on ${new Date().toLocaleString()}</p>
</div>
`;

  for (const item of generatedFiles || []) {
    const endNs = item.start_ns + item.duration_ns;
    const runtimeInfo = `Runtime: ${item.duration_ns} ns (Window: ${item.start_ns} ns ~ ${endNs} ns)`;
    html += `
<div class="wave-card">
  <h2>${item.title}</h2>
  <p>${runtimeInfo}</p>
  ${item.description ? `<p>${item.description}</p>` : ""}
  <div class="wave-view">
    <script type="WaveDrom">
${item.jsonData}
    </script>
  </div>
</div>
`;
  }

  if (!generatedFiles || generatedFiles.length === 0) {
    html += `
<div class="wave-card">
  <h2>No Waveforms</h2>
  <p>No scenario produced output JSON. Check TEST/@WAVE/@RUNTIME BEGIN:time and END:time directives in your testbench.</p>
</div>
`;
  }

  html += `
</body>
</html>`;
  return html;
}

module.exports = {
  renderSimulationHtmlReport,
};
