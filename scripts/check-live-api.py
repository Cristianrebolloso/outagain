#!/usr/bin/env python3
"""Read-only app API checks plus one generated Storage upload, always cleaned up.

Uses an existing, unexpired simulator session; never signs in, refreshes tokens,
creates posts, sends notifications, or prints credentials.
"""
import argparse
import base64
import json
import plistlib
import re
import time
import uuid
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--session-plist", type=Path, required=True)
    args = parser.parse_args()
    source = (Path(__file__).resolve().parents[1] / "OutAgain/Services/SupabaseEnvironment.swift").read_text()
    embedded = source.split("static let embedded =", 1)[1].split("static let placeholder", 1)[0]
    base = re.search(r'projectURL: "([^"]+)"', embedded).group(1)
    key = re.search(r'anonKey: "([^"]+)"', embedded).group(1)
    prefs = plistlib.loads(args.session_plist.read_bytes())
    session = json.loads(prefs["OutAgain.supabase.session"])
    if session.get("expires_at", 0) <= time.time():
        raise RuntimeError("Session expired; open the app normally before running this check")
    viewer = session["user"]["id"].lower()
    timings = []

    def call(path, method="GET", value=None, raw=None, authenticated=True, content_type="application/json"):
        headers = {"apikey": key, "Content-Type": content_type, "Cache-Control": "no-store"}
        if authenticated:
            headers["Authorization"] = "Bearer " + session["access_token"]
        data = raw if raw is not None else (json.dumps(value).encode() if value is not None else None)
        started = time.monotonic()
        try:
            with urlopen(Request(base + path, data=data, headers=headers, method=method), timeout=30) as response:
                body = response.read()
                status = response.status
        except HTTPError as error:
            body, status = error.read(), error.code
        timings.append(round((time.monotonic() - started) * 1000))
        return status, body

    status, _ = call("/auth/v1/user")
    assert status == 200, f"Session verification failed: {status}"
    status, _ = call("/rest/v1/rpc/search_profiles", "POST", {"search_query": "al"}, authenticated=False)
    assert status in (401, 403), f"Anonymous search unexpectedly allowed: {status}"

    query = urlencode({"select": "id,username,display_name", "id": "neq." + viewer, "limit": "1"})
    status, body = call("/rest/v1/profiles?" + query)
    assert status == 200, f"Profile read failed: {status}"
    profiles = json.loads(body)
    assert profiles, "No visible counterpart available for live search verification"
    target = profiles[0]
    for fragment in [target["username"], target["username"][:2], " @" + target["username"].upper() + " ", target["display_name"]]:
        status, body = call("/rest/v1/rpc/search_profiles", "POST", {"search_query": fragment})
        assert status == 200 and any(p["id"] == target["id"] for p in json.loads(body)), "Live friend search missed the expected person"
    status, body = call("/rest/v1/posts?select=id,author_id,image_path,created_at&order=created_at.desc&limit=5")
    assert status == 200 and isinstance(json.loads(body), list), f"Feed read failed: {status}"
    posts = json.loads(body)
    image_path = next((p["image_path"] for p in posts if p.get("image_path")), None)
    if image_path:
        status, _ = call("/storage/v1/object/public/moments/" + image_path, method="HEAD", authenticated=False)
        assert status == 200, f"Existing post image failed: {status}"

    # A generated 1x1 PNG, never a real user's photo or a database post.
    image = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ1sAAAAASUVORK5CYII=")
    object_path = f"posts/{viewer}/qa-reliability-{uuid.uuid4()}.png"
    try:
        status, _ = call("/storage/v1/object/moments/" + object_path, "POST", raw=image, content_type="image/png")
        assert status in (200, 201), f"Storage upload failed: {status}"
        status, downloaded = call("/storage/v1/object/public/moments/" + object_path, authenticated=False)
        assert status == 200 and downloaded == image, "Uploaded image did not round-trip correctly"
    finally:
        status, _ = call("/storage/v1/object/moments", "DELETE", {"prefixes": [object_path]})
        assert status == 200, f"Test media cleanup failed ({status}): {object_path}"
    print(json.dumps({"result": "PASS", "checks": ["authenticated session", "anonymous search denied", "exact and partial username", "case and @ normalization", "display name", "live feed", "existing photo access", "Storage upload/read/delete"], "requests": len(timings), "median_ms": sorted(timings)[len(timings)//2], "max_ms": max(timings)}))


if __name__ == "__main__":
    main()
