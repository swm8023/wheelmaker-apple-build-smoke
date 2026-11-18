import datetime
import json
import os
import plistlib
import sys
import uuid
from pathlib import Path


APP_BUNDLE = "com.wheelmaker.ios"
WIDGET_BUNDLE = APP_BUNDLE + ".session-activity"


def load_profile(root, filename, team, bundle):
    profile = plistlib.loads((root / filename).read_bytes())
    entitlements = profile["Entitlements"]
    devices = set(profile.get("ProvisionedDevices", []))
    certificates = set(profile.get("DeveloperCertificates", []))
    expires = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
    if (profile.get("TeamIdentifier") != [team]
            or entitlements.get("application-identifier") != f"{team}.{bundle}"
            or entitlements.get("get-task-allow")
            or profile.get("ProvisionsAllDevices")
            or len(devices) < 2
            or not certificates
            or expires <= datetime.datetime.now(datetime.timezone.utc)):
        raise ValueError(f"Expected a current Ad Hoc profile for {bundle} with registered devices")
    profile_id = profile["UUID"]
    if profile_id.upper() != str(uuid.UUID(profile_id)).upper():
        raise ValueError(f"Invalid profile UUID for {bundle}")
    return profile_id, devices, certificates


def prepare(root, team, live):
    app_profile, app_devices, app_certs = load_profile(root, "profile.plist", team, APP_BUNDLE)
    profiles = {APP_BUNDLE: app_profile}
    if live:
        widget_profile, widget_devices, widget_certs = load_profile(root, "widget.plist", team, WIDGET_BUNDLE)
        if app_devices != widget_devices:
            raise ValueError("The app and widget profiles must cover the same devices")
        if not app_certs.intersection(widget_certs):
            raise ValueError("The app and widget profiles must authorize the same distribution certificate")
        profiles[WIDGET_BUNDLE] = widget_profile
    (root / "ExportOptions.plist").write_bytes(plistlib.dumps({
        "method": "release-testing",
        "signingStyle": "manual",
        "signingCertificate": "Apple Distribution",
        "teamID": team,
        "manageAppVersionAndBuildNumber": False,
        "provisioningProfiles": profiles,
    }))
    print(" ".join(profiles.values()))


def verify(root, team, version, live):
    app = root / "ipa/Payload/WheelMaker.app"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    marketing_version = version[1:] + ".0"
    build_number = version[3:]
    if (info.get("CFBundleIdentifier") != APP_BUNDLE
            or info.get("CFBundleShortVersionString") != marketing_version
            or info.get("CFBundleVersion") != build_number
            or sorted(info.get("UIDeviceFamily", [])) != [1, 2]):
        raise ValueError("Signed IPA identity or device families do not match the requested release")
    evidence = {
        "bundleID": APP_BUNDLE,
        "marketingVersion": marketing_version,
        "buildNumber": build_number,
        "deviceFamilies": [1, 2],
        "teamID": team,
    }
    if live:
        widget = app / "PlugIns/WheelMakerSessionActivity.appex"
        widget_info = plistlib.loads((widget / "Info.plist").read_bytes())
        if (info.get("NSSupportsLiveActivities") is not True
                or widget_info.get("CFBundleIdentifier") != WIDGET_BUNDLE
                or widget_info.get("CFBundleShortVersionString") != marketing_version
                or widget_info.get("CFBundleVersion") != build_number
                or widget_info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension"):
            raise ValueError("Signed IPA is missing the expected Live Activity support or widget identity")
        evidence["widgetBundleID"] = WIDGET_BUNDLE
    (root / "evidence.json").write_text(json.dumps(evidence), encoding="utf-8")


if __name__ == "__main__":
    operation, mode = sys.argv[1:]
    if operation not in {"prepare", "verify"} or mode not in {"live", "legacy"}:
        raise SystemExit("Expected prepare or verify and live or legacy")
    workspace = Path(os.environ["WM_WORK"])
    team_id = os.environ["WM_TEAM_ID"]
    if operation == "prepare":
        prepare(workspace, team_id, mode == "live")
    else:
        verify(workspace, team_id, os.environ["WM_VERSION"], mode == "live")
