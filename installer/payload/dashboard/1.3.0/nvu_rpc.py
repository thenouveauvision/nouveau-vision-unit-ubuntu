import os
import re
from pathlib import Path
from urllib.parse import urlunparse

import requests


class NVURPCError(RuntimeError):
    pass


_REQUIRED_CREDENTIAL_FIELDS = {
    "RPC_HOST",
    "RPC_PORT",
    "RPC_USER",
    "RPC_PASSWORD",
    "RPC_DATADIR",
    "RPC_CONFIG",
}

_ALLOWED_CREDENTIAL_FIELDS = frozenset(
    _REQUIRED_CREDENTIAL_FIELDS
)

_ENV_OVERRIDES = {
    "RPC_HOST": "NVUN_RPC_HOST",
    "RPC_PORT": "NVUN_RPC_PORT",
    "RPC_USER": "NVUN_RPC_USER",
    "RPC_PASSWORD": "NVUN_RPC_PASSWORD",
    "RPC_DATADIR": "NVUN_DATADIR",
    "RPC_CONFIG": "NVUN_CONFIG",
}

_FIELD_PATTERN = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*$"
)


def _decode_env_value(raw_value, line_number):
    value = raw_value.strip()

    if not value:
        return ""

    if value[0] not in {"'", '"'}:
        return value

    quote = value[0]

    if len(value) < 2 or value[-1] != quote:
        raise NVURPCError(
            "Malformed quoted value in RPC credential "
            f"record at line {line_number}"
        )

    value = value[1:-1]

    if quote == "'":
        return value

    result = []
    escaped = False

    escape_map = {
        "n": "\n",
        "r": "\r",
        "t": "\t",
        "\\": "\\",
        '"': '"',
    }

    for character in value:
        if escaped:
            result.append(
                escape_map.get(
                    character,
                    character,
                )
            )
            escaped = False
            continue

        if character == "\\":
            escaped = True
            continue

        result.append(character)

    if escaped:
        result.append("\\")

    return "".join(result)


def load_rpc_credential_record(path):
    record_path = Path(path)

    if not record_path.is_file():
        raise NVURPCError(
            "RPC credential record not found: "
            f"{record_path}"
        )

    try:
        lines = record_path.read_text(
            encoding="utf-8"
        ).splitlines()

    except OSError as exc:
        raise NVURPCError(
            "Unable to read RPC credential record: "
            f"{record_path}"
        ) from exc

    values = {}

    for line_number, raw_line in enumerate(
        lines,
        start=1,
    ):
        line = raw_line.strip()

        if not line or line.startswith("#"):
            continue

        if line.startswith("export "):
            line = line[7:].lstrip()

        if "=" not in line:
            raise NVURPCError(
                "Malformed RPC credential record "
                f"at line {line_number}"
            )

        field, raw_value = line.split(
            "=",
            1,
        )

        field = field.strip()

        if not _FIELD_PATTERN.fullmatch(field):
            raise NVURPCError(
                "Invalid field name in RPC credential "
                f"record at line {line_number}"
            )

        if field not in _ALLOWED_CREDENTIAL_FIELDS:
            raise NVURPCError(
                "Unsupported field in RPC credential "
                f"record: {field}"
            )

        if field in values:
            raise NVURPCError(
                "Duplicate field in RPC credential "
                f"record: {field}"
            )

        values[field] = _decode_env_value(
            raw_value,
            line_number,
        )

    missing = sorted(
        _REQUIRED_CREDENTIAL_FIELDS
        - values.keys()
    )

    if missing:
        raise NVURPCError(
            "RPC credential record is missing "
            "required fields: "
            + ", ".join(missing)
        )

    empty = sorted(
        field
        for field in _REQUIRED_CREDENTIAL_FIELDS
        if not values[field]
    )

    if empty:
        raise NVURPCError(
            "RPC credential record contains empty "
            "required fields: "
            + ", ".join(empty)
        )

    return values


def apply_rpc_environment_overrides(values):
    result = dict(values)

    for field, environment_name in (
        _ENV_OVERRIDES.items()
    ):
        override = os.getenv(
            environment_name
        )

        if override is None:
            continue

        override = override.strip()

        if not override:
            raise NVURPCError(
                "RPC environment override is empty: "
                f"{environment_name}"
            )

        result[field] = override

    return result


def validate_rpc_configuration(values):
    host = values["RPC_HOST"].strip()

    try:
        port = int(
            values["RPC_PORT"]
        )

    except (TypeError, ValueError) as exc:
        raise NVURPCError(
            "RPC_PORT must be an integer"
        ) from exc

    if port < 1 or port > 65535:
        raise NVURPCError(
            "RPC_PORT must be between 1 and 65535"
        )

    if any(
        character in host
        for character in (
            "/",
            "\\",
            "@",
            " ",
            "\t",
            "\r",
            "\n",
        )
    ):
        raise NVURPCError(
            "RPC_HOST contains invalid characters"
        )

    username = values[
        "RPC_USER"
    ].strip()

    password = values[
        "RPC_PASSWORD"
    ]

    if not username:
        raise NVURPCError(
            "RPC_USER is empty"
        )

    if not password:
        raise NVURPCError(
            "RPC_PASSWORD is empty"
        )

    data_directory = Path(
        values["RPC_DATADIR"]
    )

    config_path = Path(
        values["RPC_CONFIG"]
    )

    return {
        "host": host,
        "port": port,
        "username": username,
        "password": password,
        "data_directory": data_directory,
        "config_path": config_path,
    }


class NVURPC:
    def __init__(
        self,
        credential_record=None,
        *,
        require_native_paths=True,
    ):
        record_path = Path(
            credential_record
            or os.getenv(
                "NVUN_RPC_CREDENTIAL_FILE",
                "/etc/nvu/credentials/"
                "rpc-client.env",
            )
        )

        record = load_rpc_credential_record(
            record_path
        )

        record = apply_rpc_environment_overrides(
            record
        )

        configuration = validate_rpc_configuration(
            record
        )

        self.credential_record = record_path
        self.host = configuration["host"]
        self.port = configuration["port"]
        self.username = configuration[
            "username"
        ]
        self.password = configuration[
            "password"
        ]
        self.data_directory = configuration[
            "data_directory"
        ]
        self.config_path = configuration[
            "config_path"
        ]

        if require_native_paths:
            if not self.data_directory.is_dir():
                raise NVURPCError(
                    "NVUN data directory not found: "
                    f"{self.data_directory}"
                )

            if not self.config_path.is_file():
                raise NVURPCError(
                    "NVUN configuration not found: "
                    f"{self.config_path}"
                )

        self.url = urlunparse(
            (
                "http",
                f"{self.host}:{self.port}",
                "/",
                "",
                "",
                "",
            )
        )

        self.session = requests.Session()
        self.session.auth = (
            self.username,
            self.password,
        )

    def call(self, method, params=None):
        payload = {
            "jsonrpc": "1.0",
            "id": "nvu-dashboard",
            "method": method,
            "params": params or [],
        }

        try:
            response = self.session.post(
                self.url,
                json=payload,
                timeout=10,
            )
            response.raise_for_status()

        except requests.RequestException as exc:
            raise NVURPCError(
                "Unable to contact NVUN RPC"
            ) from exc

        try:
            data = response.json()

        except ValueError as exc:
            raise NVURPCError(
                "NVUN returned an invalid JSON response"
            ) from exc

        if not isinstance(data, dict):
            raise NVURPCError(
                "NVUN returned an invalid RPC envelope"
            )

        if data.get("error"):
            error = data["error"]

            if isinstance(error, dict):
                code = error.get(
                    "code",
                    "unknown",
                )
                message = error.get(
                    "message",
                    "unknown RPC error",
                )

                raise NVURPCError(
                    "NVUN RPC error "
                    f"{code}: {message}"
                )

            raise NVURPCError(
                "NVUN RPC returned an error"
            )

        if "result" not in data:
            raise NVURPCError(
                "NVUN RPC response has no result field"
            )

        return data["result"]

    def blockchain_info(self):
        return self.call(
            "getblockchaininfo"
        )

    def network_info(self):
        return self.call(
            "getnetworkinfo"
        )

    def peer_info(self):
        return self.call(
            "getpeerinfo"
        )

    def best_block_hash(self):
        return self.call(
            "getbestblockhash"
        )

    def block_count(self):
        return self.call(
            "getblockcount"
        )

    def uptime(self):
        return self.call(
            "uptime"
        )

    def list_wallets(self):
        return self.call(
            "listwallets"
        )

    def wallet_info(self):
        return self.call(
            "getwalletinfo"
        )

    def wallet_transactions(
        self,
        count=10,
        skip=0,
        include_watchonly=True,
    ):
        return self.call(
            "listtransactions",
            [
                "*",
                int(count),
                int(skip),
                bool(include_watchonly),
            ],
        )

    def received_addresses(
        self,
        min_confirmations=0,
        include_empty=True,
        include_watchonly=True,
    ):
        return self.call(
            "listreceivedbyaddress",
            [
                int(min_confirmations),
                bool(include_empty),
                bool(include_watchonly),
            ],
        )

    def difficulty(self):
        return self.call(
            "getdifficulty"
        )

    def network_hashrate(self):
        return self.call(
            "getnetworkhashps"
        )

    def block_hash(self, height):
        return self.call(
            "getblockhash",
            [
                int(height)
            ],
        )

    def block(
        self,
        block_hash,
        verbosity=2,
    ):
        return self.call(
            "getblock",
            [
                block_hash,
                verbosity,
            ],
        )

    def raw_transaction(
        self,
        txid,
        verbose=True,
    ):
        return self.call(
            "getrawtransaction",
            [
                txid,
                verbose,
            ],
        )
