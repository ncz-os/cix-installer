import subprocess
import json


def run_noe_engine_benchmark(model_path: str, inputs: dict) -> dict:
    """
    Run the noe_engine_benchmark CLI and return parsed results.

    Args:
        model_path: Path to the ONNX model.
        inputs: Dictionary of input names and numpy arrays.

    Returns:
        Parsed JSON output from the benchmark CLI.
    """
    # This is a placeholder. The actual implementation would serialize
    # inputs to a file, call the CLI, and parse the output.
    cmd = ["noe_engine_benchmark", "--model", model_path]
    # In practice, you'd pass input data via files or other means
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Benchmark failed: {result.stderr}")
    return json.loads(result.stdout)
