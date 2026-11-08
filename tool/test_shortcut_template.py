"""Validate the exported X workflow and Apple-signed package."""
import hashlib
import plistlib
from pathlib import Path

directory = Path(__file__).resolve().parents[1] / "assets" / "shortcuts"
workflow = plistlib.loads((directory / "x.workflow.plist").read_bytes())
actions = workflow["WFWorkflowActions"]
assert [a["WFWorkflowActionIdentifier"] for a in actions] == [
    "com.nintran.veeaEnglishApp.CheckVeeaGateIntent",
    "is.workflow.actions.conditional",
    "is.workflow.actions.openurl",
    "is.workflow.actions.conditional",
]
check, condition, opening, end = [a["WFWorkflowActionParameters"] for a in actions]
descriptor = check["AppIntentDescriptor"]
assert descriptor["BundleIdentifier"] == "com.nintran.veeaEnglishApp"
assert descriptor["AppIntentIdentifier"] == "CheckVeeaGateIntent"
assert descriptor["TeamIdentifier"] == "9X6SFG9KXM"
assert check.get("targetApp", "X") == "X"
assert condition["WFControlFlowMode"] == 0 and condition["WFCondition"] == 4
assert condition["WFInput"]["Variable"]["Value"]["OutputUUID"] == check["UUID"]
assert opening["WFInput"] == "veea://gate?app=X"
assert end["WFControlFlowMode"] == 2
assert condition["GroupingIdentifier"] == end["GroupingIdentifier"]
triggers = workflow["WFWorkflowTriggers"]
assert len(triggers) == 1 and triggers[0]["WFTriggerIdentifier"] == "WFAppInFocusTrigger"
assert triggers[0]["WFTriggerSerializedParameters"]["WFSelectedApps"]["BundleIdentifier"] == "com.atebits.Tweetie2"
signed = (directory / "x.shortcut").read_bytes()
assert signed[:4] == b"AEA1", "Expected Apple's signed shortcut package"
expected = (directory / "x.shortcut.sha256").read_text().strip()
assert hashlib.sha256(signed).hexdigest() == expected
print("X export: correct app/intent, guarded handoff, app trigger, signed package checksum")
