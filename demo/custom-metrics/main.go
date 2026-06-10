package main

import (
	"context"
	"fmt"
	"math/rand"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/metric"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
)

func main() {
	ctx := context.Background()

	res, _ := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName("order-service"),
			semconv.ServiceVersion("1.2.0"),
		),
	)

	exporter, err := otlpmetricgrpc.New(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create exporter: %v\n", err)
		os.Exit(1)
	}

	provider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter, sdkmetric.WithInterval(10*time.Second))),
	)
	otel.SetMeterProvider(provider)

	meter := provider.Meter("order-service", metric.WithInstrumentationVersion("1.2.0"))

	ordersProcessed, _ := meter.Int64Counter("orders.processed_total",
		metric.WithDescription("Total number of orders processed"),
		metric.WithUnit("1"),
	)
	orderValue, _ := meter.Float64Histogram("orders.value_dollars",
		metric.WithDescription("Dollar value of each order"),
		metric.WithUnit("USD"),
	)
	activeCarts, _ := meter.Int64UpDownCounter("carts.active",
		metric.WithDescription("Number of currently active shopping carts"),
		metric.WithUnit("1"),
	)

	endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	fmt.Printf("Sending custom metrics to %s every 10s...\n", endpoint)
	fmt.Println("Metrics will appear in CloudWatch with full k8s + cloud enrichment.")

	regions := []string{"us-east", "us-west", "eu-west"}
	tiers := []string{"standard", "premium", "enterprise"}

	for {
		region := regions[rand.Intn(len(regions))]
		tier := tiers[rand.Intn(len(tiers))]

		ordersProcessed.Add(ctx, 1,
			metric.WithAttributes(
				attribute.String("order.region", region),
				attribute.String("order.tier", tier),
			),
		)
		orderValue.Record(ctx, 10.0+rand.Float64()*490.0,
			metric.WithAttributes(
				attribute.String("order.region", region),
				attribute.String("order.tier", tier),
			),
		)
		cartDelta := int64(1)
		if rand.Intn(2) == 0 {
			cartDelta = -1
		}
		activeCarts.Add(ctx, cartDelta,
			metric.WithAttributes(
				attribute.String("order.region", region),
			),
		)

		time.Sleep(2 * time.Second)
	}
}
