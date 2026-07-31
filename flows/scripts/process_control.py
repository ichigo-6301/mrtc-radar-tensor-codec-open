#!/usr/bin/env python3
"""Run owned commands with bounded, non-escalating process-group cleanup."""

import os
import signal
import subprocess
import time


TERMINATION_GRACE_SECONDS = 30


class ProcessTimeoutError(RuntimeError):
    """Raised after an owned command exceeds its timeout."""


def _process_group_popen_kwargs(platform_name=None):
    platform_name = platform_name or os.name
    if platform_name == "nt":
        creation_flag = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        if creation_flag:
            return {"creationflags": creation_flag}
        return {}
    return {"start_new_session": True}


def _terminate_owned_process(process, platform_name=None):
    platform_name = platform_name or os.name
    if process.poll() is not None:
        return "already_exited"
    if platform_name == "nt":
        ctrl_break = getattr(signal, "CTRL_BREAK_EVENT", None)
        new_process_group = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        if ctrl_break is not None and new_process_group:
            try:
                process.send_signal(ctrl_break)
                return "ctrl_break_process_group"
            except (OSError, ValueError):
                pass
        process.terminate()
        return "terminate_exact_child"

    try:
        process_group = os.getpgid(process.pid)
        if process_group != process.pid:
            process.terminate()
            return "terminate_exact_child_unexpected_process_group"
        os.killpg(process_group, signal.SIGTERM)
        return "sigterm_process_group"
    except ProcessLookupError:
        return "already_exited"
    except (AttributeError, OSError):
        process.terminate()
        return "terminate_exact_child"


def run_bounded_process(
    command, cwd, stdout, timeout_seconds, environment=None, resource_monitor=None
):
    """Run one owned command and never escalate beyond TERM on timeout."""
    process = subprocess.Popen(
        [str(item) for item in command],
        cwd=str(cwd),
        env=environment,
        stdout=stdout,
        stderr=subprocess.STDOUT,
        **_process_group_popen_kwargs()
    )
    previous_handlers = {}

    def forward_parent_signal(signal_number, _frame):
        _terminate_owned_process(process)
        try:
            process.wait(timeout=TERMINATION_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            pass
        raise SystemExit(128 + signal_number)

    for signal_number in (signal.SIGTERM, signal.SIGINT):
        try:
            previous_handlers[signal_number] = signal.getsignal(signal_number)
            signal.signal(signal_number, forward_parent_signal)
        except (AttributeError, ValueError):
            pass
    try:
        try:
            if resource_monitor is None:
                return process.wait(timeout=timeout_seconds)
            deadline = time.monotonic() + timeout_seconds
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout_seconds)
                try:
                    return process.wait(timeout=min(5.0, remaining))
                except subprocess.TimeoutExpired:
                    if time.monotonic() >= deadline:
                        raise
                    try:
                        resource_monitor(process.pid)
                    except RuntimeError as error:
                        termination = _terminate_owned_process(process)
                        try:
                            returncode = process.wait(
                                timeout=TERMINATION_GRACE_SECONDS
                            )
                        except subprocess.TimeoutExpired:
                            raise ProcessTimeoutError(
                                "resource guard requested TERM; reason={}; "
                                "termination={}; pid={}; process still active after "
                                "{} second TERM grace".format(
                                    error,
                                    termination,
                                    process.pid,
                                    TERMINATION_GRACE_SECONDS,
                                )
                            )
                        raise RuntimeError(
                            "resource guard stopped owned pid {}; reason={}; "
                            "termination={}; returncode={}".format(
                                process.pid, error, termination, returncode
                            )
                        )
        except subprocess.TimeoutExpired:
            termination = _terminate_owned_process(process)
            try:
                returncode = process.wait(timeout=TERMINATION_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                raise ProcessTimeoutError(
                    "command timed out after {} seconds; termination={} pid={}; "
                    "process still active after {} second TERM grace; no further "
                    "signal was sent".format(
                        timeout_seconds,
                        termination,
                        process.pid,
                        TERMINATION_GRACE_SECONDS,
                    )
                )
            raise ProcessTimeoutError(
                "command timed out after {} seconds; termination={} pid={} "
                "returncode={}".format(
                    timeout_seconds, termination, process.pid, returncode
                )
            )
    finally:
        for signal_number, previous_handler in previous_handlers.items():
            signal.signal(signal_number, previous_handler)
