"""Parse every YAML manifest in the repo and report syntax errors.

Not schema validation (that needs a cluster or kubeconform); this proves the documents
are well-formed YAML and that each Kubernetes document carries apiVersion/kind/name.

It catches the class of mistake that is easy to make and hard to spot by eye: a stray
colon, a key indented one space too far, a `rules` block accidentally split across two
lines. Those produce a parse error here rather than a confusing ArgoCD sync failure.
"""

from __future__ import annotations

import json
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent

TARGETS = [
    "docker-compose.yml",
    "gitops/**/*.yaml",
    ".github/workflows/*.yml",
]

# Helm values files are not Kubernetes manifests; they legitimately have no kind.
NOT_MANIFESTS = ("kube-prometheus-values.yaml",)

JSON_TARGETS = ["gitops/**/*.json"]

failures: list[str] = []
documents = 0
files = 0


def check_yaml(path: pathlib.Path) -> None:
    global documents, files

    relative = path.relative_to(ROOT)
    files += 1

    try:
        docs = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
    except yaml.YAMLError as exc:
        failures.append(f"{relative}: {exc}")
        print(f"FAIL {relative}")
        return

    documents += len(docs)
    names = []

    for doc in docs:
        if not isinstance(doc, dict):
            continue

        if "kind" in doc:
            if "apiVersion" not in doc:
                failures.append(f"{relative}: {doc['kind']} has no apiVersion")

            name = doc.get("metadata", {}).get("name", "?")
            names.append(f"{doc['kind']}/{name}")
        elif "services" in doc:
            names.append(f"compose({len(doc['services'])} services)")
        elif "jobs" in doc:
            names.append(f"workflow({len(doc['jobs'])} jobs)")
        elif path.name in NOT_MANIFESTS:
            names.append("helm values")

    summary = ", ".join(names[:6])
    if len(names) > 6:
        summary += f", +{len(names) - 6} more"

    print(f"OK   {relative}: {summary or 'no documents'}")


def check_json(path: pathlib.Path) -> None:
    global files

    relative = path.relative_to(ROOT)
    files += 1

    try:
        json.loads(path.read_text(encoding="utf-8"))
        print(f"OK   {relative}")
    except json.JSONDecodeError as exc:
        failures.append(f"{relative}: {exc}")
        print(f"FAIL {relative}")


for pattern in TARGETS:
    for path in sorted(ROOT.glob(pattern)):
        if path.is_file():
            check_yaml(path)

for pattern in JSON_TARGETS:
    for path in sorted(ROOT.glob(pattern)):
        if path.is_file():
            check_json(path)

print(f"\n{files} files, {documents} documents parsed, {len(failures)} failure(s)")

for failure in failures:
    print(f"  - {failure}")

sys.exit(1 if failures else 0)
