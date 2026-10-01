#!/usr/bin/env python3
"""Measure an ILB backend migration with pre-established SSH control sessions."""
import argparse
import base64
import hashlib
import json
import pathlib
import queue
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid


ROOT = pathlib.Path(__file__).resolve().parent
SOURCE = "4.227.106.227"
DESTINATION = "4.227.104.110"
CLIENT = "20.163.69.139"
SERVER = "57.154.15.145"
GROUP = "sabansal-ilb-routing-two-infra-rg"
DEPLOYMENT = "sabansal-ilb-routing-two-infra"
SOURCE_NS = "swift-ilb-router1"
DESTINATION_NS = "swift-ilb-backend2"


def checked(args, **kwargs):
    args = [shutil.which(args[0]) or args[0], *args[1:]]
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr}")
    return result.stdout


class Experiment:
    def __init__(self, key):
        self.key = str(pathlib.Path(key).expanduser().resolve())
        self.events = queue.Queue()
        self.jobs = []
        self.secrets = []
        self.tunnels = []
        self.control_rule = None

    def redact(self, text):
        for secret in self.secrets:
            text = text.replace(secret, "[REDACTED]")
        return text

    def ssh(self, host):
        return ["ssh", "-T", "-i", self.key, "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                f"azureuser@{host}"]

    def command(self, host, command, **kwargs):
        try:
            return checked(self.ssh(host) + [command], **kwargs)
        except RuntimeError as error:
            raise RuntimeError(self.redact(str(error))) from None

    def install(self, host, source, destination):
        temporary = f"/tmp/swift-migration-upload-{uuid.uuid4().hex}"
        checked(["scp", "-q", "-i", self.key, "-o", "BatchMode=yes",
                 "-o", "StrictHostKeyChecking=accept-new", str(source),
                 f"azureuser@{host}:{temporary}"])
        expected = hashlib.sha256(pathlib.Path(source).read_bytes()).hexdigest()
        self.command(host, f"test \"$(sha256sum {shlex.quote(temporary)} | cut -d' ' -f1)\" = "
                     f"{shlex.quote(expected)} && sudo install -m 0755 {shlex.quote(temporary)} "
                     f"{shlex.quote(destination)} && rm -f {shlex.quote(temporary)}")

    def prepare(self, host, name, command):
        job = Job(self, host, name, command)
        self.jobs.append(job)
        job.arm()
        self.wait(lambda: job.armed, 30, f"arming {name}")
        return job

    def wait(self, condition, timeout, description, callback=None):
        deadline = time.perf_counter() + timeout
        while not condition():
            for candidate in self.jobs:
                if candidate.transport_error:
                    raise RuntimeError(self.redact(candidate.transport_error))
            if time.perf_counter() >= deadline:
                raise TimeoutError(f"Timed out {description}")
            try:
                job, line, observed = self.events.get(timeout=0.1)
            except queue.Empty:
                continue
            job.receive(line)
            if callback:
                callback(job, line, observed)
            for candidate in self.jobs:
                if candidate.transport_error:
                    raise RuntimeError(self.redact(candidate.transport_error))

    def run(self, host, name, command, timeout=600):
        job = self.prepare(host, name, command)
        job.start()
        self.wait(lambda: job.exit_code is not None, timeout, name)
        job.require_success()
        return job

    def bridge_control(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            local_port = listener.getsockname()[1]
        forwards = (
            (SERVER, "-L", f"127.0.0.1:{local_port}:127.0.0.1:5203"),
            (CLIENT, "-R", f"127.0.0.1:5204:127.0.0.1:{local_port}"),
        )
        for host, flag, mapping in forwards:
            ssh = self.ssh(host)
            process = subprocess.Popen(ssh[:-1] + [
                "-N", "-o", "ExitOnForwardFailure=yes", flag, mapping, ssh[-1]],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                text=True)
            self.tunnels.append(process)
            deadline = time.perf_counter() + 20
            while time.perf_counter() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("SSH control forward failed: " + process.stderr.read())
                if flag == "-L":
                    try:
                        with socket.create_connection(("127.0.0.1", local_port), timeout=0.2):
                            break
                    except OSError:
                        time.sleep(0.1)
                elif "LISTEN" in self.command(CLIENT, "ss -ltn 'sport = :5204'"):
                    break
                else:
                    time.sleep(0.1)
            else:
                raise TimeoutError("SSH control forward did not become ready")
        comment = "swift-ilb-migration-" + uuid.uuid4().hex
        rule = (f"-p tcp -d 10.80.2.4 --dport 5203 -m comment --comment {comment} "
                "-j DNAT --to-destination 127.0.0.1:5204")
        self.command(CLIENT, "sudo iptables -w -t nat -I OUTPUT 1 " + rule)
        self.control_rule = rule

    def cleanup_control(self):
        try:
            if self.control_rule:
                self.command(CLIENT, "sudo iptables -w -t nat -D OUTPUT " + self.control_rule)
                self.control_rule = None
        finally:
            for process in self.tunnels:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=15)


class Job:
    def __init__(self, experiment, host, name, command):
        self.experiment, self.host, self.name = experiment, host, name
        self.unit = f"swift-ilb-migration-{uuid.uuid4().hex}"
        self.directory = f"/var/lib/swift-ilb/{self.unit}"
        self.script = f"{self.directory}/run.sh"
        self.log = f"{self.directory}/output.log"
        self.status = f"{self.directory}/status"
        self.armed = False
        self.started = False
        self.stopped = False
        self.exit_code = None
        self.transport_error = None
        self.lines = []
        self.offset = 0
        script = (f"#!/bin/bash\numask 077\n(\n{command}\n) >'{self.log}' 2>&1\n"
                  f"code=$?\nprintf '%s\\n' \"$code\" >'{self.status}'\nexit \"$code\"\n")
        data = script.encode()
        encoded = base64.b64encode(data).decode()
        expected = hashlib.sha256(data).hexdigest()
        experiment.command(host,
                           f"sudo install -d -m 0700 '{self.directory}' && "
                           f"sudo install -m 0700 /dev/null '{self.script}' && "
                           f"base64 -d | sudo tee '{self.script}' >/dev/null && "
                           f"test \"$(sudo sha256sum '{self.script}' | cut -d' ' -f1)\" = '{expected}'",
                           input=encoded)

    def arm(self):
        launch = f"""
set -e
echo __ARMED__
IFS= read -r trigger
trigger=${{trigger%$'\\r'}}
test "$trigger" = GO
context=""
if test -e /sys/fs/selinux/enforce; then context=$(sudo id -Z); fi
if test -n "$context"; then
  sudo systemd-run --quiet --unit '{self.unit}' --property="SELinuxContext=$context" /bin/bash '{self.script}'
else
  sudo systemd-run --quiet --unit '{self.unit}' /bin/bash '{self.script}'
fi
"""
        self.connect(launch + self.monitor())

        def read():
            deadline = time.perf_counter() + 900
            while True:
                process = self.process
                for line in process.stdout:
                    line = line.rstrip("\r\n")
                    match = re.fullmatch(r"__FRAME__(\d+):(.*)", line)
                    if match:
                        number = int(match[1])
                        if number <= self.offset:
                            continue
                        if number != self.offset + 1:
                            self.transport_error = f"{self.name}: remote log sequence skipped"
                            return
                        self.offset = number
                        line = match[2]
                    self.experiment.events.put((self, line, time.perf_counter()))
                code = process.wait()
                if code == 255 and self.started and time.perf_counter() < deadline:
                    print(f"[{self.name}] Reconnecting to detached job without replay.", flush=True)
                    time.sleep(0.2)
                    self.connect(self.monitor())
                    continue
                if code:
                    self.transport_error = (f"{self.name} SSH monitor exited {code}. "
                                            f"Detached job and diagnostics remain at {self.directory}: "
                                            f"{process.stderr.read()}")
                return

        threading.Thread(target=read, daemon=True).start()

    def monitor(self):
        return f"""
set -e
offset={self.offset}
while true; do
  if sudo test -f '{self.log}'; then
    total=$(sudo wc -l '{self.log}' | awk '{{print $1}}')
    if test "$total" -gt "$offset"; then
      sudo awk -v start="$((offset + 1))" -v end="$total" 'NR >= start && NR <= end {{printf "__FRAME__%d:%s\\n", NR, $0}}' '{self.log}'
      offset=$total
    fi
  fi
  if sudo test -f '{self.status}'; then
    sudo awk -v start="$((offset + 1))" 'NR >= start {{printf "__FRAME__%d:%s\\n", NR, $0}}' '{self.log}'
    printf '__JOB_EXIT__='
    sudo cat '{self.status}'
    exit 0
  fi
  sleep 0.05
done
"""

    def connect(self, remote):
        self.process = subprocess.Popen(self.experiment.ssh(self.host) + [remote],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, bufsize=1)

    def receive(self, line):
        line = self.experiment.redact(line)
        if line == "__ARMED__":
            self.armed = True
        elif line.startswith("__JOB_EXIT__="):
            self.exit_code = int(line.split("=", 1)[1])
        else:
            self.lines.append(line)
            if line.startswith("__") or "acknowledged:" in line:
                display = line[:160] + "..." if line.startswith("__PROBE_RESULT__=") else line
                print(f"[{self.name}] {display}", flush=True)

    def start(self):
        if self.started:
            raise RuntimeError(f"Refusing to replay {self.name}")
        self.started = True
        self.process.stdin.buffer.write(b"GO\n")
        self.process.stdin.buffer.flush()

    def require_success(self):
        if self.exit_code != 0:
            diagnostics = "\n".join(self.lines)
            if len(diagnostics) > 4000:
                diagnostics = diagnostics[:1000] + "\n...\n" + diagnostics[-3000:]
            raise RuntimeError(f"{self.name} exited {self.exit_code}; full log: {self.log}\n{diagnostics}")

    def cleanup(self, retain_diagnostics=False):
        if not self.started:
            self.process.stdin.close()
            self.process.wait(timeout=15)
        self.stop()
        if retain_diagnostics:
            remove = f"sudo rm -f '{self.script}'"
        else:
            remove = (f"sudo rm -f '{self.script}' '{self.log}' '{self.status}' && "
                      f"sudo rmdir '{self.directory}'")
        self.experiment.command(self.host,
                                remove)
        if self.process.poll() is None:
            self.process.terminate()

    def stop(self):
        if self.started and self.exit_code is None and not self.stopped:
            self.experiment.command(self.host,
                                    f"state=$(sudo systemctl show '{self.unit}' -p LoadState --value); "
                                    f"if test \"$state\" != not-found; then sudo systemctl stop '{self.unit}'; fi")
            self.stopped = True


def attachment(outputs, token, action, namespace, vlan):
    substitutions = {"ACTION": action, "NAMESPACE": namespace, "SWIFT_IP": "10.80.0.5",
                     "VLAN": str(vlan), "VNET_GUID": outputs["customerVnetGuid"]["value"],
                     "SUBNET": "router", "AUTH_TOKEN": token}
    command = (ROOT / "configure-swift-router.sh").read_text()
    for key, value in substitutions.items():
        command = command.replace(f"__{key}__", shlex.quote(value))
    return command


def forwarded(experiment, host, namespace=None):
    command = "cat /proc/net/snmp"
    if namespace:
        command = f"sudo ip netns exec {shlex.quote(namespace)} {command}"
    rows = [line.split() for line in experiment.command(host, command).splitlines()
            if line.startswith("Ip:")]
    if len(rows) != 2 or "ForwDatagrams" not in rows[0]:
        raise RuntimeError("Malformed forwarding counter report")
    return int(rows[1][rows[0].index("ForwDatagrams")])


def managed_attachment(experiment, host, namespace):
    script = (f"import json; s=json.load(open('/var/lib/swift-ilb/{namespace}.json')); "
              "print(json.dumps({k:s[k] for k in ('ncId','namespace','ip','vlan')}))")
    return json.loads(experiment.command(host, "sudo python3 -c " + shlex.quote(script)))


def main():
    global SOURCE, DESTINATION, CLIENT, SERVER
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", default=str(pathlib.Path.home() / ".ssh" / "id_ed25519"))
    parser.add_argument("--duration", type=int, default=120)
    parser.add_argument("--protocol", choices=("udp", "tcp"), default="udp")
    parser.add_argument("--migrate-after", type=int, default=30)
    parser.add_argument("--output-directory")
    parser.add_argument("--in-band-control", action="store_true",
                        help="Route iperf control through the ILB too; it can time out across cutover")
    parser.add_argument("--swift-binary", default=r"Q:\az\Networking-Hybrid-SurgeGuard\AKS-Multitenancy\SwiftCli\bin\Release\net10.0\linux-x64\publish\swiftcmd")
    parser.add_argument("--delegator-project", default=r"Q:\az\Networking-Hybrid-SurgeGuard\AKS-Multitenancy\NrpSubnetDelegatorCli\NrpSubnetDelegatorCli.csproj")
    args = parser.parse_args()
    if not 5 <= args.migrate_after < args.duration - 10:
        parser.error("Migration must occur at least five seconds into the run and ten seconds before its end")
    experiment = Experiment(args.key)
    outputs = json.loads(checked(["az", "deployment", "group", "show", "-g", GROUP,
                                  "-n", DEPLOYMENT, "--query", "properties.outputs", "-o", "json"]))
    SOURCE = outputs["router1PublicIp"]["value"]
    DESTINATION = outputs["router2PublicIp"]["value"]
    CLIENT = checked(["az", "vm", "show", "-d", "-g", GROUP,
                      "-n", outputs["vm1Name"]["value"], "--query", "publicIps", "-o", "tsv"]).strip()
    SERVER = checked(["az", "vm", "show", "-d", "-g", GROUP,
                      "-n", outputs["vm2Name"]["value"], "--query", "publicIps", "-o", "tsv"]).strip()
    pool = json.loads(checked(["az", "network", "lb", "show", "-g", GROUP,
                              "-n", outputs["loadBalancerName"]["value"], "--query",
                              "backendAddressPools[].loadBalancerBackendAddresses[].ipAddress", "-o", "json"]))
    if pool != ["10.80.0.5"]:
        raise RuntimeError("Expected the sole ILB backend 10.80.0.5")
    delegation_text = checked(["dotnet", "run", "--project", args.delegator_project, "--",
                               "--key-vault-name", "testGWMSS", "--certificate-name", "prodnextappCert",
                               "--app-id", "f6f9bf50-8786-4efb-a1c6-776f770b4b65",
                               "--tenant-id", "72f988bf-86f1-41af-91ab-2d7cd011db47",
                               "--subnet-resource-id", outputs["routingSubnetId"]["value"],
                               "--vnet-resource-id", outputs["infraVnetId"]["value"],
                               "--linked-resource-type", "Microsoft.Network/applicationGateways"])
    records = [json.loads(line.split(": ", 1)[1]) for line in delegation_text.splitlines()
               if line.startswith("DelegationResult: ")]
    matching = [record for record in records if record["SubnetResourceId"] == outputs["routingSubnetId"]["value"]]
    if len(matching) != 1:
        raise RuntimeError("Missing or ambiguous delegation context")
    token = matching[0]["PrimaryContextId"]
    experiment.secrets.append(token)
    for host in (SOURCE, DESTINATION):
        experiment.install(host, args.swift_binary, "/usr/local/bin/swiftcmd")
    for host in (CLIENT, SERVER):
        experiment.install(host, ROOT / "migration-probe.py", "/usr/local/sbin/swift-ilb-migration-probe.py")

    success = False
    onboard = None
    try:
        print("Restoring baseline: backend on router1; router2 retains 10.80.0.6.", flush=True)
        experiment.run(DESTINATION, "baseline backend release",
                       attachment(outputs, token, "cleanup", DESTINATION_NS, 2))
        experiment.run(SOURCE, "baseline backend attach",
                       attachment(outputs, token, "create", SOURCE_NS, 1))
        before_destination_other = forwarded(experiment, DESTINATION, "swift-ilb-router2")
        args.before_other_nc = managed_attachment(experiment, DESTINATION, "swift-ilb-router2")["ncId"]
        release = experiment.prepare(SOURCE, "source release",
                                     attachment(outputs, token, "cleanup", SOURCE_NS, 1))
        onboard = experiment.prepare(DESTINATION, "destination onboarding",
                                     attachment(outputs, token, "create", DESTINATION_NS, 2))
        result = run_measurement(experiment, release, onboard, args, before_destination_other)
        final_pool = json.loads(checked(["az", "network", "lb", "show", "-g", GROUP,
                                         "-n", outputs["loadBalancerName"]["value"], "--query",
                                         "backendAddressPools[].loadBalancerBackendAddresses[].ipAddress",
                                         "-o", "json"]))
        if final_pool != pool:
            raise RuntimeError("ILB backend pool changed during the experiment")
        success = result["forwarding_isolation_passed"]
        return result
    except BaseException:
        if onboard and onboard.started and onboard.exit_code != 0:
            print("Destination failed; stopping it before restoring router1.", flush=True)
            if onboard.exit_code is None:
                onboard.stop()
            recovery = Experiment(args.key)
            recovery.secrets.append(token)
            try:
                log = experiment.command(DESTINATION, f"sudo cat '{onboard.log}'")
                ids = re.findall(r"generated NC id: ([0-9a-fA-F-]{36})", log)
                managed = experiment.command(DESTINATION,
                                             f"if sudo test -f /var/lib/swift-ilb/{DESTINATION_NS}.json; "
                                             "then echo managed; fi").strip()
                if managed:
                    recovery.run(DESTINATION, "rollback destination",
                                 attachment(outputs, token, "cleanup", DESTINATION_NS, 2))
                elif ids:
                    if len(ids) != 1:
                        raise RuntimeError("Ambiguous partial destination NC; refusing rollback")
                    recovery.run(DESTINATION, "rollback partial destination",
                                 f"/usr/local/bin/swiftcmd delete --nc-id {shlex.quote(ids[0])} "
                                 f"--auth-token {shlex.quote(token)} --namespace {DESTINATION_NS} --vlan 2")
                recovery.run(SOURCE, "rollback source cleanup",
                             attachment(outputs, token, "cleanup", SOURCE_NS, 1))
                recovery.run(SOURCE, "rollback source attach",
                             attachment(outputs, token, "create", SOURCE_NS, 1))
                print("Restored router1 after failed migration; the experiment remains failed.", flush=True)
            finally:
                for job in recovery.jobs:
                    job.cleanup(retain_diagnostics=True)
        raise
    finally:
        errors = []
        for job in experiment.jobs:
            try:
                job.cleanup(retain_diagnostics=not success)
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
                errors.append(f"{job.name}: {error}")
        try:
            experiment.cleanup_control()
        except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
            errors.append(f"control bridge: {error}")
        if errors:
            raise RuntimeError("Migration cleanup failed: " + "; ".join(errors))


def run_measurement(experiment, release, onboard, args, before_other):
    output = pathlib.Path(args.output_directory or tempfile.mkdtemp(prefix="swift-ilb-migration-"))
    output.mkdir(parents=True, exist_ok=True)
    identifier = uuid.uuid4().hex
    csv_path = f"/var/tmp/swift-ilb-migration-{identifier}.csv"
    report_path = f"/var/tmp/swift-ilb-migration-{identifier}.json"
    in_band_control = args.in_band_control or args.protocol == "tcp"
    if not in_band_control:
        experiment.bridge_control()
    throughput_server = experiment.prepare(
        SERVER, "throughput server",
        f"timeout {args.duration + 240} /usr/local/bin/iperf3 -s -p 5203 -1 "
        f"--server-max-duration {args.duration + 60} --json")
    throughput_server.start()
    experiment.command(SERVER, "for attempt in $(seq 1 20); do "
                       "if sudo ss -ltn 'sport = :5203' | grep -q LISTEN; then exit 0; fi; "
                       "sleep 0.1; done; echo 'Throughput listener failed to start' >&2; exit 1")
    server = experiment.prepare(SERVER, "echo server",
                                f"timeout {args.duration + 240} python3 /usr/local/sbin/swift-ilb-migration-probe.py "
                                "server --bind 0.0.0.0 --port 5202")
    server.start()
    experiment.command(SERVER, "for attempt in $(seq 1 20); do "
                       "if sudo ss -lun 'sport = :5202' | grep -q ':5202'; then exit 0; fi; "
                       "sleep 0.1; done; echo 'Echo listener failed to start' >&2; exit 1")
    experiment.run(CLIENT, "baseline UDP readiness", """python3 - <<'PY'
import json, subprocess, time
deadline = time.monotonic() + 120
while time.monotonic() < deadline:
    attempt = subprocess.run([
        "python3", "/usr/local/sbin/swift-ilb-migration-probe.py", "client",
        "--target", "10.80.2.4", "--port", "5202", "--duration", "1",
        "--rate", "20", "--timeout", "0.5", "--late-grace", "0.5",
    ], capture_output=True, text=True)
    if attempt.returncode not in (0, 2):
        raise RuntimeError(f"Readiness probe failed: {attempt.stderr}")
    records = [json.loads(line.split("=", 1)[1]) for line in attempt.stdout.splitlines()
               if line.startswith("__PROBE_RESULT__=")]
    if len(records) != 1:
        raise RuntimeError("Readiness probe returned no unique result")
    if records[0]["received_count"] > 0:
        print("__BASELINE_UDP_READY__", flush=True)
        break
    print("Waiting for baseline UDP dataplane convergence", flush=True)
else:
    raise RuntimeError("Baseline UDP dataplane did not converge within 120 seconds")
PY""", timeout=150)
    probe = experiment.prepare(CLIENT, "connectivity probe",
                               "python3 /usr/local/sbin/swift-ilb-migration-probe.py client "
                               f"--target 10.80.2.4 --port 5202 --duration {args.duration + 10} "
                               f"--rate 100 --timeout 0.5 --late-grace 3 --log '{csv_path}' "
                               f"--log-format csv --report '{report_path}'")
    traffic_options = "-u -P 2 -b 2500M -l 1380 --gsro" if args.protocol == "udp" else "-P 2"
    load = experiment.prepare(CLIENT, "120-second throughput",
                              "set -euo pipefail\n"
                              "echo __LOAD_STARTED__\n"
                              f"timeout {args.duration + 60} /usr/local/bin/iperf3 -c 10.80.2.4 "
                              f"-p 5203 {traffic_options} -t {args.duration} --json")
    timings = {}
    probe_ready = []
    before_source = forwarded(experiment, SOURCE)

    def observe(job, line, timestamp):
        if job is probe and line.startswith("__PROBE_READY__="):
            probe_ready.append(json.loads(line.split("=", 1)[1]))
        if job is load and line == "__LOAD_STARTED__":
            timings["load_started"] = timestamp
        if job is release and line.startswith("[swiftcmd] NC deletion acknowledged: "):
            if "release_observed" in timings:
                raise RuntimeError("Duplicate release acknowledgement")
            timings["release_observed"] = timestamp
            onboard.start()
            timings["destination_triggered"] = time.perf_counter()
        if job is onboard and line.startswith("[swiftcmd] POST ") and "/networkContainers/" in line:
            timings.setdefault("destination_post_observed", timestamp)
        if job is onboard and line == "__SWIFT_ROUTER_READY__":
            timings["destination_ready_observed"] = timestamp

    try:
        probe.start()
        experiment.wait(lambda: len(probe_ready) >= 2, 20, "initial echo connectivity", observe)
        load.start()
        experiment.wait(lambda: "load_started" in timings, 20, "throughput startup", observe)
        migrate_at = timings["load_started"] + args.migrate_after
        experiment.wait(lambda: time.perf_counter() >= migrate_at, args.migrate_after + 5,
                        "migration time", observe)
        if load.exit_code is not None:
            raise RuntimeError("Throughput finished before the migration")
        release.start()
        experiment.wait(lambda: "release_observed" in timings or release.exit_code is not None,
                        60, "source NMAgent release acknowledgement", observe)
        if "release_observed" not in timings:
            release.require_success()
            raise RuntimeError("Source CLI did not emit the validated deletion acknowledgement")
        experiment.wait(lambda: all(job.exit_code is not None
                                    for job in (release, onboard, load, probe, throughput_server)),
                        args.duration + 120, "migration, throughput, and probes", observe)
        (output / "controller-timings.json").write_text(json.dumps(timings, indent=2))
        (output / "iperf-output.log").write_text("\n".join(load.lines))
        (output / "iperf-server-output.log").write_text("\n".join(throughput_server.lines))
        report = json.loads(experiment.command(CLIENT, f"sudo cat '{report_path}'"))
        (output / "probe-report.json").write_text(json.dumps(report, indent=2))
        (output / "probe.csv").write_text(experiment.command(CLIENT, f"sudo cat '{csv_path}'"))
        for job in (release, onboard, load, throughput_server):
            job.require_success()
        if probe.exit_code != 0:
            if probe.exit_code != 2 or report.get("status") != "incomplete_sampling":
                probe.require_success()
            print("Probe warning: incomplete sampling; local scheduling misses/send errors "
                  "are recorded separately and are not attributed to network loss.", flush=True)
        if "destination_ready_observed" not in timings:
            raise RuntimeError("Destination never reported readiness")
        throughput_text = "\n".join(line for line in load.lines if line != "__LOAD_STARTED__")
        start = throughput_text.find("{")
        if start < 0:
            raise RuntimeError("Throughput returned no JSON")
        throughput, _ = json.JSONDecoder().raw_decode(throughput_text[start:])
        if throughput_text[:start].strip():
            print("Throughput warning: " + throughput_text[:start].strip(), flush=True)
        if throughput.get("error"):
            raise RuntimeError(throughput["error"])
        sent_seconds = throughput["end"]["sum_sent"]["seconds"]
        if abs(sent_seconds - args.duration) > 1:
            raise RuntimeError(f"Requested {args.duration} seconds, but sender ran {sent_seconds}")
        after_other = forwarded(experiment, DESTINATION, "swift-ilb-router2")
        after_source = forwarded(experiment, SOURCE)
        destination_forwarded = forwarded(experiment, DESTINATION, DESTINATION_NS)
        isolation_passed = (after_other == before_other and after_source == before_source
                            and destination_forwarded > 0)
        if not isolation_passed:
            print(f"Routing concern: inactive 10.80.0.6 namespace forwarded {after_other - before_other} "
                  f"datagrams; source root forwarded {after_source - before_source}; "
                  f"migrated namespace forwarded {destination_forwarded}. "
                  "The measurement completed but exclusive-routing validation failed.", flush=True)
        source_ncs = experiment.command(SOURCE, "sudo /usr/local/bin/swiftcmd get-all-ncs")
        source_report, _ = json.JSONDecoder().raw_decode(source_ncs[source_ncs.index("{"):])
        if source_report.get("networkContainers") or source_report.get("NetworkContainers"):
            raise RuntimeError("Source NC still exists after migration")
        backend = managed_attachment(experiment, DESTINATION, DESTINATION_NS)
        retained = managed_attachment(experiment, DESTINATION, "swift-ilb-router2")
        if (backend["ip"], backend["vlan"]) != ("10.80.0.5", 2):
            raise RuntimeError("Migrated backend state differs")
        if (retained["ncId"], retained["ip"], retained["vlan"]) != (args.before_other_nc, "10.80.0.6", 1):
            raise RuntimeError("Original router2 attachment changed")
        destination_ncs = experiment.command(DESTINATION, "sudo /usr/local/bin/swiftcmd get-all-ncs")
        destination_report, _ = json.JSONDecoder().raw_decode(destination_ncs[destination_ncs.index("{"):])
        entries = destination_report.get("networkContainers") or destination_report.get("NetworkContainers") or []
        nc_ids = {entry.get("networkContainerId") or entry.get("NetworkContainerId") for entry in entries}
        if nc_ids != {backend["ncId"], retained["ncId"]}:
            raise RuntimeError("Unexpected destination network containers")
        summary = {
            "duration_s": args.duration,
            "protocol": args.protocol,
            "iperf_control_path": "ilb_in_band" if in_band_control else "ssh_out_of_band",
            "migration_requested_at_s": args.migrate_after,
            "source": SOURCE,
            "destination": DESTINATION,
            "backend_ip": "10.80.0.5",
            "backend_nc_id": backend["ncId"],
            "retained_nc_id": retained["ncId"],
            "source_release_observed_at_s": timings["release_observed"] - timings["load_started"],
            "ack_observation_to_destination_trigger_ms":
                1000 * (timings["destination_triggered"] - timings["release_observed"]),
            "destination_post_observed_after_release_s":
                timings["destination_post_observed"] - timings["release_observed"],
            "destination_ready_observed_after_release_s":
                timings["destination_ready_observed"] - timings["release_observed"],
            "controller_log_poll_interval_s": 0.05,
            "controller_clock_resolution_s": time.get_clock_info("perf_counter").resolution,
            "sent_gbps": throughput["end"]["sum_sent"]["bits_per_second"] / 1e9,
            "sent_seconds": sent_seconds,
            "received_seconds": throughput["end"]["sum_received"]["seconds"],
            "received_gbps": throughput["end"]["sum_received"]["bits_per_second"] / 1e9,
            "destination_forwarded": destination_forwarded,
            "inactive_attachment_forwarded": after_other - before_other,
            "inactive_attachment_forwarded_before": before_other,
            "inactive_attachment_forwarded_after": after_other,
            "source_host_forwarded_during_test": after_source - before_source,
            "forwarding_isolation_passed": isolation_passed,
            "probe_sampling_complete": probe.exit_code == 0,
            "max_chronological_receive_gap_s": report["max_chronological_receive_gap_s"],
            "probe_report": report,
        }
        if args.protocol == "udp":
            summary["loss_percent"] = throughput["end"]["sum_received"]["lost_percent"]
        else:
            summary["retransmits"] = throughput["end"]["sum_sent"]["retransmits"]
        (output / "summary.json").write_text(json.dumps(summary, indent=2))
        (output / "iperf.json").write_text(json.dumps(throughput, indent=2))
        (output / "probe.csv").write_text(experiment.command(CLIENT, f"sudo cat '{csv_path}'"))
        display = {key: value for key, value in summary.items() if key != "probe_report"}
        display["largest_observed_echo_gap"] = report["max_chronological_receive_gap"]
        display["probe_uncertainty"] = report["uncertainty"]
        print(json.dumps(display, indent=2), flush=True)
        print(f"Evidence: {output}", flush=True)
        experiment.command(CLIENT, f"sudo rm -f '{csv_path}' '{report_path}'")
        return summary
    except BaseException:
        # Keep migration diagnostics; only stop the dedicated measurement processes.
        for job in (server, probe, load, throughput_server):
            if job.started:
                job.stop()
                if job.process.poll() is None:
                    job.process.terminate()
        raise


if __name__ == "__main__":
    result = main()
    raise SystemExit(0 if result["forwarding_isolation_passed"] else 2)
