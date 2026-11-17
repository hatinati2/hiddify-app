#!/usr/bin/env python3
"""Apply V2rayWatch-style real-delay checks to the pinned Hiddify Core source."""
from pathlib import Path

CORE = Path("hiddify-core/hiddify-sing-box")
URLTEST = CORE / "common/urltest/urltest.go"
TESTS = CORE / "common/urltest/h_urltest_test.go"


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one matching block, found {count}")
    return source.replace(old, new, 1)


src = URLTEST.read_text(encoding="utf-8")
src = replace_once(
    src,
    "http.NewRequest(http.MethodHead, link, nil)",
    "http.NewRequest(http.MethodGet, link, nil)",
    "HTTP HEAD -> GET",
)

src = replace_once(
    src,
    """\tresp, err := client.Do(req.WithContext(ctx))
\tif err != nil {
\t\treturn
\t}
\tresp.Body.Close()

\tt = uint16(time.Since(start) / time.Millisecond)
""",
    """\tresp, err := client.Do(req.WithContext(ctx))
\tif err != nil {
\t\treturn
\t}
\tif resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
\t\tresp.Body.Close()
\t\treturn 0, fmt.Errorf("urltest: unexpected HTTP status %d from %s", resp.StatusCode, link)
\t}
\tresp.Body.Close()

\tt = uint16(time.Since(start) / time.Millisecond)
\tif t == 0 {
\t\tt = 1
\t}
""",
    "primary Real Delay response validation",
)

src = replace_once(
    src,
    """\t\tresp, err = client.Do(req.WithContext(ctx)) //H: a cancel did not stop the second request
\t\tif err != nil {
\t\t\treturn
\t\t}
\t\tresp.Body.Close()
\t\tt = uint16(time.Since(second) / time.Millisecond) //to avid timeout in the second call
""",
    """\t\tresp, err = client.Do(req.WithContext(ctx))
\t\tif err != nil {
\t\t\treturn
\t\t}
\t\tif resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
\t\t\tresp.Body.Close()
\t\t\treturn 0, fmt.Errorf("urltest: unexpected HTTP status %d from %s", resp.StatusCode, link)
\t\t}
\t\tresp.Body.Close()
\t\tt = uint16(time.Since(second) / time.Millisecond)
\t\tif t == 0 {
\t\t\tt = 1
\t\t}
""",
    "unified Real Delay response validation",
)
URLTEST.write_text(src, encoding="utf-8")

tests = TESTS.read_text(encoding="utf-8")
tests = replace_once(
    tests,
    "require.Equal(t, http.MethodHead, r.Method)",
    "require.Equal(t, http.MethodGet, r.Method)",
    "URLTest method expectation",
)

insert_before = """func TestH_URLTestCanceledAfterDialReportsError(t *testing.T) {"""
new_tests = r'''func TestH_URLTestAcceptsHTTP200(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, http.MethodGet, r.Method)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(server.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	delay, err := URLTest(ctx, "http://probe.example/success", &loopbackDialer{addr: server.Listener.Addr().String()})
	require.NoError(t, err)
	require.GreaterOrEqual(t, delay, uint16(1))
}

func TestH_URLTestRejectsHTTP403(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, http.MethodGet, r.Method)
		w.WriteHeader(http.StatusForbidden)
	}))
	t.Cleanup(server.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := URLTest(ctx, "http://probe.example/blocked", &loopbackDialer{addr: server.Listener.Addr().String()})
	require.Error(t, err, "an HTTP error page must not mark a proxy as online")
}
'''
tests = replace_once(tests, insert_before, new_tests + "\n" + insert_before, "Real Delay status tests")
TESTS.write_text(tests, encoding="utf-8")

print("Applied V2rayWatch-style Real Delay: HTTP GET, status 200/204 only, min 1 ms.")
