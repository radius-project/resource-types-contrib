#!/usr/bin/env python3

"""Offline regression tests for native recipe publication and alias promotion."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "recipe-oci.sh"
REPOSITORY = "ghcr.io/example/recipes/demo"
SOURCE = "a" * 40
DIGEST = "sha256:" + "1" * 64
OLDER = "sha256:" + "2" * 64
NEWER = "sha256:" + "3" * 64

MOCK = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

state_path = Path(os.environ["REGISTRY_STATE"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
tool = Path(sys.argv[0]).name
state["calls"].append([tool, *args])

def finish(output="", status=0):
    state_path.write_text(json.dumps(state))
    if output:
        print(output, file=sys.stderr if status else sys.stdout)
    sys.exit(status)

if tool == "rad":
    if state.get("build_error"):
        finish("Bicep compilation failed", 1)
    target = args[args.index("--target") + 1].removeprefix("br:")
    state["tags"][target] = state["build_digest"]
    finish()
if args[0] == "resolve":
    reference = args[1]
    if reference in state.get("resolve_errors", {}):
        finish(state["resolve_errors"][reference], 1)
    if reference not in state["tags"]:
        finish(f"Error response from registry: {reference}: not found", 1)
    finish(state["tags"][reference])
if args[:2] == ["repo", "tags"]:
    if args[3:] != ["--format", "json"]:
        finish("Expected native ORAS --format json", 1)
    if state.get("list_error"):
        finish(state["list_error"], 1)
    if state.get("invalid_list"):
        finish("{}")
    prefix = args[2] + ":"
    finish(json.dumps({"tags": [
        tag[len(prefix):] for tag in state["tags"] if tag.startswith(prefix)
    ]}))
if args[0] == "tag":
    if state.get("tag_fault") == "before":
        finish("Registry connection failed before write", 1)
    repository, digest = args[1].split("@")
    for tag in args[2:]:
        state["tags"][repository + ":" + tag] = digest
    if state.get("tag_fault") == "after":
        finish("Registry response lost after write", 1)
    finish()
finish("Unexpected invocation: " + repr(args), 1)
"""


class RecipeOciTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state_file = self.root / "state.json"
        self.state_file.write_text(json.dumps({
            "tags": {}, "calls": [], "build_digest": DIGEST,
        }))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for tool in ("oras", "rad"):
            path = self.bin / tool
            path.write_text(MOCK)
            path.chmod(0o755)
        self.env = os.environ | {
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "REGISTRY_STATE": str(self.state_file),
        }
        self.subjects = self.root / "subjects.txt"
        self.subjects.write_text(f"{DIGEST[7:]}  {REPOSITORY}\n")

    def state(self):
        return json.loads(self.state_file.read_text())

    def change(self, **values):
        state = self.state()
        state.update(values)
        self.state_file.write_text(json.dumps(state))

    def seed(self, **tags):
        state = self.state()
        state["tags"].update({f"{REPOSITORY}:{tag}": digest for tag, digest in tags.items()})
        self.change(tags=state["tags"])

    def run_script(self, *args):
        return subprocess.run(
            ["bash", str(SCRIPT), *args], env=self.env,
            text=True, capture_output=True, check=False,
        )

    def publish(self, *tags):
        return self.run_script("publish", "recipe.bicep", REPOSITORY, SOURCE, *tags)

    def promote(self, version="0.62.1", channel=False):
        args = ["promote", version, str(self.subjects)]
        if channel:
            args.append(version.rsplit(".", 1)[0])
        return self.run_script(*args)

    def success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def failure(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)

    def writes(self):
        return [
            call for call in self.state()["calls"]
            if call[0] == "rad" or call[:2] == ["oras", "tag"]
        ]

    def test_main_publishes_edge_without_moving_stable_aliases(self):
        self.seed(latest=OLDER, **{"0.62": OLDER})
        result = self.publish("edge")
        self.success(result)
        self.assertEqual(result.stdout.strip(), DIGEST)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:edge"], DIGEST)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:latest"], OLDER)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:0.62"], OLDER)
        self.assertEqual(len([call for call in self.writes() if call[0] == "rad"]), 1)

    def test_retry_reuses_source_and_full_version_without_building(self):
        self.success(self.publish(SOURCE, "0.62.1"))
        before = self.writes()
        self.success(self.publish(SOURCE, "0.62.1"))
        self.assertEqual(self.writes(), before)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:0.62.1"], DIGEST)

    def test_conflicting_full_version_is_never_overwritten(self):
        self.seed(**{SOURCE: DIGEST, "0.62.1": OLDER})
        self.failure(self.publish("0.62.1"), "conflicting digest")
        self.assertEqual(self.writes(), [])
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:0.62.1"], OLDER)

    def test_publishing_cannot_bypass_alias_promotion(self):
        for tag in ("latest", "0.62", "bad tag", "a" * 129):
            with self.subTest(tag=tag):
                self.assertNotEqual(self.publish(tag).returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_source_sha_must_be_complete(self):
        result = self.run_script("publish", "recipe.bicep", REPOSITORY, "short", "edge")
        self.failure(result, "full source commit SHA")
        self.assertEqual(self.writes(), [])

    def test_auth_and_transport_errors_do_not_authorize_publication(self):
        for error in (
            "HTTP 401 unauthorized", "HTTP 403 forbidden",
            "not found: denied", "TLS handshake timeout",
        ):
            with self.subTest(error=error):
                self.change(resolve_errors={f"{REPOSITORY}:{SOURCE}": error})
                self.failure(self.publish("edge"), error)
        self.assertEqual(self.writes(), [])

    def test_error_markers_inside_a_reference_are_not_http_errors(self):
        source = "403" + "a" * 37
        self.success(self.run_script("publish", "recipe.bicep", REPOSITORY, source, "edge"))
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:edge"], DIGEST)

    def test_invalid_registry_digest_is_rejected(self):
        self.seed(**{SOURCE: "sha256:1234"})
        self.failure(self.publish("edge"), "Invalid digest")
        self.assertEqual(self.writes(), [])

    def test_build_failure_never_moves_aliases(self):
        self.seed(latest=OLDER, edge=OLDER)
        self.change(build_error=True)
        self.failure(self.publish("edge"), "Bicep compilation failed")
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:edge"], OLDER)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:latest"], OLDER)

    def test_prerelease_publishes_full_version_without_aliases(self):
        self.seed(latest=OLDER, edge=OLDER)
        self.success(self.publish("0.63.0-rc.1"))
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:0.63.0-rc.1"], DIGEST)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:latest"], OLDER)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:edge"], OLDER)

    def test_stable_promotes_same_digest_after_verification(self):
        self.seed(**{"0.62.1": DIGEST, "0.62": OLDER, "latest": OLDER, "edge": NEWER})
        self.success(self.promote(channel=True))
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:latest"], DIGEST)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:0.62"], DIGEST)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:edge"], NEWER)
        self.assertFalse(any(call[0] == "rad" for call in self.writes()))

    def test_older_line_patch_only_updates_its_channel(self):
        self.seed(**{"0.62.1": DIGEST, "0.63.0": NEWER, "latest": NEWER, "0.62": OLDER})
        self.success(self.promote(channel=True))
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:latest"], NEWER)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:0.62"], DIGEST)

    def test_older_same_line_changes_neither_alias(self):
        self.seed(**{"0.62.1": DIGEST, "0.62.2": NEWER, "latest": NEWER, "0.62": NEWER})
        result = self.promote(channel=True)
        self.success(result)
        self.assertIn("newer version 0.62.2", result.stderr)
        self.assertEqual(self.writes(), [])

    def test_channel_comparison_uses_whole_major_and_minor(self):
        self.seed(**{"0.62.1": DIGEST, "10.62.2": NEWER, "latest": NEWER})
        self.success(self.promote(channel=True))
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:0.62"], DIGEST)
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:latest"], NEWER)

    def test_version_order_is_numeric_and_ignores_unrelated_tags(self):
        self.seed(**{
            "0.62.10": DIGEST, "0.62.9": OLDER, "99.0.0-rc.1": NEWER,
            "Radius.Data/v99.0.0": NEWER, "latest": OLDER,
        })
        self.success(self.promote("0.62.10"))
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:latest"], DIGEST)

    def test_rc_cannot_be_promoted(self):
        self.failure(self.promote("0.63.0-rc.1"), "stable full version")
        self.assertEqual(self.writes(), [])

    def test_promote_requires_the_attested_full_version_digest(self):
        self.seed(**{"0.62.1": OLDER})
        self.failure(self.promote(), "Full-version digest changed")
        self.assertEqual(self.writes(), [])

    def test_invalid_or_empty_subjects_are_rejected(self):
        for subjects in ("", "\n", "invalid subject\n", f"{DIGEST[7:]}  {REPOSITORY} extra\n"):
            with self.subTest(subjects=subjects):
                self.subjects.write_text(subjects)
                self.assertNotEqual(self.promote().returncode, 0)
        self.assertEqual(self.writes(), [])

    def test_tag_listing_errors_never_authorize_promotion(self):
        self.seed(**{"0.62.1": DIGEST})
        self.change(list_error="HTTP 403 forbidden")
        self.failure(self.promote(), "HTTP 403 forbidden")
        self.change(list_error="", invalid_list=True)
        self.failure(self.promote(), "Invalid registry tag listing")
        self.assertEqual(self.writes(), [])

    def test_lost_tag_response_is_reconciled_by_digest(self):
        self.seed(**{"0.62.1": DIGEST})
        self.change(tag_fault="after")
        self.success(self.promote())
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:latest"], DIGEST)
        before = self.writes()
        self.success(self.promote())
        self.assertEqual(self.writes(), before)

    def test_failed_tag_write_is_not_success(self):
        self.seed(**{"0.62.1": DIGEST, "latest": OLDER})
        self.change(tag_fault="before")
        self.failure(self.promote(), "did not resolve")
        self.assertEqual(self.state()["tags"][f"{REPOSITORY}:latest"], OLDER)

    def test_workflow_keeps_promotion_after_attestation_and_serializes_writers(self):
        workflow = (SCRIPT.parents[1] / "workflows" / "publish-bicep-recipes.yaml").read_text()
        self.assertIn("group: publish-bicep-recipes\n", workflow)
        self.assertIn("queue: max", workflow)
        self.assertIn("needs: [publish-bicep-recipes, attest-bicep-recipes]", workflow)
        self.assertIn("!contains(inputs.release_version, '-') && !inputs.pin_only", workflow)
        self.assertIn('repos/radius-project/radius/releases/tags/v${RELEASE_VERSION}', workflow)
        self.assertIn('tags="$COMMIT_SHA"', workflow)
        self.assertEqual(workflow.count("id-token: write"), 1)


if __name__ == "__main__":
    unittest.main()
