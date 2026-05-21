import os
import sys
import time

qs = os.environ.get('QUERY_STRING', '60')
try:
    sleep_seconds = int(qs)
except Exception:
    sleep_seconds = 60

print("Content-Type: text/plain")
print()
sys.stdout.write(f"Sleeping {sleep_seconds} seconds...\n")
sys.stdout.flush()
time.sleep(sleep_seconds)
print("Done")
