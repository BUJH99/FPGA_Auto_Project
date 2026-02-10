const fs = require('fs');

const jsonFile = process.argv[2];
const htmlFile = process.argv[3];

if (!jsonFile || !htmlFile) {
    console.error("Usage: node create_sim_report.js <input.json> <output.html>");
    process.exit(1);
}

const jsonData = fs.readFileSync(jsonFile, 'utf-8');

const htmlContent = `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Simulation Timing Diagram</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/wavedrom/3.5.0/skins/default.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/wavedrom/3.5.0/wavedrom.min.js"></script>
<style>
body { font-family: Arial, sans-serif; margin: 20px; }
.scroll-container { overflow-x: auto; border: 1px solid #ccc; padding: 10px; }
</style>
</head>
<body onload="WaveDrom.ProcessAll()">
<h2>Simulation Timing Diagram (Excerpt)</h2>
<p>Generated from Vivado Simulation VCD</p>
<div class="scroll-container">
<script type="WaveDrom">
${jsonData}
</script>
</div>
</body>
</html>`;

fs.writeFileSync(htmlFile, htmlContent);
console.log(`Generated HTML report: ${htmlFile}`);
