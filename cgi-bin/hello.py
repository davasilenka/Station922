import os
import sys

print("Content-Type: text/plain")
print()
print("Hello, CGI!")
print("--- Environment variables ---")
for k, v in sorted(os.environ.items()):
    print(f"{k}={v}")
