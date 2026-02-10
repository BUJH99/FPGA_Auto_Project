import sys
import re
import json

def parse_vcd(vcd_file):
    signals = {}
    timestamp = 0
    id_map = {}
    
    # Simple VCD Parser for specific signals
    # We are interested in 1-bit and small bus signals
    
    with open(vcd_file, 'r') as f:
        lines = f.readlines()
        
    header_done = False
    
    # We want to capture these signals specifically if possible, 
    # but for now let's capture everything defined in the VCD
    
    target_signals = ['iClk100m', 'iRst', 'iUartRx', 'oUartTx', 'iBtnU', 'oSeg']
    wave_data = {sig: [] for sig in target_signals}
    
    for line in lines:
        line = line.strip()
        if '$enddefinitions' in line:
            header_done = True
            continue
            
        if not header_done:
            if '$var' in line:
                parts = line.split()
                # Example: $var wire 1 ! iClk100m $end
                if len(parts) >= 5:
                    var_id = parts[3]
                    var_name = parts[4]
                    if var_name in target_signals:
                        id_map[var_id] = var_name
            continue
            
        if line.startswith('#'):
            timestamp = int(line[1:])
            continue
            
        # Value change: 0! or 1! or b1010 "
        # 1-bit
        if line[0] in ['0', '1', 'x', 'z']:
            val = line[0]
            var_id = line[1:]
            if var_id in id_map:
                name = id_map[var_id]
                wave_data[name].append((timestamp, val))
        # Bus
        elif line.startswith('b'):
            parts = line.split()
            val = parts[0][1:]
            var_id = parts[1]
            if var_id in id_map:
                name = id_map[var_id]
                wave_data[name].append((timestamp, val))

    return wave_data

def generate_wavedrom(wave_data, time_scale=1000):
    # time_scale: compress time (e.g. 1 unit in wavedrom = 1000 time units in VCD)
    
    output = {"signal": [], "head": {"text": "Simulation Timing"}, "config": {"hscale": 1}}
    
    # Find max time
    max_time = 0
    for sig in wave_data:
        if wave_data[sig]:
            max_time = max(max_time, wave_data[sig][-1][0])
            
    # Quantize time
    # WaveDrom string: "0101..." or "====..."
    
    # Let's create a sampling based approach
    # Sample every 'time_scale' ticks
    
    duration = int(max_time / time_scale) + 1
    
    for name, transitions in wave_data.items():
        if not transitions:
            continue
            
        wave_str = ""
        current_val = '0' # Default x or 0
        last_idx = 0
        
        # Initial value
        # Find transition at t=0
        for t, v in transitions:
            if t == 0:
                current_val = v
                break
                
        # Build string
        prev_val_char = '.'
        
        for i in range(duration):
            time_point = i * time_scale
            
            # Find latest value at or before time_point
            val_at_t = current_val
            
            # Update current_val based on transitions
            # Optimize: continue from last_idx
            for k in range(last_idx, len(transitions)):
                t, v = transitions[k]
                if t <= time_point:
                    current_val = v
                    last_idx = k
                else:
                    break
            
            val_at_t = current_val
            
            # Map Value to WaveDrom char
            char = 'x'
            if val_at_t == '0': char = '0'
            elif val_at_t == '1': char = '1'
            elif val_at_t.lower() == 'x': char = 'x'
            elif val_at_t.lower() == 'z': char = 'z'
            else: char = '=' # Bus
            
            # Logic to abbreviate (use '.' for repeat)
            if i > 0 and char == prev_val_char:
                wave_str += '.'
            else:
                wave_str += char
                prev_val_char = char
        
        signal_entry = {"name": name, "wave": wave_str}
        if prev_val_char == '=':
            signal_entry["data"] = "data" # Placeholder for bus data
            
        output["signal"].append(signal_entry)
        
    return output

if __name__ == "__main__":
    vcd_file = sys.argv[1]
    json_file = sys.argv[2]
    
    data = parse_vcd(vcd_file)
    wd = generate_wavedrom(data, time_scale=100000) # Adjust scale for visibility (100us per tick?)
    
    with open(json_file, 'w') as f:
        json.dump(wd, f, indent=2)
        
    print(f"Generate WaveDrom JSON: {json_file}")
