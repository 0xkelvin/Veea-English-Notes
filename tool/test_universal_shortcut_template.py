"""Check the opt-in universal candidate's bindings; device validation is separate."""
import hashlib
import plistlib
from pathlib import Path

directory = Path(__file__).resolve().parents[1] / "assets" / "shortcuts"
workflow = plistlib.loads((directory / "universal-candidate.workflow.plist").read_bytes())
actions = workflow["WFWorkflowActions"]
assert [a["WFWorkflowActionIdentifier"] for a in actions] == [
    "is.workflow.actions.getcurrentapp",
    "is.workflow.actions.number.random",
    "is.workflow.actions.number.random",
    "is.workflow.actions.gettext",
    "com.nintran.veeaEnglishApp.CheckVeeaGateIntent",
    "is.workflow.actions.conditional",
    "is.workflow.actions.openxcallbackurl",
    "is.workflow.actions.openapp",
    "is.workflow.actions.conditional",
]
current, first, second, text, check, condition, callback, opening, end = [
    action["WFWorkflowActionParameters"] for action in actions
]
for number in [first, second]:
    assert number["WFRandomNumberMinimum"] == "0"
    assert number["WFRandomNumberMaximum"] == "2147483647"
assert first["UUID"] != second["UUID"]
payload = text["WFTextActionText"]["Value"]
assert payload["string"] == "veea-universal\n\ufffc-\ufffc\n\ufffc"
assert {v["OutputUUID"] for v in payload["attachmentsByRange"].values()} == {
    first["UUID"], second["UUID"], current["UUID"]
}
descriptor = check["AppIntentDescriptor"]
assert descriptor["BundleIdentifier"] == "com.nintran.veeaEnglishApp"
assert descriptor["TeamIdentifier"] == "9X6SFG9KXM"
assert descriptor["AppIntentIdentifier"] == "CheckVeeaGateIntent"
assert check["targetApp"]["Value"]["attachmentsByRange"]["{0, 1}"]["OutputUUID"] == text["UUID"]
assert condition["WFControlFlowMode"] == 0 and condition["WFCondition"] == 4
assert condition["WFInput"]["Variable"]["Value"]["OutputUUID"] == check["UUID"]
url = callback["WFXCallbackURL"]["Value"]
assert url["string"] == "veea://gate?request=\ufffc-\ufffc"
assert url["attachmentsByRange"]["{20, 1}"]["OutputUUID"] == first["UUID"]
assert url["attachmentsByRange"]["{22, 1}"]["OutputUUID"] == second["UUID"]
# Preserve the App object: no name conversion, fixed app, or guessed URL scheme.
assert opening["WFSelectedApp"]["Value"] == {
    "OutputUUID": current["UUID"], "Type": "ActionOutput", "OutputName": "Current App"
}
assert end["WFControlFlowMode"] == 2
assert condition["GroupingIdentifier"] == end["GroupingIdentifier"]
trigger, = workflow["WFWorkflowTriggers"]
assert trigger["WFTriggerIdentifier"] == "WFAppInFocusTrigger"
assert trigger["WFTriggerSerializedParameters"] == {}, "No preselected personal apps"
questions = workflow["WFWorkflowImportQuestions"]
assert [q["ParameterKey"] for q in questions] == ["WFSelectedApps", "__enabled__"]
assert all(q["Category"] == "Trigger" and q["TriggerUUID"] == trigger["WFTriggerUUID"] for q in questions)
assert "first app" in questions[0]["Text"] and "+" in questions[0]["Text"]
signed = (directory / "universal-candidate.shortcut").read_bytes()
assert signed[:4] == b"AEA1"
assert hashlib.sha256(signed).hexdigest() == (directory / "universal-candidate.shortcut.sha256").read_text().strip()
print("Universal candidate bindings, guarded callback, original App return, setup questions and checksum passed; physical verification remains required")
