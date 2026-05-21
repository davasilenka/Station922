import os
import sys

qs = os.environ.get('QUERY_STRING', '').strip()
if qs:
    # expected format: statuscode reason, e.g. "404 Not Found"
    parts = qs.split(' ', 1)
    code = parts[0]
    reason = parts[1] if len(parts) > 1 else ''
else:
    code = '200'
    reason = 'OK'

print(f"Status: {code} {reason}")
print("Content-Type: text/plain")
print()
print(f"Status line: {code} {reason}")
