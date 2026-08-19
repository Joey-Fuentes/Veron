#!/usr/bin/env python3
# Extract the GitHub Actions run id(s) from a `gh api attestations` response.
# DEPENDENCY-FREE (python only -- Veron ships python, not jq), so this same
# tool verifies the chain on-device exactly as it does in CI. The run id lives
# in the base64 DSSE payload, at predicate.runDetails.metadata.invocationId,
# as .../actions/runs/<id>/attempts/N -- NOT in the raw JSON, which is why a
# plain grep for "actions/runs" finds nothing.
import json, base64, re, sys

def run_ids(path):
    out = []
    try:
        d = json.load(open(path))
    except Exception:
        return out
    for a in d.get("attestations", []):
        try:
            payload = a["bundle"]["dsseEnvelope"]["payload"]
            pred = json.loads(base64.b64decode(payload).decode())
            inv = pred["predicate"]["runDetails"]["metadata"]["invocationId"]
            m = re.search(r"runs/(\d+)", inv)
            if m:
                out.append(m.group(1))
        except Exception:
            pass
    return out

if __name__ == "__main__":
    for path in sys.argv[1:]:
        for r in run_ids(path):
            print(r)
