# Copyright 2026 The Radius Authors.
# Licensed under the Apache License, Version 2.0.

from pathlib import Path
import unittest

import yaml
from jsonschema import Draft4Validator


ROOT = Path(__file__).resolve().parents[3]
TYPES = {
    "stateStores": "state",
    "pubSubBrokers": "pubsub",
    "configurationStores": "configuration",
    "secretStores": "secretstores",
}


class DaprSchemaTests(unittest.TestCase):
    def test_input_constraints(self):
        for name, family in TYPES.items():
            manifest = yaml.safe_load(
                (ROOT / "Dapr" / name / f"{name}.yaml").read_text(encoding="utf-8")
            )
            versions = manifest["types"][name]["apiVersions"]
            self.assertEqual(list(versions), ["2025-08-01-preview"])
            schema = versions["2025-08-01-preview"]["schema"]
            Draft4Validator.check_schema(schema)
            validator = Draft4Validator(schema)
            # Omitted scopes are resolved by platform Recipe parameters, not the schema.
            valid = [
                {},
                {"scopes": ["backend", "a", "a" * 63]},
                {"metadata": {"plain": {"value": ""}}},
                {"metadata": {"password": {"secretKeyRef": {"name": "creds", "key": "password"}}}},
                {"componentType": f"{family}.custom", "version": "v2"},
            ]
            invalid = [
                {"scopes": []},
                {"scopes": ["backend", "backend"]},
                *({"scopes": [id_]} for id_ in ["", " ", "-app", "app-", "App", "a.b", "a" * 64]),
                {"metadata": {"password": {}}},
                {"metadata": {"password": {"value": "fixture", "secretKeyRef": {"name": "creds", "key": "password"}}}},
                {"metadata": {"password": {"secretKeyRef": {"name": "", "key": "password"}}}},
                {"metadata": {"password": {"secretKeyRef": {"name": "creds", "key": " "}}}},
                {"metadata": {"password": {"secretKeyRef": {"name": "creds"}}}},
                {"componentType": ""},
                {"componentType": "bindings.http"},
                {"version": " "},
            ]
            for properties in valid:
                with self.subTest(type=name, valid=properties):
                    validator.validate({"environment": "fixture", **properties})
            for properties in invalid:
                with self.subTest(type=name, invalid=properties):
                    self.assertFalse(validator.is_valid({"environment": "fixture", **properties}))


if __name__ == "__main__":
    unittest.main()
