"""
test_cgi.py — автотесты CGI для Station922
Запускать при работающем сервере (Station922_x64.exe)
Ожидает сервер на http://localhost:80
"""

import http.client
import sys
import threading
import time
import os

BASE_URL = "localhost"
BASE_PORT = 80
TIMEOUT = 10

TOTAL = 0
PASSED = 0
FAILED = 0
FAILURES = []


def check(name, condition, detail=""):
    global TOTAL, PASSED, FAILED
    TOTAL += 1
    if condition:
        PASSED += 1
        print(f"  PASS {name}")
    else:
        FAILED += 1
        msg = f"  FAIL {name}: {detail}"
        print(msg)
        FAILURES.append(msg)


def http_get(path, headers=None):
    conn = http.client.HTTPConnection(BASE_URL, BASE_PORT, timeout=TIMEOUT)
    try:
        conn.request("GET", path, headers=headers or {})
        resp = conn.getresponse()
        body = resp.read()
        return resp.status, resp.getheaders(), body
    except Exception as e:
        return None, None, str(e)
    finally:
        conn.close()


def http_post(path, body_data, headers=None):
    conn = http.client.HTTPConnection(BASE_URL, BASE_PORT, timeout=TIMEOUT)
    try:
        hdrs = headers or {}
        if not any(k.lower() == "content-type" for k in hdrs):
            hdrs["Content-Type"] = "application/octet-stream"
        conn.request("POST", path, body=body_data, headers=hdrs)
        resp = conn.getresponse()
        body = resp.read()
        return resp.status, resp.getheaders(), body
    except Exception as e:
        return None, None, str(e)
    finally:
        conn.close()


def header_value(headers, name):
    name_lower = name.lower()
    for k, v in headers:
        if k.lower() == name_lower:
            return v
    return None


def find_in_body(body, text):
    if isinstance(body, bytes):
        return text.encode("utf-8") in body
    return text in body


def get_env_from_body(body):
    """Parse env dump (KEY=VALUE per line) from body text."""
    env = {}
    if isinstance(body, bytes):
        text = body.decode("utf-8", errors="replace")
    else:
        text = body
    for line in text.split("\n"):
        line = line.strip()
        if "=" in line:
            key, _, value = line.partition("=")
            env[key] = value
    return env


# ============================================================
# TEST 1: Python CGI - GET hello.py
# ============================================================
def test_hello_get():
    status, headers, body = http_get("/cgi-bin/hello.py")
    check("GET hello.py returns 200", status == 200,
          f"status={status}, body_preview={str(body[:200]) if body else 'None'}")
    check("GET hello.py body contains 'Hello, CGI!'",
          find_in_body(body, "Hello, CGI!"),
          f"body_preview={str(body[:200]) if body else 'None'}")


# ============================================================
# TEST 2: Все обязательные переменные окружения
# ============================================================
def test_env_vars():
    status, headers, body = http_get("/cgi-bin/env.py")
    check("GET env.py returns 200", status == 200,
          f"status={status}")
    if status != 200:
        return
    env = get_env_from_body(body)

    mandatory = [
        "GATEWAY_INTERFACE",
        "SERVER_NAME",
        "SERVER_PORT",
        "REQUEST_METHOD",
        "QUERY_STRING",
        "SERVER_PROTOCOL",
        "SERVER_SOFTWARE",
        "SCRIPT_NAME",
    ]
    for var in mandatory:
        check(f"env var {var} present",
              var in env,
              f"env keys found: {sorted(env.keys())[:20]}")

    check("GATEWAY_INTERFACE=CGI/1.1",
          env.get("GATEWAY_INTERFACE") == "CGI/1.1",
          f"got: {env.get('GATEWAY_INTERFACE')}")
    check("SERVER_PROTOCOL=HTTP/1.1",
          env.get("SERVER_PROTOCOL") == "HTTP/1.1",
          f"got: {env.get('SERVER_PROTOCOL')}")
    check("SERVER_SOFTWARE=Station922/1.0",
          env.get("SERVER_SOFTWARE") == "Station922/1.0",
          f"got: {env.get('SERVER_SOFTWARE')}")
    check("REQUEST_METHOD=GET",
          env.get("REQUEST_METHOD") == "GET",
          f"got: {env.get('REQUEST_METHOD')}")
    check("SCRIPT_NAME contains script",
          "env.py" in env.get("SCRIPT_NAME", ""),
          f"got: {env.get('SCRIPT_NAME')}")


# ============================================================
# TEST 3: Query string
# ============================================================
def test_query_string():
    status, headers, body = http_get("/cgi-bin/env.py?a=1&b=2")
    check("GET env.py with query returns 200", status == 200)
    if status != 200:
        return
    env = get_env_from_body(body)
    check("QUERY_STRING=a=1&b=2 (no ?)",
          env.get("QUERY_STRING") == "a=1&b=2",
          f"got: {env.get('QUERY_STRING')}")


# ============================================================
# TEST 4: POST body echo
# ============================================================
def test_post_echo():
    test_data = b"Hello, POST body!"
    status, headers, body = http_post("/cgi-bin/post_echo.py", test_data)
    check("POST post_echo.py returns 200", status == 200,
          f"status={status}")
    check("POST post_echo.py echoes body",
          test_data in body if isinstance(body, bytes) else False,
          f"expected={test_data!r}, got={body[:100]!r}")


# ============================================================
# TEST 5: HTTP_* headers
# ============================================================
def test_http_headers():
    hdrs = {"Accept-Language": "ru", "User-Agent": "TestAgent/1.0"}
    status, headers, body = http_get("/cgi-bin/env.py", headers=hdrs)
    check("GET env.py with custom headers returns 200", status == 200)
    if status != 200:
        return
    env = get_env_from_body(body)
    check("HTTP_ACCEPT_LANGUAGE=ru",
          env.get("HTTP_ACCEPT_LANGUAGE") == "ru",
          f"got: {env.get('HTTP_ACCEPT_LANGUAGE')}")
    check("HTTP_USER_AGENT=TestAgent/1.0",
          env.get("HTTP_USER_AGENT") == "TestAgent/1.0",
          f"got: {env.get('HTTP_USER_AGENT')}")


# ============================================================
# TEST 6: Status header
# ============================================================
def test_status_header():
    # Test with 404 Not Found
    status, headers, body = http_get("/cgi-bin/status.py?404+Not+Found")
    check("status.py?404 returns 404",
          status == 404,
          f"status={status}")
    # Test default (200)
    status, headers, body = http_get("/cgi-bin/status.py")
    check("status.py without query returns 200",
          status == 200,
          f"status={status}")


# ============================================================
# TEST 7: 404 for nonexistent script
# ============================================================
def test_nonexistent():
    status, headers, body = http_get("/cgi-bin/nonexistent.py")
    check("GET nonexistent.py returns 404",
          status == 404,
          f"status={status}")


# ============================================================
# TEST 8: exit1.py -> 502
# ============================================================
def test_exit1():
    status, headers, body = http_get("/cgi-bin/exit1.py")
    check("GET exit1.py returns 502",
          status == 502,
          f"status={status}")


# ============================================================
# TEST 9: Параллельные запросы
# ============================================================
def concurrent_worker(path, results, idx):
    try:
        status, hdrs, body = http_get(path)
        results[idx] = status
    except Exception as e:
        results[idx] = str(e)


def test_concurrent():
    path = "/cgi-bin/hello.py"
    count = 5
    results = [None] * count
    threads = []
    for i in range(count):
        t = threading.Thread(target=concurrent_worker, args=(path, results, i))
        threads.append(t)
        t.start()
    for t in threads:
        t.join()
    all_200 = all(r == 200 for r in results)
    check(f"5 parallel GET hello.py -> all 200",
          all_200,
          f"results={results}")


# ============================================================
# TEST 10: Таймаут
# ============================================================
def test_timeout():
    status, headers, body = http_get("/cgi-bin/slow.py")
    check("GET slow.py returns 504 (timeout)",
          status == 504,
          f"status={status}, CgiTimeout in WebSites.ini should be set to 3000 (3s)")


# ============================================================
# TEST 11: Большой вывод
# ============================================================
def test_bigoutput():
    # Request 1MB of output (within the 1MB limit set in WebSites.ini)
    status, headers, body = http_get("/cgi-bin/bigoutput.py?200000")
    check("GET bigoutput.py?200000 returns 200",
          status == 200,
          f"status={status}")
    if status == 200 and body:
        check("bigoutput body >= 200000 bytes",
              len(body) >= 200000,
              f"body_len={len(body)}")


# ============================================================
# TEST 12: Content-Type from CGI response
# ============================================================
def test_content_type():
    status, headers, body = http_get("/cgi-bin/hello.py")
    check("GET hello.py returns 200 (CT check)", status == 200)
    if status != 200:
        return
    ct = header_value(headers, "Content-Type")
    check("hello.py Content-Type is text/plain",
          ct and "text/plain" in ct.lower(),
          f"got: {ct}")


# ============================================================
# MAIN
# ============================================================
def main():
    global TOTAL, PASSED, FAILED

    print("=" * 60)
    print("  Station922 CGI Test Suite")
    print("=" * 60)
    print(f"  Server: http://{BASE_URL}:{BASE_PORT}")
    print()

    # Quick health check
    print("--- Health check ---")
    status, _, body = http_get("/cgi-bin/hello.py")
    if status is None:
        print(f"  ERROR: Cannot connect to server at {BASE_URL}:{BASE_PORT}")
        print(f"  Error: {body}")
        print("  Start Station922_x64.exe first!")
        sys.exit(1)
    print("  Server is reachable")
    print()

    tests = [
        ("hello.py GET", test_hello_get),
        ("env vars", test_env_vars),
        ("query string", test_query_string),
        ("POST body echo", test_post_echo),
        ("HTTP_* headers", test_http_headers),
        ("Status header", test_status_header),
        ("nonexistent -> 404", test_nonexistent),
        ("exit1 -> 502", test_exit1),
        ("5 parallel requests", test_concurrent),
        ("slow.py timeout -> 504", test_timeout),
        ("bigoutput.py", test_bigoutput),
        ("Content-Type", test_content_type),
    ]

    for name, func in tests:
        print(f"\n--- {name} ---")
        func()

    print()
    print("=" * 60)
    print(f"  RESULTS: {PASSED}/{TOTAL} passed, {FAILED} failed")
    print("=" * 60)
    if FAILURES:
        print()
        print("Failures:")
        for f in FAILURES:
            print(f"  {f}")

    if FAILED > 0:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
