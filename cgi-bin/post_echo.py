import os
import sys

content_length_str = os.environ.get('CONTENT_LENGTH', '0')
try:
    content_length = int(content_length_str) if content_length_str.isdigit() else 0
except Exception:
    content_length = 0

data = sys.stdin.buffer.read(content_length)

print("Content-Type: application/octet-stream")
print()
sys.stdout.buffer.write(data)
