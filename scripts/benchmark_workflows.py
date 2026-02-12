#!/usr/bin/env python3
import argparse
import json
import uuid
import random
import urllib.request
import urllib.parse
import urllib.error
import time
import os
import subprocess
import sys
import shutil

try:
    import websocket # NOTE: This requires `pip install websocket-client`
except ImportError:
    print("Error: 'websocket-client' library not found. Please install it using: pip install websocket-client")
    exit(1)

def queue_prompt(server_address, prompt, client_id):
    p = {"prompt": prompt, "client_id": client_id}
    data = json.dumps(p).encode('utf-8')
    req = urllib.request.Request("http://{}/prompt".format(server_address), data=data)
    return json.loads(urllib.request.urlopen(req).read())

def get_history(server_address, prompt_id):
    with urllib.request.urlopen("http://{}/history/{}".format(server_address, prompt_id)) as response:
        return json.loads(response.read())

def track_execution(ws, prompt_id):
    """
    Listen to the websocket for execution updates for a specific prompt_id.
    Returns the execution time in seconds (or None if failed).
    """
    start_time = None
    end_time = None
    
    while True:
        out = ws.recv()
        if isinstance(out, str):
            message = json.loads(out)
            if message['type'] == 'executing':
                data = message['data']
                if data['node'] is None and data['prompt_id'] == prompt_id:
                     # Execution finished
                     end_time = time.time()
                     break
                elif data['prompt_id'] == prompt_id and start_time is None:
                    # Execution started (first node)
                     start_time = time.time()
            elif message['type'] == 'execution_start':
                # Alternative start signal
                 if message['data']['prompt_id'] == prompt_id:
                    start_time = time.time()
            elif message['type'] == 'execution_error':
                 if message['data']['prompt_id'] == prompt_id:
                     print(f"Error executing prompt {prompt_id}: {message['data']}")
                     return None
    
    if start_time and end_time:
        return end_time - start_time
    return 0 

def benchmark_workflow(server_address, workflow_file, randomize_seed=False):
    print(f"Loading workflow: {workflow_file}")
    with open(workflow_file, 'r') as f:
        prompt_workflow = json.load(f)

    if randomize_seed:
        # Helper to randomize seeds in input
        updated_count = 0
        for node_id, node in prompt_workflow.items():
            if "inputs" in node:
                for key in ["seed", "noise_seed"]:
                    if key in node["inputs"]:
                        # Generate a random integer within safe JS integer range
                        new_seed = random.randint(1, 100000000000000)
                        node["inputs"][key] = new_seed
                        updated_count += 1
                        # print(f"Updated {key} in node {node_id} to {new_seed}")
        if updated_count > 0:
            print(f"Randomized {updated_count} seeds.")

    # Connect WebSocket
    client_id = str(uuid.uuid4())
    ws = websocket.WebSocket()
    try:
        ws.connect("ws://{}/ws?clientId={}".format(server_address, client_id))
    except Exception as e:
        print(f"Failed to connect to websocket: {e}")
        return None

    # Submit prompt
    try:
        response = queue_prompt(server_address, prompt_workflow, client_id)
        prompt_id = response['prompt_id']
        print(f"Submitted. Prompt ID: {prompt_id}")
    except Exception as e:
        print(f"Failed to queue prompt: {e}")
        ws.close()
        return None

    # Measure Wall Clock from SUBMISSION to COMPLETION
    wall_start = time.time()
    
    execution_complete = False
    error = False
    
    while not execution_complete:
        try:
            out = ws.recv()
            if isinstance(out, str):
                message = json.loads(out)
                if message['type'] == 'executing':
                    data = message['data']
                    if data['node'] is None and data['prompt_id'] == prompt_id:
                        execution_complete = True
                elif message['type'] == 'execution_error':
                     if message['data']['prompt_id'] == prompt_id:
                         error = True
                         execution_complete = True
        except Exception as e:
            print(f"WebSocket error: {e}")
            error = True
            break
    
    wall_end = time.time()
    ws.close()

    if error:
        print("Workflow failed.")
        return None
    
    duration = wall_end - wall_start
    print(f"Finished in {duration:.2f}s")
    return duration

def wait_for_server(url, timeout=60):
    start = time.time()
    print(f"Waiting for server at {url}...", end="", flush=True)
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
    parser = argparse.ArgumentParser(description="Benchmark ComfyUI Workflows")
    parser.add_argument("--workflow-dir", default="/opt/comfy-workflows", help="Directory containing API-format workflow JSON files")
    parser.add_argument("--comfy-dir", default="/opt/ComfyUI", help="ComfyUI installation directory")
    parser.add_argument("--server", default="localhost:8000", help="Address of ComfyUI server (host:port)") 
    parser.add_argument("--output", default="benchmark_results.json", help="Output JSON file for results")
    parser.add_argument("--skip-errors", action="store_true", help="Continue regular execution if a workflow fails")
    parser.add_argument("--warm-start", action="store_true", help="Run a second 'warm start' execution for each workflow")

    args = parser.parse_args()
    
    if not os.path.isdir(args.workflow_dir):
        print(f"Error: Directory {args.workflow_dir} not found.")
        return

    files = sorted([f for f in os.listdir(args.workflow_dir) if f.endswith('.json')])
    
    if not files:
        print("No JSON workflows found.")
        return

    # Define absolute path for output
    output_path = os.path.abspath(args.output)
    print(f"Results will be saved to: {output_path}")

    # Load existing results for caching
    results = []
    if os.path.exists(output_path):
        try:
            with open(output_path, 'r') as f:
                results = json.load(f)
                print(f"Loaded {len(results)} existing results.")
        except Exception as e:
            print(f"Warning: Could not load existing results: {e}")

    # Define configurations
    configs = [
        {"name": "default", "env": {}}
    ]

    server_host, server_port = args.server.split(':')
    server_url = f"http://{args.server}"
    
    home_dir = os.path.expanduser("~")
    miopen_dir = os.path.join(home_dir, ".miopen")

    print(f"Found {len(files)} workflows.")
    
    for config in configs:
        print(f"\n=== Starting Configuration: {config['name']} ===")
        
        for i, filename in enumerate(files):
            # Check if result already exists
            # Treat missing 'config' as 'default' for backward compatibility
            existing = next((r for r in results if r['workflow'] == filename and r.get('config', 'default') == config['name']), None)
            if existing:
                print(f"Skipping {filename} ({config['name']}) - already done.")
                continue

            print(f"\n[{i+1}/{len(files)}] Benchmarking {filename} [{config['name']}]")
            filepath = os.path.join(args.workflow_dir, filename)
            
            # Prepare environment
            server_env = os.environ.copy()
            server_env.update(config['env'])
            
            # 1. Clean .miopen (Optional but recommended for consistency)
            if os.path.exists(miopen_dir):
                shutil.rmtree(miopen_dir)
            
            # 2. Start Server
            comfy_outputs_dir = os.path.join(home_dir, "comfy-outputs")
            comfy_cmd = [
                sys.executable, "main.py",
                "--port", server_port,
                "--output-directory", comfy_outputs_dir,
                "--disable-mmap", "--bf16-vae", "--gpu-only"
            ]
            
            log_file = open("server.log", "w") # Overwrite log for each run
            print(f"Starting server with env: {config['env']}")
            
            process = subprocess.Popen(
                comfy_cmd,
                cwd=args.comfy_dir,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                env=server_env
            )
            
            try:
                if not wait_for_server(server_url):
                    print("Server failed to start.")
                    if not args.skip_errors:
                        process.terminate()
                        break
                    continue

                # 3. Run Benchmark
                try:
                    print("--> Cold Start Run...")
                    duration_cold = benchmark_workflow(args.server, filepath, randomize_seed=True)
                    
                    duration_warm = None
                    if duration_cold is not None and args.warm_start:
                        print("--> Warm Start Run...")
                        duration_warm = benchmark_workflow(args.server, filepath, randomize_seed=True)

                    status = "success" if duration_cold is not None else "failure"
                    
                    result_entry = {
                        "workflow": filename,
                        "config": config['name'],
                        "status": status,
                        "duration_seconds": duration_cold if duration_cold else 0, # Keep for backward compatibility
                        "cold_run_seconds": duration_cold if duration_cold else 0,
                        "warm_run_seconds": duration_warm if duration_warm else 0,
                        "timestamp": time.time(),
                        "env": config['env']
                    }
                    
                    results.append(result_entry)
                    
                    # Save incremental results
                    try:
                        with open(output_path, 'w') as f:
                            json.dump(results, f, indent=2)
                        print(f"Satisfactorily saved results to {output_path}")
                    except PermissionError:
                         print(f"CRITICAL ERROR: Permission denied when writing to {output_path}")
                    except OSError as e:
                         print(f"CRITICAL ERROR: OS error when writing to {output_path}: {e}")
                    except Exception as e:
                         print(f"CRITICAL ERROR: Failed to write results to {output_path}: {e}")
                        
                except Exception as e:
                    print(f"Exception running workflow: {e}")
                    if not args.skip_errors:
                         raise
            
            finally:
                # 4. Stop Server
                print("Stopping server...")
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                log_file.close()

    print(f"\nAll benchmarks complete. Results saved to {output_path}")

if __name__ == "__main__":
    main()
