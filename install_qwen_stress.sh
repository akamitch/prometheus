#!/bin/bash
set -e

echo "============================================"
echo " Qwen GPU Stress Test – Installer"
echo "============================================"

# -------- Папка установки --------
INSTALL_DIR="${HOME}/qwen-stress"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "[+] Installing into: $INSTALL_DIR"
echo

# -------- Проверка nvidia-smi --------
if ! command -v nvidia-smi &>/dev/null; then
    echo "❌ ERROR: nvidia-smi not found."
    echo "Убедитесь, что NVIDIA-драйвер установлен."
    exit 1
fi

echo "[+] NVIDIA drivers detected."
echo

# -------- Устанавливаем зависимости для Python --------
echo "[+] Installing Python venv support..."
sudo apt update
sudo apt install -y python3 python3-venv python3-dev git

# -------- Создание VENV --------
echo "[+] Creating Python venv..."
python3 -m venv venv
source venv/bin/activate

echo "[+] Upgrading pip..."
pip install --upgrade pip

# -------- Установка Torch + Transformers --------
echo "[+] Installing PyTorch (CUDA) and HF libraries..."
pip install torch --index-url https://download.pytorch.org/whl/cu121
pip install transformers accelerate einops

echo
echo "[+] Dependencies installed."
echo

# -------- Загружаем рабочие файлы --------
echo "[+] Creating core scripts..."

# stress_qwen.py
cat > stress_qwen.py << 'EOF'
import argparse
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

parser = argparse.ArgumentParser()
parser.add_argument("--model", type=str, default="Qwen/Qwen2-7B-Instruct")
args = parser.parse_args()

print(f"[stress] Loading model: {args.model}", flush=True)

tokenizer = AutoTokenizer.from_pretrained(args.model)

model = AutoModelForCausalLM.from_pretrained(
    args.model,
    torch_dtype=torch.bfloat16,
    device_map="auto"
)

prompt = "This is a Qwen-based GPU stress test. The model will generate continuously."

print("[stress] Starting infinite generation loop...", flush=True)

while True:
    inputs = tokenizer(prompt, return_tensors="pt").to("cuda")
    _ = model.generate(
        **inputs,
        max_new_tokens=2048,
        do_sample=True,
        temperature=1.0,
        top_p=0.9,
    )
EOF

# monitor_nvidia.py
cat > monitor_nvidia.py << 'EOF'
import argparse
import subprocess
import time
import csv
import json
import datetime as dt
import sys
from pathlib import Path

def run_cmd(cmd):
    return subprocess.check_output(cmd, stderr=subprocess.STDOUT).decode("utf-8")

def poll_gpus():
    cmd = [
        "nvidia-smi",
        "--query-gpu=index,temperature.gpu,utilization.gpu,utilization.memory,"
        "memory.used,memory.total,power.draw,clocks.sm,clocks.mem",
        "--format=csv,noheader,nounits",
    ]
    out = run_cmd(cmd)
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    rows = []
    for line in lines:
        parts = [p.strip() for p in line.split(",")]
        rows.append(
            {
                "index": int(parts[0]),
                "temperature": float(parts[1]),
                "util_gpu": float(parts[2]),
                "util_mem": float(parts[3]),
                "mem_used_mb": float(parts[4]),
                "mem_total_mb": float(parts[5]),
                "power_w": float(parts[6]) if parts[6] not in ("[Not Supported]", "N/A") else None,
                "clock_sm_mhz": float(parts[7]),
                "clock_mem_mhz": float(parts[8]),
            }
        )
    return rows

def log_ecc_perf(ecc_log_path: Path):
    try:
        out = run_cmd(["nvidia-smi", "-q", "-d", "ECC,PERFORMANCE,POWER"])
    except Exception as e:
        with ecc_log_path.open("a") as f:
            f.write(f"\n===== {dt.datetime.now().isoformat()} (error reading ECC) =====\n{e}\n")
        return

    with ecc_log_path.open("a") as f:
        f.write(f"\n===== {dt.datetime.now().isoformat()} =====\n")
        f.write(out)
        f.write("\n")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration-minutes", type=float, default=30.0)
    parser.add_argument("--temp-limit", type=float, default=85.0)
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--csv", type=str, required=True)
    parser.add_argument("--json", type=str, required=True)
    parser.add_argument("--ecc-log", type=str, required=True)
    args = parser.parse_args()

    csv_path = Path(args.csv)
    json_path = Path(args.json)
    ecc_log_path = Path(args.ecc_log)

    csv_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    ecc_log_path.parent.mkdir(parents=True, exist_ok=True)

    start = time.time()
    end = start + args.duration_minutes * 60.0
    next_ecc = start
    header_written = False

    print(
        f"[monitor] duration={args.duration_minutes} min, "
        f"temp_limit={args.temp_limit}°C, interval={args.interval}s"
    )

    with csv_path.open("w", newline="") as csvfile, json_path.open("w") as jsonfile:
        writer = csv.writer(csvfile)

        while True:
            now = time.time()
            if now >= end:
                print("[monitor] Time limit reached, finishing.")
                return 0

            try:
                rows = poll_gpus()
            except Exception as e:
                print(f"[monitor] ERROR polling nvidia-smi: {e}", file=sys.stderr)
                return 1

            ts = dt.datetime.now().isoformat()
            if not header_written:
                writer.writerow(
                    [
                        "timestamp","gpu_index","temperature_c","util_gpu_percent",
                        "util_mem_percent","mem_used_mb","mem_total_mb",
                        "power_w","clock_sm_mhz","clock_mem_mhz"
                    ]
                )
                header_written = True

            max_temp = max(r["temperature"] for r in rows)

            for r in rows:
                writer.writerow(
                    [
                        ts,
                        r["index"],
                        r["temperature"],
                        r["util_gpu"],
                        r["util_mem"],
                        r["mem_used_mb"],
                        r["mem_total_mb"],
                        r["power_w"],
                        r["clock_sm_mhz"],
                        r["clock_mem_mhz"],
                    ]
                )
                csvfile.flush()

                rec = {
                    "timestamp": ts,
                    "gpu_index": r["index"],
                    "temperature_c": r["temperature"],
                    "util_gpu_percent": r["util_gpu"],
                    "util_mem_percent": r["util_mem"],
                    "mem_used_mb": r["mem_used_mb"],
                    "mem_total_mb": r["mem_total_mb"],
                    "power_w": r["power_w"],
                    "clock_sm_mhz": r["clock_sm_mhz"],
                    "clock_mem_mhz": r["clock_mem_mhz"],
                }
                jsonfile.write(json.dumps(rec, ensure_ascii=False) + "\n")
                jsonfile.flush()

            if max_temp >= args.temp_limit:
                print(
                    f"[monitor] Temperature limit exceeded: {max_temp}°C >= {args.temp_limit}°C",
                    file=sys.stderr,
                )
                return 2

            if now >= next_ecc:
                log_ecc_perf(ecc_log_path)
                next_ecc = now + 60.0

            time.sleep(args.interval)

if __name__ == "__main__":
    sys.exit(main())
EOF

# qwen_gpu_stress.sh (основной)
cat > qwen_gpu_stress.sh << 'EOF'
#!/bin/bash
set -e

MODEL="Qwen/Qwen2-7B-Instruct"
LOGDIR="./qwen_stress_logs"
PY_STRESS="stress_qwen.py"
PY_MONITOR="monitor_nvidia.py"
VENV_DIR="./venv"

DURATION_MIN=${DURATION_MIN:-30}
TEMP_LIMIT=${TEMP_LIMIT:-85}
INTERVAL_SEC=${INTERVAL_SEC:-5}

echo "============================================"
echo "      Qwen GPU Stress Test"
echo "============================================"

source "$VENV_DIR/bin/activate"

mkdir -p "$LOGDIR"

GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l || echo 0)
echo "Detected GPUs: $GPU_COUNT"
echo "Test duration : ${DURATION_MIN} min"
echo "Temp limit    : ${TEMP_LIMIT}°C"
echo

if [ "$GPU_COUNT" -eq 0 ]; then
    echo "ERROR: No NVIDIA GPUs detected."
    exit 1
fi

PIDS=()

if [ "$GPU_COUNT" -eq 1 ]; then
    echo "[Single GPU Mode]"
    CUDA_VISIBLE_DEVICES=0 python3 "$PY_STRESS" --model "$MODEL" \
        > "$LOGDIR/gpu_0.log" 2>&1 &
    PIDS+=($!)
else
    echo "[Multi-GPU Mode]"
    for GPU in $(seq 0 $((GPU_COUNT-1))); do
        CUDA_VISIBLE_DEVICES=$GPU python3 "$PY_STRESS" --model "$MODEL" \
            > "$LOGDIR/gpu_${GPU}.log" 2>&1 &
        PIDS+=($!)
    done
fi

CSV_PATH="$LOGDIR/metrics.csv"
JSON_PATH="$LOGDIR/metrics.jsonl"
ECC_LOG="$LOGDIR/ecc_throttle.log"

python3 "$PY_MONITOR" \
    --duration-minutes "$DURATION_MIN" \
    --temp-limit "$TEMP_LIMIT" \
    --interval "$INTERVAL_SEC" \
    --csv "$CSV_PATH" \
    --json "$JSON_PATH" \
    --ecc-log "$ECC_LOG"

MON_EXIT=$?

for PID in "${PIDS[@]}"; do
    kill "$PID" 2>/dev/null || true
done

echo "All stress processes stopped."

if [ "$MON_EXIT" -eq 0 ]; then
    echo "Finished by time limit."
elif [ "$MON_EXIT" -eq 2 ]; then
    echo "Stopped due to overheating."
else
    echo "Monitor exited with error."
fi

echo "CSV log : $CSV_PATH"
echo "JSON log: $JSON_PATH"
echo "ECC log : $ECC_LOG"
EOF

chmod +x qwen_gpu_stress.sh

echo
echo "============================================"
echo " Installation complete!"
echo " Run test:"
echo "   cd $INSTALL_DIR"
echo "   ./qwen_gpu_stress.sh"
echo "============================================"
