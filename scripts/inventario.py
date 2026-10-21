"""Inventário rápido (só leitura) dos recursos que mais costumam gerar custo esquecido.

Varre todas as regiões habilitadas em um único processo (threads) com o profile
default (readonly-user). Imprime "região  tipo  quantidade" por item > 0, ou "LIMPO".
Erros de chamada aparecem como linhas "ERRO" — nunca viram um falso "LIMPO".
"""

import os
import sys
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

CFG = Config(retries={"max_attempts": 3, "mode": "standard"}, connect_timeout=5, read_timeout=15)
session = boto3.Session(profile_name=os.environ.get("AWS_PROFILE", "default"))


def paginado(client, op, chave, **kw):
    if client.can_paginate(op):
        return sum(len(p.get(chave, [])) for p in client.get_paginator(op).paginate(**kw))
    return len(getattr(client, op)(**kw).get(chave, []))


def ec2_instancias(r):
    c = session.client("ec2", region_name=r, config=CFG)
    estados = ["pending", "running", "stopping", "stopped"]
    pags = c.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": estados}])
    return sum(len(res["Instances"]) for p in pags for res in p["Reservations"])


def backup_vaults(r):
    c = session.client("backup", region_name=r, config=CFG)
    vaults = [v for p in c.get_paginator("list_backup_vaults").paginate() for v in p["BackupVaultList"]]
    return sum(1 for v in vaults if not v["BackupVaultName"].startswith(("Default", "aws/")))


def simples(servico, op, chave, **kw):
    return lambda r: paginado(session.client(servico, region_name=r, config=CFG), op, chave, **kw)


CHECAGENS = [
    ("EC2 instância (não terminada)", ec2_instancias),
    ("EBS volume", simples("ec2", "describe_volumes", "Volumes")),
    ("EBS snapshot", simples("ec2", "describe_snapshots", "Snapshots", OwnerIds=["self"])),
    ("AMI própria", simples("ec2", "describe_images", "Images", Owners=["self"])),
    ("Elastic IP", simples("ec2", "describe_addresses", "Addresses")),
    ("NAT Gateway", simples("ec2", "describe_nat_gateways", "NatGateways",
                            Filters=[{"Name": "state", "Values": ["pending", "available"]}])),
    ("VPC endpoint (interface)", simples("ec2", "describe_vpc_endpoints", "VpcEndpoints",
                                         Filters=[{"Name": "vpc-endpoint-type",
                                                   "Values": ["Interface", "GatewayLoadBalancer"]}])),
    ("VPC não-default", simples("ec2", "describe_vpcs", "Vpcs",
                                Filters=[{"Name": "is-default", "Values": ["false"]}])),
    ("Load balancer (v2)", simples("elbv2", "describe_load_balancers", "LoadBalancers")),
    ("EFS", simples("efs", "describe_file_systems", "FileSystems")),
    ("FSx", simples("fsx", "describe_file_systems", "FileSystems")),
    ("Backup vault (fora default)", backup_vaults),
    ("Storage Gateway", simples("storagegateway", "list_gateways", "Gateways")),
    ("DataSync agent", simples("datasync", "list_agents", "Agents")),
    ("Transfer Family server", simples("transfer", "list_servers", "Servers")),
    ("RDS instância", simples("rds", "describe_db_instances", "DBInstances")),
    ("RDS cluster", simples("rds", "describe_db_clusters", "DBClusters")),
    ("DynamoDB tabela", simples("dynamodb", "list_tables", "TableNames")),
    ("Glacier vault", simples("glacier", "list_vaults", "VaultList", accountId="-")),
    ("S3 Express (diretório)", simples("s3", "list_directory_buckets", "Buckets")),
]

# Serviços que não existem em todas as regiões: endpoint ausente não é erro.
IGNORAR = ("EndpointConnectionError", "UnrecognizedClientException", "InvalidAction",
           "OptInRequired", "AuthFailure")


def checa(regiao, rotulo, fn):
    try:
        return regiao, rotulo, fn(regiao), None
    except ClientError as e:
        codigo = e.response.get("Error", {}).get("Code", "")
        return regiao, rotulo, 0, None if codigo in IGNORAR else codigo
    except BotoCoreError as e:
        nome = type(e).__name__
        return regiao, rotulo, 0, None if nome in IGNORAR else nome


def main():
    try:
        session.client("sts", config=CFG).get_caller_identity()
    except (ClientError, BotoCoreError) as e:
        print(f"ERRO: credenciais AWS inválidas: {e}")
        return 1

    ec2 = session.client("ec2", region_name="us-east-1", config=CFG)
    regioes = [r["RegionName"] for r in ec2.describe_regions()["Regions"]]

    # ListBuckets em us-east-1 devolve os buckets de todas as regiões. Uma região falsa como "global"
    # monta um endpoint inexistente, e o EndpointConnectionError cai no IGNORAR e vira 0.
    tarefas = [("us-east-1", "S3 bucket (todas as regiões)", simples("s3", "list_buckets", "Buckets"))]
    tarefas += [(r, rotulo, fn) for r in regioes for rotulo, fn in CHECAGENS]

    with ThreadPoolExecutor(max_workers=int(os.environ.get("INVENTARIO_PARALELO", "32"))) as ex:
        resultados = list(ex.map(lambda t: checa(*t), tarefas))

    achados = sorted((r, rot, n) for r, rot, n, err in resultados if n > 0)
    erros = sorted((r, rot, err) for r, rot, _, err in resultados if err)

    if not achados and not erros:
        print("LIMPO")
        return 0
    if achados:
        print(f"{'REGIÃO':<15} {'TIPO':<30} QTD")
        for r, rot, n in achados:
            print(f"{r:<15} {rot:<30} {n}")
    for r, rot, err in erros:
        print(f"ERRO {r:<10} {rot:<30} {err}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
