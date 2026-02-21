#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT_EPUB="${1:-}"
OUT_DIR="${2:-$ROOT_DIR/.logs/bench/$(date +%Y%m%d-%H%M%S)}"
PYTHON_BIN="${PYTHON_BIN:-$ROOT_DIR/.venv/bin/python}"

if [[ -z "$INPUT_EPUB" ]]; then
  echo "Usage: $0 <input.epub> [output_dir]"
  exit 1
fi

if [[ ! -f "$INPUT_EPUB" ]]; then
  echo "Input EPUB not found: $INPUT_EPUB"
  exit 1
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  else
    echo "Python interpreter not found. Set PYTHON_BIN or install python3."
    exit 1
  fi
fi

mkdir -p "$OUT_DIR"
SUMMARY_CSV="$OUT_DIR/summary.csv"
echo "run_id,backend,chunk_chars,pipeline_mode,exit_code,elapsed_sec,total_chars,chars_per_sec,resolved_backend,log_file,output_file" > "$SUMMARY_CSV"

extract_json_value() {
  local log_file="$1"
  local key="$2"
  "$PYTHON_BIN" - "$log_file" "$key" <<'PY'
import json
import sys

log_file, key = sys.argv[1], sys.argv[2]
value = ""
with open(log_file, "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") == "metadata" and obj.get("key") == key:
            value = str(obj.get("value", ""))
print(value)
PY
}

for backend in auto mlx pytorch; do
  for chunk_chars in 600 900 1200; do
    for pipeline_mode in sequential overlap3; do
      run_id="${backend}-c${chunk_chars}-${pipeline_mode}"
      output_file="$OUT_DIR/${run_id}.mp3"
      log_file="$OUT_DIR/${run_id}.jsonl"

      start_ts="$(date +%s)"
      set +e
      "$PYTHON_BIN" "$ROOT_DIR/app.py" \
        --input "$INPUT_EPUB" \
        --output "$output_file" \
        --backend "$backend" \
        --chunk_chars "$chunk_chars" \
        --pipeline_mode "$pipeline_mode" \
        --event_format json \
        --no_rich \
        >"$log_file" 2>&1
      exit_code="$?"
      set -e
      end_ts="$(date +%s)"

      elapsed_sec="$((end_ts - start_ts))"
      total_chars="$(extract_json_value "$log_file" total_chars)"
      resolved_backend="$(extract_json_value "$log_file" backend_resolved)"

      if [[ -z "$total_chars" || "$total_chars" == "None" ]]; then
        total_chars="0"
      fi

      chars_per_sec="0"
      if [[ "$elapsed_sec" -gt 0 ]]; then
        chars_per_sec="$("$PYTHON_BIN" - "$total_chars" "$elapsed_sec" <<'PY'
import sys
chars = int(sys.argv[1])
elapsed = int(sys.argv[2])
print(int(chars / elapsed) if elapsed > 0 else 0)
PY
)"
      fi

      echo "$run_id,$backend,$chunk_chars,$pipeline_mode,$exit_code,$elapsed_sec,$total_chars,$chars_per_sec,$resolved_backend,$log_file,$output_file" >> "$SUMMARY_CSV"
      echo "Completed: $run_id (exit=$exit_code, elapsed=${elapsed_sec}s, chars/sec=$chars_per_sec)"
    done
  done
done

echo "Benchmark summary written to: $SUMMARY_CSV"
