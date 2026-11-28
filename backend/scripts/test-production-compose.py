#!/usr/bin/env python3
"""Validate the production Make/Compose models with synthetic configuration."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

BACKEND = Path(__file__).resolve().parents[1]
SYNTHETIC_ENV = """VEEA_PROD_IMAGE=veea-backend:compose-test
VEEA_PROD_DB_ADMIN_PASSWORD=aaaaaaaa
VEEA_PROD_MIGRATION_PASSWORD=bbbbbbbb
VEEA_PROD_API_PASSWORD=cccccccc
VEEA_PROD_MAINTENANCE_PASSWORD=dddddddd
VEEA_EMAIL_FROM=synthetic@example.test
VEEA_RESEND_API_KEY=synthetic
VEEA_EMAIL_HMAC_KEY=synthetic
VEEA_OTP_KEY=synthetic
VEEA_OUTBOX_KEY=synthetic
"""


def main():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        key = root / "synthetic.p8"
        key.write_text("synthetic fixture\n")
        env_file = root / "compose.env"
        env_file.write_text(SYNTHETIC_ENV + f"VEEA_APPLE_IAP_KEY_HOST_FILE={key}\n")
        inspect = root / "Inspect.mk"
        inspect.write_text("inspect-model:\n\t@$(PROD_COMPOSE) config --format json\n")
        make = ["make", "-s", "-C", str(BACKEND), "-f", "Makefile", "-f", str(inspect),
                f"PROD_ENV_FILE={env_file}"]
        clean_env = {"PATH": os.environ["PATH"]}

        for ingress in (None, "camera", "host"):
            for use_secret in (False, True):
                args = make + ([f"PROD_INGRESS={ingress}"] if ingress else [])
                if use_secret:
                    args += ["PROD_IAP_DOCKER_SECRET=true"]
                subprocess.run(args + ["backend-prod-config"], env=clean_env, check=True)
                model = json.loads(subprocess.check_output(args + ["inspect-model"], env=clean_env))
                api = model["services"]["api"]
                assert "default" in api["networks"]
                assert any(str(p["published"]) == "28386" and p["target"] == 18386 and p["host_ip"] == "127.0.0.1"
                           for p in api["ports"])
                for service in ("postgres", "migrate", "permissions"):
                    assert set(model["services"][service]["networks"]) == {"default"}
                if ingress == "host":
                    assert set(model["networks"]) == {"default"}
                else:
                    assert model["networks"]["veea-camera"]["name"] == "veea-camera_default"
                    assert model["networks"]["veea-camera"]["external"]
                    assert "veea-production-api" in api["networks"]["veea-camera"]["aliases"]
                env = api["environment"]
                assert env["VEEA_APPLE_IAP_ENABLED"] == env["VEEA_APPLE_IAP_ALLOW_SANDBOX"] == "false"
                if use_secret:
                    assert env["VEEA_APPLE_IAP_PRIVATE_KEY_FILE"] == "/run/secrets/veea_apple_iap_key"
                    assert [secret["source"] for secret in api["secrets"]] == ["veea_apple_iap_key"]
                    assert model["secrets"]["veea_apple_iap_key"]["file"] == str(key)
                else:
                    assert not api.get("secrets") and not env["VEEA_APPLE_IAP_PRIVATE_KEY_FILE"]
                print(f"{ingress or 'default camera'}, secret={use_secret}: passed")

        bad = subprocess.run(make + ["PROD_INGRESS=unknown", "backend-prod-config"],
                             env=clean_env, capture_output=True, text=True)
        assert bad.returncode and "PROD_INGRESS must be camera or host" in bad.stderr
        bad = subprocess.run(make + ["PROD_IAP_DOCKER_SECRET=yes", "backend-prod-config"],
                             env=clean_env, capture_output=True, text=True)
        assert bad.returncode and "PROD_IAP_DOCKER_SECRET must be true or false" in bad.stderr


if __name__ == "__main__":
    main()
