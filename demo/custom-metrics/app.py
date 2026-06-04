"""
Demo: Publishing custom metrics via Container Insights OTLP endpoint.

The endpoint is configured entirely via the standard OTEL_EXPORTER_OTLP_ENDPOINT
env var in the pod spec — zero endpoint configuration in code. The collector
automatically enriches metrics with pod, namespace, workload, node, cluster,
and cloud attributes.
"""

import os
import time
import random

import grpc
from opentelemetry import metrics
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.resources import Resource

resource = Resource.create({
    "service.name": "order-service",
    "service.version": "1.2.0",
})

ca_cert_path = os.environ.get("OTEL_EXPORTER_OTLP_CERTIFICATE", "")
client_cert_path = os.environ.get("OTEL_EXPORTER_OTLP_CLIENT_CERTIFICATE", "")
client_key_path = os.environ.get("OTEL_EXPORTER_OTLP_CLIENT_KEY", "")

if client_cert_path and client_key_path:
    ca_cert = open(ca_cert_path, "rb").read() if ca_cert_path else None
    client_cert = open(client_cert_path, "rb").read()
    client_key = open(client_key_path, "rb").read()
    credentials = grpc.ssl_channel_credentials(
        root_certificates=ca_cert,
        private_key=client_key,
        certificate_chain=client_cert,
    )
    exporter = OTLPMetricExporter(credentials=credentials)
elif os.environ.get("OTEL_EXPORTER_OTLP_INSECURE", "").lower() == "true":
    exporter = OTLPMetricExporter(insecure=True)
else:
    exporter = OTLPMetricExporter()

reader = PeriodicExportingMetricReader(exporter, export_interval_millis=10_000)
provider = MeterProvider(resource=resource, metric_readers=[reader])
metrics.set_meter_provider(provider)

meter = metrics.get_meter("order-service", "1.2.0")

# --- Define application metrics ---
orders_processed = meter.create_counter(
    name="orders.processed_total",
    description="Total number of orders processed",
    unit="1",
)

order_value = meter.create_histogram(
    name="orders.value_dollars",
    description="Dollar value of each order",
    unit="USD",
)

active_carts = meter.create_up_down_counter(
    name="carts.active",
    description="Number of currently active shopping carts",
    unit="1",
)

# --- Simulate order processing ---
endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "(not set)")
print(f"Sending custom metrics to {endpoint} every 10s...")
print("Metrics will appear in CloudWatch with full k8s + cloud enrichment.")

regions = ["us-east", "us-west", "eu-west"]
tiers = ["standard", "premium", "enterprise"]

while True:
    region = random.choice(regions)
    tier = random.choice(tiers)

    orders_processed.add(1, {"order.region": region, "order.tier": tier})
    order_value.record(
        random.uniform(10.0, 500.0),
        {"order.region": region, "order.tier": tier},
    )
    active_carts.add(random.choice([-1, 1]), {"order.region": region})

    time.sleep(2)
