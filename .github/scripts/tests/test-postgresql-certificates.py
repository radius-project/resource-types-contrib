#!/usr/bin/env python3
"""Execute the certificate preparation embedded in both Kubernetes Recipes."""

import os
from datetime import datetime, timedelta
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap


ROOT = Path(__file__).resolve().parents[3]
RECIPES = ROOT / "Data/postgreSqlDatabases/recipes/kubernetes"
bicep = (RECIPES / "bicep/kubernetes-postgresql.bicep").read_text()
terraform = (RECIPES / "terraform/main.tf").read_text()
bicep_script = re.search(r"'''\n(umask 077.*?)\n'''", bicep, re.S).group(1)
terraform_script = textwrap.dedent(
    re.search(r"<<-EOT\n(.*?)\n\s*EOT", terraform, re.S).group(1)
)
assert bicep_script == terraform_script, "Certificate preparation differs between Recipes"
assert "progressDeadlineSeconds:" not in bicep
assert "progress_deadline_seconds" not in terraform
assert "timeouts {" not in terraform
images = re.findall(r"python:3\.13-slim-bookworm@sha256:[a-f0-9]{64}", bicep + terraform)
assert len(images) == 2 and images[0] == images[1]


def openssl(*args):
    return subprocess.run(
        ["openssl", *map(str, args)], check=True, capture_output=True, timeout=30
    ).stdout


with tempfile.TemporaryDirectory(prefix="rtc-postgresql-certificates-") as directory:
    root = Path(directory)
    for kind, key_args in (
        ("rsa", ["-newkey", "rsa:2048"]),
        ("ec", ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256"]),
    ):
        openssl(
            "req", "-x509", *key_args, "-nodes", "-days", "1",
            "-subj", "/CN=operator", "-keyout", root / f"{kind}.key",
            "-out", root / f"{kind}.crt",
        )
    openssl(
        "pkey", "-in", root / "rsa.key", "-aes-256-cbc", "-passout",
        "pass:fixture-password", "-out", root / "encrypted.key",
    )

    def run_case(name, files, succeeds, projection=False):
        case = root / name
        source = case / "source"
        runtime = case / "runtime"
        source.mkdir(parents=True)
        runtime.mkdir()
        material = source
        if projection:
            material = source / "..revision"
            material.mkdir()
            (source / "..data").symlink_to(material, target_is_directory=True)
        for filename, data in files.items():
            (material / filename).write_bytes(data)
        script = bicep_script.replace("/tls-source", str(source)).replace(
            "/tls-runtime", str(runtime)
        )
        result = subprocess.run(
            ["sh", "-ec", script],
            env={
                **os.environ,
                "RADIUS_TLS_SECRET": "postgresql-tls",
                "RADIUS_TLS_HOST": "postgresql.isolated.svc.cluster.local",
                "RADIUS_RESOURCE_NAME": "postgresql",
                "RADIUS_NAMESPACE": "isolated",
            },
            capture_output=True,
            timeout=30,
        )
        assert (result.returncode == 0) == succeeds, (name, result.stderr.decode())
        output = result.stdout + result.stderr
        assert b"PRIVATE KEY" not in output and b"fixture-password" not in output
        for value in files.values():
            if len(value) > 100:
                assert value not in output, f"{name}: leaked supplied material"
        assert not list(runtime.glob("prepare.*")), f"{name}: temporary files leaked"
        if succeeds:
            certificate = runtime / "server.crt"
            key = runtime / "server.key"
            assert key.stat().st_mode & 0o777 == 0o600
            assert openssl("x509", "-in", certificate, "-pubkey", "-noout") == openssl(
                "pkey", "-in", key, "-pubout"
            )
            if files:
                assert certificate.read_bytes() == files["tls.crt"]
                assert key.read_bytes() == files["tls.key"]
            else:
                sans = openssl("x509", "-in", certificate, "-noout", "-ext", "subjectAltName")
                assert b"DNS:postgresql.isolated.svc.cluster.local" in sans
                assert b"DNS:postgresql.isolated.svc" in sans
                assert b"DNS:postgresql," in sans
                details = openssl("x509", "-in", certificate, "-noout", "-text")
                assert b"Public-Key: (2048 bit)" in details
                assert b"Signature Algorithm: sha256WithRSAEncryption" in details
                assert b"CA:FALSE" in details and b"TLS Web Server Authentication" in details
                dates = openssl("x509", "-in", certificate, "-noout", "-dates").decode()
                start, end = (
                    datetime.strptime(line.split("=", 1)[1], "%b %d %H:%M:%S %Y %Z")
                    for line in dates.splitlines()
                )
                assert end - start == timedelta(days=365)
        else:
            assert b"Error: PostgreSQL TLS Secret postgresql-tls" in output
            assert not (runtime / "server.key").exists()
            assert b"Generating a self-signed" not in output

    run_case("absent", {}, True)
    run_case("empty-projection", {}, True, projection=True)
    for kind in ("rsa", "ec"):
        run_case(
            f"operator-{kind}",
            {"tls.crt": (root / f"{kind}.crt").read_bytes(),
             "tls.key": (root / f"{kind}.key").read_bytes()},
            True, projection=True,
        )
    valid = {"tls.crt": (root / "rsa.crt").read_bytes(),
             "tls.key": (root / "rsa.key").read_bytes()}
    run_case("chain", {**valid, "tls.crt": valid["tls.crt"] * 2}, True)
    for name, files in (
        ("only-certificate", {"tls.crt": valid["tls.crt"]}),
        ("only-key", {"tls.key": valid["tls.key"]}),
        ("empty-files", {"tls.crt": b"", "tls.key": b""}),
        ("unrelated-data", {"wrong": b"supplied"}),
        ("hidden-data", {".wrong": b"supplied"}),
        ("malformed-certificate", {**valid, "tls.crt": b"invalid"}),
        ("malformed-key", {**valid, "tls.key": b"invalid"}),
        ("mismatched-key", {**valid, "tls.key": (root / "ec.key").read_bytes()}),
        ("encrypted-key", {**valid, "tls.key": (root / "encrypted.key").read_bytes()}),
    ):
        run_case(name, files, False, projection=True)

print("PostgreSQL certificate preparation and Recipe parity tests passed.")
