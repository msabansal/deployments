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
connectivity_spec = importlib.util.spec_from_file_location(
    "connectivity", SCRIPT.with_name("test-connectivity.py"))
connectivity = importlib.util.module_from_spec(connectivity_spec)
connectivity_spec.loader.exec_module(connectivity)


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
        self.cleanup_calls = 0

    def emit(self, line):
        self.experiment.events.put((self, line, self.experiment.now))

    def start(self):
        self.started = True
        if self.name == "throughput server" or self.name.endswith("connectivity listener"):
            self.emit("__JOB_EXIT__=0")
        elif self.name == "connectivity probe":
            self.emit('__PROBE_READY__={"event":"first_send"}')
            self.emit('__PROBE_READY__={"event":"first_receive"}')
        elif self.name == "120-second throughput" or self.name.endswith("connectivity client"):
            duration = 120 if self.name == "120-second throughput" else 3
            if duration == 120:
                self.emit("__LOAD_STARTED__")
            self.emit(json.dumps({"end": {
                "sum_sent": {"bits_per_second": 5e9, "seconds": duration, "retransmits": 123},
                "sum_received": {"bits_per_second": 4e9, "lost_percent": 20,
                                 "seconds": duration, "bytes": 100000}}}))
            if duration != 120:
                self.emit("__JOB_EXIT__=0")
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
        if self.exit_code != 0:
            raise RuntimeError(f"{self.name} exited {self.exit_code}")

    def cleanup(self):
        self.cleanup_calls += 1


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
        job.command = command
        self.jobs.append(job)
        return job

    def run(self, host, name, command, timeout=None):
        return None

    def command(self, host, command, **kwargs):
        if "get-all-ncs" in command:
            if host == module.DESTINATION:
                return '{"networkContainers":[{"networkContainerId":"new"}]}'
            return '{"networkContainers":[]}'
        if "if sudo test -f /var/lib/swift-ilb/swift-ilb-router2.json" in command:
            return "absent"
        if "sudo python3 -c" in command:
            if module.DESTINATION_NS in command:
                return '{"ncId":"new","ip":"10.80.0.5","vlan":2}'
            raise AssertionError("The single-IP test must not read an extra attachment")
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
                                         completion_grace=5, in_band_control=True, protocol="udp")
            result = module.run_measurement(experiment, release, onboard, args, 0)
            self.assertEqual(result["duration_s"], 120)
            self.assertEqual(result["ack_observation_to_destination_trigger_ms"], 0)
            self.assertEqual(result["received_gbps"], 4)
            self.assertTrue((pathlib.Path(output) / "probe.csv").exists())
            self.assertNotIn("retained_nc_id", result)
            load = next(job for job in experiment.jobs if job.name == "120-second throughput")
            self.assertIn("timeout --kill-after=2 125 ", load.command)

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
                                         completion_grace=5, in_band_control=True, protocol="udp")
            result = module.run_measurement(experiment, release, onboard, args, 0)
            self.assertFalse(result["forwarding_isolation_passed"])
            self.assertEqual(result["destination_host_forwarded_during_test"], 1)
            saved = json.loads((pathlib.Path(output) / "summary.json").read_text())
            self.assertFalse(saved["forwarding_isolation_passed"])

    def test_no_replay(self):
        job = object.__new__(module.Job)
        job.started = True
        job.name = "already started"
        with self.assertRaisesRegex(RuntimeError, "Refusing to replay"):
            job.start()

    def test_tcp_data_does_not_use_udp_control_bridge(self):
        experiment = FakeExperiment()
        release = experiment.prepare("", "release", "")
        experiment.release = release
        onboard = experiment.prepare("", "onboard", "")
        with tempfile.TemporaryDirectory() as output, \
                patch.object(module.time, "perf_counter", lambda: experiment.now), \
                patch.object(module, "forwarded", side_effect=[0, 0, 0, 100]):
            args = types.SimpleNamespace(duration=120, migrate_after=30, output_directory=output,
                                         completion_grace=5, in_band_control=False, protocol="tcp")
            result = module.run_measurement(experiment, release, onboard, args, 0)
            self.assertEqual(result["iperf_control_path"], "ilb_in_band")
            self.assertEqual(result["retransmits"], 123)
            self.assertNotIn("loss_percent", result)
            load = next(job for job in experiment.jobs if job.name == "120-second throughput")
            self.assertNotIn(" -u ", load.command)
            self.assertNotIn("--gsro", load.command)

    def test_go_uses_linux_newline_on_windows(self):
        stream = io.BytesIO()
        job = object.__new__(module.Job)
        job.name = "start"
        job.started = False
        job.process = types.SimpleNamespace(stdin=io.TextIOWrapper(stream, newline="\r\n"))
        job.start()
        self.assertEqual(stream.getvalue(), b"GO\n")

    def test_single_ip_experiment_rejects_legacy_attachment(self):
        experiment = FakeExperiment()
        experiment.command = lambda *args: "present"
        with self.assertRaisesRegex(RuntimeError, "Remove the legacy .6"):
            module.require_no_legacy_attachment(experiment)

    def test_short_checks_cleanup_each_job_once(self):
        experiment = FakeExperiment()
        with patch.object(sys, "argv", ["test-connectivity.py"]), \
                patch.object(connectivity.migration, "Experiment", return_value=experiment), \
                patch.object(connectivity.migration, "forwarded", side_effect=[0, 100]), \
                patch.object(module.time, "perf_counter", lambda: experiment.now), \
                patch("builtins.print"):
            jobs = []
            prepare = experiment.prepare

            def record(*args):
                job = prepare(*args)
                jobs.append(job)
                return job

            experiment.prepare = record
            connectivity.main()
            self.assertEqual(len(jobs), 4)
            self.assertTrue(all(job.cleanup_calls == 1 for job in jobs))
            self.assertTrue(all("--kill-after=2 8 " in job.command
                                for job in jobs if job.name.endswith("connectivity client")))
            self.assertEqual(experiment.jobs, [])

    def test_short_checks_reject_insufficient_timeout(self):
        with patch.object(sys, "argv", ["test-connectivity.py", "--duration", "5", "--timeout", "5"]), \
                patch.object(connectivity.migration, "Experiment") as experiment, \
                patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as error:
                connectivity.main()
            self.assertEqual(error.exception.code, 2)
            experiment.assert_not_called()

    def test_short_checks_reject_extra_nc(self):
        experiment = FakeExperiment()
        command = experiment.command

        def inventory(host, text, **kwargs):
            if "get-all-ncs" in text:
                return '{"networkContainers":[{"networkContainerId":"new"},{"networkContainerId":"extra"}]}'
            return command(host, text, **kwargs)

        experiment.command = inventory
        with patch.object(sys, "argv", ["test-connectivity.py"]), \
                patch.object(connectivity.migration, "Experiment", return_value=experiment):
            with self.assertRaisesRegex(RuntimeError, "exactly one NC"):
                connectivity.main()
            self.assertEqual(experiment.jobs, [])

    def test_short_check_timeout_is_failed_and_cleaned(self):
        experiment = FakeExperiment()
        start = FakeJob.start
        jobs = []
        prepare = experiment.prepare

        def record(*args):
            job = prepare(*args)
            jobs.append(job)
            return job

        def fail_client(job):
            if job.name == "tcp connectivity client":
                job.started = True
                job.emit('{"error":"client timeout"}')
                job.emit("__JOB_EXIT__=124")
            else:
                start(job)

        experiment.prepare = record
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(sys, "argv", ["test-connectivity.py", "--output",
                                          str(pathlib.Path(directory) / "results.json")]), \
                patch.object(connectivity.migration, "Experiment", return_value=experiment), \
                patch.object(connectivity.migration, "forwarded", return_value=0), \
                patch.object(module.time, "perf_counter", lambda: experiment.now), \
                patch.object(FakeJob, "start", fail_client), patch("builtins.print"):
            with self.assertRaisesRegex(RuntimeError, "exited 124"):
                connectivity.main()
            saved = json.loads((pathlib.Path(directory) / "results.json").read_text())
            self.assertEqual(saved["status"], "failed")
            self.assertEqual(saved["tcp"]["client_exit_code"], 124)
            self.assertEqual(len(jobs), 2)
            self.assertTrue(all(job.cleanup_calls == 1 for job in jobs))


if __name__ == "__main__":
    unittest.main()
