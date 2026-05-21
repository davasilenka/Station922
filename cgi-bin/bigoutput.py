import os
import sys

qs = os.environ.get('QUERY_STRING', '1000000')
try:
    n = int(qs)
except Exception:
    n = 1000000

print("Content-Type: text/plain")
print()
sys.stdout.buffer.write(b"X" * n)
