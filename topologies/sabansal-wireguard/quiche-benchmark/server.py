#!/usr/bin/env python3
"""Supervise independent upstream servers on the VM's two SMT threads."""
import argparse
import json
import os
import signal
import subprocess
import threading
import time

def process_cpu_plan(count, pin_processes):
    if count < 1:
        raise ValueError("process count must be positive")
    if not hasattr(os, "sched_getaffinity") or (
            pin_processes and not hasattr(os, "sched_setaffinity")):
        raise RuntimeError("Linux process-affinity APIs are unavailable")
    available = sorted(os.sched_getaffinity(0))
    required = min(count, 2)
    if not available or (pin_processes and len(available) < required):
        raise RuntimeError(f"Process pinning requires {required} available CPUs; allowed CPUs: {available}")
    plans = [{available[index % required]} if pin_processes else None
             for index in range(count)]
    return available, plans


def apply_process_affinity(process, requested):
    if requested is not None:
        os.sched_setaffinity(process.pid, requested)
    actual = sorted(os.sched_getaffinity(process.pid))
    if not actual or (requested is not None and actual != sorted(requested)):
        raise RuntimeError(f"PID {process.pid} affinity mismatch: requested {requested}, actual {actual}")
    return actual


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workers", type=int, choices=[1, 2], default=1)
    parser.add_argument("--listen-ip", required=True)
    parser.add_argument("--pin-processes", action="store_true")
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    available_cpus, cpu_plans = process_cpu_plan(args.workers, args.pin_processes)
    processes = []
    affinities = []
    settings = {}
    gso_calls = {}
    lock = threading.Lock()
    stopping = threading.Event()

    def stop(_signal, _frame):
        stopping.set()

    def read_output(index, process):
        for line in process.stdout:
            line = line.strip()
            with lock:
                if line.startswith("QUICHE_SERVER_SETTINGS="):
                    settings[index] = json.loads(line.split("=", 1)[1])
                elif line.startswith("QUICHE_GSO_SENDS="):
                    gso_calls[index] = int(line.split("=", 1)[1])
                else:
                    print(f"quiche-worker-{index}: {line}", flush=True)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        threads = []
        for index in range(args.workers):
            process = subprocess.Popen(
                ["/opt/quiche-benchmark/bin/quiche-server", "--listen",
                 f"{args.listen_ip}:{4433 + index}", *arguments],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            processes.append(process)
            affinities.append(apply_process_affinity(process, cpu_plans[index]))
            thread = threading.Thread(target=read_output, args=(index, process), daemon=True)
            thread.start()
            threads.append(thread)
        deadline = time.monotonic() + 20
        announced = False
        while not stopping.wait(1):
            for index, process in enumerate(processes):
                if process.poll() is not None:
                    raise RuntimeError(f"quiche server worker {index} exited {process.returncode}")
            with lock:
                if not announced and len(settings) == args.workers:
                    summary = {
                        "gso_enabled": all(value["gso_enabled"] for value in settings.values()),
                        "pacing_enabled": all(value["pacing_enabled"] for value in settings.values()),
                        "max_udp_payload": settings[0]["max_udp_payload"],
                        "pin_processes": args.pin_processes,
                        "available_cpus": available_cpus,
                        "workers": [dict(index=index, port=4433 + index,
                                         process_id=processes[index].pid,
                                         cpu_affinity=affinities[index], **settings[index])
                                    for index in range(args.workers)],
                    }
                    print("QUICHE_SERVER_SETTINGS=" + json.dumps(summary), flush=True)
                    announced = True
                elif not announced and time.monotonic() >= deadline:
                    raise RuntimeError("quiche server startup telemetry missing")
                if announced:
                    print("QUICHE_GSO_SENDS=" + str(sum(gso_calls.values())), flush=True)
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


if __name__ == "__main__":
    main()
