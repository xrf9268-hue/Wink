#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
from urllib.parse import urlparse

def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


def build_object_key(public_base_url: str, object_name: str) -> str:
    parsed = urlparse(public_base_url)
    prefix = parsed.path.lstrip("/").rstrip("/")
    return "/".join(part for part in (prefix, object_name) if part)


def main() -> None:
    parser = argparse.ArgumentParser(description="Upload a file to Cloudflare R2 using S3-compatible auth.")
    parser.add_argument("local_path", help="Local file path to upload")
    parser.add_argument("content_type", help="Content-Type metadata to set on the uploaded object")
    parser.add_argument(
        "--object-name",
        help="Override the destination object name. Defaults to the local file basename.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate inputs and print the destination object without uploading.",
    )
    args = parser.parse_args()

    local_path = Path(args.local_path)
    if not local_path.is_file():
        raise SystemExit(f"File does not exist: {local_path}")

    account_id = require_env("R2_ACCOUNT_ID")
    access_key_id = require_env("R2_ACCESS_KEY_ID")
    secret_access_key = require_env("R2_SECRET_ACCESS_KEY")
    bucket = require_env("R2_BUCKET")
    public_base_url = require_env("R2_PUBLIC_BASE_URL")

    object_name = args.object_name or local_path.name
    object_key = build_object_key(public_base_url, object_name)

    if args.dry_run:
        print(f"Dry run: would upload {local_path} to s3://{bucket}/{object_key} ({args.content_type})")
        return

    import boto3

    client = boto3.client(
        "s3",
        endpoint_url=f"https://{account_id}.r2.cloudflarestorage.com",
        aws_access_key_id=access_key_id,
        aws_secret_access_key=secret_access_key,
        region_name="auto",
    )
    client.upload_file(
        str(local_path),
        bucket,
        object_key,
        ExtraArgs={"ContentType": args.content_type},
    )
    print(f"Uploaded {local_path} to s3://{bucket}/{object_key}")


if __name__ == "__main__":
    main()
