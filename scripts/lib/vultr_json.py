#!/usr/bin/env python3
"""Validate Vultr responses before shell scripts use them to change resources."""

from datetime import datetime
from decimal import Decimal, InvalidOperation
import ipaddress
import json
import re
import sys
from urllib.parse import quote
from uuid import UUID


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


def resource_id(value):
    value = text(value, "resource id")
    require(str(UUID(value)) == value, "resource id must be a canonical UUID")
    return value


def number(value, name, nonnegative=False):
    require(type(value) in (str, int, float), f"{name} must be numeric")
    try:
        result = Decimal(str(value))
    except InvalidOperation as error:
        raise ValueError(f"{name} must be numeric") from error
    require(result.is_finite(), f"{name} must be finite")
    require(not nonnegative or result >= 0, f"{name} must not be negative")
    return result


def instance(value):
    value = object_value(value, "instance")
    resource_id(value.get("id"))
    text(value.get("label"), "instance label", allow_empty=True)
    address = text(value.get("main_ip"), "instance IPv4", allow_empty=True)
    if address:
        ipaddress.IPv4Address(address)
    return value


def collection(value, key):
    value = object_value(value, "response")
    require(isinstance(value.get(key), list), f"{key} must be an array")
    seen = set()
    for item in value[key]:
        item = object_value(item, key + " entry")
        identifier = resource_id(item.get("id"))
        require(identifier not in seen, "duplicate resource id in response")
        seen.add(identifier)
        if key == "instances":
            instance(item)
        elif key == "ssh_keys":
            public_key = item.get("ssh_key")
            require(isinstance(public_key, str) and public_key.strip(),
                    "ssh_key must be a nonempty string")
        else:
            raise ValueError("unsupported collection")
    meta = object_value(value.get("meta"), "pagination metadata")
    links = object_value(meta.get("links"), "pagination links")
    text(links.get("next"), "next cursor", allow_empty=True)
    return value


def dump(value):
    print(json.dumps(value, separators=(",", ":"), allow_nan=False))


def main():
    mode, *arguments = sys.argv[1:]
    if mode == "validate-id":
        print(resource_id(arguments[0]))
        return
    if mode == "guard-settings":
        deadline, minimum, now = arguments
        require(bool(re.fullmatch(r"[0-9]+", now)), "current time must be epoch seconds")
        parsed = datetime.fromisoformat(deadline.replace("Z", "+00:00"))
        require(parsed.tzinfo is not None, "deadline must include a timezone")
        print(int(parsed.timestamp()), number(minimum, "credit threshold", True), int(now))
        return
    if mode == "credit-exhausted":
        remaining = number(arguments[0], "remaining credit", True)
        minimum = number(arguments[1], "credit threshold", True)
        print("yes" if remaining <= minimum else "no")
        return
    if mode == "merge":
        key = arguments[0]
        items = []
        for line in sys.stdin:
            items.extend(collection(json.loads(line), key)[key])
        combined = {key: items, "meta": {"links": {"next": ""}}}
        dump(collection(combined, key))
        return

    value = object_value(json.load(sys.stdin), "response")
    if mode == "account":
        account = object_value(value.get("account"), "account")
        balance = number(account.get("balance"), "balance")
        pending = number(account.get("pending_charges"), "pending charges", True)
        print(pending, max(Decimal(0), -balance - pending))
    elif mode == "collection":
        dump(collection(value, arguments[0]))
    elif mode == "cursor":
        page = collection(value, arguments[0])
        print(quote(page["meta"]["links"]["next"], safe=""))
    elif mode == "has-instance":
        identifier = resource_id(arguments[0])
        values = collection(value, "instances")["instances"]
        print("yes" if any(item["id"] == identifier for item in values) else "no")
    elif mode == "id":
        item = object_value(value.get(arguments[0]), arguments[0])
        print(resource_id(item.get("id")))
    elif mode == "instance":
        item = instance(value.get("instance"))
        require(item["id"] == resource_id(arguments[0]), "instance id does not match the request")
        fields = []
        for key in ("status", "power_status", "server_status"):
            field = text(item.get(key), key)
            require(bool(re.fullmatch(r"[a-z_]+", field)), f"invalid {key}")
            fields.append(field)
        print(*fields, item["main_ip"] or "0.0.0.0")
    else:
        raise ValueError("unsupported response operation")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, InvalidOperation, OverflowError) as error:
        print(f"ERROR: Invalid Vultr data: {error}", file=sys.stderr)
        sys.exit(1)
