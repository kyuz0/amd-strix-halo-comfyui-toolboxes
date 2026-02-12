#!/usr/bin/env python3
import os
import sys
import time
import subprocess
import shutil
import glob
import argparse
import urllib.request
import urllib.error

# Add current directory to path to allow importing benchmark_workflows if running from scripts/
current_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.append(current_dir)
# Also try parent dir/scripts if needed (though Dockerfile puts them flat in /opt)
sys.path.append(os.path.join(current_dir, 'scripts'))

try:
    import benchmark_workflows
except ImportError:
    # Fallback: simple check if it exists in current dir
    if os.path.exists(os.path.join(current_dir, 'benchmark_workflows.py')):
         # This block handles the case where simple import fails for some reason or structure differs
         pass
    else:
         print("Warning: 'benchmark_workflows.py' not found in python path. Ensure it is alongside this script.")

def wait_for_server(url, timeout=60):
    start = time.time()
    print(f"  Waiting for server at {url}...", end="", flush=True)
    while time.time() - start < timeout:
        try:
            with urllib.request.urlopen(url, timeout=1) as response:
                if response.status == 200:
                    print(" Ready!")
                    return True
        except Exception:
            time.sleep(1)
            print(".", end="", flush=True)
    print(" Timeout!")
    return False

def main():
    parser = argparse.ArgumentParser(description="Collect ComfyUI per-workflow performance logs")
    parser.add_argument("--workflow-dir", default="/opt/comfy-workflows", help="Directory containing API-format workflow JSON files")
    parser.add_argument("--logs-dir", default="perf_logs", help="Output directory for collected logs")
    parser.add_argument("--comfy-dir", default="/opt/ComfyUI", help="ComfyUI installation directory")
    args = parser.parse_args()

    # Verify input dir
    if not os.path.isdir(args.workflow_dir):
        print(f"Error: Workflow directory {args.workflow_dir} not found.")
        sys.exit(1)

    files = sorted(glob.glob(os.path.join(args.workflow_dir, "*.json")))
    if not files:
        print(f"No .json workflows found in {args.workflow_dir}")
        return
    
    # Verify module valid
    if 'benchmark_workflows' not in sys.modules:
        print("Error: Could not import benchmark_workflows module. Cannot proceed.")
        sys.exit(1)

    os.makedirs(args.logs_dir, exist_ok=True)
    home_dir = os.path.expanduser("~")
    miopen_dir = os.path.join(home_dir, ".miopen")
    
    # Server config
    server_host = "127.0.0.1"
    server_port = 8000
    server_addr = f"{server_host}:{server_port}"
    server_url = f"http://{server_addr}"
    
    # Define environment variables for the benchmark
    # We enforce these to ensure logs are actually generated
    benchmark_env = os.environ.copy()
    benchmark_env["MIOPEN_ENABLE_LOGGING"] = "1"
    benchmark_env["MIOPEN_ENABLE_LOGGING_CMD"] = "1"
    benchmark_env["HIPBLASLT_LOG_MASK"] = "32"
    benchmark_env["TORCH_BLAS_PREFER_HIPBLASLT"] = "1"
    benchmark_env["COMFYUI_ENABLE_MIOPEN"] = "1"
    
    # We force a specific log filename so we know where to pick it up
    # Make it absolute based on ComfyUI execution dir to avoid CWD confusion
    forced_hip_log_name = os.path.join(os.path.abspath(args.comfy_dir), "benchmark_hipblaslt_log.txt")
    benchmark_env["HIPBLASLT_LOG_FILE"] = forced_hip_log_name
    
    print(f"Found {len(files)} workflows to benchmark.")
    print(f"Logs will be saved to: {os.path.abspath(args.logs_dir)}")
    print(f"Enforcing HIPBLASLT_LOG_FILE: {forced_hip_log_name}")

    for i, workflow_file in enumerate(files):
        workflow_name = os.path.basename(workflow_file).replace(".json", "")
        print(f"\n[{i+1}/{len(files)}] Processing workflow: {workflow_name}")

        # 1. Clean .miopen
        if os.path.exists(miopen_dir):
            print(f"  Cleaning {miopen_dir}...")
            shutil.rmtree(miopen_dir)
        else:
            print(f"  {miopen_dir} not found (fresh start).")

        # 2. Start ComfyUI
        comfy_outputs_dir = os.path.join(home_dir, "comfy-outputs")
        comfy_cmd = [
            sys.executable, "main.py",
            "--port", str(server_port),
            "--output-directory", comfy_outputs_dir,
            "--disable-mmap", "--bf16-vae", "--gpu-only"
        ]
        
        # We capture the server stdout/stderr to this file
        miopen_log_file = "miopen_output_logs.txt"
        if os.path.exists(miopen_log_file):
            os.remove(miopen_log_file)
            
        # Ensure hipBLASLt log is fresh too
        if os.path.exists(forced_hip_log_name):
             os.remove(forced_hip_log_name)

        print(f"  Starting ComfyUI server in {args.comfy_dir}...")
        log_handle = open(miopen_log_file, "w")
        process = subprocess.Popen(
            comfy_cmd,
            cwd=args.comfy_dir,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            env=benchmark_env
        )

        try:
            # 3. Wait for server
            if not wait_for_server(server_url):
                print("  Error: Server failed to start. Check miopen_output_logs.txt for details.")
                continue

            # 4. Run Workflow
            print("  Running workflow...")
            try:
                # Use the imported benchmark logic
                duration = benchmark_workflows.benchmark_workflow(server_addr, workflow_file)
                if duration is not None:
                    print(f"  Success! Duration: {duration:.2f}s")
                else:
                    print("  Workflow returned None (failure).")
            except Exception as e:
                print(f"  Exception during workflow execution: {e}")

        except KeyboardInterrupt:
            print("\nInterrupted by user.")
            process.terminate()
            break
        finally:
            # 5. Stop Server
            print("  Stopping server...")
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                print("  Force killing server...")
                process.kill()
            
            log_handle.close()
        
        # 6. Collect Logs
        print("  Collecting logs...")

        # Process hipBLASLt log
        if os.path.exists(forced_hip_log_name):
            # Sort command for Linux: sort log | uniq -c | sort -nr > sorted_log
            sorted_log_name = f"{workflow_name}_sorted_hipblaslt_log.txt"
            sorted_log_path = os.path.join(args.logs_dir, sorted_log_name)
            
            cmd = f"sort {forced_hip_log_name} | uniq -c | sort -nr > {sorted_log_path}"
            subprocess.run(cmd, shell=True)
            print(f"    Generated {sorted_log_name}")
            
            # Move raw log
            raw_target_path = os.path.join(args.logs_dir, f"{workflow_name}_hipblaslt_log.txt")
            shutil.move(forced_hip_log_name, raw_target_path)
            print(f"    Saved raw log to {os.path.basename(raw_target_path)}")
        else:
            print(f"    WARNING: {forced_hip_log_name} was not generated.")

        # Process MIOpen log
        if os.path.exists(miopen_log_file):
             target_miopen = os.path.join(args.logs_dir, f"{workflow_name}_miopen_output_logs.txt")
             shutil.move(miopen_log_file, target_miopen)
             print(f"    Saved console log to {os.path.basename(target_miopen)}")
        else:
            print("    WARNING: miopen_output_logs.txt was not generated.")

    print("\nBatch collection complete.")

if __name__ == "__main__":
    main()
