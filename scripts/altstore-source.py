#!/usr/bin/env python3
"""Build stable/testing AltStore sources from published GitHub IPA releases."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta)\.(\d+))?$")


def github(*args):
    return json.loads(subprocess.check_output(["gh", *args], text=True, encoding="utf-8"))


def release_key(release):
    match = TAG.fullmatch(release["tagName"])
    if not match:
        return None
    major, minor, patch, channel, build = match.groups()
    return (int(major), int(minor), int(patch), {"alpha": 0, "beta": 1, None: 2}[channel], int(build or 0))


def make_source(repo, channel, releases):
    versions = []
    candidates = [r for r in releases if not r.get("isDraft") and release_key(r) is not None]
    for release in sorted(candidates, key=release_key, reverse=True):
        match = TAG.fullmatch(release["tagName"])
        major, minor, patch, prerelease, build = match.groups()
        if channel == "stable" and (prerelease or release.get("isPrerelease")):
            continue
        if release.get("isPrerelease") and not prerelease:
            continue
        ipa = next((a for a in release["assets"] if a["name"].endswith("-unsigned.ipa")), None)
        if not ipa:
            continue
        entry = {
            "version": f"{major}.{minor}.{patch}",
            "date": release["publishedAt"],
            "localizedDescription": (release.get("body") or "")[:4000],
            "downloadURL": ipa["url"],
            "size": ipa["size"],
            "minOSVersion": "17.0",
        }
        # These must match CFBundleShortVersionString/CFBundleVersion in the IPA.
        # Each alpha/beta has the numeric marketing version plus a unique CI build.
        if prerelease:
            entry["buildVersion"] = build
            entry["localizedDescription"] = f"{prerelease.title()} {release['tagName'][1:]}\n" + entry["localizedDescription"]
        versions.append(entry)
    if not versions:
        raise ValueError(f"No IPA releases found for {channel}")
    testing = channel == "testing"
    raw = f"https://raw.githubusercontent.com/{repo}/main"
    icon = raw + "/SpicyLyrics/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    return {
        "name": "Sweet Lyrics - " + ("Alpha & Beta" if testing else "Stable"),
        "identifier": "com.spicylyrics.unofficial.source" + (".testing" if testing else ""),
        "subtitle": "Alpha, beta and stable builds" if testing else "Stable releases",
        "description": "Sweet Lyrics for iOS: an unofficial port built on Spicy Lyrics. " + ("Testing channel: alpha, beta and stable releases." if testing else "Stable channel."),
        "iconURL": icon,
        "website": f"https://github.com/{repo}",
        "tintColor": "#FF6B9D",
        "apps": [{
            "name": "Sweet Lyrics" + (" (Alpha & Beta)" if testing else ""),
            "bundleIdentifier": "com.spicylyrics.unofficial.ios",
            "developerName": "Sppq",
            "subtitle": "Word-synced lyrics for Spotify",
            "localizedDescription": "Word-by-word synced lyrics for Spotify. Unofficial port built on Spicy Lyrics, not affiliated with it. " + ("Experimental alpha and beta updates." if testing else "Stable updates."),
            "iconURL": icon,
            "tintColor": "#FF6B9D",
            "category": "entertainment",
            "screenshots": [],
            "versions": versions,
            "appPermissions": {"entitlements": [], "privacy": {}},
        }],
        "news": [],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", default="altstore-source.json")
    parser.add_argument("--channel", choices=("stable", "testing"), default="stable")
    args = parser.parse_args()
    repo = os.environ["GH_REPO"]
    releases = github("release", "list", "--repo", repo, "--limit", "200", "--json", "tagName,isDraft,isPrerelease")
    details = []
    for release in releases:
        if release_key(release) is None or release.get("isDraft"):
            continue
        if args.channel == "stable" and (release.get("isPrerelease") or TAG.fullmatch(release["tagName"])[4]):
            continue
        detail = github("release", "view", release["tagName"], "--repo", repo, "--json", "tagName,publishedAt,body,assets,isDraft,isPrerelease")
        details.append(detail)
    source = make_source(repo, args.channel, details)
    Path(args.output).write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {args.output} with {len(source['apps'][0]['versions'])} version(s)")


if __name__ == "__main__":
    main()
