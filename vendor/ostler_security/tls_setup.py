"""Inter-service TLS – certificate generation and Docker configuration.

Generates a self-signed CA and per-service certificates for encrypted
communication between Docker containers on localhost. This is defence
in depth – the services already bind to localhost, but TLS prevents
any local process from sniffing inter-service traffic.

Services covered:
- Qdrant (:6333, :6334)
- Oxigraph (:7878)
- Redis (:6379)
- Gateway (:8000)
- MCP/REST API (:8080)

Usage:
    python -m ostler_security.tls_setup --output-dir ~/.ostler/tls

This generates:
    ca.key, ca.crt          – self-signed CA (10 year validity)
    server.key, server.crt  – server certificate (signed by CA, 2 year validity)
    client.key, client.crt  – client certificate for mTLS (2 year validity)

All certificates use Ed25519 keys for performance on Apple Silicon.
"""
from __future__ import annotations

import datetime
import logging
import os
from pathlib import Path
from typing import Optional

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.x509.oid import NameOID

logger = logging.getLogger(__name__)

DEFAULT_TLS_DIR = Path.home() / ".ostler" / "tls"

# Certificate validity periods
CA_VALIDITY_DAYS = 3650       # 10 years
SERVER_VALIDITY_DAYS = 730    # 2 years
CLIENT_VALIDITY_DAYS = 730    # 2 years


def _generate_ed25519_key() -> ed25519.Ed25519PrivateKey:
    """Generate an Ed25519 private key."""
    return ed25519.Ed25519PrivateKey.generate()


def _write_key(
    key: ed25519.Ed25519PrivateKey,
    path: Path,
    passphrase: Optional[bytes] = None,
) -> None:
    """Write a private key to a PEM file with restricted permissions.

    If passphrase is provided, the key is encrypted on disk (ATK-4 fix).
    """
    if passphrase:
        enc = serialization.BestAvailableEncryption(passphrase)
    else:
        enc = serialization.NoEncryption()
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=enc,
    )
    path.write_bytes(pem)
    path.chmod(0o600)


def _write_cert(cert: x509.Certificate, path: Path) -> None:
    """Write a certificate to a PEM file."""
    pem = cert.public_bytes(serialization.Encoding.PEM)
    path.write_bytes(pem)


def generate_ca(output_dir: Path) -> tuple:
    """Generate a self-signed Certificate Authority.

    Returns (ca_key, ca_cert) for signing server/client certs.
    """
    ca_key = _generate_ed25519_key()

    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "HK"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Ostler Local CA"),
        x509.NameAttribute(NameOID.COMMON_NAME, "Ostler Root CA"),
    ])

    now = datetime.datetime.now(datetime.timezone.utc)

    ca_cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=CA_VALIDITY_DAYS))
        .add_extension(
            x509.BasicConstraints(ca=True, path_length=0),
            critical=True,
        )
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .sign(ca_key, algorithm=None)  # Ed25519 doesn't use separate hash
    )

    _write_key(ca_key, output_dir / "ca.key")
    _write_cert(ca_cert, output_dir / "ca.crt")
    logger.info("CA certificate generated: %s", output_dir / "ca.crt")

    return ca_key, ca_cert


def generate_server_cert(
    ca_key: ed25519.Ed25519PrivateKey,
    ca_cert: x509.Certificate,
    output_dir: Path,
    hostnames: Optional[list[str]] = None,
) -> None:
    """Generate a server certificate signed by the CA.

    The certificate covers localhost and all specified hostnames.
    """
    if hostnames is None:
        hostnames = ["localhost", "127.0.0.1", "::1"]

    server_key = _generate_ed25519_key()

    subject = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "HK"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Ostler"),
        x509.NameAttribute(NameOID.COMMON_NAME, "Ostler Services"),
    ])

    now = datetime.datetime.now(datetime.timezone.utc)

    # Build SAN entries
    san_entries = []
    for h in hostnames:
        try:
            # Try as IP address
            import ipaddress
            san_entries.append(x509.IPAddress(ipaddress.ip_address(h)))
        except ValueError:
            # It's a hostname
            san_entries.append(x509.DNSName(h))

    server_cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(ca_cert.subject)
        .public_key(server_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=SERVER_VALIDITY_DAYS))
        .add_extension(
            x509.SubjectAlternativeName(san_entries),
            critical=False,
        )
        .add_extension(
            x509.BasicConstraints(ca=False, path_length=None),
            critical=True,
        )
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage([
                x509.oid.ExtendedKeyUsageOID.SERVER_AUTH,
            ]),
            critical=False,
        )
        .sign(ca_key, algorithm=None)
    )

    _write_key(server_key, output_dir / "server.key")
    _write_cert(server_cert, output_dir / "server.crt")
    logger.info("Server certificate generated: %s", output_dir / "server.crt")


def generate_client_cert(
    ca_key: ed25519.Ed25519PrivateKey,
    ca_cert: x509.Certificate,
    output_dir: Path,
    client_name: str = "ostler-client",
) -> None:
    """Generate a client certificate for mTLS, signed by the CA."""
    client_key = _generate_ed25519_key()

    subject = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "HK"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Ostler"),
        x509.NameAttribute(NameOID.COMMON_NAME, client_name),
    ])

    now = datetime.datetime.now(datetime.timezone.utc)

    client_cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(ca_cert.subject)
        .public_key(client_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=CLIENT_VALIDITY_DAYS))
        .add_extension(
            x509.BasicConstraints(ca=False, path_length=None),
            critical=True,
        )
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage([
                x509.oid.ExtendedKeyUsageOID.CLIENT_AUTH,
            ]),
            critical=False,
        )
        .sign(ca_key, algorithm=None)
    )

    _write_key(client_key, output_dir / "client.key")
    _write_cert(client_cert, output_dir / "client.crt")
    logger.info("Client certificate generated: %s", output_dir / "client.crt")


def generate_all(
    output_dir: Optional[Path] = None,
    hostnames: Optional[list[str]] = None,
) -> dict:
    """Generate CA + server + client certificates.

    Returns dict with paths to all generated files.
    """
    output_dir = output_dir or DEFAULT_TLS_DIR
    output_dir.mkdir(parents=True, exist_ok=True)

    # Generate CA
    ca_key, ca_cert = generate_ca(output_dir)

    # Generate server cert (for Docker services)
    all_hosts = ["localhost", "127.0.0.1", "::1"]
    if hostnames:
        all_hosts.extend(hostnames)
    # Add Docker service hostnames. We cover all three prefixes the
    # doctor accepts so a TLS cert generated by any deployment matches
    # the actual container names: `ostler-` (productised CM051 install),
    # `pwg-` (single-mac / dev compose), `lifeline-` (pre-rebrand). See
    # status_collector.OSTLER_CONTAINER_PREFIXES for the canonical list.
    for prefix in ("ostler-", "pwg-", "lifeline-"):
        all_hosts.extend([
            f"{prefix}qdrant",
            f"{prefix}oxigraph",
            f"{prefix}redis",
            f"{prefix}gateway",
        ])
    generate_server_cert(ca_key, ca_cert, output_dir, hostnames=all_hosts)

    # Generate client cert (for mTLS)
    generate_client_cert(ca_key, ca_cert, output_dir)

    files = {
        "ca_key": str(output_dir / "ca.key"),
        "ca_cert": str(output_dir / "ca.crt"),
        "server_key": str(output_dir / "server.key"),
        "server_cert": str(output_dir / "server.crt"),
        "client_key": str(output_dir / "client.key"),
        "client_cert": str(output_dir / "client.crt"),
    }

    logger.info("All TLS certificates generated in %s", output_dir)
    return files


def generate_docker_compose_tls(
    tls_dir: Path,
    output_path: Optional[Path] = None,
) -> str:
    """Generate a Docker Compose override for TLS-enabled services.

    This creates a docker-compose.tls.yml that adds TLS volume
    mounts and environment variables to the base services.
    """
    tls_dir_str = str(tls_dir)

    # BT8-12: validate path doesn't contain YAML-injectable characters
    if any(c in tls_dir_str for c in ('\n', '\r', ':', '{', '}', '[', ']')):
        raise ValueError(
            f"TLS directory path contains invalid characters: {tls_dir_str}"
        )

    # IMPORTANT: environment variables must use CONTAINER paths (/tls/...),
    # not host paths. The volumes: directive maps host→container.
    compose = f"""# Docker Compose TLS override – auto-generated by ostler_security
# Use with: docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
version: "3.8"

services:
  qdrant:
    volumes:
      - {tls_dir_str}/server.crt:/tls/server.crt:ro
      - {tls_dir_str}/server.key:/tls/server.key:ro
      - {tls_dir_str}/ca.crt:/tls/ca.crt:ro
    environment:
      - QDRANT__SERVICE__ENABLE_TLS=true
      - QDRANT__TLS__CERT=/tls/server.crt
      - QDRANT__TLS__KEY=/tls/server.key
      - QDRANT__TLS__CA_CERT=/tls/ca.crt

  redis:
    command: >
      redis-server
      --tls-port 6379
      --port 0
      --tls-cert-file /tls/server.crt
      --tls-key-file /tls/server.key
      --tls-ca-cert-file /tls/ca.crt
    volumes:
      - {tls_dir_str}/server.crt:/tls/server.crt:ro
      - {tls_dir_str}/server.key:/tls/server.key:ro
      - {tls_dir_str}/ca.crt:/tls/ca.crt:ro
"""

    if output_path:
        output_path.write_text(compose)
        logger.info("Docker Compose TLS override written to %s", output_path)

    return compose


# ── CLI ──────────────────────────────────────────────────────────────

def main() -> None:
    """Generate all TLS certificates and Docker Compose override."""
    import argparse

    parser = argparse.ArgumentParser(
        description="Generate TLS certificates for Ostler inter-service encryption"
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default=str(DEFAULT_TLS_DIR),
        help=f"Directory for certificate files (default: {DEFAULT_TLS_DIR})",
    )
    parser.add_argument(
        "--hostnames",
        type=str,
        default="",
        help="Additional hostnames/IPs for the server cert (comma-separated)",
    )
    parser.add_argument(
        "--docker-compose",
        action="store_true",
        help="Also generate docker-compose.tls.yml override",
    )
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)

    output_dir = Path(args.output_dir)
    extra_hosts = [h.strip() for h in args.hostnames.split(",") if h.strip()]

    files = generate_all(output_dir, hostnames=extra_hosts or None)

    print(f"\nTLS certificates generated in {output_dir}:")
    for name, path in files.items():
        print(f"  {name}: {path}")

    if args.docker_compose:
        compose_path = output_dir.parent / "docker-compose.tls.yml"
        generate_docker_compose_tls(output_dir, compose_path)
        print(f"\nDocker Compose TLS override: {compose_path}")
        print("Apply with: docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d")


if __name__ == "__main__":
    main()
