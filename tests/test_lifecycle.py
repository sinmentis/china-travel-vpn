import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTANCE_ID = "00000000-0000-4000-8000-000000000001"
INSTANCE = {
    "id": INSTANCE_ID,
    "label": "personal-vpn-primary",
    "main_ip": "192.0.2.1",
    "status": "active",
    "power_status": "running",
    "server_status": "ok",
    "region": "itm",
    "plan": "vc2-1c-1gb",
    "os_id": 2284,
}


def collection(items, cursor=""):
    return {"instances": items, "meta": {"links": {"next": cursor}}}


CURL_STUB = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
from urllib.parse import parse_qs, urlsplit

arguments = sys.argv[1:]
url = next(argument for argument in arguments if argument.startswith(("http://", "https://")))
if not url.startswith(("http://release-check.invalid/v2/", "https://target.example/")):
    raise SystemExit("Unexpected endpoint in isolated test")
method = arguments[arguments.index("-X") + 1] if "-X" in arguments else "GET"
with Path(os.environ["TEST_REQUESTS"]).open("a") as output:
    output.write(json.dumps({"method": method, "url": url, "arguments": arguments}) + "\n")
path = urlsplit(url).path
scenario = os.environ.get("TEST_SCENARIO", "existing")
instance_file = Path(os.environ["TEST_INSTANCES"])
created = Path(os.environ["HOME"]) / "created"
polled = Path(os.environ["HOME"]) / "polled"
started = Path(os.environ["HOME"]) / "started"
status = int(os.environ.get("TEST_HTTP_STATUS", "200"))
body = ""
if url.startswith("https://target.example/"):
    status = 200
elif path == "/v2/account":
    body = Path(os.environ["TEST_ACCOUNT"]).read_text()
elif path == "/v2/ssh-keys":
    key = {
        "id": "00000000-0000-4000-8000-000000000002",
        "ssh_key": os.environ.get("TEST_PUBLIC_KEY", ""),
    }
    if method == "POST":
        status = 201
        body = json.dumps({"ssh_key": key})
    else:
        keys = [] if os.environ.get("TEST_NEW_KEY") == "1" else [key]
        body = json.dumps({"ssh_keys": keys, "meta": {"links": {"next": ""}}})
elif path == "/v2/instances" and method == "POST":
    created.touch()
    status = 201
    body = json.dumps({"instance": {"id": "00000000-0000-4000-8000-000000000001"}})
elif path == "/v2/instances":
    if scenario == "fresh" and not created.exists():
        body = json.dumps({"instances": [], "meta": {"links": {"next": ""}}})
    elif os.environ.get("TEST_PAGES"):
        pages = json.loads(Path(os.environ["TEST_PAGES"]).read_text())
        cursor = parse_qs(urlsplit(url).query).get("cursor", [""])[0]
        body = json.dumps(pages[cursor])
    else:
        body = instance_file.read_text()
elif path.endswith("/start"):
    status = 409 if scenario == "fresh" else 204
    if status == 204:
        started.touch()
elif method == "DELETE":
    status = int(os.environ.get("TEST_DELETE_STATUS", "204"))
    if status in (204, 404) and os.environ.get("TEST_KEEP_INSTANCE") != "1":
        data = json.loads(instance_file.read_text())
        identifier = path.rsplit("/", 1)[-1]
        data["instances"] = [item for item in data["instances"] if item["id"] != identifier]
        if os.environ.get("TEST_REPLACEMENT_AFTER_DELETE"):
            data["instances"].append(json.loads(os.environ["TEST_REPLACEMENT_AFTER_DELETE"]))
        body_after = "<html>upstream error</html>" if os.environ.get("TEST_CORRUPT_AFTER_DELETE") else json.dumps(data)
        instance_file.write_text(body_after)
elif path.startswith("/v2/instances/"):
    item = json.loads(instance_file.read_text())["instances"][0]
    if scenario == "fresh" and not polled.exists():
        item.update(power_status="stopped", server_status="locked")
        polled.touch()
    elif scenario == "stopped" and not started.exists():
        item.update(power_status="stopped", server_status="ok")
    body = json.dumps({"instance": item})
else:
    raise SystemExit("Unexpected API operation")
output_option = next((option for option in ("-o", "--output") if option in arguments), None)
if output_option is None:
    sys.stdout.write(body)
else:
    output_path = arguments[arguments.index(output_option) + 1]
    if output_path != "/dev/null":
        Path(output_path).write_text(body)
for option in ("-w", "--write-out"):
    if option in arguments:
        sys.stdout.write(arguments[arguments.index(option) + 1].replace("%{http_code}", str(status)))
if status >= 400 and ("--fail-with-body" in arguments or "--fail" in arguments):
    raise SystemExit(22)
"""

SSH_STUB = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
payload = sys.stdin.read() if not sys.stdin.isatty() else ""
with Path(os.environ["TEST_SSH_REQUESTS"]).open("a") as output:
    output.write(json.dumps({"arguments": arguments, "payload": payload}) + "\n")
command = " ".join(arguments)
boot = Path(os.environ["HOME"]) / "booted"
if "sudo whoami" in command:
    print("root")
elif "cat /proc/sys/kernel/random/boot_id" in command:
    print("after-boot" if boot.exists() else "before-boot")
elif "systemd-run" in command:
    boot.touch()
elif "config_path = Path" in payload:
    print(os.environ.get("TEST_EXISTING_CONFIG", "yes"))
elif 'keys="$(xray x25519)"' in payload:
    print("A" * 43)
    print("B" * 43)
    print("11111111-2222-4333-8444-555555555555")
    print("0123456789abcdef")
elif "install -m 600 /dev/stdin" in command and payload.startswith("{"):
    json.loads(payload)
"""


class ScriptSandbox(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="china-travel-vpn-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        shutil.copytree(ROOT / "scripts", self.root / "scripts")
        (self.root / "bin").mkdir()
        (self.root / "home").mkdir()
        curl = self.root / "bin" / "curl"
        curl.write_text(CURL_STUB)
        curl.chmod(0o700)

        self.env_file = self.root / ".env.vultr"
        self.original_env = (
            "VULTR_API_KEY=fixture\n"
            "VULTR_INSTANCE_LABEL=personal-vpn-primary\n"
            f"VULTR_INSTANCE_ID={INSTANCE_ID}\n"
            "PRIMARY_IP=192.0.2.1\n"
            "VPN_UUID=11111111-2222-4333-8444-555555555555\n"
        )
        self.env_file.write_text(self.original_env)
        self.env_file.chmod(0o600)
        self.imports = [
            self.root / "primary-ios.local.txt",
            self.root / "primary-ios.local.png",
        ]
        for path in self.imports:
            path.write_bytes(b"test fixture")
        self.account = self.root / "account.json"
        self.account.write_text(json.dumps({
            "account": {"balance": -300, "pending_charges": 1},
        }))
        self.instances = self.root / "instances.json"
        self.instances.write_text(json.dumps(collection([INSTANCE])))
        self.requests = self.root / "requests.jsonl"
        self.state = self.root / "state"
        self.state.mkdir()
        (self.state / "status").write_text("previous real run\n")
        self.environment = {
            "PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
            "HOME": str(self.root / "home"),
            "ENV_FILE": str(self.env_file),
            "VULTR_API": "http://release-check.invalid/v2",
            "VULTR_API_KEY": "fixture",
            "CREDIT_GUARD_API": "http://release-check.invalid/v2",
            "CREDIT_GUARD_DEADLINE": "2000-01-01T00:00:00Z",
            "CREDIT_GUARD_DRY_RUN": "1",
            "CREDIT_GUARD_STATE_DIR": str(self.state),
            "TEST_ACCOUNT": str(self.account),
            "TEST_INSTANCES": str(self.instances),
            "TEST_REQUESTS": str(self.requests),
        }
        self.assertEqual(
            shutil.which("curl", path=self.environment["PATH"]), str(curl)
        )

    def run_script(self, name, *arguments):
        return subprocess.run(
            ["bash", str(self.root / "scripts" / name), *arguments],
            env=self.environment,
            cwd=self.root,
            capture_output=True,
            text=True,
            input="",
            timeout=10,
        )

    def assert_local_files_untouched(self):
        self.assertEqual(self.env_file.read_text(), self.original_env)
        for path in self.imports:
            self.assertEqual(path.read_bytes(), b"test fixture")

    def assert_no_deletes(self):
        if self.requests.exists():
            calls = [json.loads(line) for line in self.requests.read_text().splitlines()]
            self.assertFalse(any(call["method"] == "DELETE" for call in calls))

    def calls(self):
        if not self.requests.exists():
            return []
        return [json.loads(line) for line in self.requests.read_text().splitlines()]


class LifecycleTests(ScriptSandbox):
    def test_existing_instance_dry_run_preserves_local_files(self):
        result = self.run_script("bring-down.sh", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY_RUN", result.stdout + result.stderr)
        self.assert_local_files_untouched()
        self.assert_no_deletes()

    def test_absent_instance_dry_run_preserves_local_files(self):
        self.instances.write_text(json.dumps(collection([])))
        result = self.run_script("bring-down.sh", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_local_files_untouched()
        self.assert_no_deletes()

    def test_teardown_rejects_invalid_json(self):
        self.instances.write_text("<html>upstream error</html>")
        result = self.run_script("bring-down.sh", "--yes")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_local_files_untouched()
        self.assert_no_deletes()

    def test_teardown_rejects_missing_instance_list(self):
        self.instances.write_text('{"error":"unexpected response"}')
        result = self.run_script("bring-down.sh", "--yes")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_local_files_untouched()
        self.assert_no_deletes()

    def test_guard_valid_response_is_a_safe_preview(self):
        result = self.run_script("vultr-credit-guard.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("would_destroy=personal-vpn-primary", result.stdout + result.stderr)
        self.assert_no_deletes()

    def test_guard_rejects_invalid_json_in_preview(self):
        self.instances.write_text("<html>upstream error</html>")
        result = self.run_script("vultr-credit-guard.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assert_no_deletes()

    def test_guard_preview_does_not_replace_real_status(self):
        result = self.run_script("vultr-credit-guard.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.state / "status").read_text(), "previous real run\n")

    def test_successful_teardown_keeps_reusable_credentials(self):
        result = self.run_script("bring-down.sh", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = self.env_file.read_text()
        self.assertNotIn("VULTR_INSTANCE_ID=", saved)
        self.assertNotIn("PRIMARY_IP=", saved)
        self.assertIn("VPN_UUID=", saved)
        self.assertIn("VULTR_API_KEY=", saved)
        self.assertTrue(all(not path.exists() for path in self.imports))
        self.assertEqual(sum(call["method"] == "DELETE" for call in self.calls()), 1)

    def test_delete_failure_preserves_local_files(self):
        self.environment["TEST_DELETE_STATUS"] = "500"
        result = self.run_script("bring-down.sh", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assert_local_files_untouched()

    def test_invalid_resource_fields_are_rejected(self):
        for field, value in (("id", "../other"), ("label", None), ("main_ip", "not-an-ip")):
            with self.subTest(field=field):
                item = dict(INSTANCE)
                item[field] = value
                self.instances.write_text(json.dumps(collection([item])))
                result = self.run_script("bring-down.sh", "--yes")
                self.assertNotEqual(result.returncode, 0)
                self.assert_local_files_untouched()
                self.assert_no_deletes()

    def test_invalid_account_values_are_rejected(self):
        self.environment["CREDIT_GUARD_DEADLINE"] = "2100-01-01T00:00:00Z"
        for balance, pending in (("NaN", 1), ("Infinity", 1), (-300, -1), (False, 1)):
            with self.subTest(balance=balance, pending=pending):
                self.account.write_text(json.dumps({
                    "account": {"balance": balance, "pending_charges": pending},
                }))
                result = self.run_script("vultr-credit-guard.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_deletes()

    def test_guard_rejects_invalid_settings_before_api_calls(self):
        for name, value in (("CREDIT_GUARD_MIN_REMAINING", "NaN"),
                            ("CREDIT_GUARD_DEADLINE", "2000-01-01"),
                            ("CREDIT_GUARD_NOW_EPOCH", "not-a-number"),
                            ("CREDIT_GUARD_DRY_RUN", "maybe"),
                            ("CREDIT_GUARD_LABEL_PREFIX", "production-")):
            with self.subTest(name=name):
                original = dict(self.environment)
                self.environment[name] = value
                result = self.run_script("vultr-credit-guard.sh")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])
                self.environment = original

    def test_guard_failure_updates_real_status(self):
        self.environment["CREDIT_GUARD_DRY_RUN"] = "0"
        self.environment["TEST_HTTP_STATUS"] = "401"
        result = self.run_script("vultr-credit-guard.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ERROR", (self.state / "status").read_text())
        self.assert_no_deletes()

    def test_guard_removes_only_managed_instances(self):
        self.environment["CREDIT_GUARD_DRY_RUN"] = "0"
        other = dict(INSTANCE, id="00000000-0000-4000-8000-000000000003", label="unrelated")
        self.instances.write_text(json.dumps(collection([INSTANCE, other])))
        result = self.run_script("vultr-credit-guard.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.instances.read_text())["instances"], [other])
        self.assertIn("DESTROYED", (self.state / "status").read_text())

    def test_pagination_finds_target_after_first_page(self):
        other = dict(INSTANCE, id="00000000-0000-4000-8000-000000000003", label="unrelated")
        pages = self.root / "pages.json"
        pages.write_text(json.dumps({
            "": collection([other], "next+/="),
            "next+/=": collection([INSTANCE]),
        }))
        self.environment["TEST_PAGES"] = str(pages)
        result = self.run_script("bring-down.sh", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DRY_RUN", result.stdout + result.stderr)
        self.assertEqual(len(self.calls()), 2)
        self.assert_local_files_untouched()

    def test_repeated_pagination_cursor_fails(self):
        self.instances.write_text(json.dumps(collection([INSTANCE], "repeat")))
        result = self.run_script("bring-down.sh", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_deletes()

    def test_api_calls_have_timeouts(self):
        result = self.run_script("bring-down.sh", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        for call in self.calls():
            self.assertIn("--connect-timeout", call["arguments"])
            self.assertIn("--max-time", call["arguments"])

    def test_delete_success_is_confirmed_by_id_not_label(self):
        replacement = dict(INSTANCE, id="00000000-0000-4000-8000-000000000003")
        self.environment["TEST_REPLACEMENT_AFTER_DELETE"] = json.dumps(replacement)
        result = self.run_script("bring-down.sh", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.instances.read_text())["instances"], [replacement])

    def test_failed_delete_confirmation_preserves_local_files(self):
        self.environment["TEST_CORRUPT_AFTER_DELETE"] = "1"
        result = self.run_script("bring-down.sh", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assert_local_files_untouched()

    def test_guard_stops_at_credit_threshold(self):
        self.environment["CREDIT_GUARD_DRY_RUN"] = "0"
        self.environment["CREDIT_GUARD_DEADLINE"] = "2100-01-01T00:00:00Z"
        self.account.write_text('{"account":{"balance":-1,"pending_charges":0}}')
        result = self.run_script("vultr-credit-guard.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reason=credit", (self.state / "status").read_text())
        self.assertEqual(json.loads(self.instances.read_text())["instances"], [])

    def test_expired_deadline_does_not_depend_on_account_data(self):
        self.environment["CREDIT_GUARD_DRY_RUN"] = "0"
        self.account.write_text("<html>account endpoint unavailable</html>")
        result = self.run_script("vultr-credit-guard.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reason=deadline", (self.state / "status").read_text())
        self.assertFalse(any(call["url"].endswith("/account") for call in self.calls()))

    def test_real_guard_rejects_a_simulated_clock(self):
        self.environment["CREDIT_GUARD_DRY_RUN"] = "0"
        self.environment["CREDIT_GUARD_NOW_EPOCH"] = "2000000000"
        result = self.run_script("vultr-credit-guard.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_guard_does_not_list_instances_before_a_trigger(self):
        self.environment["CREDIT_GUARD_DRY_RUN"] = "0"
        self.environment["CREDIT_GUARD_DEADLINE"] = "2100-01-01T00:00:00Z"
        result = self.run_script("vultr-credit-guard.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertTrue(self.calls()[0]["url"].endswith("/account"))
        self.assertIn(" OK ", (self.state / "status").read_text())

    def test_missing_guard_key_does_not_leave_stale_success(self):
        self.environment["CREDIT_GUARD_DRY_RUN"] = "0"
        self.environment.pop("VULTR_API_KEY")
        result = self.run_script("vultr-credit-guard.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ERROR", (self.state / "status").read_text())
        self.assertEqual(self.calls(), [])

    def test_renamed_instance_does_not_clear_saved_state(self):
        self.instances.write_text(json.dumps(collection([dict(INSTANCE, label="unrelated")])))
        result = self.run_script("bring-down.sh", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assert_local_files_untouched()
        self.assert_no_deletes()

    def test_duplicate_labels_are_not_deleted(self):
        duplicate = dict(INSTANCE, id="00000000-0000-4000-8000-000000000003")
        self.instances.write_text(json.dumps(collection([INSTANCE, duplicate])))
        result = self.run_script("bring-down.sh", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assert_local_files_untouched()
        self.assert_no_deletes()

    def test_dry_run_does_not_create_lock_files(self):
        result = self.run_script("bring-down.sh", "--dry-run", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(str(self.env_file) + ".lock").exists())
        self.assert_local_files_untouched()

    def test_http_error_is_not_treated_as_an_empty_account(self):
        self.environment["TEST_HTTP_STATUS"] = "401"
        result = self.run_script("bring-down.sh", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assert_local_files_untouched()
        self.assert_no_deletes()


class BringUpTests(ScriptSandbox):
    def setUp(self):
        super().setUp()
        self.key = self.root / "home" / "travel_ed25519"
        self.public_key = "ssh-ed25519 AAAA fixture"
        self.key.write_text("fixture private key")
        self.key.chmod(0o600)
        self.key.with_suffix(".pub").write_text(self.public_key)
        self.original_env += (
            f"SSH_KEY_PATH={self.key}\n"
            "SSH_KEY_PASSPHRASE=fixture\n"
            "REALITY_TARGET=target.example\n"
            f"REALITY_PRIVATE_KEY={'A' * 43}\n"
            f"REALITY_PUBLIC_KEY={'B' * 43}\n"
            "REALITY_SHORT_ID=0123456789abcdef\n"
        )
        self.env_file.write_text(self.original_env)
        self.environment.update({
            "TEST_PUBLIC_KEY": self.public_key,
            "TEST_SSH_REQUESTS": str(self.root / "ssh.jsonl"),
            "BRING_UP_SKIP_CLIENT_TEST": "1",
            "BRING_UP_SKIP_REBOOT": "1",
        })
        for name, contents in {
            "openssl": "#!/bin/sh\nif [ \"$1\" = rand ]; then printf 'fixture-passphrase\\n'; else printf 'TLSv1.3\\nALPN protocol: h2\\nVerify return code: 0 (ok)\\n'; fi\n",
            "ssh-agent": "#!/bin/sh\nprintf 'SSH_AGENT_PID=424242; export SSH_AGENT_PID;\\n'\n",
            "ssh-add": "#!/bin/sh\nexit 0\n",
            "ssh": SSH_STUB,
            "sleep": "#!/bin/sh\nexit 0\n",
        }.items():
            path = self.root / "bin" / name
            path.write_text(contents)
            path.chmod(0o700)

    def test_verify_only_preserves_state_and_imports(self):
        result = self.run_script("bring-up.sh", "--verify-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_local_files_untouched()
        self.assertTrue(all(call["method"] == "GET" for call in self.calls()))

    def test_verify_only_does_not_create_missing_env(self):
        self.env_file.unlink()
        result = self.run_script("bring-up.sh", "--verify-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.env_file.exists())

    def test_verify_only_does_not_start_stopped_instance(self):
        self.environment["TEST_SCENARIO"] = "stopped"
        result = self.run_script("bring-up.sh", "--verify-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(call["method"] == "GET" for call in self.calls()))
        self.assert_local_files_untouched()

    def test_new_instance_waits_out_provisioning_lock(self):
        self.environment["TEST_SCENARIO"] = "fresh"
        result = self.run_script("bring-up.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("READY", result.stdout)
        self.assertFalse(any(call["url"].endswith("/start") for call in self.calls()))

    def test_fresh_account_generates_key_and_credentials(self):
        self.key.unlink()
        self.key.with_suffix(".pub").unlink()
        self.env_file.write_text(
            f"VULTR_API_KEY=fixture\nREALITY_TARGET=target.example\nSSH_KEY_PATH={self.key}\n"
        )
        self.environment["TEST_SCENARIO"] = "fresh"
        self.environment["TEST_NEW_KEY"] = "1"
        result = self.run_script("bring-up.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.key.exists())
        self.assertIn("REALITY_PRIVATE_KEY=", self.env_file.read_text())
        self.assertTrue(any(call["method"] == "POST" and call["url"].endswith("/ssh-keys")
                            for call in self.calls()))
        self.assertTrue(all(path.exists() for path in self.imports[:1]))

    def test_partial_credentials_fail_before_api_access(self):
        self.env_file.write_text("\n".join(
            line for line in self.original_env.splitlines()
            if not line.startswith("REALITY_PUBLIC_KEY=")
        ) + "\n")
        result = self.run_script("bring-up.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_existing_config_is_not_overwritten_without_credentials(self):
        self.env_file.write_text("\n".join(
            line for line in self.original_env.splitlines()
            if not line.startswith(("REALITY_PRIVATE_KEY=", "REALITY_PUBLIC_KEY=",
                                    "REALITY_SHORT_ID=", "VPN_UUID="))
        ) + "\n")
        result = self.run_script("bring-up.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Existing VLESS configuration found", result.stderr)
        ssh_calls = [json.loads(line) for line in (self.root / "ssh.jsonl").read_text().splitlines()]
        self.assertFalse(any("apt-get" in call["payload"] for call in ssh_calls))

    def test_verification_can_export_only_when_requested(self):
        result = self.run_script("bring-up.sh", "--verify-only", "--export-client")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.env_file.read_text(), self.original_env)
        self.assertTrue(self.imports[0].read_text().startswith("vless://"))
        self.assertTrue(all(call["method"] == "GET" for call in self.calls()))

    def test_existing_stopped_instance_is_started_once(self):
        self.environment["TEST_SCENARIO"] = "stopped"
        result = self.run_script("bring-up.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        starts = [call for call in self.calls() if call["url"].endswith("/start")]
        self.assertEqual(len(starts), 1)

    def test_reboot_waits_for_new_boot_id(self):
        self.environment["BRING_UP_SKIP_REBOOT"] = "0"
        result = self.run_script("bring-up.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "home" / "booted").exists())

    def test_remote_scripts_parse_and_ops_is_checked_before_ssh_changes(self):
        result = self.run_script("bring-up.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [json.loads(line) for line in (self.root / "ssh.jsonl").read_text().splitlines()]
        ops_check = next(index for index, call in enumerate(calls)
                         if "sudo whoami" in " ".join(call["arguments"]))
        policy_change = next(index for index, call in enumerate(calls)
                             if "/etc/ssh/sshd_config.d/00-personal-vpn.conf" in call["payload"])
        self.assertLess(ops_check, policy_change)
        for call in calls:
            if "bash -se" in " ".join(call["arguments"]):
                parsed = subprocess.run(
                    ["bash", "-n"], input=call["payload"], text=True, capture_output=True
                )
                self.assertEqual(parsed.returncode, 0, parsed.stderr)
        for request in self.calls():
            if request["method"] == "POST":
                self.assertNotIn("--retry", request["arguments"])

    def test_verify_only_does_not_generate_a_missing_key(self):
        self.key.unlink()
        result = self.run_script("bring-up.sh", "--verify-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.key.exists())
        self.assert_local_files_untouched()

    def test_shell_metacharacters_in_target_are_rejected(self):
        self.env_file.write_text(self.original_env.replace(
            "REALITY_TARGET=target.example", "REALITY_TARGET='target.example;touch unwanted'"
        ))
        result = self.run_script("bring-up.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
