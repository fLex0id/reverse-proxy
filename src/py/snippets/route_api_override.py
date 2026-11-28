import json, sys
try:
    result = json.load(sys.stdin)["balancer"]["override"]
    expected = "" if sys.argv[1] == "clear" else sys.argv[1]
    assert isinstance(result, dict) and result.get("target", "") == expected
except (ValueError, KeyError, TypeError, AssertionError):
    sys.exit(1)
