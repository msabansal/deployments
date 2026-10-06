#!/usr/bin/env python3
"""Aggregate synchronized receiver application-byte counters, never payload output."""
import argparse
import base64
import gzip
import json
import os
import pathlib
import subprocess
import threading
import time

from server import apply_process_affinity, process_cpu_plan


def cpu():
    values = [int(value) for value in pathlib.Path("/proc/stat").read_text().splitlines()[0].split()[1:9]]
    return sum(values), values[3] + values[4]


def cpu_percent(before, after):
    total = after[0] - before[0]
    if total <= 0:
        raise RuntimeError("invalid CPU observation interval")
    return 100 * (1 - (after[1] - before[1]) / total)


def wait_until(timestamp):
    while True:
        delay = timestamp - time.time()
        if delay <= 0:
            return
        time.sleep(min(delay, 0.1))


def sample_cpu(start, duration, path):
    wait_until(start)
    begin = time.monotonic()
    before = cpu()
    wait_until(start + duration)
    after = cpu()
    result = {
        "vm_cpu_percent": cpu_percent(before, after),
        "cpu_observation_seconds": time.monotonic() - begin,
        "measurement_start_unix_seconds": start,
    }
    pathlib.Path(path).write_text(json.dumps(result))


parser = argparse.ArgumentParser()
subparsers = parser.add_subparsers(dest="mode", required=True)
client = subparsers.add_parser("client")
client.add_argument("--target", required=True)
client.add_argument("--cert", required=True)
client.add_argument("--connections", type=int, default=4)
client.add_argument("--server-workers", type=int, choices=[1, 2], default=1)
client.add_argument("--streams", type=int, default=1)
client.add_argument("--duration", type=int, default=30)
client.add_argument("--warmup", type=int, default=5)
client.add_argument("--start", type=float, required=True)
client.add_argument("--cc", choices=["cubic", "bbr"], default="cubic")
client.add_argument("--window", type=int, default=67108864)
client.add_argument("--stream-window", type=int, default=4194304)
client.add_argument("--max-udp", type=int, default=1472)
client.add_argument("--initial-cwnd", type=int, default=32)
client.add_argument("--disable-gro", action="store_true")
client.add_argument("--pin-processes", action="store_true")
client.add_argument("--output", required=True)
monitor = subparsers.add_parser("cpu")
monitor.add_argument("--start", type=float, required=True)
monitor.add_argument("--duration", type=int, required=True)
monitor.add_argument("--output", required=True)
args = parser.parse_args()

if args.mode == "cpu":
    sample_cpu(args.start, args.duration, args.output)
else:
    if not (1 <= args.connections <= 32 and 1 <= args.streams <= 32 and
            1200 <= args.max_udp <= 1472 and args.duration > 0 and args.warmup > 0):
        raise ValueError("invalid benchmark configuration")
    if args.start - time.time() < args.warmup:
        raise ValueError("insufficient time left for configured warmup")
    available_cpus, cpu_plans = process_cpu_plan(args.connections, args.pin_processes)
    command = [
        "/opt/quiche-benchmark/bin/quiche-client",
        "--http-version", "HTTP/3", "--wire-version", "1",
        "--connect-to", f"{args.target}:4433",
        "--trust-origin-ca-pem", args.cert,
        "--cc-algorithm", args.cc,
        "--max-data", str(args.window), "--max-window", str(args.window),
        "--max-stream-data", str(args.stream_window),
        "--max-stream-window", str(args.stream_window),
        "--idle-timeout", str((args.duration + args.warmup + 20) * 1000),
        "--initial-rtt", "1", "--initial-cwnd-packets", str(args.initial_cwnd),
        "--requests", str(args.streams),
        "https://quiche-benchmark.internal:4433/stream-bytes/65536",
    ]
    environment = dict(os.environ, QUICHE_BENCH_START_NS=str(round(args.start * 1e9)),
                       QUICHE_BENCH_DURATION=str(args.duration),
                       QUICHE_BENCH_MAX_UDP=str(args.max_udp),
                       QUICHE_BENCH_GRO="0" if args.disable_gro else "1",
                       RUST_LOG="error")
    environment.pop("SSLKEYLOGFILE", None)
    environment.pop("QLOGDIR", None)
    processes = []
    affinities = []
    cpu_file = str(pathlib.Path(args.output).with_suffix(".cpu.json"))
    cpu_errors = []

    def sample():
        try:
            sample_cpu(args.start, args.duration, cpu_file)
        except Exception as error:
            cpu_errors.append(error)

    worker = threading.Thread(target=sample)
    try:
        for index in range(args.connections):
            worker_command = command.copy()
            worker_command[worker_command.index("--connect-to") + 1] = f"{args.target}:{4433 + index % args.server_workers}"
            process = subprocess.Popen(worker_command, env=environment,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            processes.append(process)
            affinities.append(apply_process_affinity(process, cpu_plans[index]))
        worker.start()
        results = []
        for index, process in enumerate(processes):
            output, errors = process.communicate(timeout=max(1, args.start + args.duration + 15 - time.time()))
            if process.returncode:
                raise RuntimeError(f"quiche-client exited {process.returncode}: {errors}\n{output}")
            lines = [line.removeprefix("QUICHE_RESULT=") for line in output.splitlines()
                     if line.startswith("QUICHE_RESULT=")]
            if len(lines) != 1:
                raise RuntimeError(f"expected one receiver result: {output}\n{errors}")
            result = json.loads(lines[0])
            if result["bytes_received"] <= 0 or result["duration_seconds"] != args.duration:
                raise RuntimeError(f"invalid receiver counter: {result}")
            if not result["certificate_verified"] or result["early_data"]:
                raise RuntimeError("unverified certificate or early data benchmark")
            result["process_index"] = index
            result["process_id"] = process.pid
            result["cpu_affinity"] = affinities[index]
            results.append(result)
        worker.join()
        if cpu_errors:
            raise cpu_errors[0]
        data = {
            "protocol": "HTTP/3 over QUIC v1 / TLS 1.3 / UDP (cloudflare/quiche)",
            "bytes_received": sum(result["bytes_received"] for result in results),
            "duration_seconds": args.duration,
            "measurement_start_unix_seconds": args.start,
            "connections": args.connections,
            "server_workers": args.server_workers,
            "streams_per_connection": args.streams,
            "warmup_seconds": args.warmup,
            "pin_processes": args.pin_processes,
            "available_cpus": available_cpus,
            "receiver_results": results,
            "client_cpu": json.loads(pathlib.Path(cpu_file).read_text()),
            "build": json.loads(pathlib.Path("/opt/quiche-benchmark/source.json").read_text()),
        }
        data["bits_per_second"] = data["bytes_received"] * 8 / args.duration
        pathlib.Path(args.output).write_text(json.dumps(data))
        print("QUICHE_CLIENT_RESULT_B64=" +
              base64.b64encode(gzip.compress(json.dumps(data).encode())).decode())
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if worker.ident is not None:
            worker.join()
