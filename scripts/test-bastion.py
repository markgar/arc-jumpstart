import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent

FAKE_AZ = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
log = Path(os.environ["FAKE_AZ_LOG"])
calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
with log.open("a") as stream:
    stream.write(json.dumps(args) + "\\n")

def value(flag):
    return args[args.index(flag) + 1] if flag in args else ""

if args[:2] == ["account", "set"] or args[:2] == ["group", "create"]:
    pass
elif args[:2] == ["account", "show"]:
    print("user")
elif args[:3] == ["deployment", "group", "create"]:
    if value("--name") == "arc-jumpstart-20-host-network" and os.environ.get("FAKE_NETWORK_FAIL") == "true":
        print("Mock network stage failed.", file=sys.stderr)
        sys.exit(8)
    if value("--name") == "arc-jumpstart-bastion":
        if "--no-wait" not in args:
            sys.exit("Synchronous Bastion provisioning is forbidden in this test.")
        if os.environ.get("FAKE_BASTION_SUBMIT_FAIL") == "true":
            print("Mock Bastion request rejected.", file=sys.stderr)
            sys.exit(7)
elif args[:3] == ["deployment", "group", "show"]:
    if value("--name") == "arc-jumpstart-bastion":
        sys.exit("The build must not monitor Bastion.")
    elif value("--query") == "properties.outputs.hostSubnetId.value":
        print("/subscriptions/mock/resourceGroups/mock/providers/Microsoft.Network/virtualNetworks/mock-vnet/subnets/snet-host")
    elif value("--query") == "properties.provisioningState":
        print("Succeeded")
    else:
        sys.exit("Unexpected deployment query: " + str(args))
elif args[:3] == ["network", "vnet", "show"]:
    print("Succeeded")
elif args[:2] == ["vm", "show"]:
    sys.exit(1)
elif args[:2] == ["vm", "restart"]:
    pass
elif args[:2] == ["vm", "get-instance-view"]:
    print("PowerState/running" if "PowerState/" in value("--query") else "ProvisioningState/succeeded")
elif args[:3] == ["vm", "run-command", "show"]:
    name = value("--name")
    deployment = {"stage30-images": "arc-jumpstart-30-images", "stage45-sql-install": "arc-jumpstart-45-sql-install"}[name]
    generation = sum(call[:3] == ["deployment", "group", "create"] and deployment in call for call in calls)
    if name == "stage30-images" and generation and os.environ.get("FAKE_IMAGE_FAIL") == "true":
        print("Failed|1|" + str(generation))
        sys.exit(0)
    print("Succeeded|0|" + str(generation))
else:
    sys.exit("Unexpected fake Azure command: " + str(args))
"""


class BastionWrapperTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix=".bastion-test-", dir=ROOT)
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.config = self.path / "mock.env"
        self.log = self.path / "az.jsonl"
        executable = self.path / "az"
        executable.write_text(FAKE_AZ)
        executable.chmod(0o700)
        self.environment = {
            **os.environ,
            "PATH": str(self.path) + os.pathsep + os.environ["PATH"],
            "ENV_FILE": str(self.config),
            "FAKE_AZ_LOG": str(self.log),
        }
        self.environment.pop("DEPLOY_BASTION", None)
        self.write_config()

    def write_config(self, bastion=None, credentials=True):
        values = {
            "AZURE_SUBSCRIPTION_ID": "mock-subscription",
            "AZURE_RESOURCE_GROUP": "mock-rg",
            "AZURE_LOCATION": "eastus2",
            "NAME_PREFIX": "mock",
            "AUTO_SHUTDOWN_ENABLED": "false",
            "AUTO_SHUTDOWN_TIME": "2200",
            "AUTO_SHUTDOWN_TIME_ZONE": "Central Standard Time",
            "PREPARE_ARC_LAUNCHERS": "true",
            "ARC_RESOURCE_GROUP": "mock-arc-rg",
            "ARC_LOCATION": "westus2",
        }
        if credentials:
            values.update({
                "HOST_ADMIN_USERNAME": "mockadmin",
                "HOST_ADMIN_PASSWORD": "Fake-Test-Only123!",
                "NESTED_WINDOWS_PASSWORD": "Fake-Test-Only123!",
                "SAFE_MODE_PASSWORD": "Fake-Test-Only123!",
                "SQL_SERVICE_ACCOUNT_PASSWORD": "Fake-Test-Only123!",
                "SQL_DOWNLOAD_URL": "https://example.invalid/sql.iso",
            })
        if bastion is not None:
            values["DEPLOY_BASTION"] = bastion
        self.config.write_text("".join(f"{key}={value}\n" for key, value in values.items()))
        self.config.chmod(0o600)

    def run_script(self, script, argument):
        return subprocess.run(
            ["bash", str(ROOT / "scripts" / script), argument],
            env=self.environment, capture_output=True, text=True, timeout=15,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def deployments(self):
        return [call for call in self.calls() if call[:3] == ["deployment", "group", "create"]]

    def test_default_build_submits_bastion_independently_and_reaches_stage60(self):
        result = self.run_script("deploy.sh", "all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.deployments()), 11)
        self.assertIn("arc-jumpstart-bastion", self.deployments()[1])
        self.assertIn("--no-wait", self.deployments()[1])
        self.assertIn("arc-jumpstart-auto-shutdown", self.deployments()[3])
        self.assertIn("arc-jumpstart-60-sql-ag", self.deployments()[-2])
        self.assertIn("arc-jumpstart-arc-launchers", self.deployments()[-1])
        self.assertEqual([call for call in self.calls() if "arc-jumpstart-bastion" in call],
                         [self.deployments()[1]])
        self.assertFalse(any(arg.startswith("deployBastion=") for call in self.calls() for arg in call))
        self.assertIn("DEPLOY_BASTION=true", (ROOT / "deploy.env.example").read_text())

    def test_auto_shutdown_requires_explicit_setup_decision(self):
        self.write_config()
        text = self.config.read_text().replace("AUTO_SHUTDOWN_ENABLED=false\n", "")
        self.config.write_text(text)
        result = self.run_script("deploy.sh", "all")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AUTO_SHUTDOWN_ENABLED must be explicitly set", result.stderr)

    def test_auto_shutdown_can_be_updated_without_replaying_host_stage(self):
        self.write_config()
        result = self.run_script("deploy.sh", "auto-shutdown")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.deployments()), 1)
        call = self.deployments()[0]
        self.assertIn("arc-jumpstart-auto-shutdown", call)
        self.assertIn("enabled=false", call)
        self.assertIn("shutdownTime=2200", call)
        self.assertIn("timeZoneId=Central Standard Time", call)

    def test_arc_launchers_can_be_omitted_from_full_build(self):
        self.write_config()
        text = self.config.read_text().replace(
            "PREPARE_ARC_LAUNCHERS=true\n",
            "PREPARE_ARC_LAUNCHERS=false\n",
        )
        self.config.write_text(text)
        result = self.run_script("deploy.sh", "all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("arc-jumpstart-arc-launchers" in call for call in self.deployments()))

    def test_explicit_false_omits_bastion(self):
        self.write_config(bastion="false")
        result = self.run_script("deploy.sh", "00")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.deployments()), 1)

    def test_all_continues_with_bastion_running_or_failed_without_polling(self):
        self.write_config(bastion="true")
        for state in ("Running", "Failed"):
            with self.subTest(state=state):
                self.log.unlink(missing_ok=True)
                self.environment["FAKE_BASTION_STATE"] = state
                result = self.run_script("deploy.sh", "all")
                self.assertEqual(result.returncode, 0, result.stderr)
                deployments = self.deployments()
                self.assertEqual(len(deployments), 11)
                self.assertIn("arc-jumpstart-00-foundation", deployments[0])
                self.assertIn("arc-jumpstart-bastion", deployments[1])
                self.assertIn("--no-wait", deployments[1])
                self.assertIn("arc-jumpstart-10-hyperv-host", deployments[2])
                self.assertIn("arc-jumpstart-60-sql-ag", deployments[-2])
                self.assertIn("arc-jumpstart-arc-launchers", deployments[-1])
                bastion_calls = [call for call in self.calls() if "arc-jumpstart-bastion" in call]
                self.assertEqual(bastion_calls, [deployments[1]])
                self.assertIn("does not monitor or wait", result.stdout)

    def test_rejected_optional_submission_does_not_fail_or_stop_core_build(self):
        self.write_config(bastion="true")
        self.environment["FAKE_BASTION_SUBMIT_FAIL"] = "true"
        result = self.run_script("deploy.sh", "all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("arc-jumpstart-60-sql-ag" in call for call in self.deployments()))
        self.assertIn("arc-jumpstart-arc-launchers", self.deployments()[-1])
        self.assertIn("Mock Bastion request rejected.", result.stderr)
        self.assertIn("WARNING: Optional Bastion submission failed", result.stderr)
        self.assertIn("retry separately", result.stdout)

    def test_on_demand_bastion_needs_no_guest_credentials_or_flag(self):
        self.write_config(credentials=False)
        result = self.run_script("deploy.sh", "bastion")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.deployments()), 1)
        self.assertIn("arc-jumpstart-bastion", self.deployments()[0])
        self.assertIn("--no-wait", self.deployments()[0])
        self.assertIn("Azure will continue provisioning", result.stdout)

    def test_on_demand_submission_failure_returns_failure(self):
        self.write_config(credentials=False)
        self.environment["FAKE_BASTION_SUBMIT_FAIL"] = "true"
        result = self.run_script("deploy.sh", "bastion")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertNotIn("request accepted", result.stdout)

    def test_resuming_host_stage_does_not_submit_or_check_bastion(self):
        self.write_config(bastion="true")
        result = self.run_script("deploy.sh", "10")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.deployments()), 1)
        self.assertFalse(any("arc-jumpstart-bastion" in call for call in self.calls()))

    def test_invalid_flag_fails_before_azure_mutation(self):
        self.write_config(bastion="maybe")
        result = self.run_script("deploy.sh", "all")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("DEPLOY_BASTION must be true or false", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_images_start_before_network_and_join_before_guest_creation(self):
        result = self.run_script("deploy.sh", "all")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        def creation(name):
            return next(index for index, call in enumerate(calls)
                        if call[:3] == ["deployment", "group", "create"] and name in call)
        images = creation("arc-jumpstart-30-images")
        network = creation("arc-jumpstart-20-host-network")
        guests = creation("arc-jumpstart-40-nested-vms")
        self.assertLess(images, network)
        self.assertLess(network, guests)
        waits = [index for index, call in enumerate(calls)
                 if call[:3] == ["vm", "run-command", "show"] and "stage30-images" in call and index > images]
        self.assertTrue(waits)
        self.assertTrue(all(network < index < guests for index in waits))

    def test_parallel_pair_is_available_without_replaying_foundation_or_host(self):
        result = self.run_script("deploy.sh", "20-30")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.deployments()), 2)
        self.assertIn("arc-jumpstart-30-images", self.deployments()[0])
        self.assertIn("arc-jumpstart-20-host-network", self.deployments()[1])
        self.assertNotIn("may outlive this wrapper", result.stderr)

    def test_image_failure_blocks_guest_creation(self):
        self.environment["FAKE_IMAGE_FAIL"] = "true"
        result = self.run_script("deploy.sh", "all")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stage30-images ended in state Failed", result.stderr)
        self.assertFalse(any("arc-jumpstart-40-nested-vms" in call for call in self.calls()))

    def test_network_failure_reports_outstanding_images_and_blocks_guest_creation(self):
        self.environment["FAKE_NETWORK_FAIL"] = "true"
        result = self.run_script("deploy.sh", "all")
        self.assertEqual(result.returncode, 8)
        self.assertIn("Mock network stage failed.", result.stderr)
        self.assertIn("may outlive this wrapper", result.stderr)
        self.assertFalse(any("arc-jumpstart-40-nested-vms" in call for call in self.calls()))


class BastionTemplateTests(unittest.TestCase):
    def compile_template(self, stage):
        result = subprocess.run(
            ["az", "bicep", "build", "--file", str(ROOT / "infra/stages" / stage / "main.bicep"), "--stdout"],
            check=True, capture_output=True, text=True, timeout=60,
        )
        return json.loads(result.stdout)

    def test_foundation_only_deploys_network_and_reserves_access_subnet(self):
        template = self.compile_template("00-foundation")
        network = template["resources"][0]["properties"]["template"]["resources"]
        self.assertEqual({resource["type"] for resource in network}, {
            "Microsoft.Network/networkSecurityGroups", "Microsoft.Network/virtualNetworks",
        })
        vnet = next(resource for resource in network if resource["type"] == "Microsoft.Network/virtualNetworks")
        self.assertEqual({subnet["name"] for subnet in vnet["properties"]["subnets"]},
                         {"snet-host", "AzureBastionSubnet"})

    def test_bastion_does_not_write_the_shared_vnet_or_host(self):
        template = self.compile_template("bastion")
        self.assertEqual({resource["type"] for resource in template["resources"]}, {
            "Microsoft.Network/publicIPAddresses", "Microsoft.Network/bastionHosts",
        })


if __name__ == "__main__":
    unittest.main()
