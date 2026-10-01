#!/usr/bin/env python3
"""Check the sole SWIFT backend using short, in-band connectivity tests."""
import argparse
import importlib.util
import json
import pathlib
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "migration", pathlib.Path(__file__).with_name("test-migration.py"))
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", default=str(pathlib.Path.home() / ".ssh" / "id_ed25519"))
    parser.add_argument("--router-host", default=migration.DESTINATION)
    parser.add_argument("--client-host", default=migration.CLIENT)
    parser.add_argument("--server-host", default=migration.SERVER)
    parser.add_argument("--namespace", default=migration.DESTINATION_NS)
    parser.add_argument("--duration", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=8)
    parser.add_argument("--output")
    args = parser.parse_args()
    if not 1 <= args.duration <= 10 or not args.duration + 2 <= args.timeout <= 20:
        parser.error("Duration must be 1-10 seconds; timeout must be duration+2 through 20 seconds")
    experiment = migration.Experiment(args.key)
    results = {"status": "failed", "duration_s": args.duration, "client_timeout_s": args.timeout}
    try:
        backend = migration.managed_attachment(experiment, args.router_host, args.namespace)
        inventory = experiment.command(args.router_host, "sudo /usr/local/bin/swiftcmd get-all-ncs",
                                       timeout=15)
        inventory = json.loads(inventory[inventory.index("{"):])
        entries = inventory.get("networkContainers") or inventory.get("NetworkContainers") or []
        ids = {entry.get("networkContainerId") or entry.get("NetworkContainerId") for entry in entries}
        if backend["ip"] != "10.80.0.5" or ids != {backend["ncId"]}:
            raise RuntimeError("Expected exactly one NC, owning 10.80.0.5")
        before = migration.forwarded(experiment, args.router_host, args.namespace)
        for host, target, label in (
                (args.client_host, "10.80.2.4", "vm1_to_vm2"),
                (args.server_host, "10.80.1.4", "vm2_to_vm1")):
            results[label] = experiment.command(host, f"ping -n -c 2 -W 1 -w 3 {target}",
                                               timeout=10).strip()
            print(f"{label}: ping passed", flush=True)
        for protocol in ("tcp", "udp"):
            server = experiment.prepare(
                args.server_host, f"{protocol} connectivity listener",
                f"timeout --kill-after=2 {args.timeout + 5} /usr/local/bin/iperf3 "
                f"-s -p 5203 -1 --rcv-timeout {args.timeout * 1000} --json")
            options = "-u -b 100M -l 1380" if protocol == "udp" else ""
            client = experiment.prepare(
                args.client_host, f"{protocol} connectivity client",
                f"timeout --kill-after=2 {args.timeout} /usr/local/bin/iperf3 "
                f"-c 10.80.2.4 -p 5203 --connect-timeout 2000 "
                f"{options} -t {args.duration} --json")
            server.start()
            experiment.command(
                args.server_host,
                "for attempt in $(seq 1 20); do "
                "if sudo ss -ltn 'sport = :5203' | grep -q LISTEN; then exit 0; fi; "
                "sleep 0.1; done; echo 'Listener failed to start' >&2; exit 1", timeout=10)
            client.start()
            experiment.wait(lambda: client.exit_code is not None and server.exit_code is not None,
                            args.timeout + 7, f"{protocol} connectivity")
            text = "\n".join(client.lines)
            results[protocol] = {"client_exit_code": client.exit_code,
                                 "server_exit_code": server.exit_code, "raw_output": text}
            client.require_success()
            server.require_success()
            payload = json.loads(text[text.index("{"):])
            if payload.get("error"):
                raise RuntimeError(payload["error"])
            end = payload["end"]
            if abs(end["sum_sent"]["seconds"] - args.duration) > 1:
                raise RuntimeError(f"{protocol}: incomplete measurement window")
            if end["sum_received"]["bytes"] <= 0:
                raise RuntimeError(f"{protocol}: no data received")
            results[protocol]["iperf"] = payload
            print(f"{protocol.upper()}: {end['sum_received']['bits_per_second'] / 1e6:.2f} Mbit/s "
                  f"received over {args.duration}s", flush=True)
            for job in (server, client):
                job.cleanup()
                experiment.jobs.remove(job)
        after = migration.forwarded(experiment, args.router_host, args.namespace)
        if after <= before:
            raise RuntimeError("The .5 namespace did not forward any test traffic")
        results["backend"] = backend
        results["backend_forwarded_during_checks"] = after - before
        results["status"] = "passed"
        print(f"Only .5 is attached; its namespace forwarded {after - before} datagrams.", flush=True)
    finally:
        errors = []
        for job in experiment.jobs:
            try:
                job.cleanup()
            except (RuntimeError, OSError, TimeoutError) as error:
                errors.append(f"{job.name}: {error}")
        if errors:
            results["status"] = "failed"
            results["cleanup_errors"] = errors
        if args.output:
            pathlib.Path(args.output).write_text(json.dumps(results, indent=2))
        if errors:
            raise RuntimeError("Connectivity cleanup failed: " + "; ".join(errors))


if __name__ == "__main__":
    main()
