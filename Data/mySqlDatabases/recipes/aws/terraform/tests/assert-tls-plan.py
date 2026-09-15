#!/usr/bin/env python3
"""Check real module resources in `terraform test -json -verbose` output."""

import json
import sys


EXPECTED = {"omitted": "1", "required": "1", "optional": "0", "null_policy": "1"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def resource_after(plan, resource_type):
    matches = [
        resource
        for resource in plan["resource_changes"]
        if resource["type"] == resource_type
        and resource["address"].startswith("module.db.")
        and resource["mode"] == "managed"
    ]
    require(len(matches) == 1, f"expected one RDS {resource_type}")
    change = matches[0]["change"]
    require(change["actions"] == ["create"], f"expected a new {resource_type}")
    return change["after"]


def check_plan(plan, expected):
    group = resource_after(plan, "aws_db_parameter_group")
    parameters = {item["name"]: item for item in group["parameter"]}
    require(
        len(group["parameter"]) == len(parameters) == 3,
        "expected exactly the transport and two character-set parameters",
    )
    for name in ("character_set_client", "character_set_server"):
        require(parameters[name]["value"] == "utf8mb4", f"{name} changed")
    transport = parameters["require_secure_transport"]
    require(transport["value"] == expected, "incorrect require_secure_transport value")
    require(transport["apply_method"] == "immediate", "transport is not immediate")
    require(group["family"] == "mysql8.0", "parameter group family changed")

    instance = resource_after(plan, "aws_db_instance")
    require(
        group["id"] == group["name"] == instance.get("parameter_group_name"),
        "RDS instance is not attached to the planned parameter group",
    )
    require(instance["apply_immediately"] is True, "instance changes are not immediate")
    require(instance["engine"] == "mysql", "database engine changed")


def main(stream):
    plans = set()
    passed = set()
    summary = None
    for line in stream:
        if not line.strip():
            continue
        message = json.loads(line.lstrip("\ufeff"))
        kind = message["type"]
        if kind == "diagnostic":
            diagnostic = message["diagnostic"]
            # Do not echo verbose plans or source excerpts containing credentials.
            require(
                diagnostic["severity"] != "error",
                f"Terraform diagnostic: {diagnostic['summary']}",
            )
        elif kind == "test_plan":
            run = message["@testrun"]
            require(run in EXPECTED, f"unexpected plan run: {run}")
            require(run not in plans, f"duplicate plan run: {run}")
            try:
                check_plan(message["test_plan"], EXPECTED[run])
            except (ValueError, KeyError, TypeError) as error:
                raise ValueError(f"{run}: {error}") from error
            plans.add(run)
        elif kind == "test_run":
            run = message["test_run"]
            if run["progress"] == "complete":
                require(run["status"] == "pass", f"Terraform run failed: {run['run']}")
                passed.add(run["run"])
        elif kind == "test_summary":
            summary = message["test_summary"]

    require(plans == set(EXPECTED), "missing TLS policy plans")
    require(passed == set(EXPECTED), "missing passing Terraform runs")
    require(
        summary is not None
        and summary["status"] == "pass"
        and summary["passed"] == len(EXPECTED)
        and summary["failed"] == 0
        and summary["errored"] == 0
        and summary["skipped"] == 0,
        "missing or unsuccessful Terraform test summary",
    )
    for run, value in EXPECTED.items():
        print(f"PASS {run}: require_secure_transport={value}, immediate, group attached")
    print("PASS: all four RDS module plans preserve character sets and enforce TLS policy")


if __name__ == "__main__":
    try:
        main(sys.stdin)
    except (ValueError, KeyError, TypeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
