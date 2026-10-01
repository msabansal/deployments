import importlib.util
import io
import json
import pathlib
import queue
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPT = pathlib.Path(__file__).with_name("test-migration.py")
spec = importlib.util.spec_from_file_location("coordinator", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeJob:
    def __init__(self, experiment, name):
        self.experiment = experiment
        self.name = name
        self.host = "offline"
        self.started = False
        self.exit_code = None
        self.transport_error = None
        self.lines = []
        self.log = "offline-log"

    def emit(self, line):
        self.experiment.events.put((self, line, self.experiment.now))

    def start(self):
        self.started = True
        if self.name == "throughput server":
            self.emit("__JOB_EXIT__=0")
        elif self.name == "connectivity probe":
            self.emit('__PROBE_READY__={"event":"first_send"}')
            self.emit('__PROBE_READY__={"event":"first_receive"}')
        elif self.name == "120-second throughput":
            self.emit("__LOAD_STARTED__")
            self.emit(json.dumps({"end": {
                "sum_sent": {"bits_per_second": 5e9, "seconds": 120},
                "sum_received": {"bits_per_second": 4e9, "lost_percent": 20, "seconds": 120}}}))
        elif self.name == "release":
            self.emit("[swiftcmd] NC deletion acknowledged: test-nc")
            self.emit("__JOB_EXIT__=0")
        elif self.name == "onboard":
            assert self.experiment.release.exit_code is None, "Destination waited for source cleanup"
            self.emit("[swiftcmd] POST http://host/networkContainers/test")
            self.emit("__SWIFT_ROUTER_READY__")
            self.emit("__JOB_EXIT__=0")
            for job in self.experiment.jobs:
                if job.name in ("120-second throughput", "connectivity probe"):
                    job.emit("__JOB_EXIT__=0")

    def receive(self, line):
        if line.startswith("__JOB_EXIT__="):
            self.exit_code = int(line.split("=")[1])
        else:
            self.lines.append(line)

    def require_success(self):
        assert self.exit_code == 0


class FakeEvents(queue.Queue):
    def __init__(self, experiment):
        super().__init__()
        self.experiment = experiment

    def get(self, timeout=None):
        if self.empty():
            self.experiment.now += 0.1
        return super().get(block=False)


class FakeExperiment:
    wait = module.Experiment.wait

    def __init__(self):
        self.now = 0
        self.events = FakeEvents(self)
        self.jobs = []

    def redact(self, text):
        return text

    def prepare(self, host, name, command):
        job = FakeJob(self, name)
        self.jobs.append(job)
        return job

    def run(self, host, name, command, timeout=None):
        return None

    def command(self, host, command):
        if "get-all-ncs" in command:
            if host == module.DESTINATION:
                return '{"networkContainers":[{"networkContainerId":"new"},{"networkContainerId":"retained"}]}'
            return '{"networkContainers":[]}'
        if "sudo python3 -c" in command:
            if module.DESTINATION_NS in command:
                return '{"ncId":"new","ip":"10.80.0.5","vlan":2}'
            return '{"ncId":"retained","ip":"10.80.0.6","vlan":1}'
        if ".json" in command and "cat" in command:
            return ('{"outages":[],"uncertainty":{"sampling_interval_s":0.01},'
                    '"max_chronological_receive_gap_s":0.01,"max_chronological_receive_gap":null}')
        if ".csv" in command and "cat" in command:
            return "sequence,send\n1,0\n"
        return ""


class Tests(unittest.TestCase):
    def test_ack_starts_destination_before_source_cleanup(self):
        experiment = FakeExperiment()
        release = experiment.prepare("", "release", "")
        experiment.release = release
        onboard = experiment.prepare("", "onboard", "")
        with tempfile.TemporaryDirectory() as output, \
                patch.object(module.time, "perf_counter", lambda: experiment.now), \
                patch.object(module, "forwarded", side_effect=[0, 0, 0, 100]):
            args = types.SimpleNamespace(duration=120, migrate_after=30, output_directory=output,
                                         before_other_nc="retained", in_band_control=True)
            result = module.run_measurement(experiment, release, onboard, args, 0)
            self.assertEqual(result["duration_s"], 120)
            self.assertEqual(result["ack_observation_to_destination_trigger_ms"], 0)
            self.assertEqual(result["received_gbps"], 4)
            self.assertTrue((pathlib.Path(output) / "probe.csv").exists())

    def test_redaction(self):
        experiment = module.Experiment("offline")
        experiment.secrets.append("test-secret")
        self.assertEqual(experiment.redact("argument test-secret"), "argument [REDACTED]")

    def test_isolation_failure_is_not_reported_as_success(self):
        experiment = FakeExperiment()
        release = experiment.prepare("", "release", "")
        experiment.release = release
        onboard = experiment.prepare("", "onboard", "")
        with tempfile.TemporaryDirectory() as output, \
                patch.object(module.time, "perf_counter", lambda: experiment.now), \
                patch.object(module, "forwarded", side_effect=[0, 1, 0, 100]):
            args = types.SimpleNamespace(duration=120, migrate_after=30, output_directory=output,
                                         before_other_nc="retained", in_band_control=True)
            result = module.run_measurement(experiment, release, onboard, args, 0)
            self.assertFalse(result["forwarding_isolation_passed"])
            self.assertEqual(result["inactive_attachment_forwarded"], 1)
            saved = json.loads((pathlib.Path(output) / "summary.json").read_text())
            self.assertFalse(saved["forwarding_isolation_passed"])

    def test_no_replay(self):
        job = object.__new__(module.Job)
        job.started = True
        job.name = "already started"
        with self.assertRaisesRegex(RuntimeError, "Refusing to replay"):
            job.start()

    def test_go_uses_linux_newline_on_windows(self):
        stream = io.BytesIO()
        job = object.__new__(module.Job)
        job.name = "start"
        job.started = False
        job.process = types.SimpleNamespace(stdin=io.TextIOWrapper(stream, newline="\r\n"))
        job.start()
        self.assertEqual(stream.getvalue(), b"GO\n")


if __name__ == "__main__":
    unittest.main()
