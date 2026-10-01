#!/usr/bin/env python3
"""Independent, same-flow UDP round-trip sampling; no migration orchestration.

Run ``server`` on the destination and ``client`` on the source. All elapsed
times, RTTs and loss boundaries use the client's monotonic clock. Wall timestamps
are for correlation only. Timeout events are provisional: an echo arriving
before the final observation deadline still counts as delivered.
The separate chronological receive gap includes ordinary sampling gaps and
locally missed slots; it is an observed echo gap, not exact fabric downtime.
"""

import argparse
import csv
import errno
import heapq
import json
import math
import os
import select
import signal
import socket
import struct
import sys
import time
import uuid
from time import perf_counter as monotonic


MAGIC = b"SWIFTP01"
PACKET = struct.Struct("!8s16sQ")
LOG_FIELDS = (
    "event", "seq", "elapsed_s", "wall_time_unix", "scheduled_s",
    "send_s", "receive_s", "rtt_s", "late", "detail",
)
TRANSIENT_ERRORS = {
    errno.ECONNREFUSED, errno.ECONNRESET, errno.ENETUNREACH, errno.EHOSTUNREACH,
    errno.ENOBUFS, errno.EAGAIN, errno.EWOULDBLOCK,
    10054, 10055, 10065, 10051,
}
RECEIVE_POLL_S = 0.01 if os.name == "nt" else 0.0


def wait_readable(sock, timeout):
    # Windows select timeouts can round to 15.6 ms. Python 3.11+ sleep uses
    # a high-resolution timer; bounded 10 ms receive polling preserves 100 Hz
    # sending without busy-spinning or changing system-wide timer settings.
    if RECEIVE_POLL_S:
        time.sleep(min(timeout, RECEIVE_POLL_S))
        return select.select([sock], [], [], 0)[0]
    return select.select([sock], [], [], timeout)[0]


def marker(name, data):
    print(name + "=" + json.dumps(data, separators=(",", ":"), allow_nan=False),
          flush=True)


class EventLog:
    def __init__(self, path=None, format_name="jsonl"):
        self.file = open(path, "w", newline="", encoding="utf-8") if path else None
        self.writer = None
        if self.file and format_name == "csv":
            self.writer = csv.DictWriter(self.file, fieldnames=LOG_FIELDS)
            self.writer.writeheader()

    def write(self, event, elapsed_s, **fields):
        if not self.file:
            return
        row = dict.fromkeys(LOG_FIELDS, None)
        row.update(event=event, elapsed_s=elapsed_s, wall_time_unix=time.time())
        row.update(fields)
        if self.writer:
            self.writer.writerow(row)
        else:
            self.file.write(json.dumps(row, separators=(",", ":"),
                                       allow_nan=False) + "\n")

    def flush(self):
        if self.file:
            self.file.flush()

    def close(self):
        if self.file:
            self.file.close()


def probe_detail(probe):
    return {key: probe.get(key) for key in (
        "seq", "scheduled_s", "send_s", "receive_s", "timeout_s",
        "send_error", "scheduler_missed",
    )}


def chronological_receive_gap(probes):
    """Use first actual echo per sequence, independently of send/loss ordering."""
    successes = sorted((p for p in probes if p["receive_s"] is not None),
                       key=lambda p: (p["receive_s"], p["seq"]))
    if len(successes) < 2:
        return None
    previous, following = max(
        zip(successes, successes[1:]),
        key=lambda pair: pair[1]["receive_s"] - pair[0]["receive_s"],
    )
    lower, upper = previous["receive_s"], following["receive_s"]
    # Receive boundaries need not have increasing sequence numbers. Count
    # attempts by send time and unsent slots by scheduled time, not seq range.
    attempts = [p for p in probes if p["send_s"] is not None
                and lower < p["send_s"] < upper]
    lost_sent = sum(p["receive_s"] is None and p["send_error"] is None
                    for p in attempts)
    send_errors = sum(p["send_error"] is not None for p in attempts)
    missed = sum(p["scheduler_missed"] and p["send_s"] is None
                 and lower < p["scheduled_s"] < upper for p in probes)
    return {
        "receive_gap_s": upper - lower,
        "previous_success": probe_detail(previous),
        "next_success": probe_detail(following),
        "intervening_lost_sent_count": lost_sent,
        "intervening_scheduler_missed_count": missed,
        "intervening_send_error_count": send_errors,
        "local_sampling_uncertainty": bool(missed or send_errors),
    }


def assess(probes, rate_hz, timeout_s, duration_s, grace_s, elapsed_s, counters,
           interrupted=False):
    """Assess final per-sequence delivery, never provisional timeout order."""
    lost = [p for p in probes if p["send_s"] is not None
            and p["receive_s"] is None]
    runs = []
    index = 0
    while index < len(probes):
        probe = probes[index]
        if probe["send_s"] is None or probe["receive_s"] is not None:
            index += 1
            continue
        first = index
        while (index + 1 < len(probes)
               and probes[index + 1]["send_s"] is not None
               and probes[index + 1]["receive_s"] is None):
            index += 1
        last = index
        before = probes[first - 1] if first else None
        after = probes[last + 1] if last + 1 < len(probes) else None
        before_ok = before is not None and before["receive_s"] is not None
        after_ok = after is not None and after["receive_s"] is not None
        if before_ok and after_ok:
            kind = "interior"
        elif first == 0 and last == len(probes) - 1:
            kind = "entire_test"
        elif first == 0:
            kind = "initial"
        elif last == len(probes) - 1:
            kind = "final"
        else:
            kind = "unbracketed_scheduler_gap"
        receive_gap = (after["receive_s"] - before["receive_s"]
                       if before_ok and after_ok else None)
        runs.append({
            "kind": kind, "first_seq": probes[first]["seq"],
            "last_seq": probes[last]["seq"], "lost_count": last - first + 1,
            "first_lost_send_s": probes[first]["send_s"],
            "last_lost_send_s": probes[last]["send_s"],
            "lost_run_send_span_s": probes[last]["send_s"] - probes[first]["send_s"],
            "lost_scheduled_window_s": (last - first + 1) / rate_hz,
            "last_success": probe_detail(before) if before_ok else None,
            "first_recovery": probe_detail(after) if after_ok else None,
            "success_receive_gap_s": receive_gap,
            "receive_order_reversed": receive_gap is not None and receive_gap < 0,
        })
        index += 1
    missed = [probe_detail(p) for p in probes if p["send_s"] is None]
    timeouts = [probe_detail(p) for p in probes if p["timeout_s"] is not None]
    rtts = [p["receive_s"] - p["send_s"] for p in probes
            if p["receive_s"] is not None]
    interior = [run for run in runs if run["kind"] == "interior"]
    lag = [p["send_s"] - p["scheduled_s"] for p in probes
           if p["send_s"] is not None]
    send_errors = [probe_detail(p) for p in probes if p["send_error"] is not None]
    limited = [p["seq"] for p in lost if p["send_s"] + timeout_s > elapsed_s]
    chronological_gap = chronological_receive_gap(probes)
    return {
        "schema_version": 1,
        "measurement": "same_flow_udp_echo_round_trip",
        "status": ("interrupted" if interrupted else
                   "incomplete_sampling" if missed or send_errors else "complete"),
        "duration_s": duration_s, "rate_hz": rate_hz,
        "timeout_s": timeout_s, "late_grace_s": grace_s,
        "observation_elapsed_s": elapsed_s,
        "scheduled_count": len(probes),
        "sent_count": sum(p["send_s"] is not None and p["send_error"] is None
                          for p in probes),
        "received_count": len(rtts), "lost_count": len(lost),
        "scheduler_missed_count": len(missed), "send_error_count": len(send_errors),
        "timeout_count": len(timeouts),
        "late_received_count": sum(p["receive_s"] is not None
                                   and p["receive_s"] > p["send_s"] + timeout_s
                                   for p in probes),
        "has_interior_loss": bool(interior),
        "outage_count": len(interior),
        "max_success_receive_gap_s": max(
            (max(0.0, run["success_receive_gap_s"]) for run in interior),
            default=0.0),
        "max_lost_run_send_span_s": max(
            (run["lost_run_send_span_s"] for run in interior), default=0.0),
        "max_chronological_receive_gap_s": (
            chronological_gap["receive_gap_s"] if chronological_gap else 0.0),
        "max_chronological_receive_gap": chronological_gap,
        "outages": interior,
        "initial_loss": [run for run in runs if run["kind"] in ("initial", "entire_test")],
        "final_loss": [run for run in runs if run["kind"] in ("final", "entire_test")],
        "loss_runs": runs,
        "lost_probes": [probe_detail(p) for p in lost],
        "timed_out_probes": timeouts,
        "scheduler_missed_probes": missed, "send_errors": send_errors,
        "rtt_s": {"min": min(rtts) if rtts else None,
                  "max": max(rtts) if rtts else None,
                  "mean": sum(rtts) / len(rtts) if rtts else None},
        "uncertainty": {
            "sampling_period_s": 1.0 / rate_hz,
            "clock_resolution_s": time.get_clock_info("perf_counter").resolution,
            "receive_poll_interval_s": RECEIVE_POLL_S,
            "max_send_scheduling_lag_s": max(lag, default=0.0),
            "ack_timeout_s": timeout_s,
            "late_echo_observation_limit_s": duration_s + grace_s,
            "loss_before_timeout_deadline_seqs": limited,
            "chronological_receive_gap_interpretation": (
                "Maximum gap between consecutive unique actual echoes sorted "
                "by receive_s, including ordinary sampling gaps; NOT exact "
                "fabric outage. Intervening counts use timestamps strictly "
                "inside the receive interval: actual send_s for sent probes "
                "and scheduled_s for unsent slots. Lost-sent means no echo by "
                "final assessment and excludes local send errors. Unsent slots "
                "are NOT network loss. Local sampling uncertainty flags missed "
                "slots or send errors inside this interval; other timing "
                "uncertainties still apply. Fewer than two echoes yields zero "
                "with null boundaries, not evidence of continuous connectivity."
            ),
            "interpretation": (
                "Receive gaps are observed round-trip success gaps, NOT exact "
                "zero-packet downtime. Lost send span is last minus first lost "
                "send (one lost probe has zero span). Boundaries are sampled at "
                "1/rate plus scheduling lag; timeout is a detection delay, not "
                "an outage duration. Echoes after the observation limit are "
                "unknown. RTT/queueing and reordered echoes affect receive gaps. "
                "Local send errors and missed scheduling invalidate complete "
                "path-loss attribution."
            ),
        },
        "counters": counters,
    }


def install_stop_handler():
    stopped = [False]
    previous = {}

    def stop(_signum, _frame):
        stopped[0] = True

    for signum in (signal.SIGINT, signal.SIGTERM):
        previous[signum] = signal.signal(signum, stop)
    return stopped, previous


def restore_handlers(previous):
    for signum, handler in previous.items():
        signal.signal(signum, handler)


def server(args):
    stopped, previous = install_stop_handler()
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind((args.bind, args.port))
            sock.setblocking(False)
            marker("__PROBE_READY__", {"mode": "server", "phase": "listening",
                                       "bind": args.bind, "port": sock.getsockname()[1]})
            while not stopped[0]:
                readable, _, _ = select.select([sock], [], [], 0.25)
                if not readable:
                    continue
                try:
                    payload, peer = sock.recvfrom(65535)
                    if len(payload) == PACKET.size and payload[:8] == MAGIC:
                        sock.sendto(payload, peer)
                except OSError as error:
                    if error.errno not in TRANSIENT_ERRORS and getattr(
                            error, "winerror", None) not in TRANSIENT_ERRORS:
                        raise
                    print("probe server UDP error: " + str(error), file=sys.stderr,
                          flush=True)
    finally:
        restore_handlers(previous)
    return 0


def client(args):
    target = (socket.gethostbyname(args.target), args.port)
    run_id = uuid.uuid4().bytes
    probes = []
    deadlines = []
    counters = {"duplicate_echoes": 0, "out_of_order_echoes": 0,
                "invalid_echoes": 0, "receive_errors": 0}
    highest_received = -1
    first_receive = False
    first_send = False
    log = EventLog(args.log, args.log_format)
    stopped, previous = install_stop_handler()
    start_wall = time.time()
    start = monotonic()
    period = 1.0 / args.rate
    next_seq = 0
    next_progress = 1.0
    send_end = start + args.duration
    observation_end = send_end + args.late_grace
    total = math.ceil(args.duration * args.rate)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind((args.bind, args.source_port))
            sock.setblocking(False)
            local = sock.getsockname()
            while not stopped[0]:
                now = monotonic()
                if now >= observation_end:
                    break
                # Do not burst stale slots following a scheduler stall.
                while next_seq < total and (
                        start + next_seq * period + period <= now or now >= send_end):
                    scheduled = next_seq * period
                    probes.append({"seq": next_seq, "scheduled_s": scheduled,
                                   "send_s": None, "receive_s": None,
                                   "timeout_s": None, "send_error": None,
                                   "scheduler_missed": True})
                    log.write("scheduler_missed", now - start, seq=next_seq,
                              scheduled_s=scheduled)
                    next_seq += 1
                if next_seq < total and now >= start + next_seq * period:
                    probe = {"seq": next_seq, "scheduled_s": next_seq * period,
                             "send_s": monotonic() - start, "receive_s": None,
                             "timeout_s": None, "send_error": None,
                             "scheduler_missed": False}
                    probes.append(probe)
                    try:
                        sock.sendto(PACKET.pack(MAGIC, run_id, next_seq), target)
                    except OSError as error:
                        if error.errno not in TRANSIENT_ERRORS and getattr(
                                error, "winerror", None) not in TRANSIENT_ERRORS:
                            raise
                        probe["send_error"] = str(error)
                    log.write("tx" if probe["send_error"] is None else "tx_error",
                              probe["send_s"], seq=next_seq,
                              scheduled_s=probe["scheduled_s"],
                              send_s=probe["send_s"], detail=probe["send_error"])
                    heapq.heappush(deadlines, (start + probe["send_s"] + args.timeout,
                                              next_seq))
                    if not first_send and probe["send_error"] is None:
                        first_send = True
                        log.flush()
                        marker("__PROBE_READY__", {
                            "mode": "client", "phase": "first_send", "seq": next_seq,
                            "elapsed_s": probe["send_s"], "wall_time_unix": time.time(),
                            "local_port": local[1], "target": target[0], "port": target[1],
                        })
                    next_seq += 1
                now = monotonic()
                while deadlines and deadlines[0][0] <= now:
                    _, seq = heapq.heappop(deadlines)
                    probe = probes[seq]
                    if probe["receive_s"] is None:
                        probe["timeout_s"] = now - start
                        log.write("timeout", now - start, seq=seq,
                                  scheduled_s=probe["scheduled_s"], send_s=probe["send_s"])
                if args.progress and now - start >= next_progress:
                    marker("__PROBE_PROGRESS__", {
                        "elapsed_s": now - start, "scheduled_count": len(probes),
                        "received_count": sum(p["receive_s"] is not None for p in probes),
                    })
                    log.flush()
                    next_progress = math.floor(now - start) + 1.0
                wake = min(observation_end, now + 0.25)
                if next_seq < total:
                    wake = min(wake, start + next_seq * period)
                if deadlines:
                    wake = min(wake, deadlines[0][0])
                if args.progress:
                    wake = min(wake, start + next_progress)
                readable = wait_readable(sock, max(0.0, wake - now))
                if readable:
                    for _ in range(256):
                        try:
                            payload, peer = sock.recvfrom(65535)
                        except BlockingIOError:
                            break
                        except OSError as error:
                            if error.errno not in TRANSIENT_ERRORS and getattr(
                                    error, "winerror", None) not in TRANSIENT_ERRORS:
                                raise
                            counters["receive_errors"] += 1
                            log.write("receive_error", monotonic() - start,
                                      detail=str(error))
                            break
                        received = monotonic()
                        if received >= observation_end:
                            break
                        if len(payload) != PACKET.size or peer != target:
                            counters["invalid_echoes"] += 1
                            continue
                        magic, echoed_id, seq = PACKET.unpack(payload)
                        if (magic != MAGIC or echoed_id != run_id or seq >= len(probes)
                                or probes[seq]["send_s"] is None
                                or probes[seq]["send_error"] is not None):
                            counters["invalid_echoes"] += 1
                            continue
                        probe = probes[seq]
                        duplicate = probe["receive_s"] is not None
                        if duplicate:
                            counters["duplicate_echoes"] += 1
                        else:
                            probe["receive_s"] = received - start
                            if seq < highest_received:
                                counters["out_of_order_echoes"] += 1
                            highest_received = max(highest_received, seq)
                        log.write("duplicate" if duplicate else "recv", received - start,
                                  seq=seq, scheduled_s=probe["scheduled_s"],
                                  send_s=probe["send_s"], receive_s=received - start,
                                  rtt_s=received - start - probe["send_s"],
                                  late=received - start > probe["send_s"] + args.timeout)
                        if not first_receive:
                            first_receive = True
                            log.flush()
                            marker("__PROBE_READY__", {
                                "mode": "client", "phase": "first_receive", "seq": seq,
                                "elapsed_s": received - start,
                                "wall_time_unix": time.time(),
                                "rtt_s": received - start - probe["send_s"],
                            })
            elapsed = monotonic() - start
            if not stopped[0]:
                while next_seq < total:
                    scheduled = next_seq * period
                    probes.append({"seq": next_seq, "scheduled_s": scheduled,
                                   "send_s": None, "receive_s": None,
                                   "timeout_s": None, "send_error": None,
                                   "scheduler_missed": True})
                    log.write("scheduler_missed", elapsed, seq=next_seq,
                              scheduled_s=scheduled)
                    next_seq += 1
            report = assess(probes, args.rate, args.timeout, args.duration,
                            args.late_grace, elapsed, counters, stopped[0])
            report.update(target=target[0], port=target[1], local_port=local[1],
                          start_wall_time_unix=start_wall, planned_probe_count=total)
            if args.report:
                with open(args.report, "w", encoding="utf-8") as output:
                    json.dump(report, output, indent=2, allow_nan=False)
                    output.write("\n")
            log.flush()
            marker("__PROBE_RESULT__", report)
            return 2 if stopped[0] or report["status"] != "complete" else 0
    finally:
        log.close()
        restore_handlers(previous)


def positive_float(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return number


def grace_float(value):
    number = float(value)
    if not math.isfinite(number) or not 0 <= number <= 3:
        raise argparse.ArgumentTypeError("must be between 0 and 3 seconds")
    return number


def port_number(value):
    number = int(value)
    if not 1 <= number <= 65535:
        raise argparse.ArgumentTypeError("must be between 1 and 65535")
    return number


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="mode", required=True)
    listener = commands.add_parser("server", help="echo valid probe datagrams")
    listener.add_argument("--bind", default="0.0.0.0")
    listener.add_argument("--port", type=port_number, default=5202)
    listener.set_defaults(run=server)
    sender = commands.add_parser("client", help="sample UDP echo connectivity")
    sender.add_argument("--target", default="10.80.2.4")
    sender.add_argument("--port", type=port_number, default=5202)
    sender.add_argument("--bind", default="0.0.0.0")
    sender.add_argument("--source-port", type=port_number, default=0,
                        help="fixed source port; default chooses one ephemeral port")
    sender.add_argument("--duration", type=positive_float, default=120.0)
    sender.add_argument("--rate", type=positive_float, default=100.0, help="probes/second")
    sender.add_argument("--timeout", type=positive_float, default=0.5,
                        help="provisional acknowledgement timeout in seconds")
    sender.add_argument("--late-grace", type=grace_float, default=3.0,
                        help="final receive-only grace, 0 to 3 seconds")
    sender.add_argument("--log", help="event file path, including remote /var/tmp paths")
    sender.add_argument("--log-format", choices=("csv", "jsonl"), default="jsonl")
    sender.add_argument("--report", help="optional final JSON file path")
    sender.add_argument("--progress", action="store_true", help="one-second stdout markers")
    sender.set_defaults(run=client)
    args = parser.parse_args(argv)
    try:
        return args.run(args)
    except (OSError, ValueError) as error:
        marker("__PROBE_ERROR__", {"error": str(error)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
