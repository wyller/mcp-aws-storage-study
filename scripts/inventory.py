"""Quick (read-only) inventory of the resources that most often cause forgotten costs.

Scans every enabled region in a single process (threads) with the default profile
(readonly-user). Prints "region  type  count" for each item > 0, or "CLEAN".
Call errors show up as "ERROR" lines — they never turn into a false "CLEAN".
"""

import os
import sys
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

CFG = Config(retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=5, read_timeout=15)
session = boto3.Session(profile_name=os.environ.get("AWS_PROFILE", "default"))


def paginated(client, op, key, **kw):
    if client.can_paginate(op):
        return sum(len(p.get(key, [])) for p in client.get_paginator(op).paginate(**kw))
    return len(getattr(client, op)(**kw).get(key, []))


def ec2_instances(r):
    c = session.client("ec2", region_name=r, config=CFG)
    states = ["pending", "running", "stopping", "stopped"]
    pages = c.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": states}])
    return sum(len(res["Instances"]) for p in pages for res in p["Reservations"])


def backup_vaults(r):
    c = session.client("backup", region_name=r, config=CFG)
    vaults = [v for p in c.get_paginator("list_backup_vaults").paginate() for v in p["BackupVaultList"]]
    return sum(1 for v in vaults if not v["BackupVaultName"].startswith(("Default", "aws/")))


def simple(service, op, key, **kw):
    return lambda r: paginated(session.client(service, region_name=r, config=CFG), op, key, **kw)


CHECKS = [
    ("EC2 instance (not terminated)", ec2_instances),
    ("EBS volume", simple("ec2", "describe_volumes", "Volumes")),
    ("EBS snapshot", simple("ec2", "describe_snapshots", "Snapshots", OwnerIds=["self"])),
    ("Own AMI", simple("ec2", "describe_images", "Images", Owners=["self"])),
    ("Elastic IP", simple("ec2", "describe_addresses", "Addresses")),
    ("NAT Gateway", simple("ec2", "describe_nat_gateways", "NatGateways",
                           Filters=[{"Name": "state", "Values": ["pending", "available"]}])),
    ("VPC endpoint (interface)", simple("ec2", "describe_vpc_endpoints", "VpcEndpoints",
                                        Filters=[{"Name": "vpc-endpoint-type",
                                                  "Values": ["Interface", "GatewayLoadBalancer"]}])),
    ("Non-default VPC", simple("ec2", "describe_vpcs", "Vpcs",
                               Filters=[{"Name": "is-default", "Values": ["false"]}])),
    ("Load balancer (v2)", simple("elbv2", "describe_load_balancers", "LoadBalancers")),
    ("EFS", simple("efs", "describe_file_systems", "FileSystems")),
    ("FSx", simple("fsx", "describe_file_systems", "FileSystems")),
    ("Backup vault (non-default)", backup_vaults),
    ("Storage Gateway", simple("storagegateway", "list_gateways", "Gateways")),
    ("DataSync agent", simple("datasync", "list_agents", "Agents")),
    ("Transfer Family server", simple("transfer", "list_servers", "Servers")),
    ("RDS instance", simple("rds", "describe_db_instances", "DBInstances")),
    ("RDS cluster", simple("rds", "describe_db_clusters", "DBClusters")),
    ("DynamoDB table", simple("dynamodb", "list_tables", "TableNames")),
    ("Glacier vault", simple("glacier", "list_vaults", "VaultList", accountId="-")),
    ("S3 Express (directory)", simple("s3", "list_directory_buckets", "Buckets")),
]

# Services that don't exist in every region: a missing endpoint is not an error.
IGNORE = ("EndpointConnectionError", "UnrecognizedClientException", "InvalidAction",
          "OptInRequired", "AuthFailure")


def check(region, label, fn):
    try:
        return region, label, fn(region), None
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        return region, label, 0, None if code in IGNORE else code
    except BotoCoreError as e:
        name = type(e).__name__
        return region, label, 0, None if name in IGNORE else name


def main():
    try:
        session.client("sts", config=CFG).get_caller_identity()
    except (ClientError, BotoCoreError) as e:
        print(f"ERROR: invalid AWS credentials: {e}")
        return 1

    ec2 = session.client("ec2", region_name="us-east-1", config=CFG)
    regions = [r["RegionName"] for r in ec2.describe_regions()["Regions"]]

    # ListBuckets from us-east-1 returns buckets in every region. A fake region like "global"
    # builds a nonexistent endpoint whose EndpointConnectionError IGNORE would swallow as 0.
    tasks = [("us-east-1", "S3 bucket (all regions)", simple("s3", "list_buckets", "Buckets"))]
    tasks += [(r, label, fn) for r in regions for label, fn in CHECKS]

    with ThreadPoolExecutor(max_workers=int(os.environ.get("INVENTORY_PARALLEL", "32"))) as ex:
        results = list(ex.map(lambda t: check(*t), tasks))

    findings = sorted((r, label, n) for r, label, n, err in results if n > 0)
    errors = sorted((r, label, err) for r, label, _, err in results if err)

    if not findings and not errors:
        print("CLEAN")
        return 0
    if findings:
        print(f"{'REGION':<15} {'TYPE':<30} COUNT")
        for r, label, n in findings:
            print(f"{r:<15} {label:<30} {n}")
    for r, label, err in errors:
        print(f"ERROR {r:<10} {label:<30} {err}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
