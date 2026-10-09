"""Selection must preserve reverse dependencies and reject incomplete evidence."""
import importlib.util
import copy
import json
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ci_test_targets", ROOT / "scripts/ci-test-targets.py")
targets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(targets)


def plan(paths, lane="fast"):
    value = targets.load_policy().make_plan("pull_request", {
        "action": "opened", "pull_request": {"labels": [], "user": {"login": "fixture"}}
    }, paths)
    value["lane"] = lane
    return value


class TestTargetsTests(unittest.TestCase):
    def manifest_fixture(self):
        value = targets.graph()
        model = {"targets": [], "products": []}
        for name, deps in value["dependencies"].items():
            target = {"name": name, "type": "test" if name in value["testTargets"] else "regular",
                      "dependencies": [{"byName": [dep, None]} for dep in deps]}
            if name in value["supportTargets"]:
                target["path"] = "Tests/" + name
            model["targets"].append(target)
        model["products"] = [{"name": name, "targets": [name]}
                             for name in value["sourceTargets"] if name != "InnoFlowMacros"]
        inventory = json.loads((ROOT / "docs/contracts/swift-test-inventory.json").read_text())
        return value, model, inventory

    def test_manifest_support_modules_are_not_test_dependencies_or_shipping_products(self):
        value, model, inventory = self.manifest_fixture()
        targets.verify_manifest(value, model, inventory)
        support = value["supportTargets"][0]
        for kind in ("test", "executable"):
            invalid = copy.deepcopy(model)
            next(item for item in invalid["targets"] if item["name"] == support)["type"] = kind
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                targets.verify_manifest(value, invalid, inventory)
        invalid = copy.deepcopy(model)
        next(item for item in invalid["targets"] if item["name"] == support)["path"] = "Sources/" + support
        with self.assertRaises(ValueError):
            targets.verify_manifest(value, invalid, inventory)
        invalid = copy.deepcopy(model)
        invalid["products"][0]["targets"].append(support)
        with self.assertRaises(ValueError):
            targets.verify_manifest(value, invalid, inventory)

    def test_manifest_rejects_test_target_dependencies_and_incomplete_inventory(self):
        value, model, inventory = self.manifest_fixture()
        invalid_value, invalid_model = copy.deepcopy(value), copy.deepcopy(model)
        name, dependency = "InnoFlowCoreTestSupport", "InnoFlowCoreTests"
        invalid_value["dependencies"][name].append(dependency)
        next(item for item in invalid_model["targets"] if item["name"] == name)["dependencies"].append(
            {"byName": [dependency, None]})
        with self.assertRaisesRegex(ValueError, "depend on test targets"):
            targets.verify_manifest(invalid_value, invalid_model, inventory)
        invalid_inventory = copy.deepcopy(inventory)
        invalid_inventory["hostTargets"].remove(name)
        with self.assertRaises(ValueError):
            targets.verify_manifest(value, model, invalid_inventory)
        invalid_inventory = copy.deepcopy(inventory)
        invalid_inventory["tests"][0]["target"] = name
        with self.assertRaises(ValueError):
            targets.verify_manifest(value, model, invalid_inventory)

    def test_inspector_excludes_unrelated_test_targets_and_products(self):
        chosen = targets.selection(plan(["Sources/InnoFlowInspector/Graph.swift"]))
        self.assertEqual(chosen["testTargets"], ["InnoFlowInspectorTests"])
        self.assertEqual(targets.closure(chosen["testTargets"], targets.graph()),
                         ["InnoFlowCore", "InnoFlowInspector", "InnoFlowInspectorTests"])

    def test_swiftui_and_testing_keep_cross_product_contracts(self):
        self.assertEqual(targets.selection(plan(["Sources/InnoFlowSwiftUI/Binding.swift"]))["testTargets"],
                         ["InnoFlowSwiftUIIntegrationTests", "InnoFlowSwiftUITests", "InnoFlowTests"])
        self.assertEqual(targets.selection(plan(["Sources/InnoFlowTesting/TestStore.swift"]))["testTargets"],
                         ["InnoFlowSwiftUIIntegrationTests", "InnoFlowTestingTests", "InnoFlowTests"])

    def test_shared_unknown_mixed_and_non_source_changes_are_full(self):
        for paths in ([], ["Package.swift"], ["Package.resolved"], ["Sources/InnoFlowCore/Store.swift"],
                      ["Sources/InnoFlowMacros/Macro.swift"], ["Sources/InnoFlow/Exports.swift"],
                      ["Tests/InnoFlowCoreTestSupport/CoreFixtures.swift"], ["Sources/InnoFlowSwiftUI/README.md"],
                      ["Sources/InnoFlowInspector/Graph.swift", "README.md"],
                      ["Sources/InnoFlowSwiftUI/Binding.swift", "Sources/InnoFlowTesting/TestStore.swift"]):
            with self.subTest(paths=paths):
                self.assertEqual(targets.selection(plan(paths))["mode"], "full")

    def test_main_release_and_unreviewed_manifest_are_full(self):
        for lane in ("full", "release-validation"):
            self.assertEqual(targets.selection(plan(["Sources/InnoFlowInspector/Graph.swift"], lane))["mode"], "full")
        with tempfile.TemporaryDirectory() as temporary:
            self.assertEqual(targets.selection(plan(["Sources/InnoFlowInspector/Graph.swift"]), Path(temporary))["mode"], "full")

    def test_invalid_plan_and_unknown_target_cannot_select(self):
        value = plan(["Sources/InnoFlowInspector/Graph.swift"])
        value["jobs"]["tests"] = False
        with self.assertRaises(ValueError):
            targets.selection(value)
        for selected in ([], ["InnoFlowInspector"], ["UnknownTests"]):
            with self.subTest(selected=selected), self.assertRaises(ValueError):
                targets.closure(selected, targets.graph())


if __name__ == "__main__":
    unittest.main()
