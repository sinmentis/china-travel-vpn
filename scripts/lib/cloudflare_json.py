#!/usr/bin/env python3
"""Validate Cloudflare responses before shell scripts act on them."""

import base64
import json
import re
import sys

HOSTNAME = re.compile(r"[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?")
CERTIFICATE_BLOCK = re.compile(
    r"-----BEGIN CERTIFICATE-----\n([A-Za-z0-9+/=\n]+?)\n?-----END CERTIFICATE-----"
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def object_value(value, name):
    require(isinstance(value, dict), f"{name} must be an object")
    return value


def text(value, name, allow_empty=False):
    require(isinstance(value, str), f"{name} must be a string")
    require(allow_empty or bool(value), f"{name} must not be empty")
    require(not any(ord(char) < 32 or ord(char) == 127 for char in value),
            f"{name} contains control characters")
    return value


def hostname(value):
    value = text(value, "hostname")
    require(len(value) <= 253, "hostname is too long")
    labels = value.split(".")
    require(len(labels) >= 2, "hostname must be fully qualified")
    for label in labels:
        require(HOSTNAME.fullmatch(label), f"invalid hostname label: {label}")
    return value


def identifier(value):
    value = text(value, "resource id")
    require(re.fullmatch(r"[0-9a-f]{32}", value), "resource id must be a Cloudflare hex id")
    return value


def envelope(value):
    """Unwrap the {success, errors, result} response Cloudflare returns."""
    value = object_value(value, "response")
    require(value.get("success") is True, describe_errors(value))
    return value.get("result")


def describe_errors(value):
    errors = value.get("errors")
    if isinstance(errors, list) and errors:
        parts = []
        for item in errors:
            if isinstance(item, dict):
                message = item.get("message")
                code = item.get("code")
                if isinstance(message, str):
                    parts.append(f"{message} (code {code})" if code else message)
        if parts:
            return "Cloudflare rejected the request: " + "; ".join(parts)
    return "Cloudflare reported the request as unsuccessful"


def certificate(value):
    """Accept only a PEM chain whose blocks decode as base64 DER."""
    require(isinstance(value, str) and value, "certificate must be a nonempty string")
    require(not any(ord(char) < 32 and char not in "\r\n" for char in value),
            "certificate contains control characters")
    blocks = CERTIFICATE_BLOCK.findall(value)
    require(blocks, "certificate is not PEM encoded")
    for block in blocks:
        body = "".join(block.split())
        try:
            decoded = base64.b64decode(body, validate=True)
        except (ValueError, base64.binascii.Error) as error:
            raise ValueError("certificate is not valid base64") from error
        require(len(decoded) > 64, "certificate block is too short to be a certificate")
        require(decoded[0] == 0x30, "certificate block is not DER encoded")
    return value


def main():
    mode, *arguments = sys.argv[1:]
    if mode == "validate-hostname":
        print(hostname(arguments[0]))
        return
    if mode == "zone-suffixes":
        labels = hostname(arguments[0]).split(".")
        for index in range(len(labels) - 1):
            print(".".join(labels[index:]))
        return

    result = envelope(json.load(sys.stdin))
    if mode == "zone-id":
        require(isinstance(result, list), "zone listing must be an array")
        expected = hostname(arguments[0])
        matches = [item for item in result
                   if object_value(item, "zone").get("name") == expected]
        require(len(matches) <= 1, f"more than one Cloudflare zone is named {expected}")
        print(identifier(matches[0]["id"]) if matches else "")
    elif mode == "record-id":
        require(isinstance(result, list), "record listing must be an array")
        expected = hostname(arguments[0])
        matches = [item for item in result
                   if object_value(item, "record").get("name") == expected
                   and item.get("type") == "A"]
        require(len(matches) <= 1, f"more than one A record exists for {expected}")
        print(identifier(matches[0]["id"]) if matches else "")
    elif mode == "record-applied":
        record = object_value(result, "record")
        require(record.get("type") == "A", "record is not an A record")
        require(record.get("name") == hostname(arguments[0]), "record name does not match")
        require(record.get("content") == arguments[1], "record does not point at the server")
        require(record.get("proxied") is True, "record is not proxied through Cloudflare")
        print(identifier(record.get("id")))
    elif mode == "certificate":
        record = object_value(result, "certificate")
        print(identifier(record.get("id")))
        print(json.dumps(certificate(record.get("certificate"))))
    else:
        raise ValueError("unsupported response operation")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError) as error:
        print(f"ERROR: Invalid Cloudflare data: {error}", file=sys.stderr)
        sys.exit(1)
