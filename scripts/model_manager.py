#!/usr/bin/env python3
import sys
import os
import shutil
import tempfile
import subprocess
from pathlib import Path

# --- Configuration ---
# Hardcoded paths for Docker environment
SCRIPT_DIR = Path("/opt")
WORKFLOW_DIR = Path("/opt/comfy-workflows")

# --- Mappings ---
WORKFLOW_MAPPINGS = [
    # Hunyuan 1.5
    {
        "keywords": ["Hunyuan", "i2v"], 
        "script": "get_hunyuan15.sh", 
        "args": ["common", "720p-i2v", "lora"],
        "name": "HunyuanVideo 1.5 - Image to Video (720p)"
    },
    {
        "keywords": ["Hunyuan", "t2v"], 
        "script": "get_hunyuan15.sh", 
        "args": ["common", "720p-t2v", "lora"],
        "name": "HunyuanVideo 1.5 - Text to Video (720p)"
    },
    
    # Wan 2.2
    {
        "keywords": ["Wan2.2", "I2V", "A14B"], 
        "script": "get_wan22.sh", 
        "args": ["common", "14b-i2v", "lora"],
        "name": "Wan 2.2 - Image to Video (14B)"
    },
    {
        "keywords": ["Wan2.2", "T2V", "A14B"], 
        "script": "get_wan22.sh", 
        "args": ["common", "14b-t2v", "lora"],
        "name": "Wan 2.2 - Text to Video (14B)"
    },

    # Qwen Image
    {
        "keywords": ["Qwen-Image", "LoRA"],
        "script": "get_qwen_image.sh", 
        "args": ["3"], # 3 = Qwen-Image-Lightning LoRA
        "name": "Qwen Image + Lightning LoRA (4-steps)"
    },
    {
        "keywords": ["Qwen-Image"],
        "script": "get_qwen_image.sh", 
        "args": ["1"], # 1 = Qwen-Image (20B)
        "name": "Qwen Image (Base 20B)"
    },

    # Qwen Edit
    {
         "keywords": ["Qwen-Image-Edit", "LoRA"],
         "script": "get_qwen_image.sh",
         "args": ["4"], # 4 = Qwen-Image-Edit-Lightning LoRA
         "name": "Qwen Image Edit + Lightning LoRA"
    },
    {
         "keywords": ["Qwen-Image-Edit"],
         "script": "get_qwen_image.sh",
         "args": ["2"], # 2 = Qwen-Image-Edit 2511
         "name": "Qwen Image Edit (Base)"
    }
]

def check_dependencies():
    """Checks if dialog is installed."""
    if not shutil.which("dialog"):
        print("Error: 'dialog' is required. Please install it (e.g., apt-get install dialog).")
        sys.exit(1)

def run_dialog(args):
    """Runs dialog and returns stderr (selection)."""
    with tempfile.NamedTemporaryFile(mode="w+") as tf:
        cmd = ["dialog"] + args
        try:
            subprocess.run(cmd, stderr=tf, check=True)
            tf.seek(0)
            return tf.read().strip()
        except subprocess.CalledProcessError:
            return None # User cancelled

def find_workflows():
    """Scans workflow directory and maps them to download actions."""
    if not WORKFLOW_DIR.exists():
        run_dialog(["--msgbox", f"Error: Workflow directory not found at:\n{WORKFLOW_DIR}\n\nMake sure you are running inside the Docker container.", "12", "60"])
        sys.exit(1)
        return []

    found_workflows = []
    
    for json_file in WORKFLOW_DIR.glob("*.json"):
        filename = json_file.name
        best_match = None
        
        for mapping in WORKFLOW_MAPPINGS:
            # Check for keyword match
            if all(k in filename for k in mapping["keywords"]):
                # Conflict resolution for Qwen Edit vs Qwen Image
                if "Qwen-Image" in mapping["keywords"] and "Edit" not in mapping["keywords"]:
                     if "Edit" in filename:
                         continue 
                
                best_match = mapping
                break
        
        if best_match:
            found_workflows.append({
                "file": filename,
                "config": best_match
            })
        else:
            found_workflows.append({
                "file": filename,
                "config": {
                    "name": f"Unknown: {filename}",
                    "script": None,
                    "args": []
                }
            })
            
    found_workflows.sort(key=lambda x: x["config"]["name"])
    return found_workflows

def execute_download(script_name, args):
    """Executes the download script using dialog --programbox."""
    script_path = SCRIPT_DIR / script_name
    
    if not script_path.exists():
        script_path = Path(script_name)
        if not script_path.exists():
             run_dialog(["--msgbox", f"Script not found:\n{script_name}", "10", "60"])
             return

    cmds = []
    for arg in args:
        cmds.append(f"bash {script_path} {arg}")
        
    full_cmd = " && ".join(cmds)
    
    # Run directly in terminal to allow native progress bars (TTY)
    # We clear screen first to make it look clean
    subprocess.run(["clear"])
    print(f"Executing: {full_cmd}")
    print("-" * 60)
    
    try:
        # Use shell=True so && and bash work expectedly
        subprocess.run(full_cmd, shell=True)
    except KeyboardInterrupt:
        print("\nProcess interrupted by user.")
    
    print("-" * 60)
    input("Press Enter to return to the menu...")

def main():
    check_dependencies()
    
    while True:
        workflows = find_workflows()
        
        menu_items = []
        for i, wf in enumerate(workflows):
            menu_items.extend([str(i), f"{wf['config']['name']}"])

        choice = run_dialog([
            "--clear", "--backtitle", "AMD Ryzen AI Max \"Strix Halo\" ComfyUI Model Manager",
            "--title", "Select Workflow to Download Models",
            "--cancel-label", "Exit",
            "--menu", "Select a workflow to install dependencies for:", "30", "120", "20"
        ] + menu_items)


        if not choice:
            subprocess.run(["clear"])
            sys.exit(0)
            
        selected = workflows[int(choice)]
        config = selected["config"]
        
        if not config["script"]:
             run_dialog(["--msgbox", f"No download script mapped for:\n{selected['file']}", "10", "60"])
             continue
             
        confirm_msg = (
            f"Workflow: {selected['file']}\n"
            f"Action:   Download dependencies using {config['script']}\n"
            f"Targets:  {', '.join(config['args'])}\n\n"
            "Proceed?"
        )
        
        try:
            subprocess.run(["dialog", "--yesno", confirm_msg, "12", "70"], check=True)
            # Exit code 0 means Yes
            execute_download(config["script"], config["args"])
            
            run_dialog(["--msgbox", "Download process finished.\nCheck output for any errors.", "8", "50"])
            
        except subprocess.CalledProcessError:
            pass # No/Cancel

if __name__ == "__main__":
    main()
