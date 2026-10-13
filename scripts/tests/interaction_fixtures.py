"""Deterministic synthetic xcresulttool 0.4.0 reports; never launch an app."""

import hashlib
import json

import gates


def reports(scheme, test_count=2):
    device = {"deviceId": "synthetic-device", "architecture": "arm64"}
    summary = {
        "title": f"Test - {scheme}", "result": "Passed",
        "totalTestCount": test_count, "passedTests": test_count, "failedTests": 0,
        "skippedTests": 0, "expectedFailures": 0, "testFailures": [], "runtimeWarnings": [],
        "devicesAndConfigurations": [{
            "device": device, "passedTests": test_count, "failedTests": 0,
            "skippedTests": 0, "expectedFailures": 0,
        }],
    }
    tests = {
        "devices": [device],
        "testNodes": [{
            "nodeType": "Test Plan", "name": scheme, "result": "Passed", "children": [{
                "nodeType": "UI test bundle", "name": "SyntheticInteractionTests",
                "result": "Passed", "children": [{
                    "nodeType": "Test Case", "name": f"testSynthetic{index}()",
                    "nodeIdentifier": f"InteractionTests/testSynthetic{index}()", "result": "Passed",
                } for index in range(test_count)],
            }],
        }],
    }
    return {
        "summary": summary, "tests": tests,
        "availability": {"hasCoverage": False, "hasTestResults": True},
    }


def source_files(root):
    for name in ("InteractionHost", "InteractionTests"):
        path = root / name / "Synthetic.swift"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("// Synthetic fixture\n")


def write_evidence(root, directory, current, config):
    for key, platform, destination in (
        ("ios-iphone", "ios", config["IOS_TEST_DESTINATION"]),
        ("ios-ipad", "ios", config["IPAD_TEST_DESTINATION"]),
        ("macos", "macos", "platform=macOS,arch=arm64"),
    ):
        scheme = gates.INTERACTION_SCHEMES[platform]
        evidence = {
            "provenance": current, "sources": gates.interaction_sources(root),
            "scheme": scheme, "destination": destination,
        }
        for name, report in reports(scheme).items():
            content = json.dumps(report).encode()
            (directory / f"interaction-{name}-{key}.json").write_bytes(content)
            evidence[f"{name}SHA256"] = hashlib.sha256(content).hexdigest()
        (directory / f"interaction-{key}.json").write_text(json.dumps(evidence))
